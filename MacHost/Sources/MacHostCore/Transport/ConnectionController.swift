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
    
    public var deviceId: String? {
        switch self {
        case .usb(let id, _): return id
        case .lan: return nil
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
    
    /// Запуск намеренного подключения (вызывается строго по интенту пользователя или по явному кандидату)
    public func connect(
        targetCandidate: CandidatePath? = nil,
        customHost: String? = nil,
        customPort: UInt16? = nil,
        isExplicitUserAction: Bool = false,
        viewModel: DualPaneViewModel
    ) async -> Bool {
        if isExplicitUserAction {
            isManualDisconnectSuppressed = false
        } else if isManualDisconnectSuppressed {
            // Фоновое автоподключение блокируется подавлением ручного отключения
            return false
        }
        
        activeViewModel = viewModel
        let attemptId = UUID()
        activeAttemptId = attemptId
        
        let targetDesc = targetCandidate?.displayString ?? customHost ?? "авто"
        phase = .connecting(attemptId: attemptId, target: targetDesc)
        viewModel.statusMessage = "Поиск и проверка доступности устройства (\(targetDesc))..."
        
        // 1. Если задан конкретный проверенный кандидат от автоподключения
        if let candidate = targetCandidate {
            return await connectToCandidate(candidate, attemptId: attemptId, viewModel: viewModel)
        }
        
        // 2. Если задан явный пользовательский хост (ручной ввод в UI)
        if let host = customHost, !host.isEmpty {
            let port = customPort ?? 2222
            let isV6 = host.contains(":")
            let path = CandidatePath.lan(host: host, port: port, isV6: isV6)
            return await connectToCandidate(path, attemptId: attemptId, viewModel: viewModel)
        }
        
        // 3. Автоматический выбор пути через PhoneConnectionManager (USB -> Wi-Fi)
        let res = await PhoneConnectionManager.shared.establishConnection()
        guard isAttemptValid(attemptId) else { return false }
        
        switch res {
        case .usbSuccess(let deviceId, _, let port, _):
            let path = CandidatePath.usb(deviceId: deviceId, localPort: port)
            return await connectToCandidate(path, attemptId: attemptId, viewModel: viewModel)
            
        case .wifiSuccess(let host, let port, _):
            let isV6 = host.contains(":")
            let path = CandidatePath.lan(host: host, port: port, isV6: isV6)
            return await connectToCandidate(path, attemptId: attemptId, viewModel: viewModel)
            
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
    
    /// Подключение к строго выбранному пути без подмены устройства
    private func connectToCandidate(
        _ candidate: CandidatePath,
        attemptId: UUID,
        viewModel: DualPaneViewModel
    ) async -> Bool {
        guard isAttemptValid(attemptId) else { return false }
        
        let host = candidate.host
        let port = candidate.port
        let deviceId: String?
        let devName: String
        
        switch candidate {
        case .usb(let id, _):
            deviceId = id
            devName = PhoneConnectionManager.shared.deviceNameForHost("127.0.0.1") ?? "Android Device"
        case .lan(let h, _, _):
            deviceId = nil
            devName = DeviceRegistry.shared.device(matchingHost: h)?.name ?? "Телефон Android"
        }
        
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
                deviceId: deviceId,
                devName: devName,
                viewModel: viewModel,
                attemptId: attemptId
            )
            guard isAttemptValid(attemptId) else { return false }
            
            currentPath = candidate
            currentDeviceName = devName
            phase = .connected(path: candidate, deviceName: devName)
            viewModel.isPhoneConnected = true
            viewModel.transport.rootIsEmulatedZero = viewModel.remoteDriver.rootIsEmulatedZero
            viewModel.statusMessage = "✓ Подключено: \(devName) (\(candidate.displayString))"
            
            let effectiveId = !deviceId.orEmpty.isEmpty ? deviceId! : (!fp.isEmpty ? "dev_\(fp.suffix(12))" : "device_\(host)")
            DeviceRegistry.shared.registerOrUpdate(
                id: effectiveId,
                name: devName,
                fingerprint: fp,
                host: host,
                port: port,
                isMigrated: isMigrated
            )
            // Сохраняем фактически использованный endpoint, включая адрес,
            // найденный через Bonjour/ARP. Это позволяет восстановить Wi‑Fi
            // после смены интерфейса или перезапуска приложения.
            if case .lan = candidate {
                UserDefaults.standard.set(host, forKey: "lastConnectedHost")
                UserDefaults.standard.set(Int(port), forKey: "lastConnectedPort")
                Self.rememberConnection(name: devName, host: host, port: port)
            }
            return true
        } catch {
            guard isAttemptValid(attemptId) else { return false }
            phase = .authFailed(reason: error.localizedDescription)
            viewModel.statusMessage = "⚠️ Ошибка авторизации SFTP: \(error.localizedDescription)"
            return false
        }
    }
    
    /// Аутентификация, строгая валидация Host Key и активная миграция на изолированный ключ
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
        
        // 1. Слой 1: Проверка и обязательная фиксация отпечатка хост-ключа сервера
        guard let fp = PhoneConnectionManager.shared.fetchHostFingerprint(host: host, port: port), !fp.isEmpty else {
            throw NSError(
                domain: "ConnectionController",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось получить криптографический отпечаток узла \(host):\(port). Подключение отклонено в целях безопасности."]
            )
        }
        
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
                userInfo: [NSLocalizedDescriptionKey: "Host Key сервера не совпадает с сохраненным! (Ожидался \(expected), получен \(actual)). Возможна атака перехвата."]
            )
        }
        
        // 2. Слой 3: Проверка статуса сопряжения и миграции
        let existingDev = DeviceRegistry.shared.device(matchingFingerprint: fp)
            ?? DeviceRegistry.shared.device(matchingHost: host)
            ?? (deviceId != nil ? DeviceRegistry.shared.device(withId: deviceId!) : nil)
        
        let alreadyMigrated = existingDev?.isMigratedToDedicatedKey == true
        let isKnownLegacyDevice: Bool
        if let existing = existingDev {
            isKnownLegacyDevice = !existing.isMigratedToDedicatedKey
        } else {
            isKnownLegacyDevice = HostKeyStore.shared.isHostPinned(host: host, port: Int(port), deviceId: deviceId)
        }
        
        if alreadyMigrated {
            // Устройство уже мигрировано: строго запрещен фоллбэк на личные ключи пользователя
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
                
                // Для неизвестных / новых устройств фоллбэк на личный ключ пользователя СТРОГО ЗАПРЕЩЕН:
                guard isKnownLegacyDevice else {
                    throw NSError(
                        domain: "ConnectionController",
                        code: 403,
                        userInfo: [NSLocalizedDescriptionKey: "Новое устройство не спарено с MacDroid Commander. Требуется сопряжение (TOFU) через выделенный ключ приложения."]
                    )
                }
                
                // Известное legacy-устройство: подключаемся через контролируемый фоллбэк
                try await viewModel.remoteDriver.warmUpConnection(allowLegacyFallback: true)
                
                // ВЫПОЛНЯЕМ АКТИВНУЮ МИГРАЦИЮ:
                // Отправляем открытый ключ macdroid_id_ed25519.pub на смартфон
                let home = FileManager.default.homeDirectoryForCurrentUser
                let pubKeyURL = home.appendingPathComponent(".ssh/macdroid_id_ed25519.pub")
                if let pubData = try? Data(contentsOf: pubKeyURL),
                   let pubStr = String(data: pubData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !pubStr.isEmpty {
                    
                    let migrated = await pushDedicatedPublicKey(host: host, port: port, pubKey: pubStr)
                    if migrated {
                        // Перепроверяем, что теперь телефон принимает подключение БЕЗ фоллбэка
                        do {
                            try await viewModel.remoteDriver.warmUpConnection(allowLegacyFallback: false)
                            return (fp, true)
                        } catch {
                            return (fp, false)
                        }
                    }
                }
                return (fp, false)
            }
        }
    }
    
    /// Отправка специализированного открытого ключа приложения в authorized_keys смартфона через SSH exec
    private func pushDedicatedPublicKey(host: String, port: UInt16, pubKey: String) async -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacyKey = home.appendingPathComponent(".ssh/id_ed25519")
        guard FileManager.default.fileExists(atPath: legacyKey.path) else { return false }
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-i", legacyKey.path,
            "-p", String(port),
            "-F", "/dev/null",
            "-o", "IdentitiesOnly=yes",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=4",
            "-o", "StrictHostKeyChecking=accept-new",
            "root@\(host)",
            "authorize_key \(pubKey)"
        ]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        
        do {
            try proc.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let outStr = String(data: outData, encoding: .utf8) ?? ""
            return proc.terminationStatus == 0 && outStr.contains("AUTHORIZED_OK")
        } catch {
            return false
        }
    }
    
    /// Отмена текущей попытки подключения с немедленным завершением дочерних процессов
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

    private static func rememberConnection(name: String, host: String, port: UInt16) {
        let newConnection = SavedConnection(name: name, host: host, port: Int(port))
        var history = (try? JSONDecoder().decode(
            [SavedConnection].self,
            from: UserDefaults.standard.data(forKey: "phoneConnectionHistory") ?? Data()
        )) ?? []
        history.removeAll { $0.host == host && $0.port == Int(port) }
        history.insert(newConnection, at: 0)
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(history.prefix(8))), forKey: "phoneConnectionHistory")
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
