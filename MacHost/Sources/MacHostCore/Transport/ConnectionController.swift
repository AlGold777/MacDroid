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
    @Published public private(set) var lastConnectionDiagnostics: String = ""
    
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
        preferredDeviceId: String? = nil,
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
        lastConnectionDiagnostics = ""
        
        let targetDesc = targetCandidate?.displayString ?? customHost ?? "авто"
        phase = .connecting(attemptId: attemptId, target: targetDesc)
        if isExplicitUserAction {
            viewModel.statusMessage = "Поиск и проверка доступности устройства (\(targetDesc))..."
        }
        
        // 1. Если задан конкретный проверенный кандидат от автоподключения
        if let candidate = targetCandidate {
            return await connectToCandidate(candidate, attemptId: attemptId, isExplicit: isExplicitUserAction, viewModel: viewModel)
        }
        
        // 2. Если задан явный пользовательский хост (ручной ввод в UI)
        if let host = customHost, !host.isEmpty {
            let port = customPort ?? 2222
            let isV6 = host.contains(":")
            let path = CandidatePath.lan(host: host, port: port, isV6: isV6)
            return await connectToCandidate(path, attemptId: attemptId, isExplicit: isExplicitUserAction, viewModel: viewModel)
        }
        
        // 3. Автоматический выбор пути через PhoneConnectionManager (USB -> Wi-Fi)
        let res = await PhoneConnectionManager.shared.establishConnection(preferredDeviceId: preferredDeviceId)
        guard isAttemptValid(attemptId) else { return false }

        switch res {
        case .usbSuccess(_, _, _, let log), .unauthorized(_, let log), .failure(_, let log):
            lastConnectionDiagnostics = log
        case .wifiSuccess(let host, let port, _):
            lastConnectionDiagnostics = "Wi-Fi endpoint discovered: \(host):\(port)"
        }
        
        switch res {
        case .usbSuccess(let deviceId, _, let port, _):
            let path = CandidatePath.usb(deviceId: deviceId, localPort: port)
            return await connectToCandidate(path, attemptId: attemptId, isExplicit: isExplicitUserAction, viewModel: viewModel)
            
        case .wifiSuccess(let host, let port, _):
            let isV6 = host.contains(":")
            let path = CandidatePath.lan(host: host, port: port, isV6: isV6)
            return await connectToCandidate(path, attemptId: attemptId, isExplicit: isExplicitUserAction, viewModel: viewModel)
            
        case .unauthorized(let deviceId, _):
            phase = .authFailed(reason: "Отладка по USB не подтверждена на экране")
            if isExplicitUserAction {
                viewModel.statusMessage = "⚠️ Подтвердите отладку по USB на экране \(deviceId)"
            }
            return false
            
        case .failure(let reason, _):
            phase = .disconnected(reason: reason)
            if isExplicitUserAction {
                viewModel.statusMessage = "⚠️ \(reason)"
            }
            return false
        }
    }
    
    /// Подключение к строго выбранному пути без подмены устройства
    private func connectToCandidate(
        _ candidate: CandidatePath,
        attemptId: UUID,
        isExplicit: Bool = true,
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
        
        // W9: отменённая попытка не запускает новые сетевые пробы (nc/ssh-keyscan).
        guard isAttemptValid(attemptId) else { return false }
        let reachable = await Task.detached(priority: .userInitiated) {
            PhoneConnectionManager.shared.isHostPortReachable(host: host, port: port, timeoutSeconds: 2)
        }.value
        guard reachable else {
            guard isAttemptValid(attemptId) else { return false }
            lastConnectionDiagnostics = "TCP probe failed for \(candidate.displayString) at \(host):\(port). Verify that the companion service is listening and that the route/ADB forward is active."
            phase = .disconnected(reason: "Устройство не отвечает по адресу \(host):\(port)")
            if isExplicit {
                viewModel.statusMessage = "⚠️ Устройство не отвечает по адресу \(host):\(port)"
            }
            return false
        }
        
        guard isAttemptValid(attemptId) else { return false }
        viewModel.updateRemoteEndpoint(host: host, port: port, deviceId: deviceId)
        do {
            let (fp, isMigrated, pinKey) = try await authenticateAndWarmUp(
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
            
            // Идентичность устройства — ключ закрепления (проверенный отпечаток), а не адрес.
            DeviceRegistry.shared.registerOrUpdate(
                id: pinKey,
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
                UserDefaults.standard.removeObject(forKey: "lastConnectedDeviceId")
                UserDefaults.standard.set(ConnectionHostAddress.normalized(host), forKey: "lastSuccessfulPhoneHost")
                UserDefaults.standard.set(Int(port), forKey: "lastSuccessfulPhonePort")
                Self.rememberConnection(name: devName, host: host, port: port)
            } else if let deviceId {
                UserDefaults.standard.set("127.0.0.1", forKey: "lastConnectedHost")
                UserDefaults.standard.set(Int(port), forKey: "lastConnectedPort")
                UserDefaults.standard.set(deviceId, forKey: "lastConnectedDeviceId")
            }
            return true
        } catch {
            guard isAttemptValid(attemptId) else { return false }
            lastConnectionDiagnostics = "Endpoint: \(candidate.displayString) (\(host):\(port))\nSSH/SFTP setup failed: \(error.localizedDescription)"
            phase = .authFailed(reason: error.localizedDescription)
            if isExplicit {
                viewModel.statusMessage = "⚠️ Ошибка авторизации SFTP: \(error.localizedDescription)"
            }
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
    ) async throws -> (fingerprint: String, isMigrated: Bool, pinKey: String) {
        guard isAttemptValid(attemptId) else {
            throw NSError(domain: "ConnectionController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Attempt cancelled"])
        }

        // 1. Ключ узла только наблюдается: без доверия и без закрепления.
        let hostKey: SSHHostKeyObservation
        do {
            hostKey = try await HostKeyStore.shared.fetchHostKeyObservation(host: host, port: port)
        } catch {
            throw NSError(
                domain: "ConnectionController",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось получить криптографический отпечаток узла \(host):\(port). Подключение отклонено в целях безопасности."]
            )
        }
        let fp = hostKey.fingerprint
        // W9: попытка могла быть отменена, пока шёл ssh-keyscan — дальше не идём.
        guard isAttemptValid(attemptId) else {
            throw NSError(domain: "ConnectionController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Attempt cancelled"])
        }

        // 2. Устройство определяется по стабильному id или по уже закреплённому ключу, а не по адресу.
        guard let pinKey = HostKeyStore.shared.resolvePinKey(deviceId: deviceId, host: host, observedFingerprint: fp) else {
            throw NSError(
                domain: "ConnectionController",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: HostKeyStoreError.notPaired.localizedDescription]
            )
        }

        // 3. Доверие только к закреплённому (подтверждённому пользователем) ключу. Несовпадение = отказ, без записи.
        switch HostKeyStore.shared.verifyPinned(deviceId: pinKey, fingerprint: fp) {
        case .trusted:
            break
        case .mismatchWarning(let expected, let actual):
            throw NSError(
                domain: "ConnectionController",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: HostKeyStoreError.hostKeyMismatch(expected: expected, actual: actual).localizedDescription]
            )
        case .pinnedNew, .notPinned:
            throw NSError(
                domain: "ConnectionController",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: HostKeyStoreError.notPaired.localizedDescription]
            )
        }

        let hostKeyAlias = HostKeyStore.safeHostKeyAlias(pinKey)
        // Сама SSH-сессия принимает только тот ключ, который только что сверен с закреплённым.
        try HostKeyStore.shared.installOpenSSHHostKey(hostKey, host: host, port: port, deviceId: pinKey, hostKeyAlias: hostKeyAlias)
        viewModel.remoteDriver.coordinator.setExpectedHostKeyAlgorithm(hostKey.keyAlgorithm)
        viewModel.remoteDriver.coordinator.setHostKeyAlias(hostKeyAlias)

        // Личный ключ (legacy fallback) допускается только для устройства с подтверждённым закреплённым отпечатком.
        let existingDev = DeviceRegistry.shared.device(withId: pinKey)
        let isKnownLegacyDevice = existingDev.map { !$0.isMigratedToDedicatedKey } ?? false

        // 2. Слой 3: Проверка статуса сопряжения и миграции
        let alreadyMigrated = existingDev?.isMigratedToDedicatedKey == true
        
        if alreadyMigrated {
            // Устройство уже мигрировано: строго запрещен фоллбэк на личные ключи пользователя
            try await viewModel.remoteDriver.warmUpConnection(allowLegacyFallback: false)
            return (fp, true, pinKey)
        } else {
            // Устройство ещё не мигрировано: сначала пробуем только изолированный macdroid_id_ed25519
            do {
                try await viewModel.remoteDriver.warmUpConnection(allowLegacyFallback: false)
                // Если телефон принял macdroid_id_ed25519 без фоллбэка, фиксируем миграцию
                return (fp, true, pinKey)
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
                    
                    let migrated = await pushDedicatedPublicKey(host: host, port: port, deviceId: deviceId, hostKeyAlias: hostKeyAlias, pubKey: pubStr)
                    if migrated {
                        // Перепроверяем, что теперь телефон принимает подключение БЕЗ фоллбэка
                        do {
                            try await viewModel.remoteDriver.warmUpConnection(allowLegacyFallback: false)
                            return (fp, true, pinKey)
                        } catch {
                            return (fp, false, pinKey)
                        }
                    }
                }
                return (fp, false, pinKey)
            }
        }
    }
    
    /// Отправка специализированного открытого ключа приложения в authorized_keys смартфона через SSH exec
    private func pushDedicatedPublicKey(host: String, port: UInt16, deviceId: String?, hostKeyAlias: String, pubKey: String) async -> Bool {
        await Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let legacyKey = home.appendingPathComponent(".ssh/id_ed25519")
            guard FileManager.default.fileExists(atPath: legacyKey.path) else { return false }
            let knownHostsURL = HostKeyStore.shared.openSSHKnownHostsURL(host: host, port: port, deviceId: deviceId)
            let sshUser = UserDefaults.standard.string(forKey: "sshUser") ?? NSUserName()
            guard SessionCoordinator.isValidSSHUser(sshUser) else { return false }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = [
                "-i", legacyKey.path, "-p", String(port), "-F", "/dev/null",
                "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=4",
                "-o", "StrictHostKeyChecking=yes", "-o", "HostKeyAlias=\(hostKeyAlias)",
                "-o", "UserKnownHostsFile=\(HostKeyStore.openSSHConfigValue(knownHostsURL.path))",
                "--", "\(sshUser)@\(host)", "authorize_key \(pubKey)"
            ]
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = FileHandle.nullDevice
            // Дедлайн: зависший ssh не должен блокировать подключение бесконечно.
            let watchdog = DispatchWorkItem { [weak proc] in
                if proc?.isRunning == true { proc?.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
            do {
                try proc.run()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                watchdog.cancel()
                let outStr = String(data: outData, encoding: .utf8) ?? ""
                return proc.terminationStatus == 0 && outStr.contains("AUTHORIZED_OK")
            } catch { return false }
        }.value
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
        let normalizedHost = ConnectionHostAddress.normalized(host)
        let newConnection = SavedConnection(name: name, host: normalizedHost, port: Int(port))
        var history = (try? JSONDecoder().decode(
            [SavedConnection].self,
            from: UserDefaults.standard.data(forKey: "phoneConnectionHistory") ?? Data()
        )) ?? []
        var seen = Set<String>()
        history = history.compactMap { item in
            let host = ConnectionHostAddress.normalized(item.host)
            let key = "\(host):\(item.port)"
            guard seen.insert(key).inserted, key != "\(normalizedHost):\(port)" else { return nil }
            return SavedConnection(name: item.name, host: host, port: item.port, date: item.date)
        }
        history.insert(newConnection, at: 0)
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(history.prefix(4))), forKey: "phoneConnectionHistory")
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
