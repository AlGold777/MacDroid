import Foundation
import CryptoKit

/// Единый координатор сессии Mac ↔ Android, управляющий жизненным циклом соединения,
/// каналами SFTP, бюджетами ресурсов и сопоставлением путей.
public final class SessionCoordinator: @unchecked Sendable {
    public static let shared = SessionCoordinator()
    
    private let lock = NSRecursiveLock()
    
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
    
    public init() {}
    
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
        return _bulkChannel ?? _interactiveChannel
    }
    
    public func updateEndpoint(host: String, port: UInt16, deviceId: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if self.host == host && self.port == port && self.deviceId == deviceId && isConnected {
            return
        }
        self.host = host
        self.port = port
        self.deviceId = deviceId
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
    
    /// Гарантирует активное подключение к Android
    public func ensureConnected(allowLegacyFallback: Bool = false) async throws {
        lock.lock()
        if let chan = _interactiveChannel, chan.isRunning {
            lock.unlock()
            return
        }
        if let existing = activeConnectTask {
            lock.unlock()
            try await existing.value
            return
        }
        
        let task = Task { [weak self] () -> Void in
            guard let self = self else { return }
            try await self.performConnect(allowLegacyFallback: allowLegacyFallback)
        }
        self.activeConnectTask = task
        lock.unlock()
        
        defer {
            lock.lock()
            if self.activeConnectTask == task {
                self.activeConnectTask = nil
            }
            lock.unlock()
        }
        try await task.value
    }
    
    private func performConnect(allowLegacyFallback: Bool) async throws {
        disconnect()
        
        lock.lock()
        sessionEpoch += 1
        budget.reset()
        let currentEpoch = sessionEpoch
        let targetHost = self.host
        let targetPort = self.port
        let devId = self.deviceId
        lock.unlock()
        
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
        
        let isLoopback = (targetHost == "127.0.0.1" || targetHost == "localhost")
        let knownHostsURL: URL
        if isLoopback {
            let devTag = devId ?? PhoneConnectionManager.shared.getConnectedDeviceId() ?? "usb_default"
            knownHostsURL = sshDir.appendingPathComponent("macdroid_known_hosts_\(devTag)")
        } else {
            knownHostsURL = sshDir.appendingPathComponent("macdroid_known_hosts")
        }
        if !FileManager.default.fileExists(atPath: knownHostsURL.path) {
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
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-o", "Compression=no",
            "-o", "IPQoS=throughput",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHostsURL.path)",
            "-p", String(targetPort)
        ])
        let sshDestination = "\(sshUser)@\(targetHost)"
        
        // Попытка OpenSSH Multiplexing через ControlMaster
        let socketId = UUID().uuidString.prefix(8)
        let sockPath = "/tmp/mcd_\(socketId).sock"
        
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
            masterProc.standardError = FileHandle.nullDevice
            
            try masterProc.run()
            self.lock.lock()
            self.masterProcess = masterProc
            self.muxSocketPath = sockPath
            self.lock.unlock()
            
            // Ждем появления сокета (до 2 сек)
            var sockReady = false
            for _ in 0..<20 {
                if FileManager.default.fileExists(atPath: sockPath) {
                    sockReady = true
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            
            if sockReady {
                // Создаем два SFTP канала через slave ssh процессы
                let chan1 = try spawnSlaveChannel(
                    sockPath: sockPath,
                    destination: sshDestination,
                    channelId: "interactive_\(currentEpoch)",
                    isInteractive: true
                )
                let chan2 = try spawnSlaveChannel(
                    sockPath: sockPath,
                    destination: sshDestination,
                    channelId: "bulk_\(currentEpoch)",
                    isInteractive: false
                )
                
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
                    if let secondInit = try? await chan2.sendInitPacket(packet: initPkt2), secondInit.type == .version {
                        bulkChan = chan2
                    } else {
                        // Один рабочий канал лучше двух, один из которых
                        // фактически не прошёл SFTP handshake.
                        chan2.close()
                        bulkChan = chan1
                    }
                    isMultiplexed = true
                }
            }
        } catch {
            // Фолбэк на единый безопасный канал при невозможности мультиплексирования
            isMultiplexed = false
        }
        
        if !isMultiplexed {
            // Очищаем неудавшийся мастер-процесс
            cleanupMasterProcess()
            
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
            singleProc.standardError = FileHandle.nullDevice
            
            try singleProc.run()
            
            let chan = SFTPChannel(
                channelId: "single_\(currentEpoch)",
                isInteractive: true,
                process: singleProc,
                inHandle: inPipe.fileHandleForWriting,
                outHandle: outPipe.fileHandleForReading
            )
            
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
        if let (statResp, _) = try? await activeInteractive.sendRequest(packet: statPacket, requestId: statReqId) {
            self.lock.lock()
            self.rootIsEmulatedZero = (statResp != .attrs)
            self.lock.unlock()
        }
        
        self.lock.lock()
        self._interactiveChannel = activeInteractive
        self._bulkChannel = bulkChan
        self.lock.unlock()
    }
    
    private func spawnSlaveChannel(sockPath: String, destination: String, channelId: String, isInteractive: Bool) throws -> SFTPChannel {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-S", sockPath,
            "-F", "/dev/null",
            "-o", "BatchMode=yes",
            destination,
            "-s", "sftp"
        ]
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        
        return SFTPChannel(
            channelId: channelId,
            isInteractive: isInteractive,
            process: proc,
            inHandle: inPipe.fileHandleForWriting,
            outHandle: outPipe.fileHandleForReading
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
    
    public func disconnect() {
        lock.lock()
        activeConnectTask?.cancel()
        activeConnectTask = nil
        _interactiveChannel?.close()
        _interactiveChannel = nil
        _bulkChannel?.close()
        _bulkChannel = nil
        budget.reset()
        lock.unlock()
        
        cleanupMasterProcess()
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
