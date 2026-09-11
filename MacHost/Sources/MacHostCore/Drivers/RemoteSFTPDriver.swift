import Foundation

public final class RemoteSFTPDriver: FileSystemDriver, @unchecked Sendable {
    private var host: String
    private var port: UInt16
    private var sshClient: SSHControlClient
    private let packetEngine = SFTPPacketEngine()
    private let hostKeyStore = HostKeyStore.shared
    private var isSftpInitialized = false
    private let lock = NSLock()
    private var nextReqId: UInt32 = 100
    
    public private(set) var isConnected: Bool = false
    public private(set) var lastSyncTimestamp: Double = 0
    
    public init(host: String = "127.0.0.1", port: UInt16 = 2222) {
        self.host = host
        self.port = port
        self.sshClient = SSHControlClient(host: host, port: port)
    }
    
    public func updateEndpoint(host: String, port: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        self.host = host
        self.port = port
        self.sshClient = SSHControlClient(host: host, port: port)
        self.isSftpInitialized = false
        self.isConnected = false
    }
    
    private func getNextRequestId() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        let req = nextReqId
        nextReqId = (nextReqId == UInt32.max) ? 1 : nextReqId + 1
        return req
    }
    
    private func ensureConnected() async throws {
        if !isSftpInitialized {
            do {
                try await sshClient.connect()
                let initPacket = packetEngine.createInitPacket()
                let (respType, _) = try await sshClient.sendSFTPPacket(packet: initPacket)
                guard respType == .version else {
                    throw NSError(
                        domain: "RemoteSFTPDriver",
                        code: 10,
                        userInfo: [NSLocalizedDescriptionKey: "Unexpected SFTP init response: \(respType)"]
                    )
                }
                isSftpInitialized = true
                isConnected = true
                
                // Авто-определение структуры корня SFTP:
                // Проверяем, существует ли /emulated/0 на сервере.
                // Если нет — корень SFTP на смартфоне привязан напрямую к /storage/emulated/0
                let statReqId = getNextRequestId()
                let statPacket = packetEngine.createStatPacket(requestId: statReqId, path: "/emulated/0")
                if let (statResp, _) = try? await sshClient.sendSFTPPacket(packet: statPacket) {
                    self.rootIsEmulatedZero = (statResp != .attrs)
                }
            } catch {
                isSftpInitialized = false
                isConnected = false
                throw error
            }
        }
    }
    
    public var rootIsEmulatedZero: Bool = false
    
    private func toSftpPath(_ path: String) -> String {
        var p = path.precomposedStringWithCanonicalMapping
        if rootIsEmulatedZero && p.hasPrefix("/storage/emulated/0") {
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
    
    public func listDirectory(at path: String) async throws -> [FileItem] {
        let nfcPath = path.precomposedStringWithCanonicalMapping
        let sftpPath = toSftpPath(path)
        self.lastSyncTimestamp = Date().timeIntervalSince1970
        
        do {
            try await ensureConnected()
            
            // 1. Открываем каталог через SSH_FXP_OPENDIR
            let openDirReqId = getNextRequestId()
            var currentSftpPath = sftpPath
            let openDirPacket = packetEngine.createOpenDirPacket(requestId: openDirReqId, path: currentSftpPath)
            var (openRespType, openPayload) = try await sshClient.sendSFTPPacket(packet: openDirPacket)
            
            // Если каталог не найден, проверяем альтернативное сопоставление корня (/emulated/0 <-> /)
            if openRespType != .handle {
                let altPath: String
                if currentSftpPath.hasPrefix("/emulated/0") {
                    let sub = String(currentSftpPath.dropFirst("/emulated/0".count))
                    altPath = sub.isEmpty ? "/" : sub
                } else {
                    altPath = "/emulated/0" + (currentSftpPath == "/" ? "" : currentSftpPath)
                }
                let altPacket = packetEngine.createOpenDirPacket(requestId: getNextRequestId(), path: altPath)
                if let (altResp, altData) = try? await sshClient.sendSFTPPacket(packet: altPacket), altResp == .handle {
                    self.rootIsEmulatedZero = currentSftpPath.hasPrefix("/emulated/0")
                    currentSftpPath = altPath
                    openRespType = altResp
                    openPayload = altData
                }
            }
            
            guard openRespType == .handle else {
                throw NSError(
                    domain: "RemoteSFTPDriver",
                    code: 20,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to open remote dir: \(nfcPath)"]
                )
            }
            let (_, dirHandle) = try packetEngine.parseHandleResponse(data: openPayload)
            
            var allEntries: [FileItem] = []
            
            // 2. Читаем записи каталога через SSH_FXP_READDIR
            while true {
                let readDirReqId = getNextRequestId()
                let readDirPacket = packetEngine.createReadDirPacket(requestId: readDirReqId, handle: dirHandle)
                let (readRespType, readPayload) = try await sshClient.sendSFTPPacket(packet: readDirPacket)
                
                if readRespType == .name {
                    let nameEntries = try packetEngine.parseNameResponse(data: readPayload)
                    for entry in nameEntries {
                        if entry.filename == "." || entry.filename == ".." {
                            continue
                        }
                        let itemPath = (nfcPath as NSString).appendingPathComponent(entry.filename).precomposedStringWithCanonicalMapping
                        allEntries.append(FileItem(
                            id: itemPath,
                            name: entry.filename,
                            path: itemPath,
                            size: entry.size,
                            mtime: Double(entry.mtime),
                            isDirectory: entry.isDirectory,
                            source: .remotePhone
                        ))
                    }
                } else if readRespType == .status {
                    let (_, code, _) = try packetEngine.parseStatusResponse(data: readPayload)
                    if code == .eof { break }
                    break
                } else {
                    break
                }
            }
            
            // 3. Закрываем дескриптор каталога
            let closeReqId = getNextRequestId()
            let closePacket = packetEngine.createClosePacket(requestId: closeReqId, handle: dirHandle)
            _ = try? await sshClient.sendSFTPPacket(packet: closePacket)
            
            return allEntries
            
        } catch {
            // Если SFTP недоступен, но подключен кабель USB / ADB:
            // 1) Получаем реальные файлы напрямую через ADB shell
            if let adbItems = PhoneConnectionManager.shared.listDirectoryAdb(path: nfcPath) {
                // В фоне запускаем автоматическое поднятие SFTP (adb forward + запуск демона)
                Task {
                    _ = await PhoneConnectionManager.shared.establishConnection()
                }
                return adbItems
            }
            
            // 2) Если ADB также недоступен — телефон действительно оффлайн.
            // НЕ возвращаем фальшивые заглушки-папки! Бросаем явную ошибку для понятного отображения в UI.
            throw NSError(
                domain: "RemoteSFTPDriver",
                code: 1009,
                userInfo: [NSLocalizedDescriptionKey: "Телефон не подключен. Подключите смартфон по USB или выполните сопряжение по Wi-Fi."]
            )
        }
    }
    
    public func createDirectory(at path: String) async throws {
        let reqId = getNextRequestId()
        let sftpPath = toSftpPath(path)
        do {
            try await ensureConnected()
            let packet = packetEngine.createMkdirPacket(requestId: reqId, path: sftpPath)
            let (respType, payload) = try await sshClient.sendSFTPPacket(packet: packet)
            if respType == .status {
                let (_, code, msg) = try packetEngine.parseStatusResponse(data: payload)
                if code != .ok {
                    throw NSError(domain: "RemoteSFTPDriver", code: Int(code.rawValue), userInfo: [NSLocalizedDescriptionKey: "MKDIR failed: \(msg)"])
                }
            }
        } catch {
            // Резервная попытка через ADB mkdir -p (если доступен USB/ADB)
            let escaped = PhoneConnectionManager.shellEscape(path)
            let (status, adbErr) = PhoneConnectionManager.shared.executeAdbShell(command: "mkdir -p -- \(escaped)")
            if status == 0 {
                return
            }
            throw NSError(domain: "RemoteSFTPDriver", code: 30, userInfo: [NSLocalizedDescriptionKey: "Не удалось создать каталог «\(path)»: \(error.localizedDescription) (ADB: \(adbErr))"])
        }
    }
    
    public func deleteItem(at path: String, moveToTrash: Bool) async throws {
        // Быстрый путь через ADB rm -rf (если доступен USB/ADB)
        if PhoneConnectionManager.shared.fastDeleteAdb(remotePath: path) {
            return
        }
        
        let sftpPath = toSftpPath(path)
        try await ensureConnected()
        
        // Сначала пробуем удалить как файл (SSH_FXP_REMOVE)
        let reqId = getNextRequestId()
        let removePacket = packetEngine.createRemovePacket(requestId: reqId, path: sftpPath)
        let (respType, payload) = try await sshClient.sendSFTPPacket(packet: removePacket)
        if respType == .status {
            let (_, code, _) = try packetEngine.parseStatusResponse(data: payload)
            if code == .ok {
                return
            }
        }
        
        // Если как файл не удалилось, пробуем удалить как пустую директорию (SSH_FXP_RMDIR)
        let rmdirReqId = getNextRequestId()
        let rmdirPacket = packetEngine.createRmdirPacket(requestId: rmdirReqId, path: sftpPath)
        let (rmdirResp, rmdirPayload) = try await sshClient.sendSFTPPacket(packet: rmdirPacket)
        if rmdirResp == .status {
            let (_, rmdirCode, _) = try packetEngine.parseStatusResponse(data: rmdirPayload)
            if rmdirCode == .ok {
                return
            }
        }
        
        // Если папка не пуста — рекурсивно удаляем всё её содержимое по SFTP
        try await deleteDirectoryRecursive(at: path)
    }
    
    /// Безопасное удаление директории ТОЛЬКО если она пустая (SSH_FXP_RMDIR)
    public func deleteEmptyDirectory(at path: String) async throws -> Bool {
        let sftpPath = toSftpPath(path)
        try await ensureConnected()
        let rmdirReqId = getNextRequestId()
        let rmdirPacket = packetEngine.createRmdirPacket(requestId: rmdirReqId, path: sftpPath)
        let (rmdirResp, rmdirPayload) = try await sshClient.sendSFTPPacket(packet: rmdirPacket)
        if rmdirResp == .status {
            let (_, rmdirCode, _) = try packetEngine.parseStatusResponse(data: rmdirPayload)
            return rmdirCode == .ok
        }
        return false
    }
    
    /// Рекурсивное удаление содержимого директории по SFTP (post-order traversal)
    private func deleteDirectoryRecursive(at path: String) async throws {
        let entries = try await listDirectory(at: path)
        for entry in entries {
            if entry.isDirectory {
                try await deleteDirectoryRecursive(at: entry.path)
            } else {
                let sftpChildPath = toSftpPath(entry.path)
                let reqId = getNextRequestId()
                let removePacket = packetEngine.createRemovePacket(requestId: reqId, path: sftpChildPath)
                _ = try? await sshClient.sendSFTPPacket(packet: removePacket)
            }
        }
        
        // После удаления всех вложенных файлов и папок удаляем сам каталог
        let sftpPath = toSftpPath(path)
        let rmdirReqId = getNextRequestId()
        let rmdirPacket = packetEngine.createRmdirPacket(requestId: rmdirReqId, path: sftpPath)
        let (rmdirResp, rmdirPayload) = try await sshClient.sendSFTPPacket(packet: rmdirPacket)
        if rmdirResp == .status {
            let (_, rmdirCode, rmdirMsg) = try packetEngine.parseStatusResponse(data: rmdirPayload)
            if rmdirCode != .ok {
                throw NSError(domain: "RemoteSFTPDriver", code: Int(rmdirCode.rawValue), userInfo: [NSLocalizedDescriptionKey: "Delete dir failed: \(rmdirMsg)"])
            }
        }
    }
    
    public func renameItem(from sourcePath: String, to destinationPath: String) async throws {
        let reqId = getNextRequestId()
        let sftpSrc = toSftpPath(sourcePath)
        let sftpDst = toSftpPath(destinationPath)
        do {
            try await ensureConnected()
            let packet = packetEngine.createRenamePacket(requestId: reqId, oldPath: sftpSrc, newPath: sftpDst)
            let (respType, payload) = try await sshClient.sendSFTPPacket(packet: packet)
            if respType == .status {
                let (_, code, msg) = try packetEngine.parseStatusResponse(data: payload)
                if code != .ok {
                    throw NSError(domain: "RemoteSFTPDriver", code: Int(code.rawValue), userInfo: [NSLocalizedDescriptionKey: "Rename failed: \(msg)"])
                }
            }
        } catch {
            // Резервная попытка через ADB mv (если доступен USB/ADB)
            let escapedSrc = PhoneConnectionManager.shellEscape(sourcePath)
            let escapedDst = PhoneConnectionManager.shellEscape(destinationPath)
            let (status, adbErr) = PhoneConnectionManager.shared.executeAdbShell(command: "mv -- \(escapedSrc) \(escapedDst)")
            if status == 0 {
                return
            }
            throw NSError(domain: "RemoteSFTPDriver", code: 31, userInfo: [NSLocalizedDescriptionKey: "Не удалось переименовать «\(sourcePath)»: \(error.localizedDescription) (ADB: \(adbErr))"])
        }
    }
    
    private var cachedSpace: (free: UInt64, total: UInt64)?
    private var cachedSpaceTime: Date?
    
    private func getCachedSpace() -> (free: UInt64, total: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedSpace, let time = cachedSpaceTime, Date().timeIntervalSince(time) < 15.0 {
            return cached
        }
        return nil
    }
    
    private func setCachedSpace(_ space: (free: UInt64, total: UInt64)) {
        lock.lock()
        defer { lock.unlock() }
        cachedSpace = space
        cachedSpaceTime = Date()
    }
    
    public func checkFreeSpace(at path: String) async throws -> (free: UInt64, total: UInt64) {
        if let cached = getCachedSpace() {
            return cached
        }
        
        // 1. Попытка получить через ADB df
        if let adbSpace = PhoneConnectionManager.shared.getStorageSpaceAdb() {
            setCachedSpace(adbSpace)
            return adbSpace
        }
        
        // 2. Попытка запросить df через SSH
        if let sshSpace = await queryStorageSpaceViaSSH() {
            setCachedSpace(sshSpace)
            return sshSpace
        }
        
        // 3. Fallback (дефолтные значения)
        let fallback = (UInt64(280_000_000_000), UInt64(512_000_000_000))
        setCachedSpace(fallback)
        return fallback
    }
    
    private func queryStorageSpaceViaSSH() async -> (free: UInt64, total: UInt64)? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let keyURL = home.appendingPathComponent(".ssh/id_ed25519")
        guard FileManager.default.fileExists(atPath: keyURL.path) else { return nil }
        
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
            "-o", "ConnectTimeout=3",
            "-p", String(port),
            "\(sshUser)@\(host)",
            "df"
        ]
        
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let out = String(data: data, encoding: .utf8) else { return nil }
            
            // Парсинг вывода EmbeddedServer df:
            // Filesystem 1B-blocks Used Available Use% Mounted on
            // /storage/emulated/0 <totalBytes> <usedBytes> <availBytes> 50% /storage/emulated/0
            let lines = out.components(separatedBy: "\n")
            guard lines.count >= 2 else { return nil }
            let parts = lines[1].split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 4 {
                if let total = UInt64(parts[1]), let avail = UInt64(parts[3]), total > 0 {
                    return (free: avail, total: total)
                }
            }
        } catch {
            return nil
        }
        return nil
    }
}
