import Foundation
import Combine

/// Возможные пути подключения к устройству
public enum CandidatePath: Equatable, Sendable {
    case usb(deviceId: String, localPort: UInt16)
    case lan(host: String, port: UInt16, isV6: Bool)
    
    public var displayString: String {
        switch self {
        case .usb(let id, let port):
            return "USB (\(id):\(port))"
        case .lan(let host, let port, let isV6):
            return isV6 ? "Wi-Fi IPv6 (\(host):\(port))" : "Wi-Fi (\(host):\(port))"
        }
    }
    
    public var host: String {
        switch self {
        case .usb: return "127.0.0.1"
        case .lan(let h, _, _): return h
        }
    }
    
    public var port: UInt16 {
        switch self {
        case .usb(_, let p): return p
        case .lan(_, let p, _): return p
        }
    }
}

/// Состояния жизненного цикла соединения
public enum ConnectionPhase: Equatable, Sendable {
    case disconnected(reason: String?)
    case discovering
    case connecting(attemptId: UUID, target: String)
    case connected(path: CandidatePath, deviceName: String)
    case authFailed(reason: String)
}

/// Единый контроллер соединения MacDroid Commander (Слой 3: Сессия и Транспорт)
@MainActor
public final class ConnectionController: ObservableObject {
    public static let shared = ConnectionController()
    
    @Published public private(set) var phase: ConnectionPhase = .disconnected(reason: nil)
    @Published public private(set) var currentPath: CandidatePath? = nil
    @Published public private(set) var currentDeviceName: String = ""
    
    @Published public private(set) var isManualDisconnectSuppressed: Bool = false
    
    private var activeAttemptId: UUID? = nil
    
    public init() {}
    
    /// Проверка, разрешено ли автоподключение для данного устройства с учетом подавления после ручного отключения
    public func shouldAttemptAutoConnect(for deviceId: String?) -> Bool {
        guard !isManualDisconnectSuppressed else { return false }
        guard let id = deviceId, let dev = DeviceRegistry.shared.device(withId: id) else { return false }
        return dev.autoConnect
    }
    
