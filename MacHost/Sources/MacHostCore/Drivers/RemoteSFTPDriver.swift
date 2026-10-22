import Foundation

public final class RemoteSFTPDriver: FileSystemDriver, @unchecked Sendable {
    public let coordinator: SessionCoordinator
    private let packetEngine: SFTPPacketEngine
    
    public private(set) var lastSyncTimestamp: Double = 0
    
    public init(host: String = "127.0.0.1", port: UInt16 = 2222, deviceId: String? = nil, coordinator: SessionCoordinator = .shared) {
        self.coordinator = coordinator
        self.packetEngine = coordinator.packetEngine
        // T10 (оставлено намеренно): инициализатор применяет endpoint к SessionCoordinator.shared.
        // Причина: тесты (RemoteSFTPDriver(host:port:)) и DualPaneViewModel полагаются на это поведение.
        // Переход на явный updateEndpoint требует правки вызывающих; делается отдельно.
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
    
    public func ensureConnected(allowLegacyFallback: Bool? = nil) async throws {
        try await coordinator.ensureConnected(allowLegacyFallback: allowLegacyFallback)
    }
    
    public func warmUpConnection(allowLegacyFallback: Bool = false) async throws {
        try await coordinator.ensureConnected(allowLegacyFallback: allowLegacyFallback)
    }
    
    public func disconnect() {
        coordinator.disconnect()
        DirectoryCache.shared.invalidateAll()
    }
    
    public var rootIsEmulatedZero: Bool {
        get { coordinator.rootIsEmulatedZero }
        set { /* Управляется SessionCoordinator */ }
    }
    
    /// Граница компонента: "/emulated/0" и "/emulated/0/..." совпадают, "/emulated/01" — нет.
    static func isEmulatedZeroPath(_ path: String) -> Bool {
        path == "/emulated/0" || path.hasPrefix("/emulated/0/")
    }

    private func toSftpPath(_ path: String) -> String {
        return coordinator.toSftpPath(path)
    }
    
    public func listDirectory(at path: String) async throws -> [FileItem] {
        return try await listDirectory(at: path, forceRefresh: false)
    }
    
    public func listDirectory(at path: String, forceRefresh: Bool) async throws -> [FileItem] {
        let nfcPath = path.precomposedStringWithCanonicalMapping
        if !forceRefresh, let cached = DirectoryCache.shared.get(path: nfcPath) {
            return cached
        }
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
            if openRespType == .status,
               let (_, openCode, _) = try? packetEngine.parseStatusResponse(data: openPayload),
               openCode == .noSuchFile {
                let altPath: String
                if Self.isEmulatedZeroPath(currentSftpPath) {
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
            defer {
                let closeReqId = channel.allocateRequestId()
                let closePacket = packetEngine.createClosePacket(requestId: closeReqId, handle: dirHandle)
                channel.writeStreamingPacket(packet: closePacket, requestId: closeReqId) { _ in }
            }
            
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
            
            DirectoryCache.shared.set(path: nfcPath, items: allEntries)
            return allEntries
            
        } catch {
            throw error
        }
    }
    
    public func createDirectory(at path: String) async throws {
        defer { DirectoryCache.shared.invalidate(path: path) }
        let sftpPath = toSftpPath(path)
        try await ensureConnected()
        guard let channel = coordinator.interactiveChannel else {
            throw NSError(domain: "RemoteSFTPDriver", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active SFTP channel"])
        }
        let reqId = channel.allocateRequestId()
        let packet = packetEngine.createMkdirPacket(requestId: reqId, path: sftpPath)
        let (respType, payload) = try await channel.sendRequest(packet: packet, requestId: reqId)
        // Нестатусный ответ не считается успехом (иначе каталог мог не создаться, а операция — «пройти»).
        guard respType == .status else {
            throw NSError(domain: "RemoteSFTPDriver", code: 2, userInfo: [NSLocalizedDescriptionKey: "MKDIR: неожиданный ответ сервера (\(respType))"])
        }
        let (_, code, msg) = try packetEngine.parseStatusResponse(data: payload)
        if code != .ok {
            throw NSError(domain: "RemoteSFTPDriver", code: Int(code.rawValue), userInfo: [NSLocalizedDescriptionKey: "MKDIR failed: \(msg)"])
        }
    }
    
    public func deleteItem(at path: String, moveToTrash: Bool) async throws {
        defer { DirectoryCache.shared.invalidate(path: path) }
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
        defer { DirectoryCache.shared.invalidate(path: path) }
        let sftpPath = toSftpPath(path)
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
        return false
    }
    
    private func deleteDirectoryRecursive(at path: String) async throws {
        let entries = try await listDirectory(at: path, forceRefresh: true)
        for entry in entries {
            if entry.isDirectory {
                try await deleteDirectoryRecursive(at: entry.path)
            } else {
                let sftpChildPath = toSftpPath(entry.path)
                guard let channel = coordinator.interactiveChannel else { throw CancellationError() }
                let reqId = channel.allocateRequestId()
                let removePacket = packetEngine.createRemovePacket(requestId: reqId, path: sftpChildPath)
                let (response, payload) = try await channel.sendRequest(packet: removePacket, requestId: reqId)
                guard response == .status else { throw NSError(domain: "RemoteSFTPDriver", code: 32, userInfo: [NSLocalizedDescriptionKey: "Unexpected response while deleting \(entry.path)"]) }
                let (_, code, msg) = try packetEngine.parseStatusResponse(data: payload)
                guard code == .ok || code == .noSuchFile else { throw NSError(domain: "RemoteSFTPDriver", code: Int(code.rawValue), userInfo: [NSLocalizedDescriptionKey: msg]) }
            }
        }
        
        let sftpPath = toSftpPath(path)
        guard let channel = coordinator.interactiveChannel else {
            throw NSError(domain: "RemoteSFTPDriver", code: 1, userInfo: [NSLocalizedDescriptionKey: "SFTP channel closed while deleting \(path)"])
        }
        let rmdirReqId = channel.allocateRequestId()
        let rmdirPacket = packetEngine.createRmdirPacket(requestId: rmdirReqId, path: sftpPath)
        let (rmdirResp, rmdirPayload) = try await channel.sendRequest(packet: rmdirPacket, requestId: rmdirReqId)
        guard rmdirResp == .status else {
            throw NSError(domain: "RemoteSFTPDriver", code: 33, userInfo: [NSLocalizedDescriptionKey: "Unexpected response while removing directory \(path)"])
        }
        let (_, rmdirCode, rmdirMsg) = try packetEngine.parseStatusResponse(data: rmdirPayload)
        if rmdirCode != .ok {
            throw NSError(domain: "RemoteSFTPDriver", code: Int(rmdirCode.rawValue), userInfo: [NSLocalizedDescriptionKey: "Delete dir failed: \(rmdirMsg)"])
        }
    }
    
    public func renameItem(from sourcePath: String, to destinationPath: String) async throws {
        defer {
            DirectoryCache.shared.invalidate(path: sourcePath)
            DirectoryCache.shared.invalidate(path: destinationPath)
        }
        let sftpSrc = toSftpPath(sourcePath)
        let sftpDst = toSftpPath(destinationPath)
        try await ensureConnected()
        guard let channel = coordinator.interactiveChannel else {
            throw NSError(domain: "RemoteSFTPDriver", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active SFTP channel"])
        }
            
            // The OpenSSH POSIX rename extension replaces an existing destination;
            // regular SFTP rename preserves the server's no-overwrite behavior.
            let reqId = channel.allocateRequestId()
            let packet = packetEngine.createRenamePacket(requestId: reqId, oldPath: sftpSrc, newPath: sftpDst)
            let (respType, payload) = try await channel.sendRequest(packet: packet, requestId: reqId)
            guard respType == .status else {
                throw NSError(domain: "RemoteSFTPDriver", code: 3, userInfo: [NSLocalizedDescriptionKey: "Rename: неожиданный ответ сервера (\(respType))"])
            }
            let (_, code, msg) = try packetEngine.parseStatusResponse(data: payload)
            if code != .ok {
                throw NSError(domain: "RemoteSFTPDriver", code: Int(code.rawValue), userInfo: [NSLocalizedDescriptionKey: "Rename failed: \(msg)"])
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
        
        // ADB cannot be used here: the selected SFTP session may be Wi-Fi while a
        // different phone is attached over USB.
        return (free: 0, total: 0)
    }
}
