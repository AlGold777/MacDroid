import Foundation
import CryptoKit

public struct RemoteStat: Sendable {
    public let size: UInt64
    public let mtime: Int64
    public let isDirectory: Bool
    
    public init(size: UInt64, mtime: Int64, isDirectory: Bool = false) {
        self.size = size
        self.mtime = mtime
        self.isDirectory = isDirectory
    }
}

public final class TransportMultiplexer: @unchecked Sendable {
    public let coordinator: SessionCoordinator
    private let packetEngine: SFTPPacketEngine
    
    public init(host: String = "127.0.0.1", port: UInt16 = 2222, coordinator: SessionCoordinator = .shared) {
        self.coordinator = coordinator
        self.packetEngine = coordinator.packetEngine
        if host != "127.0.0.1" || port != 2222 {
            coordinator.updateEndpoint(host: host, port: port)
        }
    }
    
    public func updateEndpoint(host: String, port: UInt16) {
        coordinator.updateEndpoint(host: host, port: port)
    }
    
    public func invalidateSession() {
        coordinator.disconnect()
    }
    
    public func ensureConnected() async throws {
        try await coordinator.ensureConnected()
    }
    
    public var rootIsEmulatedZero: Bool {
        get { coordinator.rootIsEmulatedZero }
        set { /* управлялось координатором, сохранено для обратной совместимости */ }
    }
    
    public func toSftpPath(_ path: String) -> String {
        return coordinator.toSftpPath(path)
    }
    
    public func prepareRead(actionId: String, path: String) async throws -> RemoteStat {
        try await ensureConnected()
        guard let channel = coordinator.interactiveChannel else {
            throw NSError(domain: "TransportMultiplexer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active SFTP channel"])
        }
        
        var sftpPath = toSftpPath(path)
        let reqId = channel.allocateRequestId()
        let statPacket = packetEngine.createStatPacket(requestId: reqId, path: sftpPath)
        var (respType, payload) = try await channel.sendRequest(packet: statPacket, requestId: reqId)
        
        // Автоматическое переключение альтернативного сопоставления корня (/emulated/0 <-> /)
        if respType == .status, let (_, code, _) = try? packetEngine.parseStatusResponse(data: payload), code == .noSuchFile {
            let altPath: String
            if sftpPath.hasPrefix("/emulated/0") {
                let sub = String(sftpPath.dropFirst("/emulated/0".count))
                altPath = sub.isEmpty ? "/" : sub
            } else {
                altPath = "/emulated/0" + (sftpPath == "/" ? "" : sftpPath)
            }
            let altReqId = channel.allocateRequestId()
            let altPacket = packetEngine.createStatPacket(requestId: altReqId, path: altPath)
            if let (altResp, altPayload) = try? await channel.sendRequest(packet: altPacket, requestId: altReqId), altResp == .attrs {
                sftpPath = altPath
                respType = altResp
                payload = altPayload
            }
        }
        
