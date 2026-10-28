import Foundation
import CryptoKit
import AppKit

/// Единый координатор сессии Mac ↔ Android, управляющий жизненным циклом соединения,
/// каналами SFTP, бюджетами ресурсов и сопоставлением путей.
public final class SessionCoordinator: @unchecked Sendable {
    public static func controlSocketPath(home: URL, identifier: UUID = UUID()) -> String {
        let compactIdentifier = identifier.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return home
            .appendingPathComponent("Library/Caches/MCD", isDirectory: true)
            .appendingPathComponent("c_\(compactIdentifier)", isDirectory: false)
            .path
    }

    public static let shared = SessionCoordinator()
    
    private let lock = NSRecursiveLock()
    /// Выставляется по NSWorkspace.didWakeNotification; сбрасывается после health probe.
    private var needsProbeAfterWake = false
    /// Единственная активная проба живости: канал и общая задача (под lock; см. sharedHealthProbe).
    private var activeProbe: (channel: ObjectIdentifier, task: Task<Bool, Never>)?

    public private(set) var host: String = "127.0.0.1"
    public private(set) var port: UInt16 = 2222
    public private(set) var deviceId: String? = nil
    public private(set) var hostKeyFingerprint: String? = nil
    public private(set) var isMigratedToDedicatedKey: Bool = false
    
    public private(set) var sessionEpoch: UInt64 = 0
    public let budget = SessionBudget()
    public let packetEngine = SFTPPacketEngine()
    
    public private(set) var rootIsEmulatedZero: Bool = false
    public private(set) var serverExtensions: [String: String] = [:]
    public private(set) var serverLimits: SFTPLimits? = nil
    
    private var _interactiveChannel: SFTPChannel?
    private var _bulkChannel: SFTPChannel?
    
    private var masterProcess: Process?
    private var muxSocketPath: String?
    
    private var activeConnectTask: Task<Void, Error>?
    private var activeConnectAllowsLegacyFallback: Bool?
    private var activeSessionAllowsLegacyFallback: Bool?
    private var preferredLegacyFallbackPolicy: Bool?
    private var expectedHostKeyAlgorithm: String?
    private var hostKeyAlias: String?
    private var connectingChannels: [SFTPChannel] = []
    
