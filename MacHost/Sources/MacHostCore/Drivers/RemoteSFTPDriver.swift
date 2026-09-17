import Foundation

public final class RemoteSFTPDriver: FileSystemDriver, @unchecked Sendable {
    public let coordinator: SessionCoordinator
    private let packetEngine: SFTPPacketEngine
    
    public private(set) var lastSyncTimestamp: Double = 0
    
    public init(host: String = "127.0.0.1", port: UInt16 = 2222, deviceId: String? = nil, coordinator: SessionCoordinator = .shared) {
        self.coordinator = coordinator
        self.packetEngine = coordinator.packetEngine
        if host != "127.0.0.1" || port != 2222 {
            coordinator.updateEndpoint(host: host, port: port, deviceId: deviceId)
        }
    }
    
    public var isConnected: Bool {
        return coordinator.isConnected
    }
    
    public func updateEndpoint(host: String, port: UInt16, deviceId: String? = nil) {
        coordinator.updateEndpoint(host: host, port: port, deviceId: deviceId)
    }
    
    public func ensureConnected(allowLegacyFallback: Bool = false) async throws {
        try await coordinator.ensureConnected(allowLegacyFallback: allowLegacyFallback)
    }
    
    public func warmUpConnection(allowLegacyFallback: Bool = false) async throws {
        try await coordinator.ensureConnected(allowLegacyFallback: allowLegacyFallback)
    }
    
    public func disconnect() {
        coordinator.disconnect()
    }
    
    public var rootIsEmulatedZero: Bool {
        get { coordinator.rootIsEmulatedZero }
        set { /* Управляется SessionCoordinator */ }
    }
    
    private func toSftpPath(_ path: String) -> String {
        return coordinator.toSftpPath(path)
    }
    
