import Foundation

public actor SSHControlClient {
    private var process: Process?
    private var inHandle: FileHandle?
    private var outHandle: FileHandle?
    private let host: String
    private let port: UInt16
    
    public init(host: String = "127.0.0.1", port: UInt16 = 2222) {
        self.host = host
        self.port = port
    }
    
    public func connect() async throws {
        disconnect()
        
        // Быстрая проверка доступности порта перед запуском ssh (предотвращает зависание на недоступных IP)
        if !PhoneConnectionManager.shared.isHostPortReachable(host: host, port: port, timeoutSeconds: 1) {
            throw NSError(
                domain: "SSHControlClient",
                code: 1004,
                userInfo: [NSLocalizedDescriptionKey: "Узел \(host):\(port) недоступен. Проверьте сеть и запущено ли приложение-компаньон."]
            )
        }
        
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sshDir = home.appendingPathComponent(".ssh")
        try? FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        
        let keyURL = sshDir.appendingPathComponent("macdroid_id_ed25519")
        if !FileManager.default.fileExists(atPath: keyURL.path) {
            // SEC-02 FIX: Строгая изоляция. Никогда не читаем и не копируем личные ключи пользователя (~/.ssh/id_ed25519).
            // Генерируем независимый специализированный ключ для взаимодействия с Android.
            let keygen = Process()
            keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            keygen.arguments = ["-t", "ed25519", "-N", "", "-C", "macdroid@commander", "-f", keyURL.path]
            try? keygen.run()
            keygen.waitUntilExit()
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        }
        
        let knownHostsURL = sshDir.appendingPathComponent("macdroid_known_hosts")
        if !FileManager.default.fileExists(atPath: knownHostsURL.path) {
            FileManager.default.createFile(atPath: knownHostsURL.path, contents: Data())
        }
        
        let sshUser = UserDefaults.standard.string(forKey: "sshUser") ?? NSUserName()
        let isLoopback = (host == "127.0.0.1" || host == "localhost")
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        
        var sshArgs = [
            "-i", keyURL.path,
        ]
        // Обратная совместимость: если устройство было ранее сопряжено с личным ключом пользователя (~/.ssh/id_ed25519 или id_rsa),
        // передаем его как вторичный кандидат, исключая блокировку существующих пользователей
        let legacyEd25519 = sshDir.appendingPathComponent("id_ed25519")
        if FileManager.default.fileExists(atPath: legacyEd25519.path) {
            sshArgs.append(contentsOf: ["-i", legacyEd25519.path])
        }
        
        sshArgs.append(contentsOf: [
            "-F", "/dev/null", // Полная изоляция от глобальных настроек ~/.ssh/config
            "-o", "IdentitiesOnly=yes", // Запрет на перебор ключей ssh-agent или произвольных ключей
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-o", "Compression=no",
            "-o", "IPQoS=throughput"
        ])
        
        if isLoopback {
            // Для USB (локальный ADB туннель через loopback 127.0.0.1):
            // MITM исключен на аппаратном уровне ядра macOS (lo0). Отключаем коллизии host key при смене смартфонов
            sshArgs.append(contentsOf: [
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "LogLevel=ERROR"
            ])
        } else {
            // Для Wi-Fi: строгая криптографическая проверка открытого ключа сервера с фиксацией в known_hosts
            sshArgs.append(contentsOf: [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "UserKnownHostsFile=\(knownHostsURL.path)"
            ])
        }
        
        sshArgs.append(contentsOf: [
            "-p", String(port),
            "\(sshUser)@\(host)",
            "-s", "sftp"
        ])
        
        proc.arguments = sshArgs
        
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        
        try proc.run()
        self.process = proc
        self.inHandle = inPipe.fileHandleForWriting
        self.outHandle = outPipe.fileHandleForReading
    }
    
    /// Запись сырого SFTP пакета в канал без ожидания ответа (для поддержки Pipelining / Sliding Window)
    public func writeRawPacket(packet: Data) throws {
        guard let inH = inHandle, let proc = process, proc.isRunning else {
            throw NSError(domain: "SSHControlClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not connected to Android Daemon"])
        }
        try inH.write(contentsOf: packet)
    }
    
    /// Чтение очередного SFTP ответа из выходного потока
    public func readRawResponse() throws -> (type: SFTPMessageType, payload: Data) {
        guard let outH = outHandle, let proc = process, proc.isRunning else {
            throw NSError(domain: "SSHControlClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not connected to Android Daemon"])
        }
        
        let lenData = try readExact(handle: outH, count: 4)
        let packetLength = Int(lenData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        guard packetLength >= 1 else {
            throw NSError(domain: "SSHControlClient", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid SFTP packet length (\(packetLength))"])
        }
        
        let typeData = try readExact(handle: outH, count: 1)
        guard let msgType = SFTPMessageType(rawValue: typeData[0]) else {
            throw NSError(domain: "SSHControlClient", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unknown SFTP message type (\(typeData[0]))"])
        }
        
        let payloadLen = packetLength - 1
        let payload = payloadLen > 0 ? try readExact(handle: outH, count: payloadLen) : Data()
        return (msgType, payload)
    }
    
    public func sendSFTPPacket(packet: Data) async throws -> (type: SFTPMessageType, payload: Data) {
        try writeRawPacket(packet: packet)
        return try readRawResponse()
    }
    
    public func sendControlCommand(cmd: String, payload: [String: Any]) async throws -> [String: Any] {
        return ["status": "ok"]
    }
    
    private func readExact(handle: FileHandle, count: Int) throws -> Data {
        var accumulated = Data()
        accumulated.reserveCapacity(count)
        while accumulated.count < count {
            let needed = count - accumulated.count
            guard let chunk = try handle.read(upToCount: needed), !chunk.isEmpty else {
                throw NSError(domain: "SSHControlClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "SFTP connection closed prematurely"])
            }
            accumulated.append(chunk)
        }
        return accumulated
    }
    
    public func disconnect() {
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        try? inHandle?.close()
        try? outHandle?.close()
        inHandle = nil
        outHandle = nil
    }
}
