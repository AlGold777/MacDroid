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
    
    private weak var activeViewModel: DualPaneViewModel?
    
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
        activeViewModel = viewModel
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
                let (fp, isMigrated) = try await authenticateAndWarmUp(
                    host: host,
                    port: port,
                    deviceId: nil,
                    devName: "Телефон Android",
                    viewModel: viewModel,
                    attemptId: attemptId
                )
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
                
                let effectiveId = !fp.isEmpty ? "dev_\(fp.suffix(12))" : "device_\(host)"
                DeviceRegistry.shared.registerOrUpdate(
                    id: effectiveId,
                    name: name,
                    fingerprint: fp,
                    host: host,
                    port: port,
                    isMigrated: isMigrated
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
            let model = PhoneConnectionManager.shared.deviceNameForHost("127.0.0.1") ?? "Android Device"
            do {
                let (fp, isMigrated) = try await authenticateAndWarmUp(
                    host: host,
                    port: port,
                    deviceId: deviceId,
                    devName: model,
                    viewModel: viewModel,
                    attemptId: attemptId
                )
                guard isAttemptValid(attemptId) else { return false }
                
                let path = CandidatePath.usb(deviceId: deviceId, localPort: port)
                currentPath = path
                currentDeviceName = model
                phase = .connected(path: path, deviceName: model)
                viewModel.isPhoneConnected = true
                viewModel.transport.rootIsEmulatedZero = viewModel.remoteDriver.rootIsEmulatedZero
                viewModel.statusMessage = "✓ Подключено по USB (\(model))"
                
                let effectiveId = !deviceId.isEmpty ? deviceId : (!fp.isEmpty ? "dev_\(fp.suffix(12))" : "usb_device")
                DeviceRegistry.shared.registerOrUpdate(
                    id: effectiveId,
                    name: model,
                    fingerprint: fp,
                    host: host,
                    port: port,
                    isMigrated: isMigrated
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
                let (fp, isMigrated) = try await authenticateAndWarmUp(
                    host: host,
                    port: port,
                    deviceId: nil,
                    devName: name,
                    viewModel: viewModel,
                    attemptId: attemptId
                )
                guard isAttemptValid(attemptId) else { return false }
                
                let isV6 = host.contains(":")
                let path = CandidatePath.lan(host: host, port: port, isV6: isV6)
                currentPath = path
                currentDeviceName = name
                phase = .connected(path: path, deviceName: name)
                viewModel.isPhoneConnected = true
                viewModel.transport.rootIsEmulatedZero = viewModel.remoteDriver.rootIsEmulatedZero
                viewModel.statusMessage = "✓ Подключено по Wi-Fi (\(name))"
                
                let effectiveId = !fp.isEmpty ? "dev_\(fp.suffix(12))" : "device_\(host)"
                DeviceRegistry.shared.registerOrUpdate(
                    id: effectiveId,
                    name: name,
                    fingerprint: fp,
                    host: host,
                    port: port,
                    isMigrated: isMigrated
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
    
    /// Аутентификация, валидация Host Key и управляемый переход на изолированный ключ
    private func authenticateAndWarmUp(
        host: String,
        port: UInt16,
        deviceId: String?,
        devName: String,
        viewModel: DualPaneViewModel,
        attemptId: UUID
    ) async throws -> (fingerprint: String, isMigrated: Bool) {
        guard isAttemptValid(attemptId) else {
            throw NSError(domain: "ConnectionController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Attempt cancelled"])
        }
        
        // 1. Слой 1: Проверка и фиксация отпечатка хост-ключа сервера (HostKeyStore)
        let fp = PhoneConnectionManager.shared.fetchHostFingerprint(host: host, port: port) ?? ""
        if !fp.isEmpty {
            let keyStatus = HostKeyStore.shared.verifyOrPin(
                host: host,
                port: Int(port),
                deviceId: deviceId,
                fingerprint: fp
            )
            if case .mismatchWarning(let expected, let actual) = keyStatus {
                throw NSError(
                    domain: "ConnectionController",
                    code: 403,
                    userInfo: [NSLocalizedDescriptionKey: "Host Key сервера не совпадает с сохраненным! (Ожидался \(expected), получен \(actual)). Проверьте безопасность сети."]
                )
            }
        }
        
        // 2. Слой 3: Проверка статуса миграции на изолированный ключ
        let existingDev = DeviceRegistry.shared.device(matchingFingerprint: fp)
            ?? DeviceRegistry.shared.device(matchingHost: host)
            ?? (deviceId != nil ? DeviceRegistry.shared.device(withId: deviceId!) : nil)
        
        let alreadyMigrated = existingDev?.isMigratedToDedicatedKey == true
        
        if alreadyMigrated {
            // Устройство уже мигрировано: строгий режим без фоллбэка на личные ключи пользователя
            try await viewModel.remoteDriver.warmUpConnection(allowLegacyFallback: false)
            return (fp, true)
        } else {
            // Устройство ещё не мигрировано: сначала пробуем только изолированный macdroid_id_ed25519
            do {
                try await viewModel.remoteDriver.warmUpConnection(allowLegacyFallback: false)
                // Если телефон принял macdroid_id_ed25519 без фоллбэка, фиксируем миграцию
                return (fp, true)
            } catch {
                guard isAttemptValid(attemptId) else {
                    throw NSError(domain: "ConnectionController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Attempt cancelled"])
                }
                // Если телефон отклонил macdroid_id_ed25519, пробуем контролируемый фоллбэк на legacy-ключ
                try await viewModel.remoteDriver.warmUpConnection(allowLegacyFallback: true)
                // Подключение удалось через legacy-ключ; миграция остаётся false
                return (fp, false)
            }
        }
    }
    
    /// Отмена текущей попытки подключения с завершением дочерних процессов
    public func cancel(viewModel: DualPaneViewModel? = nil) {
        isManualDisconnectSuppressed = true
        activeAttemptId = nil
        let targetVm = viewModel ?? activeViewModel
        targetVm?.remoteDriver.disconnect()
        phase = .disconnected(reason: "Подключение отменено пользователем")
    }
    
    /// Явное отключение устройства
    public func disconnect(viewModel: DualPaneViewModel) {
        isManualDisconnectSuppressed = true
        cancel(viewModel: viewModel)
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