    /// Запуск намеренного подключения (вызывается строго по интенту пользователя или по явному флагу автоподключения)
    public func connect(
        customHost: String? = nil,
        customPort: UInt16? = nil,
        viewModel: DualPaneViewModel
    ) async -> Bool {
        isManualDisconnectSuppressed = false
        let attemptId = UUID()
        activeAttemptId = attemptId
        
        phase = .connecting(attemptId: attemptId, target: customHost ?? "авто")
        viewModel.statusMessage = "Поиск и проверка доступности устройства..."
        
        // 1. Если задан явный пользовательский хост (ручной ввод в UI)
        if let host = customHost, !host.isEmpty {
            let port = customPort ?? 2222
            guard isAttemptValid(attemptId) else { return false }
            
            let reachable = PhoneConnectionManager.shared.isHostPortReachable(host: host, port: port, timeoutSeconds: 2)
            guard reachable else {
                guard isAttemptValid(attemptId) else { return false }
                phase = .disconnected(reason: "Устройство не отвечает по адресу \(host):\(port)")
                viewModel.statusMessage = "⚠️ Устройство не отвечает по адресу \(host):\(port)"
                return false
            }
            
            viewModel.updateRemoteEndpoint(host: host, port: port)
            do {
                try await viewModel.remoteDriver.warmUpConnection()
                guard isAttemptValid(attemptId) else { return false }
                
                let isV6 = host.contains(":")
                let path = CandidatePath.lan(host: host, port: port, isV6: isV6)
                let name = DeviceRegistry.shared.device(matchingHost: host)?.name ?? "Телефон Android"
                
                currentPath = path
                currentDeviceName = name
                phase = .connected(path: path, deviceName: name)
                viewModel.isPhoneConnected = true
                viewModel.transport.rootIsEmulatedZero = viewModel.remoteDriver.rootIsEmulatedZero
                viewModel.statusMessage = "✓ Подключено: \(name) (\(path.displayString))"
                
                DeviceRegistry.shared.registerOrUpdate(
                    id: "device_\(host)",
                    name: name,
                    fingerprint: "",
                    host: host,
                    port: port
                )
                return true
            } catch {
                guard isAttemptValid(attemptId) else { return false }
                phase = .authFailed(reason: error.localizedDescription)
                viewModel.statusMessage = "⚠️ Ошибка авторизации SFTP: \(error.localizedDescription)"
                return false
            }
        }
        
        // 2. Автоматический выбор пути через PhoneConnectionManager (USB -> Wi-Fi)
        let res = await PhoneConnectionManager.shared.establishConnection()
        guard isAttemptValid(attemptId) else { return false }
        
        switch res {
        case .usbSuccess(let deviceId, let host, let port, _):
            viewModel.updateRemoteEndpoint(host: host, port: port)
            do {
                try await viewModel.remoteDriver.warmUpConnection()
                guard isAttemptValid(attemptId) else { return false }
                
                let path = CandidatePath.usb(deviceId: deviceId, localPort: port)
                let model = PhoneConnectionManager.shared.deviceNameForHost("127.0.0.1") ?? "Android Device"
                currentPath = path
                currentDeviceName = model
                phase = .connected(path: path, deviceName: model)
                viewModel.isPhoneConnected = true
                viewModel.transport.rootIsEmulatedZero = viewModel.remoteDriver.rootIsEmulatedZero
                viewModel.statusMessage = "✓ Подключено по USB (\(model))"
                
                DeviceRegistry.shared.registerOrUpdate(
                    id: deviceId,
                    name: model,
                    fingerprint: "",
                    host: host,
                    port: port
                )
                return true
            } catch {
                guard isAttemptValid(attemptId) else { return false }
                phase = .authFailed(reason: error.localizedDescription)
                viewModel.statusMessage = "⚠️ Ошибка SFTP по USB: \(error.localizedDescription)"
                return false
            }
            
        case .wifiSuccess(let host, let port, let name):
            viewModel.updateRemoteEndpoint(host: host, port: port)
            do {
                try await viewModel.remoteDriver.warmUpConnection()
                guard isAttemptValid(attemptId) else { return false }
                
                let isV6 = host.contains(":")
                let path = CandidatePath.lan(host: host, port: port, isV6: isV6)
                currentPath = path
                currentDeviceName = name
                phase = .connected(path: path, deviceName: name)
                viewModel.isPhoneConnected = true
                viewModel.transport.rootIsEmulatedZero = viewModel.remoteDriver.rootIsEmulatedZero
                viewModel.statusMessage = "✓ Подключено по Wi-Fi (\(name))"
                
                DeviceRegistry.shared.registerOrUpdate(
                    id: "device_\(host)",
                    name: name,
                    fingerprint: "",
                    host: host,
                    port: port
                )
                return true
            } catch {
                guard isAttemptValid(attemptId) else { return false }
                phase = .authFailed(reason: error.localizedDescription)
                viewModel.statusMessage = "⚠️ Ошибка SFTP по Wi-Fi: \(error.localizedDescription)"
                return false
            }
            
        case .unauthorized(let deviceId, _):
            phase = .authFailed(reason: "Отладка по USB не подтверждена на экране")
            viewModel.statusMessage = "⚠️ Подтвердите отладку по USB на экране \(deviceId)"
            return false
            
        case .failure(let reason, _):
            phase = .disconnected(reason: reason)
            viewModel.statusMessage = "⚠️ \(reason)"
            return false
        }
    }
    
    /// Отмена текущей попытки подключения
    public func cancel() {
        isManualDisconnectSuppressed = true
        activeAttemptId = nil
        phase = .disconnected(reason: "Подключение отменено пользователем")
    }
    
    /// Явное отключение
    public func disconnect(viewModel: DualPaneViewModel) {
        isManualDisconnectSuppressed = true
        cancel()
        currentPath = nil
        currentDeviceName = ""
        viewModel.isPhoneConnected = false
        phase = .disconnected(reason: nil)
        viewModel.statusMessage = "Телефон отключен"
    }
    
    private func isAttemptValid(_ id: UUID) -> Bool {
        return activeAttemptId == id
    }
}
