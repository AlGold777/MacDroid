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

    public var phoneTrash: PhoneTrashService { PhoneTrashService(storage: self) }
    
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
        if moveToTrash {
            _ = try await phoneTrash.moveToTrash(at: path)
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

extension RemoteSFTPDriver: PhoneTrashStorage {
    public func list(_ path: String) async throws -> [FileItem] {
        try await listDirectory(at: path, forceRefresh: true)
    }

    public func exists(_ path: String) async throws -> Bool {
        try await ensureConnected()
        guard let channel = coordinator.interactiveChannel else {
            throw NSError(domain: "PhoneTrash", code: 1, userInfo: [NSLocalizedDescriptionKey: "SFTP channel unavailable"])
        }
        let requestId = channel.allocateRequestId()
        let packet = packetEngine.createStatPacket(requestId: requestId, path: toSftpPath(path))
        let (response, payload) = try await channel.sendRequest(packet: packet, requestId: requestId)
        if response == .attrs {
            let parsed = try packetEngine.parseAttrsResponse(data: payload)
            guard parsed.requestId == requestId else { throw phoneTrashProtocolError("STAT вернул другой request id") }
            return true
        }
        if response == .status {
            let parsed = try packetEngine.parseStatusResponse(data: payload)
            guard parsed.requestId == requestId else { throw phoneTrashProtocolError("STAT вернул другой request id") }
            if parsed.code == .noSuchFile { return false }
            throw phoneTrashStatusError("STAT", code: parsed.code, message: parsed.message)
        }
        throw phoneTrashProtocolError("STAT: неожиданный ответ сервера (\(response))")
    }

    public func mkdir(_ path: String) async throws {
        defer { DirectoryCache.shared.invalidate(path: path) }
        try await createDirectory(at: path)
    }

    public func rename(_ source: String, _ destination: String) async throws {
        try await renameItem(from: source, to: destination)
    }

    public func readSmallFile(_ path: String, maxBytes: Int) async throws -> Data {
        guard (0...PhoneTrashService.maximumMetadataBytes).contains(maxBytes) else {
            throw PhoneTrashError.fileTooLarge(path)
        }
        try await ensureConnected()
        guard let channel = coordinator.interactiveChannel else {
            throw NSError(domain: "PhoneTrash", code: 1, userInfo: [NSLocalizedDescriptionKey: "SFTP channel unavailable"])
        }
        let openId = channel.allocateRequestId()
        let openPacket = packetEngine.createOpenPacket(requestId: openId, path: toSftpPath(path), pflags: 0x00000001)
        let (openResponse, openPayload) = try await channel.sendRequest(packet: openPacket, requestId: openId)
        guard openResponse == .handle else {
            if openResponse == .status {
                let status = try packetEngine.parseStatusResponse(data: openPayload)
                throw phoneTrashStatusError("OPEN", code: status.code, message: status.message)
            }
            throw phoneTrashProtocolError("OPEN: неожиданный ответ сервера (\(openResponse))")
        }
        let parsedHandle = try packetEngine.parseHandleResponse(data: openPayload)
        guard parsedHandle.requestId == openId else { throw phoneTrashProtocolError("OPEN вернул другой request id") }
        let handle = parsedHandle.handle
        var didClose = false
        do {
            var output = Data()
            while true {
                let readId = channel.allocateRequestId()
                let remainingPlusSentinel = maxBytes - output.count + 1
                let length = UInt32(max(1, min(16 * 1024, remainingPlusSentinel)))
                let packet = packetEngine.createReadPacket(requestId: readId, handle: handle,
                                                          offset: UInt64(output.count), length: length)
                let (response, payload) = try await channel.sendRequest(packet: packet, requestId: readId)
                if response == .data {
                    let result = try packetEngine.parseDataResponse(data: payload)
                    guard result.requestId == readId else { throw phoneTrashProtocolError("READ вернул другой request id") }
                    if result.data.isEmpty { break }
                    output.append(result.data)
                    guard output.count <= maxBytes else { throw PhoneTrashError.fileTooLarge(path) }
                } else if response == .status {
                    let status = try packetEngine.parseStatusResponse(data: payload)
                    guard status.requestId == readId else { throw phoneTrashProtocolError("READ вернул другой request id") }
                    if status.code == .eof { break }
                    throw phoneTrashStatusError("READ", code: status.code, message: status.message)
                } else {
                    throw phoneTrashProtocolError("READ: неожиданный ответ сервера (\(response))")
                }
            }
            try await closePhoneTrashHandle(handle, on: channel)
            didClose = true
            return output
        } catch {
            if !didClose { try? await closePhoneTrashHandle(handle, on: channel) }
            throw error
        }
    }

    public func writeExclusive(_ path: String, data: Data) async throws {
        guard data.count <= PhoneTrashService.maximumMetadataBytes else {
            throw PhoneTrashError.fileTooLarge(path)
        }
        try await ensureConnected()
        guard let channel = coordinator.interactiveChannel else {
            throw NSError(domain: "PhoneTrash", code: 1, userInfo: [NSLocalizedDescriptionKey: "SFTP channel unavailable"])
        }
        let openId = channel.allocateRequestId()
        // SSH_FXF_WRITE | SSH_FXF_CREAT | SSH_FXF_EXCL
        let openPacket = packetEngine.createOpenPacket(requestId: openId, path: toSftpPath(path), pflags: 0x0000002A)
        let (openResponse, openPayload) = try await channel.sendRequest(packet: openPacket, requestId: openId)
        guard openResponse == .handle else {
            if openResponse == .status {
                let status = try packetEngine.parseStatusResponse(data: openPayload)
                throw phoneTrashStatusError("OPEN(EXCL)", code: status.code, message: status.message)
            }
            throw phoneTrashProtocolError("OPEN(EXCL): неожиданный ответ сервера (\(openResponse))")
        }
        let parsedHandle = try packetEngine.parseHandleResponse(data: openPayload)
        guard parsedHandle.requestId == openId else { throw phoneTrashProtocolError("OPEN(EXCL) вернул другой request id") }
        let handle = parsedHandle.handle
        var didClose = false
        do {
            var offset = 0
            while offset < data.count {
                let end = min(offset + 16 * 1024, data.count)
                let chunk = data.subdata(in: offset..<end)
                let writeId = channel.allocateRequestId()
                let packet = packetEngine.createWritePacket(requestId: writeId, handle: handle,
                                                           offset: UInt64(offset), data: chunk)
                let (response, payload) = try await channel.sendRequest(packet: packet, requestId: writeId)
                guard response == .status else {
                    throw phoneTrashProtocolError("WRITE: неожиданный ответ сервера (\(response))")
                }
                let status = try packetEngine.parseStatusResponse(data: payload)
                guard status.requestId == writeId else { throw phoneTrashProtocolError("WRITE вернул другой request id") }
                guard status.code == .ok else {
                    throw phoneTrashStatusError("WRITE", code: status.code, message: status.message)
                }
                offset = end
            }
            try await closePhoneTrashHandle(handle, on: channel)
            didClose = true
        } catch {
            if !didClose { try? await closePhoneTrashHandle(handle, on: channel) }
            throw error
        }
    }

    public func deletePermanent(_ path: String) async throws {
        try await deleteItem(at: path, moveToTrash: false)
    }

    public func deleteFile(_ path: String) async throws {
        defer { DirectoryCache.shared.invalidate(path: path) }
        try await ensureConnected()
        guard let channel = coordinator.interactiveChannel else {
            throw NSError(domain: "PhoneTrash", code: 1, userInfo: [NSLocalizedDescriptionKey: "SFTP channel unavailable"])
        }
        let requestId = channel.allocateRequestId()
        let packet = packetEngine.createRemovePacket(requestId: requestId, path: toSftpPath(path))
        let (response, payload) = try await channel.sendRequest(packet: packet, requestId: requestId)
        guard response == .status else { throw phoneTrashProtocolError("REMOVE: неожиданный ответ сервера (\(response))") }
        let status = try packetEngine.parseStatusResponse(data: payload)
        guard status.requestId == requestId else { throw phoneTrashProtocolError("REMOVE вернул другой request id") }
        guard status.code == .ok || status.code == .noSuchFile else {
            throw phoneTrashStatusError("REMOVE", code: status.code, message: status.message)
        }
    }

    public func removeEmptyDirectory(_ path: String) async throws {
        defer { DirectoryCache.shared.invalidate(path: path) }
        try await ensureConnected()
        guard let channel = coordinator.interactiveChannel else {
            throw NSError(domain: "PhoneTrash", code: 1, userInfo: [NSLocalizedDescriptionKey: "SFTP channel unavailable"])
        }
        let requestId = channel.allocateRequestId()
        let packet = packetEngine.createRmdirPacket(requestId: requestId, path: toSftpPath(path))
        let (response, payload) = try await channel.sendRequest(packet: packet, requestId: requestId)
        guard response == .status else { throw phoneTrashProtocolError("RMDIR: неожиданный ответ сервера (\(response))") }
        let status = try packetEngine.parseStatusResponse(data: payload)
        guard status.requestId == requestId else { throw phoneTrashProtocolError("RMDIR вернул другой request id") }
        guard status.code == .ok || status.code == .noSuchFile else {
            throw phoneTrashStatusError("RMDIR", code: status.code, message: status.message)
        }
    }

    private func closePhoneTrashHandle(_ handle: Data, on channel: SFTPChannel) async throws {
        let requestId = channel.allocateRequestId()
        let packet = packetEngine.createClosePacket(requestId: requestId, handle: handle)
        let (response, payload) = try await channel.sendRequest(packet: packet, requestId: requestId)
        guard response == .status else {
            throw phoneTrashProtocolError("CLOSE: неожиданный ответ сервера (\(response))")
        }
        let status = try packetEngine.parseStatusResponse(data: payload)
        guard status.requestId == requestId else { throw phoneTrashProtocolError("CLOSE вернул другой request id") }
        guard status.code == .ok else { throw phoneTrashStatusError("CLOSE", code: status.code, message: status.message) }
    }

    private func phoneTrashStatusError(_ operation: String, code: SFTPStatusCode, message: String) -> NSError {
        NSError(domain: "PhoneTrash", code: Int(code.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (SFTP \(code.rawValue)): \(message)"])
    }

    private func phoneTrashProtocolError(_ message: String) -> NSError {
        NSError(domain: "PhoneTrash", code: 100, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