        if respType == .attrs {
            let (_, size, mtime, isDir) = try packetEngine.parseAttrsResponse(data: payload)
            return RemoteStat(size: size, mtime: Int64(mtime), isDirectory: isDir)
        } else if respType == .status {
            let (_, code, msg) = try packetEngine.parseStatusResponse(data: payload)
            throw NSError(
                domain: "TransportMultiplexer",
                code: Int(code.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "SFTP Stat error: \(msg) (code \(code.rawValue))"]
            )
        } else {
            throw NSError(
                domain: "TransportMultiplexer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "SFTP Stat unexpected response type: \(respType)"]
            )
        }
    }
    
    /// Чтение начального чанка файла для безопасной верификации префикса при возобновлении (Resume)
    public func readChunk(remotePath: String, offset: UInt64, length: UInt32) async throws -> Data {
        try await ensureConnected()
        guard let channel = coordinator.interactiveChannel else {
            throw NSError(domain: "TransportMultiplexer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active SFTP channel"])
        }
        
        var sftpPath = toSftpPath(remotePath)
        let openReqId = channel.allocateRequestId()
        let openPacket = packetEngine.createOpenPacket(requestId: openReqId, path: sftpPath, pflags: 0x00000001) // SSH_FXF_READ
        var (openRespType, openPayload) = try await channel.sendRequest(packet: openPacket, requestId: openReqId)
        
        if openRespType != .handle {
            let altPath: String
            if sftpPath.hasPrefix("/emulated/0") {
                let sub = String(sftpPath.dropFirst("/emulated/0".count))
                altPath = sub.isEmpty ? "/" : sub
            } else {
                altPath = "/emulated/0" + (sftpPath == "/" ? "" : sftpPath)
            }
            let altReqId = channel.allocateRequestId()
            let altPacket = packetEngine.createOpenPacket(requestId: altReqId, path: altPath, pflags: 0x00000001)
            if let (altResp, altData) = try? await channel.sendRequest(packet: altPacket, requestId: altReqId), altResp == .handle {
                sftpPath = altPath
                openRespType = altResp
                openPayload = altData
            }
        }
        
        guard openRespType == .handle else {
            throw NSError(domain: "TransportMultiplexer", code: 20, userInfo: [NSLocalizedDescriptionKey: "Failed to open remote file \(sftpPath) for prefix check"])
        }
        let (_, fileHandle) = try packetEngine.parseHandleResponse(data: openPayload)
        
        var resultData = Data()
        var readError: Error?
        
        let readReqId = channel.allocateRequestId()
        let readPacket = packetEngine.createReadPacket(requestId: readReqId, handle: fileHandle, offset: offset, length: length)
        do {
            let (readRespType, readPayload) = try await channel.sendRequest(packet: readPacket, requestId: readReqId)
            if readRespType == .data {
                let (_, chunkData) = try packetEngine.parseDataResponse(data: readPayload)
                resultData = chunkData
            } else if readRespType == .status {
                let (_, code, _) = try packetEngine.parseStatusResponse(data: readPayload)
                if code != .eof {
                    readError = NSError(domain: "TransportMultiplexer", code: Int(code.rawValue), userInfo: [NSLocalizedDescriptionKey: "SFTP read chunk error code \(code.rawValue)"])
                }
            }
        } catch {
            readError = error
        }
        
        let closeReqId = channel.allocateRequestId()
        let closePacket = packetEngine.createClosePacket(requestId: closeReqId, handle: fileHandle)
        _ = try? await channel.sendRequest(packet: closePacket, requestId: closeReqId)
        
        if let err = readError {
            throw err
        }
        return resultData
    }
    
    /// Потоковая загрузка с отслеживанием подтвержденных диапазонов (Range Tracker) и учетом общего SessionBudget
    public func downloadFileStreaming(
        actionId: String,
        remotePath: String,
        targetURL: URL,
        totalSize: UInt64,
        startOffset: UInt64 = 0,
        rangeTracker: ConfirmedRangeTracker? = nil,
        onRangeConfirmed: (@Sendable (Range<UInt64>) -> Void)? = nil,
        onProgress: @escaping @Sendable (UInt64) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        let handle: FileHandle
        if startOffset == 0 || !FileManager.default.fileExists(atPath: targetURL.path) {
            FileManager.default.createFile(atPath: targetURL.path, contents: nil)
            handle = try FileHandle(forWritingTo: targetURL)
        } else {
            handle = try FileHandle(forWritingTo: targetURL)
            try handle.seek(toOffset: startOffset)
        }
        defer { try? handle.close() }
        
        let chunkSize: UInt32 = 128 * 1024 // 128 KiB chunk (согласно P0.3 целевым параметрам)
        let sftpPath = toSftpPath(remotePath)
        
        try await ensureConnected()
        guard let channel = coordinator.bulkChannel else {
            throw NSError(domain: "TransportMultiplexer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No bulk SFTP channel"])
        }
        
        let budget = coordinator.budget
        guard budget.acquireHandle() else {
            throw NSError(domain: "TransportMultiplexer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Exceeded max handles in SessionBudget"])
        }
        defer { budget.releaseHandle() }
        
        // 1. Открываем файл (SSH_FXF_READ = 0x00000001)
        let openReqId = channel.allocateRequestId()
        var currentSftpPath = sftpPath
        let openPacket = packetEngine.createOpenPacket(requestId: openReqId, path: currentSftpPath, pflags: 0x00000001)
        var (openRespType, openPayload) = try await channel.sendRequest(packet: openPacket, requestId: openReqId)
        
        if openRespType != .handle {
            let altPath: String
            if currentSftpPath.hasPrefix("/emulated/0") {
                let sub = String(currentSftpPath.dropFirst("/emulated/0".count))
                altPath = sub.isEmpty ? "/" : sub
            } else {
                altPath = "/emulated/0" + (currentSftpPath == "/" ? "" : currentSftpPath)
            }
            let altReqId = channel.allocateRequestId()
            let altPacket = packetEngine.createOpenPacket(requestId: altReqId, path: altPath, pflags: 0x00000001)
            if let (altResp, altData) = try? await channel.sendRequest(packet: altPacket, requestId: altReqId), altResp == .handle {
                currentSftpPath = altPath
                openRespType = altResp
                openPayload = altData
            }
        }
        
        guard openRespType == .handle else {
            throw NSError(domain: "TransportMultiplexer", code: 20, userInfo: [NSLocalizedDescriptionKey: "Failed to open remote file \(sftpPath)"])
        }
        let (_, remoteHandle) = try packetEngine.parseHandleResponse(data: openPayload)
        
        // 2. Конвейерное чтение с учетом SessionBudget (окно до 4 запросов в P0)
        let windowCapacity = 4
        var activeRequests: [UInt32: Task<(Range<UInt64>, Data), Error>] = [:]
        var requestOffset = startOffset
        var confirmedBytes = startOffset
        
        do {
            while (confirmedBytes < totalSize || !activeRequests.isEmpty) {
                if Task.isCancelled {
                    throw CancellationError()
                }
                
                // Запускаем запросы в пределах окна и бюджета
                while activeRequests.count < windowCapacity && requestOffset < totalSize {
                    let toRead = UInt32(min(UInt64(chunkSize), totalSize - requestOffset))
                    let readOffset = requestOffset
                    requestOffset += UInt64(toRead)
                    
                    await budget.acquirePayload(bytes: Int(toRead), isInteractive: false)
                    
                    let readReqId = channel.allocateRequestId()
                    let readPkt = packetEngine.createReadPacket(requestId: readReqId, handle: remoteHandle, offset: readOffset, length: toRead)
                    
                    let task = Task<(Range<UInt64>, Data), Error> {
                        defer {
                            budget.releasePayload(bytes: Int(toRead))
                        }
                        let (rType, rPayload) = try await channel.sendRequest(packet: readPkt, requestId: readReqId)
                        if rType == .data {
                            let (_, data) = try self.packetEngine.parseDataResponse(data: rPayload)
                            return (readOffset..<(readOffset + UInt64(data.count)), data)
                        } else if rType == .status {
                            let (_, code, msg) = try self.packetEngine.parseStatusResponse(data: rPayload)
                            if code == .eof {
                                return (readOffset..<readOffset, Data())
                            }
                            throw NSError(domain: "TransportMultiplexer", code: Int(code.rawValue), userInfo: [NSLocalizedDescriptionKey: "SFTP read error: \(msg)"])
                        } else {
                            throw NSError(domain: "TransportMultiplexer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected response type \(rType)"])
                        }
                    }
                    activeRequests[readReqId] = task
                }
                
                guard let (finishedId, finishedTask) = activeRequests.first else {
                    break
                }
                activeRequests.removeValue(forKey: finishedId)
                
                let (range, data) = try await finishedTask.value
                if !data.isEmpty {
                    try handle.seek(toOffset: range.lowerBound)
                    handle.write(data)
                    confirmedBytes = max(confirmedBytes, range.upperBound)
                    onRangeConfirmed?(range)
                    onProgress(confirmedBytes)
                }
            }
            
            // 3. Закрываем дескриптор
            let closeReqId = channel.allocateRequestId()
            let closePacket = packetEngine.createClosePacket(requestId: closeReqId, handle: remoteHandle)
            _ = try? await channel.sendRequest(packet: closePacket, requestId: closeReqId)
            
        } catch {
            let closeReqId = channel.allocateRequestId()
            let closePacket = packetEngine.createClosePacket(requestId: closeReqId, handle: remoteHandle)
            _ = try? await channel.sendRequest(packet: closePacket, requestId: closeReqId)
            throw error
        }
        
        try handle.synchronize()
        guard confirmedBytes == totalSize else {
            throw NSError(
                domain: "TransportMultiplexer",
                code: 416,
                userInfo: [NSLocalizedDescriptionKey: "Incomplete download: received \(confirmedBytes) of \(totalSize) bytes"]
            )
        }
    }
    
    /// Потоковая выгрузка (Upload) с учетом SessionBudget и подтверждением диапазонов
    public func uploadFileStreaming(
        actionId: String,
        localURL: URL,
        remotePath: String,
        startOffset: UInt64 = 0,
        rangeTracker: ConfirmedRangeTracker? = nil,
        onRangeConfirmed: (@Sendable (Range<UInt64>) -> Void)? = nil,
        onProgress: @escaping @Sendable (UInt64) -> Void
    ) async throws {
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw NSError(domain: "TransportMultiplexer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Local file not found: \(localURL.path)"])
        }
        
        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? fileHandle.close() }
        
        if startOffset > 0 {
            try fileHandle.seek(toOffset: startOffset)
        }
        
        let fileSize = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let totalSize = UInt64(fileSize)
        let sftpPath = toSftpPath(remotePath)
        
        try await ensureConnected()
        guard let channel = coordinator.bulkChannel else {
            throw NSError(domain: "TransportMultiplexer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No bulk SFTP channel"])
        }
        
        let budget = coordinator.budget
        guard budget.acquireHandle() else {
            throw NSError(domain: "TransportMultiplexer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Exceeded max handles in SessionBudget"])
        }
        defer { budget.releaseHandle() }
        
        // Флаги: при startOffset > 0 открываем без TRUNC
        let pflags: UInt32 = (startOffset > 0)
            ? (0x00000002 | 0x00000008) // WRITE | CREAT
            : (0x00000002 | 0x00000008 | 0x00000010) // WRITE | CREAT | TRUNC
            
        let openReqId = channel.allocateRequestId()
        let openPacket = packetEngine.createOpenPacket(requestId: openReqId, path: sftpPath, pflags: pflags)
        let (openRespType, openPayload) = try await channel.sendRequest(packet: openPacket, requestId: openReqId)
        
        guard openRespType == .handle else {
            throw NSError(domain: "TransportMultiplexer", code: 20, userInfo: [NSLocalizedDescriptionKey: "Failed to open remote file for writing: \(sftpPath)"])
        }
        let (_, remoteHandle) = try packetEngine.parseHandleResponse(data: openPayload)
        
        let chunkSize: Int = 128 * 1024 // 128 KiB chunk (P0.3 target)
        let windowCapacity = 4
        var activeRequests: [UInt32: Task<Range<UInt64>, Error>] = [:]
        var offset: UInt64 = startOffset
        var confirmedBytes = startOffset
        
        do {
            while (confirmedBytes < totalSize || !activeRequests.isEmpty) {
                if Task.isCancelled {
                    throw CancellationError()
                }
                
                while activeRequests.count < windowCapacity && offset < totalSize {
                    let toRead = min(chunkSize, Int(totalSize - offset))
                    guard let chunk = try fileHandle.read(upToCount: toRead), !chunk.isEmpty else {
                        break
                    }
                    
                    let writeOffset = offset
                    offset += UInt64(chunk.count)
                    
                    await budget.acquirePayload(bytes: chunk.count, isInteractive: false)
                    
                    let writeReqId = channel.allocateRequestId()
                    let writePkt = packetEngine.createWritePacket(requestId: writeReqId, handle: remoteHandle, offset: writeOffset, data: chunk)
                    
                    let task = Task<Range<UInt64>, Error> {
                        defer {
                            budget.releasePayload(bytes: chunk.count)
                        }
                        let (wType, wPayload) = try await channel.sendRequest(packet: writePkt, requestId: writeReqId)
                        if wType == .status {
                            let (_, code, msg) = try self.packetEngine.parseStatusResponse(data: wPayload)
                            if code != .ok {
                                throw NSError(domain: "TransportMultiplexer", code: Int(code.rawValue), userInfo: [NSLocalizedDescriptionKey: "SFTP write error: \(msg)"])
                            }
                            return writeOffset..<(writeOffset + UInt64(chunk.count))
                        } else {
                            throw NSError(domain: "TransportMultiplexer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected write response type \(wType)"])
                        }
                    }
                    activeRequests[writeReqId] = task
                }
                
                guard let (finishedId, finishedTask) = activeRequests.first else {
                    break
                }
                activeRequests.removeValue(forKey: finishedId)
                
                let range = try await finishedTask.value
                confirmedBytes = max(confirmedBytes, range.upperBound)
                onRangeConfirmed?(range)
                onProgress(confirmedBytes)
            }
            
            // Fsync расширение при поддержке сервером
            if coordinator.serverExtensions["fsync@openssh.com"] != nil {
                let fsyncReqId = channel.allocateRequestId()
                let fsyncPacket = packetEngine.createFsyncPacket(requestId: fsyncReqId, handle: remoteHandle)
                _ = try? await channel.sendRequest(packet: fsyncPacket, requestId: fsyncReqId)
            }
            
            let closeReqId = channel.allocateRequestId()
            let closePacket = packetEngine.createClosePacket(requestId: closeReqId, handle: remoteHandle)
            _ = try? await channel.sendRequest(packet: closePacket, requestId: closeReqId)
            
        } catch {
            let closeReqId = channel.allocateRequestId()
            let closePacket = packetEngine.createClosePacket(requestId: closeReqId, handle: remoteHandle)
            _ = try? await channel.sendRequest(packet: closePacket, requestId: closeReqId)
            throw error
        }
        
        guard confirmedBytes == totalSize else {
            throw NSError(
                domain: "TransportMultiplexer",
                code: 416,
                userInfo: [NSLocalizedDescriptionKey: "Incomplete upload: sent \(confirmedBytes) of \(totalSize) bytes"]
            )
        }
    }
    
    public func executeRename(oldPath: String, newPath: String) async throws -> Bool {
        try await ensureConnected()
        guard let channel = coordinator.interactiveChannel else { return false }
        
        let sftpOld = toSftpPath(oldPath)
        let sftpNew = toSftpPath(newPath)
        
        // Попытка через posix-rename@openssh.com при наличии
        if coordinator.serverExtensions["posix-rename@openssh.com"] != nil {
            let reqId = channel.allocateRequestId()
            let posixPacket = packetEngine.createPosixRenamePacket(requestId: reqId, oldPath: sftpOld, newPath: sftpNew)
            if let (respType, payload) = try? await channel.sendRequest(packet: posixPacket, requestId: reqId), respType == .status {
                let (_, code, _) = try packetEngine.parseStatusResponse(data: payload)
                if code == .ok { return true }
            }
        }
        
        let reqId = channel.allocateRequestId()
        let renamePacket = packetEngine.createRenamePacket(requestId: reqId, oldPath: sftpOld, newPath: sftpNew)
        if let (respType, payload) = try? await channel.sendRequest(packet: renamePacket, requestId: reqId), respType == .status {
            let (_, code, _) = try packetEngine.parseStatusResponse(data: payload)
            return code == .ok
        }
        return false
    }
    
    public func executeDelete(actionId: String, path: String) async throws -> Bool {
        try await ensureConnected()
        guard let channel = coordinator.interactiveChannel else { return false }
        
        let sftpPath = toSftpPath(path)
        let reqId = channel.allocateRequestId()
        let removePacket = packetEngine.createRemovePacket(requestId: reqId, path: sftpPath)
        if let (respType, payload) = try? await channel.sendRequest(packet: removePacket, requestId: reqId), respType == .status {
            let (_, code, _) = try packetEngine.parseStatusResponse(data: payload)
            return code == .ok || code == .noSuchFile
        }
        return false
    }
    
    public func setRemoteMtime(path: String, mtime: Int64) async throws -> Bool {
        try await ensureConnected()
        guard let channel = coordinator.interactiveChannel else { return false }
        
        let sftpPath = toSftpPath(path)
        let reqId = channel.allocateRequestId()
        let setstatPacket = packetEngine.createSetstatMtimePacket(requestId: reqId, path: sftpPath, mtime: UInt32(max(0, mtime)))
        if let (respType, payload) = try? await channel.sendRequest(packet: setstatPacket, requestId: reqId), respType == .status {
            let (_, code, _) = try packetEngine.parseStatusResponse(data: payload)
            return code == .ok
        }
        return false
    }
    
    public func checkFreeSpace(at path: String) async -> (free: UInt64, total: UInt64)? {
        guard let channel = coordinator.interactiveChannel,
              coordinator.serverExtensions["statvfs@openssh.com"] != nil else {
            return nil
        }
        
        let sftpPath = toSftpPath(path)
        let reqId = channel.allocateRequestId()
        let statvfsPacket = packetEngine.createStatVfsPacket(requestId: reqId, path: sftpPath)
        guard let (respType, payload) = try? await channel.sendRequest(packet: statvfsPacket, requestId: reqId),
              respType == .extendedReply,
              let (_, vfs) = try? packetEngine.parseStatVfsResponse(data: payload) else {
            return nil
        }
        
        let free = vfs.bavail * vfs.frsize
        let total = vfs.blocks * vfs.frsize
        return (free: free, total: total)
    }
    
    public func getRemoteFileDigest(actionId: String, path: String) async throws -> String {
        let escaped = PhoneConnectionManager.shellEscape(path)
        let (status, out) = PhoneConnectionManager.shared.executeAdbShell(command: "sha256sum -- \(escaped)")
        if status == 0, !out.isEmpty {
            let parts = out.split(whereSeparator: { $0.isWhitespace })
            if let first = parts.first, first.count == 64 {
                return String(first)
            }
        }
        
        try await ensureConnected()
        let stat = try await prepareRead(actionId: actionId, path: path)
        let readLen = min(stat.size, 1024 * 1024)
        let chunk = try await readChunk(remotePath: path, offset: 0, length: UInt32(readLen))
        let hash = SHA256.hash(data: chunk)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    public func disconnect() {
        coordinator.disconnect()
    }
}