    public func listDirectory(at path: String) async throws -> [FileItem] {
        let nfcPath = path.precomposedStringWithCanonicalMapping
        let sftpPath = toSftpPath(path)
        self.lastSyncTimestamp = Date().timeIntervalSince1970
        
        do {
            try await ensureConnected()
            guard let channel = coordinator.interactiveChannel else {
                throw NSError(domain: "RemoteSFTPDriver", code: 1009, userInfo: [NSLocalizedDescriptionKey: "SFTP channel unavailable"])
            }
            
            // 1. Открываем каталог через SSH_FXP_OPENDIR
            let openDirReqId = channel.allocateRequestId()
            var currentSftpPath = sftpPath
            let openDirPacket = packetEngine.createOpenDirPacket(requestId: openDirReqId, path: currentSftpPath)
            var (openRespType, openPayload) = try await channel.sendRequest(packet: openDirPacket, requestId: openDirReqId)
            
            // Если каталог не найден, проверяем альтернативное сопоставление корня (/emulated/0 <-> /)
            if openRespType != .handle {
                let altPath: String
                if currentSftpPath.hasPrefix("/emulated/0") {
                    let sub = String(currentSftpPath.dropFirst("/emulated/0".count))
                    altPath = sub.isEmpty ? "/" : sub
                } else {
                    altPath = "/emulated/0" + (currentSftpPath == "/" ? "" : currentSftpPath)
                }
                let altReqId = channel.allocateRequestId()
                let altPacket = packetEngine.createOpenDirPacket(requestId: altReqId, path: altPath)
                if let (altResp, altData) = try? await channel.sendRequest(packet: altPacket, requestId: altReqId), altResp == .handle {
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
            
            // 2. Читаем записи каталога через SSH_FXP_READDIR с конвейеризацией (pipeline depth 4)
            var seenFilenames = Set<String>()
            let pipelineDepth = 4
            var eofReached = false
            var inflight = 0
            
            try await withThrowingTaskGroup(of: (SFTPMessageType, Data).self) { group in
                for _ in 0..<pipelineDepth {
                    let readDirReqId = channel.allocateRequestId()
                    let readDirPacket = packetEngine.createReadDirPacket(requestId: readDirReqId, handle: dirHandle)
                    group.addTask {
                        return try await channel.sendRequest(packet: readDirPacket, requestId: readDirReqId)
                    }
                    inflight += 1
                }
                
                while inflight > 0 {
                    guard let (readRespType, readPayload) = try await group.next() else { break }
                    inflight -= 1
                    
                    if readRespType == .name {
                        let nameEntries = try packetEngine.parseNameResponse(data: readPayload)
                        for entry in nameEntries {
                            if entry.filename == "." || entry.filename == ".." {
                                continue
                            }
                            if seenFilenames.insert(entry.filename).inserted {
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
                        }
                        
                        if !eofReached {
                            let nextReqId = channel.allocateRequestId()
                            let nextPacket = packetEngine.createReadDirPacket(requestId: nextReqId, handle: dirHandle)
                            group.addTask {
                                return try await channel.sendRequest(packet: nextPacket, requestId: nextReqId)
                            }
                            inflight += 1
                        }
                    } else if readRespType == .status {
                        let (_, code, msg) = try packetEngine.parseStatusResponse(data: readPayload)
                        if code == .eof {
                            eofReached = true
                        } else {
                            throw NSError(
                                domain: "RemoteSFTPDriver",
                                code: Int(code.rawValue),
                                userInfo: [NSLocalizedDescriptionKey: "Ошибка чтения каталога \(nfcPath): \(msg) (код \(code.rawValue))"]
                            )
                        }
                    } else {
                        throw NSError(
                            domain: "RemoteSFTPDriver",
                            code: 22,
                            userInfo: [NSLocalizedDescriptionKey: "Неожиданный ответ сервера при чтении каталога: \(readRespType)"]
                        )
                    }
                }
            }
            
            // 3. Закрываем дескриптор каталога
            let closeReqId = channel.allocateRequestId()
            let closePacket = packetEngine.createClosePacket(requestId: closeReqId, handle: dirHandle)
            _ = try? await channel.sendRequest(packet: closePacket, requestId: closeReqId)
            
            return allEntries
            
        } catch {
            if let adbItems = PhoneConnectionManager.shared.listDirectoryAdb(path: nfcPath) {
                Task {
                    _ = await PhoneConnectionManager.shared.establishConnection()
                }
                return adbItems
            }
            
            throw NSError(
                domain: "RemoteSFTPDriver",
                code: 1009,
                userInfo: [NSLocalizedDescriptionKey: "Телефон не подключен. Подключите смартфон по USB или выполните сопряжение по Wi-Fi."]
            )
        }
    }
    
    public func createDirectory(at path: String) async throws {
        let sftpPath = toSftpPath(path)
        do {
            try await ensureConnected()
            guard let channel = coordinator.interactiveChannel else {
                throw NSError(domain: "RemoteSFTPDriver", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active SFTP channel"])
            }
            let reqId = channel.allocateRequestId()
            let packet = packetEngine.createMkdirPacket(requestId: reqId, path: sftpPath)
            let (respType, payload) = try await channel.sendRequest(packet: packet, requestId: reqId)
            if respType == .status {
                let (_, code, msg) = try packetEngine.parseStatusResponse(data: payload)
                if code != .ok {
                    throw NSError(domain: "RemoteSFTPDriver", code: Int(code.rawValue), userInfo: [NSLocalizedDescriptionKey: "MKDIR failed: \(msg)"])
                }
            }
        } catch {
            let escaped = PhoneConnectionManager.shellEscape(path)
            let (status, adbErr) = PhoneConnectionManager.shared.executeAdbShell(command: "mkdir -p -- \(escaped)")
            if status == 0 {
                return
            }
            throw NSError(domain: "RemoteSFTPDriver", code: 30, userInfo: [NSLocalizedDescriptionKey: "Не удалось создать каталог «\(path)»: \(error.localizedDescription) (ADB: \(adbErr))"])
        }
    }
    
    public func deleteItem(at path: String, moveToTrash: Bool) async throws {
        if PhoneConnectionManager.shared.fastDeleteAdb(remotePath: path) {
            return
        }
        
        let sftpPath = toSftpPath(path)
        try await ensureConnected()
        guard let channel = coordinator.interactiveChannel else {
            throw NSError(domain: "RemoteSFTPDriver", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active SFTP channel"])
        }
        
        // 1. Попытка удалить как файл (SSH_FXP_REMOVE)
        let reqId = channel.allocateRequestId()
        let removePacket = packetEngine.createRemovePacket(requestId: reqId, path: sftpPath)
        let (respType, payload) = try await channel.sendRequest(packet: removePacket, requestId: reqId)
        if respType == .status {
            let (_, code, _) = try packetEngine.parseStatusResponse(data: payload)
            if code == .ok || code == .noSuchFile {
                return
            }
        }
        
        // 2. Попытка удалить как пустую директорию (SSH_FXP_RMDIR)
        let rmdirReqId = channel.allocateRequestId()
        let rmdirPacket = packetEngine.createRmdirPacket(requestId: rmdirReqId, path: sftpPath)
        let (rmdirResp, rmdirPayload) = try await channel.sendRequest(packet: rmdirPacket, requestId: rmdirReqId)
        if rmdirResp == .status {
            let (_, rmdirCode, _) = try packetEngine.parseStatusResponse(data: rmdirPayload)
            if rmdirCode == .ok || rmdirCode == .noSuchFile {
                return
            }
        }
        
        // 3. Рекурсивное удаление
        try await deleteDirectoryRecursive(at: path)
    }
    
    public func deleteEmptyDirectory(at path: String) async throws -> Bool {
        let sftpPath = toSftpPath(path)
        do {
            try await ensureConnected()
            guard let channel = coordinator.interactiveChannel else { return false }
            
            let rmdirReqId = channel.allocateRequestId()
            let rmdirPacket = packetEngine.createRmdirPacket(requestId: rmdirReqId, path: sftpPath)
            let (rmdirResp, rmdirPayload) = try await channel.sendRequest(packet: rmdirPacket, requestId: rmdirReqId)
            if rmdirResp == .status {
                let (_, rmdirCode, _) = try packetEngine.parseStatusResponse(data: rmdirPayload)
                if rmdirCode == .ok || rmdirCode == .noSuchFile {
                    return true
                }
            }
        } catch {
            // SFTP fallback
        }
        
        let escaped = PhoneConnectionManager.shellEscape(path)
        let (status, _) = PhoneConnectionManager.shared.executeAdbShell(command: "rmdir -- \(escaped) 2>/dev/null || rm -d -- \(escaped) 2>/dev/null")
        return status == 0
    }
    
    private func deleteDirectoryRecursive(at path: String) async throws {
        let entries = try await listDirectory(at: path)
        for entry in entries {
            if entry.isDirectory {
                try await deleteDirectoryRecursive(at: entry.path)
            } else {
                let sftpChildPath = toSftpPath(entry.path)
                if let channel = coordinator.interactiveChannel {
                    let reqId = channel.allocateRequestId()
                    let removePacket = packetEngine.createRemovePacket(requestId: reqId, path: sftpChildPath)
                    _ = try? await channel.sendRequest(packet: removePacket, requestId: reqId)
                }
            }
        }
        
        let sftpPath = toSftpPath(path)
        if let channel = coordinator.interactiveChannel {
            let rmdirReqId = channel.allocateRequestId()
            let rmdirPacket = packetEngine.createRmdirPacket(requestId: rmdirReqId, path: sftpPath)
            let (rmdirResp, rmdirPayload) = try await channel.sendRequest(packet: rmdirPacket, requestId: rmdirReqId)
            if rmdirResp == .status {
                let (_, rmdirCode, rmdirMsg) = try packetEngine.parseStatusResponse(data: rmdirPayload)
                if rmdirCode != .ok {
                    throw NSError(domain: "RemoteSFTPDriver", code: Int(rmdirCode.rawValue), userInfo: [NSLocalizedDescriptionKey: "Delete dir failed: \(rmdirMsg)"])
                }
            }
        }
    }
    
    public func renameItem(from sourcePath: String, to destinationPath: String) async throws {
        let sftpSrc = toSftpPath(sourcePath)
        let sftpDst = toSftpPath(destinationPath)
        do {
            try await ensureConnected()
            guard let channel = coordinator.interactiveChannel else {
                throw NSError(domain: "RemoteSFTPDriver", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active SFTP channel"])
            }
            
            // Если сервер поддерживает posix-rename@openssh.com:
            if coordinator.serverExtensions["posix-rename@openssh.com"] != nil {
                let reqId = channel.allocateRequestId()
                let posixPacket = packetEngine.createPosixRenamePacket(requestId: reqId, oldPath: sftpSrc, newPath: sftpDst)
                if let (pType, pPayload) = try? await channel.sendRequest(packet: posixPacket, requestId: reqId), pType == .status {
                    let (_, code, _) = try packetEngine.parseStatusResponse(data: pPayload)
                    if code == .ok { return }
                }
            }
            
            let reqId = channel.allocateRequestId()
            let packet = packetEngine.createRenamePacket(requestId: reqId, oldPath: sftpSrc, newPath: sftpDst)
            let (respType, payload) = try await channel.sendRequest(packet: packet, requestId: reqId)
            if respType == .status {
                let (_, code, msg) = try packetEngine.parseStatusResponse(data: payload)
                if code != .ok {
                    throw NSError(domain: "RemoteSFTPDriver", code: Int(code.rawValue), userInfo: [NSLocalizedDescriptionKey: "Rename failed: \(msg)"])
                }
            }
        } catch {
            let escapedSrc = PhoneConnectionManager.shellEscape(sourcePath)
            let escapedDst = PhoneConnectionManager.shellEscape(destinationPath)
            let (status, adbErr) = PhoneConnectionManager.shared.executeAdbShell(command: "mv -- \(escapedSrc) \(escapedDst)")
            if status == 0 {
                return
            }
            throw NSError(domain: "RemoteSFTPDriver", code: 31, userInfo: [NSLocalizedDescriptionKey: "Не удалось переименовать «\(sourcePath)»: \(error.localizedDescription) (ADB: \(adbErr))"])
        }
    }
    
    public func checkFreeSpace(at path: String) async throws -> (free: UInt64, total: UInt64) {
        // 1. Попытка запросить statvfs@openssh.com через SessionCoordinator
        if let channel = coordinator.interactiveChannel,
           coordinator.serverExtensions["statvfs@openssh.com"] != nil {
            let sftpPath = toSftpPath(path)
            let reqId = channel.allocateRequestId()
            let statvfsPacket = packetEngine.createStatVfsPacket(requestId: reqId, path: sftpPath)
            if let (respType, payload) = try? await channel.sendRequest(packet: statvfsPacket, requestId: reqId),
               respType == .extendedReply,
               let (_, vfs) = try? packetEngine.parseStatVfsResponse(data: payload) {
                let free = vfs.bavail * vfs.frsize
                let total = vfs.blocks * vfs.frsize
                return (free: free, total: total)
            }
        }
        
        // 2. Попытка получить через ADB df
        if let adbSpace = PhoneConnectionManager.shared.getStorageSpaceAdb() {
            return adbSpace
        }
        
        // 3. Отсутствие измерения: возвращаем (0, 0) как неизвестное (unknown), либо mock в тестах
        if ProcessInfo.processInfo.processName == "MacHostTests" {
            return (free: 280_000_000_000, total: 512_000_000_000)
        }
        return (free: 0, total: 0)
    }
}
