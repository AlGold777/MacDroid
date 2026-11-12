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
    private var lanSearchTask: Task<LanPhoneSearchResult, Never>?
    
    private weak var activeViewModel: DualPaneViewModel?
    
    public init() {}
    
    /// Проверка, разрешено ли автоподключение для данного устройства с учетом подавления после ручного отключения
    public func shouldAttemptAutoConnect(for deviceId: String?) -> Bool {
        guard !isManualDisconnectSuppressed else { return false }
        guard let id = deviceId,
              let dev = DeviceRegistry.shared.device(withId: id) ?? DeviceRegistry.shared.device(matchingUsbSerial: id) else { return false }
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
        let started = Date()
        let success = await performConnect(
            targetCandidate: targetCandidate,
            customHost: customHost,
            customPort: customPort,
            preferredDeviceId: preferredDeviceId,
            isExplicitUserAction: isExplicitUserAction,
            viewModel: viewModel
        )
        let outcome: String
        switch phase {
        case .connected(let path, let name): outcome = "подключено \(name) \(path.displayString)"
        case .authFailed(let reason): outcome = "отказ доверия: \(reason)"
        case .disconnected(let reason): outcome = "отказ: \(reason ?? "без причины")"
        case .connecting, .discovering: outcome = success ? "подключено" : "попытка заменена новой"
        }
        let diagnostics = success || lastConnectionDiagnostics.isEmpty ? "" : " подробности=\(lastConnectionDiagnostics.suffix(300))"
        SSHTransportLog.write("CONNECT итог=\(outcome) \(String(format: "%.1f", Date().timeIntervalSince(started)))с\(diagnostics)")
        return success
    }

    private func performConnect(
        targetCandidate: CandidatePath?,
        customHost: String?,
        customPort: UInt16?,
        preferredDeviceId: String?,
        isExplicitUserAction: Bool,
        viewModel: DualPaneViewModel
    ) async -> Bool {
        if isExplicitUserAction {
            isManualDisconnectSuppressed = false
        } else if isManualDisconnectSuppressed {
            // Фоновое автоподключение блокируется подавлением ручного отключения
            SSHTransportLog.event(key: "connect-skip", signature: "manual",
                                  "CONNECT пропуск: телефон отключён вручную, автоподключение ждёт кнопку PHONE")
            return false
        }
        
        activeViewModel = viewModel
        lanSearchTask?.cancel()
        lanSearchTask = nil
        let attemptId = UUID()
        activeAttemptId = attemptId
        lastConnectionDiagnostics = ""
        
        let targetDesc = targetCandidate?.displayString ?? customHost ?? "авто"
        phase = .connecting(attemptId: attemptId, target: targetDesc)
        SSHTransportLog.write("CONNECT начало цель=\(targetDesc) \(isExplicitUserAction ? "по кнопке" : "авто")")
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
        
        let res: ConnectionResult
        if preferredDeviceId == nil {
            // PHONE ищет Wi-Fi endpoint независимо от доступности других транспортов.
            // Поиск принадлежит текущей попытке и прекращается при отмене/новом выборе.
            DiscoveryService.shared.refresh()
            let searchTask = Task.detached(priority: .userInitiated) {
                await PhoneConnectionManager.shared.findPairedPhoneOnLan(deep: true)
            }
            lanSearchTask = searchTask
            let searchResult = await withTaskCancellationHandler {
                await searchTask.value
            } onCancel: {
                searchTask.cancel()
            }
            guard isAttemptValid(attemptId) else { return false }
            lanSearchTask = nil
            switch searchResult {
            case .paired(let host, let port, _, let name):
                res = .wifiSuccess(host: host, port: port, name: name)
            case .unpaired(let hosts):
                res = .wifiUnpaired(hosts: hosts, log: "Wi-Fi endpoints require pairing: \(hosts.joined(separator: ", "))")
            case .notFound:
                // Wi-Fi не нашёл телефон: кабель — следующий маршрут, но только для серийника,
                // опознанного пробой по закреплённому ключу. Без явного действия пользователя — ещё и с autoConnect.
                let requireAutoConnect = !isExplicitUserAction
                let usbSerial = await Task.detached(priority: .userInitiated) {
                    PhoneConnectionManager.shared.chooseUsbSerialForPhone(requireAutoConnect: requireAutoConnect)
                }.value
                guard isAttemptValid(attemptId) else { return false }
                if let serial = usbSerial {
                    res = await PhoneConnectionManager.shared.establishConnection(preferredDeviceId: serial)
                } else {
                    res = .failure(
                        reason: "Телефон не найден по Wi-Fi. Проверьте общую сеть и откройте MacDroid Companion на телефоне.",
                        log: "Wi-Fi discovery finished without a reachable paired endpoint; no authorized USB device."
                    )
                }
            }
        } else {
            // Явно выбранное устройство сохраняет существующий путь подключения.
            if isExplicitUserAction {
                DiscoveryService.shared.startDiscovery()
            }
            res = await PhoneConnectionManager.shared.establishConnection(preferredDeviceId: preferredDeviceId)
        }
        guard isAttemptValid(attemptId) else { return false }

        switch res {
        case .usbSuccess(_, _, _, let log), .unauthorized(_, let log), .wifiUnpaired(_, let log), .failure(_, let log):
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

        case .wifiUnpaired(let hosts, _):
            let hostList = hosts.joined(separator: ", ")
            phase = .disconnected(reason: "Телефон \(hostList) не сопряжён")
            if isExplicitUserAction {
                viewModel.statusMessage = "Найден телефон (\(hostList)), но он ещё не сопряжён — сверьте отпечаток в окне сопряжения"
                viewModel.showPairingDialog = true
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
            let normHost = ConnectionHostAddress.normalized(h)
            if let found = DiscoveryService.shared.discoveredDevices.first(where: { ConnectionHostAddress.normalized($0.host) == normHost }), !found.name.isEmpty {
                devName = found.name
            } else if let dev = DeviceRegistry.shared.device(matchingHost: normHost), dev.name != "Телефон Android", dev.name != "Android", !dev.name.isEmpty {
                devName = dev.name
            } else if let name = PhoneConnectionManager.shared.deviceNameForHost(normHost), name != "Телефон Android", name != "Android", !name.isEmpty {
                devName = name
            } else {
                devName = "Телефон Android"
            }
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
                attemptId: attemptId,
                isExplicit: isExplicit
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
                isMigrated: isMigrated,
                usbSerial: deviceId
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
                UserDefaults.standard.set(pinKey, forKey: "lastSuccessfulPhoneDeviceId")
                Self.rememberConnection(name: devName, host: host, port: port)
            } else if let deviceId {
                UserDefaults.standard.set("127.0.0.1", forKey: "lastConnectedHost")
                UserDefaults.standard.set(Int(port), forKey: "lastConnectedPort")
                UserDefaults.standard.set(deviceId, forKey: "lastConnectedDeviceId")
            }
            return true
        } catch {
            guard isAttemptValid(attemptId) else { return false }
            let reason = error.localizedDescription
            lastConnectionDiagnostics = "Endpoint: \(candidate.displayString) (\(host):\(port))\nSSH/SFTP setup failed: \(reason)"
            if Self.isTrustFailure(error) {
                // Решение о доверии: фон не повторяет попытку до ручного действия (см. DualPaneViewModel.connectPhone)
                phase = .authFailed(reason: reason)
                if isExplicit {
                    viewModel.statusMessage = "⚠️ Ошибка авторизации SFTP: \(reason)"
                }
            } else {
                // Временный сбой (ключ узла не получен, SSH/SFTP, таймаут): фон повторит по паузе
                phase = .disconnected(reason: reason)
                if isExplicit {
                    viewModel.statusMessage = "⚠️ Не удалось подключиться: \(reason)"
                }
            }
            return false
        }
    }
    
    /// Решение о доверии: отпечаток не закреплён, не совпал или устройство не сопряжено (NSError code 403).
    /// Только такой сбой переводит фазу в `.authFailed` и блокирует фоновое автоподключение до ручного действия.
    /// Временные сбои (401 — ключ узла не получен, SSH/SFTP, таймауты, отмена попытки) — не trust-сбой.
    nonisolated static func isTrustFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "ConnectionController" && nsError.code == 403
    }

    /// Аутентификация, строгая валидация Host Key и активная миграция на изолированный ключ
    private func authenticateAndWarmUp(
        host: String,
        port: UInt16,
        deviceId: String?,
        devName: String,
        viewModel: DualPaneViewModel,
        attemptId: UUID,
        // Явное подключение пользователем НЕ ослабляет проверку закреплённого ключа: при смене ключа хоста
        // нужен осознанный «Сбросить ключ» с показом старого и нового отпечатков (peer-review W4/W5).
        isExplicit: Bool = false
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
        viewModel.remoteDriver.coordinator.setSessionIdentity(fingerprint: fp, isMigrated: false)

        // Личный ключ (legacy fallback) допускается только для устройства с подтверждённым закреплённым отпечатком.
        // pinKey может быть другим id того же отпечатка: запись реестра ищется и по отпечатку.
        let existingDev = DeviceRegistry.shared.device(withId: pinKey, orFingerprint: fp)
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
        lanSearchTask?.cancel()
        lanSearchTask = nil
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
        return activeAttemptId == id && !Task.isCancelled
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