    public init() {
        // W16: после сна Mac соединение, скорее всего, мертво — проверить при следующем использовании.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.markNeedsProbeAfterWake()
        }
    }

    private func markNeedsProbeAfterWake() {
        lock.lock()
        defer { lock.unlock() }
        needsProbeAfterWake = true
    }
    
    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _interactiveChannel?.isRunning == true
    }
    
    public var interactiveChannel: SFTPChannel? {
        lock.lock()
        defer { lock.unlock() }
        return _interactiveChannel
    }
    
    public var bulkChannel: SFTPChannel? {
        lock.lock()
        defer { lock.unlock() }
        return _bulkChannel?.isRunning == true ? _bulkChannel : _interactiveChannel
    }
    
    /// Допустимое имя пользователя SSH: формат [A-Za-z_][A-Za-z0-9_-]{0,31}, ASCII only.
    public static func isValidSSHUser(_ user: String) -> Bool {
        guard let first = user.first, user.count <= 32 else { return false }
        guard first.isASCII, first.isLetter || first == "_" else { return false }
        return user.allSatisfy { c in c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-") }
    }

    public func updateEndpoint(host: String, port: UInt16, deviceId: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if self.host == host && self.port == port && self.deviceId == deviceId {
            return
        }
        disconnect()
        self.host = host
        self.port = port
        self.deviceId = deviceId
        self.expectedHostKeyAlgorithm = nil
        self.hostKeyFingerprint = nil
        self.hostKeyAlias = nil
        self.preferredLegacyFallbackPolicy = nil
        self._interactiveChannel?.close()
        self._interactiveChannel = nil
        self._bulkChannel?.close()
        self._bulkChannel = nil
        self.activeConnectTask = nil
    }
    
    public func setSessionIdentity(fingerprint: String?, isMigrated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.hostKeyFingerprint = fingerprint
        self.isMigratedToDedicatedKey = isMigrated
    }

    public func setExpectedHostKeyAlgorithm(_ algorithm: String?) {
        lock.lock()
        defer { lock.unlock() }
        expectedHostKeyAlgorithm = algorithm
    }

    public func setHostKeyAlias(_ alias: String?) {
        lock.lock()
        defer { lock.unlock() }
        hostKeyAlias = alias.map(HostKeyStore.safeHostKeyAlias)
    }
    
    /// Гарантирует активное подключение к Android
    public func ensureConnected(allowLegacyFallback: Bool? = nil) async throws {
        lock.lock()
        let resolvedLegacyFallback = allowLegacyFallback ?? preferredLegacyFallbackPolicy ?? activeSessionAllowsLegacyFallback ?? false
        if let allowLegacyFallback {
            preferredLegacyFallbackPolicy = allowLegacyFallback
        }
        if let chan = _interactiveChannel, chan.isRunning,
           activeSessionAllowsLegacyFallback == resolvedLegacyFallback {
            // После сна/пробуждения проверяем связь всегда, иначе — только после простоя.
            let shouldProbe = needsProbeAfterWake || chan.idleDuration >= 20
            needsProbeAfterWake = false
            lock.unlock()
            if shouldProbe {
                // Одна общая проба на канал: параллельные вызовы ждут её результат и не запускают свою.
                let alive = try await sharedHealthProbe(chan)
                if !alive {
                    // Compare-and-disconnect: рвём, только если проверенный канал всё ещё текущий.
                    // Иначе сессию уже заменили, и повторный вызов просто использует новую.
                    lock.lock()
                    if _interactiveChannel === chan {
                        // Полная очистка (каналы + ControlMaster), иначе ssh-процесс остаётся висеть (W8).
                        disconnect()
                    }
                    lock.unlock()
                    try await ensureConnected()
                }
            }
            return
        }
        if let existing = activeConnectTask {
            if activeConnectAllowsLegacyFallback == resolvedLegacyFallback {
                lock.unlock()
                try await existing.value
                return
            }
            disconnect()
        } else if _interactiveChannel != nil {
            // Мёртвый канал (isRunning == false) тоже очищаем до нового подключения:
            // иначе старые ControlMaster, bulk-слейв и сокет остаются висеть, а budget не сбрасывается.
            // disconnect() увеличивает sessionEpoch, поэтому epoch ниже берётся уже после очистки.
            disconnect()
        }

        let epoch = sessionEpoch
        let task = Task { [weak self] () -> Void in
            guard let self = self else { return }
            try await self.performConnect(allowLegacyFallback: resolvedLegacyFallback, epoch: epoch)
        }
        self.activeConnectTask = task
        self.activeConnectAllowsLegacyFallback = resolvedLegacyFallback
        lock.unlock()
        
        defer {
            lock.lock()
            if self.activeConnectTask == task {
                self.activeConnectTask = nil
                self.activeConnectAllowsLegacyFallback = nil
            }
            lock.unlock()
        }
        // T2: отмена вызывающего должна прерывать подключение, а не только ждать его.
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Потокобезопасная проверка расширения сервера (значения пишутся под lock в performConnect).
    public func hasServerExtension(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return serverExtensions[name] != nil
    }

    /// Потокобезопасное чтение лимитов сервера.
    public var currentServerLimits: SFTPLimits? {
        lock.lock()
        defer { lock.unlock() }
        return serverLimits
    }

    /// Проба живости канала: stat("/") с заданным таймаутом; бросает ошибку, если ответа нет.
    private func probeChannelAlive(_ chan: SFTPChannel, timeoutSeconds: TimeInterval) async throws {
        let requestId = chan.allocateRequestId()
        let packet = packetEngine.createStatPacket(requestId: requestId, path: "/")
        _ = try await chan.sendRequest(packet: packet, requestId: requestId, timeoutSeconds: timeoutSeconds)
    }

    /// Single-flight проба: одна задача на канал, её результат получают все вызывающие.
    /// Задача не привязана к вызывающему и не отменяется вместе с ним: отмена вызывающего
    /// даёт ему CancellationError, но не прерывает общую пробу и не рвёт сессию.
    /// Lock не удерживается через await.
    private func sharedHealthProbe(_ chan: SFTPChannel) async throws -> Bool {
        let id = ObjectIdentifier(chan)
        lock.lock()
        let probe: Task<Bool, Never>
        if let active = activeProbe, active.channel == id {
            probe = active.task
        } else {
            probe = Task { [weak self] () -> Bool in
                let alive = await self?.runHealthProbeRounds(chan) ?? false
                self?.finishHealthProbe(id)
                return alive
            }
            activeProbe = (id, probe)
        }
        lock.unlock()
        // Отмена вызывающего сразу прерывает его ожидание (T2), но не общую пробу.
        let waiter = HealthProbeWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                waiter.install(continuation)
                Task { waiter.resume(.success(await probe.value)) }
            }
        } onCancel: {
            waiter.resume(.failure(CancellationError()))
        }
    }

    /// Два раунда пробы: 2 с; при неудаче и живом канале — повтор с 5 с. Возвращает, жив ли канал.
    private func runHealthProbeRounds(_ chan: SFTPChannel) async -> Bool {
        do {
            // Короткий таймаут: мёртвая связь должна обнаруживаться за секунды, а не за 5+ с.
            try await probeChannelAlive(chan, timeoutSeconds: 2)
            return true
        } catch {
            SSHTransportLog.write("SFTP health probe failed channel=\(chan.channelId) error=\(error.localizedDescription)")
        }
        // Один медленный ответ (энергосбережение телефона, передача под нагрузкой) не означает разрыв.
        guard chan.isRunning else { return false }
        do {
            try await probeChannelAlive(chan, timeoutSeconds: 5)
            SSHTransportLog.write("SFTP health probe recovered on retry channel=\(chan.channelId)")
            return true
        } catch let retryError {
            SSHTransportLog.write("SFTP health probe retry failed channel=\(chan.channelId) error=\(retryError.localizedDescription)")
            return false
        }
    }

    /// Снимает активную пробу, если она всё ещё та же (вызывается из задачи пробы).
    private func finishHealthProbe(_ id: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        if activeProbe?.channel == id { activeProbe = nil }
    }

    private func performConnect(allowLegacyFallback: Bool, epoch: UInt64) async throws {
        lock.lock()
        guard epoch == sessionEpoch, !Task.isCancelled else {
            lock.unlock()
            throw CancellationError()
        }
        // T4: budget НЕ сбрасывается здесь: при активных передачах это обнулило бы их учёт.
        // Сброс бюджета происходит только в disconnect().
        // T3: расширения и лимиты сервера относятся к предыдущей сессии — очищаем до нового handshake.
        serverExtensions = [:]
        serverLimits = nil
        let currentEpoch = sessionEpoch
        let targetHost = self.host
        let targetPort = self.port
        let devId = self.deviceId
        let expectedKeyAlgorithm = self.expectedHostKeyAlgorithm
        let keyAlias = self.hostKeyAlias
        lock.unlock()
        defer {
            lock.lock()
            if epoch == sessionEpoch {
                if _interactiveChannel == nil {
                    connectingChannels.forEach { $0.close() }
                    cleanupMasterProcess()
                }
                connectingChannels.removeAll()
            }
            lock.unlock()
        }
        
        // Быстрая проверка доступности порта
        if !PhoneConnectionManager.shared.isHostPortReachable(host: targetHost, port: targetPort, timeoutSeconds: 1) {
            throw NSError(
                domain: "SessionCoordinator",
                code: 1004,
                userInfo: [NSLocalizedDescriptionKey: "Узел \(targetHost):\(targetPort) недоступен."]
            )
        }
        
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sshDir = home.appendingPathComponent(".ssh")
        try? FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        
        let keyURL = sshDir.appendingPathComponent("macdroid_id_ed25519")
        if !FileManager.default.fileExists(atPath: keyURL.path) {
            let keygen = Process()
            keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            keygen.arguments = ["-t", "ed25519", "-N", "", "-C", "macdroid@commander", "-f", keyURL.path]
            try? keygen.run()
            keygen.waitUntilExit()
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        }
        
        let knownHostsURL = HostKeyStore.shared.openSSHKnownHostsURL(host: targetHost, port: targetPort, deviceId: devId)
        if !FileManager.default.fileExists(atPath: knownHostsURL.path) {
            try? FileManager.default.createDirectory(at: knownHostsURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: knownHostsURL.path, contents: Data())
        }
        
        let sshUser = UserDefaults.standard.string(forKey: "sshUser") ?? NSUserName()
        
        // Базовые аргументы SSH
        var baseArgs = [
            "-i", keyURL.path,
        ]
        if allowLegacyFallback {
            let legacyEd25519 = sshDir.appendingPathComponent("id_ed25519")
            if FileManager.default.fileExists(atPath: legacyEd25519.path) {
                baseArgs.append(contentsOf: ["-i", legacyEd25519.path])
            }
        }
        baseArgs.append(contentsOf: [
            "-F", "/dev/null",
            "-o", "IdentitiesOnly=yes",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=2",
            "-o", "LogLevel=VERBOSE",
            "-o", "Compression=no",
            "-o", "IPQoS=throughput",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(HostKeyStore.openSSHConfigValue(knownHostsURL.path))",
            "-p", String(targetPort)
        ])
        if let keyAlias {
            baseArgs.append(contentsOf: ["-o", "HostKeyAlias=\(keyAlias)"])
        }
        if let expectedKeyAlgorithm {
            let allowedAlgorithms = expectedKeyAlgorithm == "ssh-rsa"
                ? "rsa-sha2-512,rsa-sha2-256,ssh-rsa"
                : expectedKeyAlgorithm
            baseArgs.append(contentsOf: ["-o", "HostKeyAlgorithms=\(allowedAlgorithms)"])
        }
        // Защита от инъекции опций: имя пользователя и адрес не могут начинаться с "-" и содержать мусор.
        guard Self.isValidSSHUser(sshUser), !targetHost.hasPrefix("-") else {
            throw NSError(domain: "SessionCoordinator", code: 1005, userInfo: [NSLocalizedDescriptionKey: "Недопустимое имя пользователя или адрес SSH."])
        }
        let sshDestination = "\(sshUser)@\(targetHost)"

        // Попытка OpenSSH Multiplexing через ControlMaster
        let socketDirectory = home.appendingPathComponent("Library/Caches/MCD", isDirectory: true)
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: socketDirectory.path)
        let sockPath = Self.controlSocketPath(home: home)
        
        var interactiveChan: SFTPChannel?
        var bulkChan: SFTPChannel?
        var isMultiplexed = false
        
        do {
            let masterProc = Process()
            masterProc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            var masterArgs = baseArgs
            masterArgs.append(contentsOf: [
                "-M",
                "-S", sockPath,
                "-N",
                sshDestination
            ])
            masterProc.arguments = masterArgs
            masterProc.standardInput = FileHandle.nullDevice
            masterProc.standardOutput = FileHandle.nullDevice
            let masterErrorPipe = Pipe()
            masterProc.standardError = masterErrorPipe
            let masterDiagnostics = SSHDiagnostics(pipe: masterErrorPipe)
            masterProc.terminationHandler = { process in
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) {
                    SSHTransportLog.write("ControlMaster exited status=\(process.terminationStatus) reason=\(process.terminationReason) stderr=\(masterDiagnostics.message)")
                }
            }
            
            try masterProc.run()
            self.lock.lock()
            guard epoch == sessionEpoch, !Task.isCancelled else {
                self.lock.unlock()
                masterProc.terminate()
                throw CancellationError()
            }
            self.masterProcess = masterProc
            self.muxSocketPath = sockPath
            self.lock.unlock()
            
            // Ждем появления сокета: Wi-Fi host-key handshake может занимать несколько секунд.
            var sockReady = false
            for _ in 0..<80 {
                if FileManager.default.fileExists(atPath: sockPath) {
                    sockReady = true
                    break
                }
                if !masterProc.isRunning { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            
            if sockReady {
                try checkControlMaster(sockPath: sockPath, port: targetPort, destination: sshDestination)
                // Создаем два SFTP канала через slave ssh процессы
                let chan1 = try spawnSlaveChannel(
                    sockPath: sockPath,
                    baseArgs: baseArgs,
                    destination: sshDestination,
                    masterDiagnostics: masterDiagnostics,
                    channelId: "interactive_\(currentEpoch)",
                    isInteractive: true
                )
                try trackConnectingChannel(chan1, epoch: epoch)
                let chan2 = try spawnSlaveChannel(
                    sockPath: sockPath,
                    baseArgs: baseArgs,
                    destination: sshDestination,
                    masterDiagnostics: masterDiagnostics,
                    channelId: "bulk_\(currentEpoch)",
                    isInteractive: false
                )
                try trackConnectingChannel(chan2, epoch: epoch)
                
                // Проверяем первый канал init
                let initPkt = packetEngine.createInitPacket()
                let (vType, vPayload) = try await chan1.sendInitPacket(packet: initPkt)
                if vType == .version {
                    let (_, extensions) = (try? packetEngine.parseVersionResponse(data: vPayload)) ?? (3, [:])
                    self.lock.lock()
                    self.serverExtensions = extensions
                    self.lock.unlock()
                    
                    // Инициализируем и второй канал
                    interactiveChan = chan1
                    let initPkt2 = packetEngine.createInitPacket()
                    do {
                        let secondInit = try await chan2.sendInitPacket(packet: initPkt2)
                        guard secondInit.type == .version else {
                            throw NSError(domain: "SessionCoordinator", code: 12, userInfo: [NSLocalizedDescriptionKey: "Unexpected SFTP init response: \(secondInit.type)"])
                        }
                        bulkChan = chan2
                    } catch {
                        SSHTransportLog.write("Bulk SFTP channel init failed channel=\(chan2.channelId) error=\(error.localizedDescription) stderr=\(chan2.sshDiagnosticMessage)")
                        // Один рабочий канал лучше двух, один из которых
                        // фактически не прошёл SFTP handshake.
                        chan2.close()
                        bulkChan = chan1
                    }
                    isMultiplexed = true
                }
            }
        } catch {
            try Task.checkCancellation()
            // Фолбэк на единый безопасный канал при невозможности мультиплексирования
            isMultiplexed = false
        }
        
        if !isMultiplexed {
            try Task.checkCancellation()
            // Очищаем неудавшийся мастер-процесс
            lock.lock()
            guard epoch == sessionEpoch else {
                lock.unlock()
                throw CancellationError()
            }
            connectingChannels.forEach { $0.close() }
            connectingChannels.removeAll()
            cleanupMasterProcess()
            lock.unlock()
            
            // Запускаем единый SFTP процесс напрямую: ssh ... -s sftp
            let singleProc = Process()
            singleProc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            var singleArgs = baseArgs
            singleArgs.append(contentsOf: [sshDestination, "-s", "sftp"])
            singleProc.arguments = singleArgs
            
            let inPipe = Pipe()
            let outPipe = Pipe()
            singleProc.standardInput = inPipe
            singleProc.standardOutput = outPipe
            let errorPipe = Pipe()
            singleProc.standardError = errorPipe
            let diagnostics = SSHDiagnostics(pipe: errorPipe)
            singleProc.terminationHandler = { process in
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) {
                    SSHTransportLog.write("SSH SFTP process exited channel=single_\(currentEpoch) status=\(process.terminationStatus) reason=\(process.terminationReason) stderr=\(diagnostics.message)")
                }
            }
            
            try singleProc.run()
            
            let chan = SFTPChannel(
                channelId: "single_\(currentEpoch)",
                isInteractive: true,
                process: singleProc,
                inHandle: inPipe.fileHandleForWriting,
                outHandle: outPipe.fileHandleForReading,
                diagnosticMessage: { diagnostics.message },
                waitForDiagnostics: { timeout in diagnostics.messageAfterDraining(timeout: timeout) }
            )
            try trackConnectingChannel(chan, epoch: epoch)
            
            let initPkt = packetEngine.createInitPacket()
            let (vType, vPayload) = try await chan.sendInitPacket(packet: initPkt)
            guard vType == .version else {
                throw NSError(domain: "SessionCoordinator", code: 10, userInfo: [NSLocalizedDescriptionKey: "Unexpected SFTP init response: \(vType)"])
            }
            let (_, extensions) = (try? packetEngine.parseVersionResponse(data: vPayload)) ?? (3, [:])
            self.lock.lock()
            self.serverExtensions = extensions
            self.lock.unlock()
            
            interactiveChan = chan
            bulkChan = chan
        }
        
        guard let activeInteractive = interactiveChan else {
            throw NSError(domain: "SessionCoordinator", code: 11, userInfo: [NSLocalizedDescriptionKey: "Failed to establish SFTP channel"])
        }
        
        // Запрос лимитов сервера, если поддерживается limits@openssh.com
        if serverExtensions["limits@openssh.com"] != nil {
            let limReqId = activeInteractive.allocateRequestId()
            let limPacket = packetEngine.createLimitsPacket(requestId: limReqId)
            if let (lType, lPayload) = try? await activeInteractive.sendRequest(packet: limPacket, requestId: limReqId), lType == .extendedReply {
                if let (_, limits) = try? packetEngine.parseLimitsResponse(data: lPayload) {
                    self.lock.lock()
                    self.serverLimits = limits
                    self.lock.unlock()
                }
            }
        }
        
        // Автоопределение корня (/emulated/0 <-> /)
        let statReqId = activeInteractive.allocateRequestId()
        let statPacket = packetEngine.createStatPacket(requestId: statReqId, path: "/emulated/0")
        if let (statResp, statPayload) = try? await activeInteractive.sendRequest(packet: statPacket, requestId: statReqId) {
            self.lock.lock()
            if statResp == .status,
               let (_, code, _) = try? packetEngine.parseStatusResponse(data: statPayload) {
                self.rootIsEmulatedZero = code == .noSuchFile
            } else {
                self.rootIsEmulatedZero = false
            }
            self.lock.unlock()
        }
        
        self.lock.lock()
        guard epoch == sessionEpoch, !Task.isCancelled, activeInteractive.isRunning else {
            self.lock.unlock()
            activeInteractive.close()
            bulkChan?.close()
            throw CancellationError()
        }
        self._interactiveChannel = activeInteractive
        self._bulkChannel = bulkChan
        self.activeSessionAllowsLegacyFallback = allowLegacyFallback
        self.lock.unlock()
    }

    private func trackConnectingChannel(_ channel: SFTPChannel, epoch: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard epoch == sessionEpoch, !Task.isCancelled else {
            channel.close()
            throw CancellationError()
        }
        connectingChannels.append(channel)
    }

    private func checkControlMaster(sockPath: String, port: UInt16, destination: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-F", "/dev/null", "-S", sockPath, "-p", String(port), "-O", "check", destination]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let diagnostics = SSHDiagnostics(pipe: errorPipe)
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            SSHTransportLog.write("ControlMaster check timed out socket=\(sockPath)")
            throw NSError(domain: "SessionCoordinator", code: 13, userInfo: [NSLocalizedDescriptionKey: "ControlMaster check timed out"])
        }
        guard process.terminationStatus == 0 else {
            let message = diagnostics.message
            SSHTransportLog.write("ControlMaster check failed status=\(process.terminationStatus) stderr=\(message)")
            throw NSError(domain: "SessionCoordinator", code: 14, userInfo: [NSLocalizedDescriptionKey: "ControlMaster unavailable: \(message)"])
        }
    }
    
    private func spawnSlaveChannel(
        sockPath: String,
        baseArgs: [String],
        destination: String,
        masterDiagnostics: SSHDiagnostics,
        channelId: String,
        isInteractive: Bool
    ) throws -> SFTPChannel {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = baseArgs + ["-S", sockPath, destination, "-s", "sftp"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        let errorPipe = Pipe()
        proc.standardError = errorPipe
        let diagnostics = SSHDiagnostics(pipe: errorPipe)
        proc.terminationHandler = { process in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) {
                SSHTransportLog.write("SSH SFTP process exited channel=\(channelId) status=\(process.terminationStatus) reason=\(process.terminationReason) stderr=\(diagnostics.message)")
            }
        }
        try proc.run()
        
        return SFTPChannel(
            channelId: channelId,
            isInteractive: isInteractive,
            process: proc,
            inHandle: inPipe.fileHandleForWriting,
            outHandle: outPipe.fileHandleForReading,
            diagnosticMessage: {
                [diagnostics.message, masterDiagnostics.message].filter { !$0.isEmpty }.joined(separator: "\n")
            },
            waitForDiagnostics: { timeout in
                let deadline = ProcessInfo.processInfo.systemUptime + timeout
                let channelMessage = diagnostics.messageAfterDraining(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
                let masterMessage = masterDiagnostics.messageAfterDraining(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
                return [channelMessage, masterMessage].filter { !$0.isEmpty }.joined(separator: "\n")
            }
        )
    }
    
    private func cleanupMasterProcess() {
        lock.lock()
        defer { lock.unlock() }
        if let proc = masterProcess, proc.isRunning {
            proc.terminate()
        }
        masterProcess = nil
        if let sock = muxSocketPath {
            try? FileManager.default.removeItem(atPath: sock)
            muxSocketPath = nil
        }
    }
    
    /// Снимает процессы сессии, чей interactive-канал умер, если подключение сейчас не идёт
    /// и по второму каналу не идёт передача (её не рвём: сессия снимется на следующем тике после неё).
    /// Вызывает монитор связи: иначе ControlMaster и сокет висят до следующей попытки подключения.
    public func releaseDeadSession() {
        lock.lock()
        defer { lock.unlock() }
        guard activeConnectTask == nil, let chan = _interactiveChannel, !chan.isRunning,
              _bulkChannel?.isRunning != true else { return }
        disconnect()
    }

    public func disconnect() {
        lock.lock()
        sessionEpoch &+= 1
        activeConnectTask?.cancel()
        activeConnectTask = nil
        activeConnectAllowsLegacyFallback = nil
        activeSessionAllowsLegacyFallback = nil
        connectingChannels.forEach { $0.close() }
        connectingChannels.removeAll()
        _interactiveChannel?.close()
        _interactiveChannel = nil
        _bulkChannel?.close()
        _bulkChannel = nil
        budget.reset()
        cleanupMasterProcess()
        lock.unlock()
    }
    
    /// Capture identity, channel, epoch and path mapping under one lock.
    public func captureExternalEditSession(fingerprint: String, path: String)
        throws -> (channel: SFTPChannel, epoch: UInt64, path: String) {
        lock.lock()
        defer { lock.unlock() }
        guard hostKeyFingerprint == fingerprint,
              let pinKey = HostKeyStore.shared.pinnedDeviceId(matchingFingerprint: fingerprint),
              hostKeyAlias == HostKeyStore.safeHostKeyAlias(pinKey) else { throw ExternalEditError.wrongDevice }
        guard let channel = _bulkChannel?.isRunning == true ? _bulkChannel : _interactiveChannel,
              channel.isRunning else { throw ExternalEditError.unavailable }
        return (channel, sessionEpoch, toSftpPath(path))
    }

    public func toSftpPath(_ path: String) -> String {
        var p = path.precomposedStringWithCanonicalMapping
        lock.lock()
        let emZero = rootIsEmulatedZero
        lock.unlock()
        
        if emZero && p.hasPrefix("/storage/emulated/0") {
            p = String(p.dropFirst("/storage/emulated/0".count))
        } else if p.hasPrefix("/storage") {
            p = String(p.dropFirst("/storage".count))
        }
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        if p.isEmpty || p == "/" {
            return "/"
        }
        if !p.hasPrefix("/") {
            p = "/" + p
        }
        return p
    }
}

/// Одноразовое ожидание общей пробы: результат или отмена — что придёт раньше.
/// Отмена до `install` запоминается и применяется при установке continuation.
private final class HealthProbeWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Error>?
    private var pending: Result<Bool, Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Bool, Error>) {
        lock.lock()
        if let pending {
            finished = true
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ result: Result<Bool, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard let continuation else {
            if pending == nil { pending = result }
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
