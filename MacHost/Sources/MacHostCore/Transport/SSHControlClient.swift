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
        
        let keyURL = sshDir.appendingPathComponent("id_ed25519")
        if !FileManager.default.fileExists(atPath: keyURL.path) {
            let keygen = Process()
            keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            keygen.arguments = ["-t", "ed25519", "-N", "", "-f", keyURL.path]
            try? keygen.run()
            keygen.waitUntilExit()
        }
        
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDir = appSupport.appendingPathComponent("MacDroidCommander")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let knownHostsURL = appDir.appendingPathComponent("known_hosts")
        if !FileManager.default.fileExists(atPath: knownHostsURL.path) {
            FileManager.default.createFile(atPath: knownHostsURL.path, contents: Data())
        }
        
        let sshUser = UserDefaults.standard.string(forKey: "sshUser") ?? NSUserName()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-i", keyURL.path,
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHostsURL.path)",
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-p", String(port),
            "\(sshUser)@\(host)",
            "-s", "sftp"
        ]
        
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
    
    public func sendSFTPPacket(packet: Data) async throws -> (type: SFTPMessageType, payload: Data) {
        guard let inH = inHandle, let outH = outHandle, let proc = process, proc.isRunning else {
            throw NSError(domain: "SSHControlClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not connected to Android Daemon"])
        }
        
        try inH.write(contentsOf: packet)
        
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
