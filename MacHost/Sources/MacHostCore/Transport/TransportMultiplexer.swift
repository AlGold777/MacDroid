import CryptoKit
import Foundation

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
    
    public func updateEndpoint(host: String, port: UInt16, deviceId: String? = nil) {
        coordinator.updateEndpoint(host: host, port: port, deviceId: deviceId)
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
            SSHTransportLog.write("PREPARE_READ_NO_CHANNEL path=\(path)")
            throw NSError(domain: "TransportMultiplexer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active SFTP channel"])
        }
        
        var sftpPath = toSftpPath(path)
        let reqId = channel.allocateRequestId()
        let statPacket = packetEngine.createStatPacket(requestId: reqId, path: sftpPath)
        SSHTransportLog.write("PREPARE_READ_SEND path=\(path) sftpPath=\(sftpPath) reqId=\(reqId)")
        var (respType, payload) = try await channel.sendRequest(packet: statPacket, requestId: reqId)
        SSHTransportLog.write("PREPARE_READ_RESP path=\(path) respType=\(respType)")
        
        // Автоматическое переключение альтернативного сопоставления корня (/emulated/0 <-> /)
        if respType == .status, let (_, code, _) = try? packetEngine.parseStatusResponse(data: payload), code == .noSuchFile {
            let altPath: String
            if RemoteSFTPDriver.isEmulatedZeroPath(sftpPath) {
                let sub = String(sftpPath.dropFirst("/emulated/0".count))
                altPath = sub.isEmpty ? "/" : sub
            } else {
                altPath = "/emulated/0" + (sftpPath == "/" ? "" : sftpPath)
            }
            let altReqId = channel.allocateRequestId()
            let altPacket = packetEngine.createStatPacket(requestId: altReqId, path: altPath)
            SSHTransportLog.write("PREPARE_READ_ALT path=\(altPath) reqId=\(altReqId)")
            if let (altResp, altPayload) = try? await channel.sendRequest(packet: altPacket, requestId: altReqId), altResp == .attrs {
                sftpPath = altPath
                respType = altResp
                payload = altPayload
                SSHTransportLog.write("PREPARE_READ_ALT_OK path=\(altPath)")
            }
        }
        
        if respType == .attrs {
            let (_, size, mtime, isDir) = try packetEngine.parseAttrsResponse(data: payload)
            SSHTransportLog.write("PREPARE_READ_SUCCESS path=\(path) size=\(size) mtime=\(mtime) isDir=\(isDir)")
            return RemoteStat(size: size, mtime: Int64(mtime), isDirectory: isDir)
        } else if respType == .status {
            let (_, code, msg) = try packetEngine.parseStatusResponse(data: payload)
            SSHTransportLog.write("PREPARE_READ_FAILED_STATUS path=\(path) code=\(code.rawValue) msg=\(msg)")
            throw NSError(
                domain: "TransportMultiplexer",
                code: Int(code.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "SFTP Stat error: \(msg) (code \(code.rawValue))"]
            )
        } else {
            SSHTransportLog.write("PREPARE_READ_UNEXPECTED path=\(path) respType=\(respType)")
            throw NSError(
                domain: "TransportMultiplexer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "SFTP Stat unexpected response type: \(respType)"]
            )
        }
    }

    /// Streams a remote file through one captured SFTP channel and hashes its bytes.
    /// The listing metadata is checked before and after the read to reject stale or
    /// concurrently changed entries instead of returning an unverified digest.
    public func digestRemoteFile(at path: String, expectedSize: UInt64, expectedMtime: Double) async throws -> String {
        try await ensureConnected()
        guard let channel = coordinator.interactiveChannel else {
            throw NSError(domain: "TransportMultiplexer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No active SFTP channel"])
        }

        return try await digestCapturedRemoteFile(at: toSftpPath(path), expectedSize: expectedSize,
                                                  expectedMtime: expectedMtime, channel: channel)
    }

    private func digestCapturedRemoteFile(at path: String, expectedSize: UInt64, expectedMtime: Double,
                                          channel: SFTPChannel, resolveAlternate: Bool = true) async throws -> String {
        let (sftpPath, before) = resolveAlternate
            ? try await resolveRemoteFile(path, channel: channel)
            : (path, try await statRemoteFile(path, channel: channel))
        guard !before.isDirectory,
              before.size == expectedSize,
              Double(before.mtime) == expectedMtime else {
            throw FileContentError.changed(path)
        }

        let openId = channel.allocateRequestId()
        let openPacket = packetEngine.createOpenPacket(requestId: openId, path: sftpPath, pflags: 0x00000001)
        let (openResponse, openPayload) = try await channel.sendRequest(packet: openPacket, requestId: openId)
        guard openResponse == .handle else {
            if openResponse == .status {
                let status = try packetEngine.parseStatusResponse(data: openPayload)
                guard status.requestId == openId else { throw contentProtocolError("OPEN вернул другой request id") }
                throw contentStatusError("OPEN", status.code, status.message)
            }
            throw contentProtocolError("OPEN: неожиданный ответ сервера (\(openResponse))")
        }
        let parsedHandle = try packetEngine.parseHandleResponse(data: openPayload)
        guard parsedHandle.requestId == openId else { throw contentProtocolError("OPEN вернул другой request id") }
        let handle = parsedHandle.handle
        var didClose = false
        do {
            var hasher = SHA256()
            var offset: UInt64 = 0
            let advertisedReadLimit = coordinator.currentServerLimits?.maxReadLen ?? UInt64(64 * 1024)
            guard advertisedReadLimit > 0 else {
                throw contentProtocolError("SFTP server advertised a zero read limit")
            }
            let effectiveChunkSize = min(UInt64(256 * 1024), advertisedReadLimit)
            while offset < before.size {
                try Task.checkCancellation()
                let length = UInt32(min(effectiveChunkSize, before.size - offset))
                let readId = channel.allocateRequestId()
                let packet = packetEngine.createReadPacket(requestId: readId, handle: handle,
                                                           offset: offset, length: length)
                let (response, payload) = try await channel.sendRequest(packet: packet, requestId: readId,
                                                                        timeoutSeconds: 30)
                if response == .data {
                    let result = try packetEngine.parseDataResponse(data: payload)
                    guard result.requestId == readId else { throw contentProtocolError("READ вернул другой request id") }
                    guard !result.data.isEmpty, result.data.count <= Int(length) else {
                        throw FileContentError.incompleteRead(path)
                    }
                    hasher.update(data: result.data)
                    offset += UInt64(result.data.count)
                } else if response == .status {
                    let status = try packetEngine.parseStatusResponse(data: payload)
                    guard status.requestId == readId else { throw contentProtocolError("READ вернул другой request id") }
                    if status.code == .eof { throw FileContentError.incompleteRead(path) }
                    throw contentStatusError("READ", status.code, status.message)
                } else {
                    throw contentProtocolError("READ: неожиданный ответ сервера (\(response))")
                }
            }

            try await closeContentHandle(handle, channel: channel)
            didClose = true
            try Task.checkCancellation()
            let after = try await statRemoteFile(sftpPath, channel: channel)
            guard !after.isDirectory, after.size == before.size, after.mtime == before.mtime else {
                throw FileContentError.changed(path)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            if !didClose { await sendCloseUncancellable(handle: handle, channel: channel) }
            throw error
        }
    }

    private func resolveRemoteFile(_ initialPath: String, channel: SFTPChannel) async throws -> (String, RemoteStat) {
        do {
            return (initialPath, try await statRemoteFile(initialPath, channel: channel))
        } catch let error as NSError
            where error.domain == "TransportMultiplexer" && error.code == Int(SFTPStatusCode.noSuchFile.rawValue) {
            let alternatePath: String
            if RemoteSFTPDriver.isEmulatedZeroPath(initialPath) {
                let suffix = String(initialPath.dropFirst("/emulated/0".count))
                alternatePath = suffix.isEmpty ? "/" : suffix
            } else {
                alternatePath = "/emulated/0" + (initialPath == "/" ? "" : initialPath)
            }
            return (alternatePath, try await statRemoteFile(alternatePath, channel: channel))
        }
    }

    private func statRemoteFile(_ path: String, channel: SFTPChannel) async throws -> RemoteStat {
        let requestId = channel.allocateRequestId()
        let packet = packetEngine.createStatPacket(requestId: requestId, path: path)
        let (response, payload) = try await channel.sendRequest(packet: packet, requestId: requestId)
        if response == .attrs {
            let parsed = try packetEngine.parseAttrsResponse(data: payload)
            guard parsed.requestId == requestId else { throw contentProtocolError("STAT вернул другой request id") }
            return RemoteStat(size: parsed.size, mtime: Int64(parsed.mtime), isDirectory: parsed.isDirectory)
        }
        if response == .status {
            let status = try packetEngine.parseStatusResponse(data: payload)
            guard status.requestId == requestId else { throw contentProtocolError("STAT вернул другой request id") }
            throw contentStatusError("STAT", status.code, status.message)
        }
        throw contentProtocolError("STAT: неожиданный ответ сервера (\(response))")
    }

    private func closeContentHandle(_ handle: Data, channel: SFTPChannel) async throws {
        let requestId = channel.allocateRequestId()
        let packet = packetEngine.createClosePacket(requestId: requestId, handle: handle)
        let (response, payload) = try await channel.sendRequest(packet: packet, requestId: requestId)
        guard response == .status else { throw contentProtocolError("CLOSE: неожиданный ответ сервера (\(response))") }
        let status = try packetEngine.parseStatusResponse(data: payload)
        guard status.requestId == requestId else { throw contentProtocolError("CLOSE вернул другой request id") }
        guard status.code == .ok else { throw contentStatusError("CLOSE", status.code, status.message) }
    }

    private func contentStatusError(_ operation: String, _ code: SFTPStatusCode, _ message: String) -> NSError {
        NSError(domain: "TransportMultiplexer", code: Int(code.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "\(operation): \(message) (SFTP \(code.rawValue))"])
    }

    private func contentProtocolError(_ message: String) -> NSError {
        NSError(domain: "TransportMultiplexer", code: 100,
                userInfo: [NSLocalizedDescriptionKey: message])
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
        
        if openRespType == .status,
           let (_, openCode, _) = try? packetEngine.parseStatusResponse(data: openPayload),
           openCode == .noSuchFile {
            let altPath: String
            if RemoteSFTPDriver.isEmulatedZeroPath(sftpPath) {
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
        resultData.reserveCapacity(Int(length))
        var readError: Error?
        let maxChunk = UInt32(min(UInt64(64 * 1024), coordinator.serverLimits?.maxReadLen ?? UInt64(64 * 1024)))
        
        while resultData.count < Int(length) {
            if Task.isCancelled { break }
            let cursor = offset + UInt64(resultData.count)
            let remaining = UInt32(Int(length) - resultData.count)
            let toRead = min(remaining, maxChunk)
            let readReqId = channel.allocateRequestId()
            let readPacket = packetEngine.createReadPacket(requestId: readReqId, handle: fileHandle, offset: cursor, length: toRead)
            do {
                let (readRespType, readPayload) = try await channel.sendRequest(packet: readPacket, requestId: readReqId, timeoutSeconds: 15)
                if readRespType == .data {
                    let (_, chunkData) = try packetEngine.parseDataResponse(data: readPayload)
                    guard !chunkData.isEmpty else { break }
                    resultData.append(chunkData)
                } else if readRespType == .status {
                    let (_, code, _) = try packetEngine.parseStatusResponse(data: readPayload)
                    if code == .eof {
                        break
                    }
                    readError = NSError(domain: "TransportMultiplexer", code: Int(code.rawValue), userInfo: [NSLocalizedDescriptionKey: "SFTP read chunk error code \(code.rawValue)"])
                    break
                } else {
                    break
                }
            } catch {
                readError = error
                break
            }
        }
        
        let closeReqId = channel.allocateRequestId()
        let closePacket = packetEngine.createClosePacket(requestId: closeReqId, handle: fileHandle)
        _ = try? await channel.sendRequest(packet: closePacket, requestId: closeReqId)
        
        if let err = readError, resultData.isEmpty {
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
        SSHTransportLog.write("DL_OPEN_START path=\(currentSftpPath) reqId=\(openReqId) channel=\(channel.channelId)")
        var (openRespType, openPayload) = try await channel.sendRequest(packet: openPacket, requestId: openReqId)
        SSHTransportLog.write("DL_OPEN_DONE respType=\(openRespType) channel=\(channel.channelId)")
        
        if openRespType == .status,
           let (_, openCode, _) = try? packetEngine.parseStatusResponse(data: openPayload),
           openCode == .noSuchFile {
            let altPath: String
            if RemoteSFTPDriver.isEmulatedZeroPath(currentSftpPath) {
                let sub = String(currentSftpPath.dropFirst("/emulated/0".count))
                altPath = sub.isEmpty ? "/" : sub
            } else {
                altPath = "/emulated/0" + (currentSftpPath == "/" ? "" : currentSftpPath)
            }
            let altReqId = channel.allocateRequestId()
            let altPacket = packetEngine.createOpenPacket(requestId: altReqId, path: altPath, pflags: 0x00000001)
            SSHTransportLog.write("DL_OPEN_ALT path=\(altPath) reqId=\(altReqId)")
            if let (altResp, altData) = try? await channel.sendRequest(packet: altPacket, requestId: altReqId), altResp == .handle {
                currentSftpPath = altPath
                openRespType = altResp
                openPayload = altData
                SSHTransportLog.write("DL_OPEN_ALT_OK path=\(altPath)")
            }
        }
        
        guard openRespType == .handle else {
            SSHTransportLog.write("DL_OPEN_FAILED respType=\(openRespType) path=\(sftpPath)")
            throw NSError(domain: "TransportMultiplexer", code: 20, userInfo: [NSLocalizedDescriptionKey: "Failed to open remote file \(sftpPath)"])
        }
        let (_, remoteHandle) = try packetEngine.parseHandleResponse(data: openPayload)
        SSHTransportLog.write("DL_HANDLE_OK path=\(currentSftpPath) handleLen=\(remoteHandle.count)")
        
        // 2. Конвейерное чтение с учетом SessionBudget (окно до 16 запросов по 256 КиБ = 4 МиБ)
        let advertisedReadLimit = coordinator.currentServerLimits?.maxReadLen ?? UInt64(256 * 1024)
        guard advertisedReadLimit > 0 else {
            throw NSError(domain: "TransportMultiplexer", code: 21, userInfo: [NSLocalizedDescriptionKey: "SFTP server advertised a zero read limit"])
        }
        let effectiveChunkSize = UInt32(min(UInt64(256 * 1024), advertisedReadLimit))
        let windowCapacity = 16
        var requestOffset = startOffset
        var confirmedBytes = startOffset
        var confirmedRanges = rangeTracker ?? ConfirmedRangeTracker()
        if rangeTracker == nil && startOffset > 0 { confirmedRanges.addRange(0..<startOffset) }
        var activeInflight = 0
        
        SSHTransportLog.write("DL_PIPELINE_START totalSize=\(totalSize) chunkSize=\(effectiveChunkSize) startOffset=\(startOffset)")
        
        do {
            try await withThrowingTaskGroup(of: (Range<UInt64>, Data).self) { group in
                while activeInflight < windowCapacity && requestOffset < totalSize {
                    let toRead = UInt32(min(UInt64(effectiveChunkSize), totalSize - requestOffset))
                    let readOffset = requestOffset
                    requestOffset += UInt64(toRead)
                    
                    guard await budget.acquirePayload(bytes: Int(toRead), isInteractive: false) else { throw CancellationError() }
                    group.addTask {
                        defer { budget.releasePayload(bytes: Int(toRead)) }
                        let data = try await self.readExactRemoteChunk(channel: channel, handle: remoteHandle, offset: readOffset, length: toRead)
                        return (readOffset..<(readOffset + UInt64(data.count)), data)
                    }
                    activeInflight += 1
                }
                
                while activeInflight > 0 {
                    if Task.isCancelled { throw CancellationError() }
                    guard let (range, data) = try await group.next() else { break }
                    activeInflight -= 1
                    
                    if !data.isEmpty {
                        try handle.seek(toOffset: range.lowerBound)
                        try handle.write(contentsOf: data)
                        confirmedRanges.addRange(range)
                        confirmedBytes = confirmedRanges.contiguousFrontier
                        onRangeConfirmed?(range)
                        onProgress(confirmedBytes)
                    }
                    
                    if requestOffset < totalSize {
                        let toRead = UInt32(min(UInt64(effectiveChunkSize), totalSize - requestOffset))
                        let readOffset = requestOffset
                        requestOffset += UInt64(toRead)
                        
                        guard await budget.acquirePayload(bytes: Int(toRead), isInteractive: false) else { throw CancellationError() }
                        group.addTask {
                            defer { budget.releasePayload(bytes: Int(toRead)) }
                            let data = try await self.readExactRemoteChunk(channel: channel, handle: remoteHandle, offset: readOffset, length: toRead)
                            return (readOffset..<(readOffset + UInt64(data.count)), data)
                        }
                        activeInflight += 1
                    }
                }
            }
            
            // 3. Закрываем дескриптор
            SSHTransportLog.write("DL_CLOSE_START channel=\(channel.channelId)")
            let closeReqId = channel.allocateRequestId()
            let closePacket = packetEngine.createClosePacket(requestId: closeReqId, handle: remoteHandle)
            _ = try? await channel.sendRequest(packet: closePacket, requestId: closeReqId)
            SSHTransportLog.write("DL_CLOSE_DONE channel=\(channel.channelId)")
            
        } catch {
            SSHTransportLog.write("DL_ERROR err=\(error.localizedDescription) channel=\(channel.channelId)")
            await sendCloseUncancellable(handle: remoteHandle, channel: channel)
            throw error
        }
        
        try handle.synchronize()
        guard confirmedRanges.isFullyCovered(expectedSize: totalSize) else {
            throw NSError(
                domain: "TransportMultiplexer",
                code: 416,
                userInfo: [NSLocalizedDescriptionKey: "Incomplete download: received \(confirmedBytes) of \(totalSize) bytes"]
            )
        }

    }

    private func readExactRemoteChunk(channel: SFTPChannel, handle: Data, offset: UInt64, length: UInt32) async throws -> Data {
        guard length > 0 else {
            throw NSError(domain: "TransportMultiplexer", code: 21, userInfo: [NSLocalizedDescriptionKey: "Cannot issue an empty SFTP read"])
        }
        var result = Data()
        result.reserveCapacity(Int(length))
        let readTimeout: TimeInterval = 30
        while result.count < Int(length) {
            try Task.checkCancellation()
            let cursor = offset + UInt64(result.count)
            let remaining = UInt32(Int(length) - result.count)
            let requestId = channel.allocateRequestId()
            let packet = packetEngine.createReadPacket(requestId: requestId, handle: handle, offset: cursor, length: remaining)
            let (response, payload) = try await channel.sendRequest(packet: packet, requestId: requestId, timeoutSeconds: readTimeout)
            if response == .data {
                let (_, bytes) = try packetEngine.parseDataResponse(data: payload)
                guard !bytes.isEmpty, bytes.count <= Int(remaining) else {
                    throw NSError(domain: "TransportMultiplexer", code: 22, userInfo: [NSLocalizedDescriptionKey: "Invalid or empty SFTP READ data response (bytes=\(bytes.count), expected<=\(remaining))"])
                }
                result.append(bytes)
            } else if response == .status {
                let (_, code, message) = try packetEngine.parseStatusResponse(data: payload)
                if code == .eof {
                    break
                }
                throw NSError(domain: "TransportMultiplexer", code: Int(code.rawValue), userInfo: [NSLocalizedDescriptionKey: "SFTP READ ended before the requested range was complete: \(message)"])
            } else {
                throw NSError(domain: "TransportMultiplexer", code: 23, userInfo: [NSLocalizedDescriptionKey: "Unexpected SFTP READ response \(response)"])
            }
        }
        return result
    }
    
    /// Publishes an edited snapshot as a NEW sibling. The original is never opened for writing.
    /// Every request uses one captured channel; a reconnect cannot redirect an in-flight save.
    public func publishEditedCopy(snapshot: ExternalEditSnapshot, deviceFingerprint: String) async throws {
        try await ensureConnected()
        guard coordinator.hostKeyFingerprint == deviceFingerprint,
              HostKeyStore.shared.pinnedDeviceId(matchingFingerprint: deviceFingerprint) != nil else {
            throw ExternalEditError.wrongDevice
        }
        let captured = try coordinator.captureExternalEditSession(fingerprint: deviceFingerprint, path: snapshot.remotePath)
        let channel = captured.channel
        let epoch = captured.epoch
        let target = captured.path
        let parent = (target as NSString).deletingLastPathComponent
        let part = (parent as NSString).appendingPathComponent(".mcdedit-\(UUID().uuidString).part")
        let budget = coordinator.budget
        guard budget.acquireHandle() else { throw ExternalEditError.unavailable }
        defer { budget.releaseHandle() }

        func checkSession() throws {
            try Task.checkCancellation()
            guard coordinator.sessionEpoch == epoch, coordinator.hostKeyFingerprint == deviceFingerprint else {
                throw ExternalEditError.wrongDevice
            }
        }
        func status(_ packet: Data, id: UInt32) async throws {
            try checkSession()
            let (type, payload) = try await channel.sendRequest(packet: packet, requestId: id)
            guard type == .status else { throw contentProtocolError("Unexpected response during edited copy upload") }
            let reply = try packetEngine.parseStatusResponse(data: payload)
            guard reply.requestId == id else { throw contentProtocolError("Mismatched request id during edited copy upload") }
            guard reply.code == .ok else { throw contentStatusError("Edited copy upload", reply.code, reply.message) }
        }

        try checkSession()
        let local = try FileHandle(forReadingFrom: snapshot.url)
        defer { try? local.close() }
        let openId = channel.allocateRequestId()
        // WRITE | CREAT | EXCL; never truncate an existing path, even a staging path.
        let packet = packetEngine.createOpenPacket(requestId: openId, path: part, pflags: 0x2A)
        let (type, payload) = try await channel.sendRequest(packet: packet, requestId: openId)
        guard type == .handle else {
            if type == .status {
                let reply = try packetEngine.parseStatusResponse(data: payload)
                throw contentStatusError("OPEN(EXCL)", reply.code, reply.message)
            }
            throw contentProtocolError("OPEN(EXCL): unexpected reply")
        }
        let opened = try packetEngine.parseHandleResponse(data: payload)
        guard opened.requestId == openId else { throw contentProtocolError("OPEN(EXCL): mismatched id") }
        var closed = false
        do {
            let limit = min(UInt64(64 * 1024), coordinator.currentServerLimits?.maxWriteLen ?? 65536)
            guard limit > 0 else { throw contentProtocolError("Zero write limit") }
            var offset: UInt64 = 0
            while let data = try local.read(upToCount: Int(limit)), !data.isEmpty {
                guard await budget.acquirePayload(bytes: data.count, isInteractive: false) else { throw CancellationError() }
                do {
                    let id = channel.allocateRequestId()
                    try await status(packetEngine.createWritePacket(requestId: id, handle: opened.handle,
                                                                   offset: offset, data: data), id: id)
                } catch {
                    budget.releasePayload(bytes: data.count)
                    throw error
                }
                budget.releasePayload(bytes: data.count)
                offset += UInt64(data.count)
            }
            let closeId = channel.allocateRequestId()
            try await status(packetEngine.createClosePacket(requestId: closeId, handle: opened.handle), id: closeId)
            closed = true
            try checkSession()
            let info = try await statRemoteFile(part, channel: channel)
            guard info.size == offset,
                  try await digestCapturedRemoteFile(at: part, expectedSize: info.size,
                                                     expectedMtime: Double(info.mtime), channel: channel, resolveAlternate: false) == snapshot.digest else {
                throw contentProtocolError("Uploaded edited copy failed SHA-256 verification")
            }
            // SFTP v3 RENAME refuses an existing destination. Do NOT use posix-rename here.
            let renameId = channel.allocateRequestId()
            try await status(packetEngine.createRenamePacket(requestId: renameId, oldPath: part, newPath: target), id: renameId)
            try checkSession()
            let result = try await statRemoteFile(target, channel: channel)
            guard result.size == offset,
                  try await digestCapturedRemoteFile(at: target, expectedSize: result.size,
                                                     expectedMtime: Double(result.mtime), channel: channel, resolveAlternate: false) == snapshot.digest else {
                throw ExternalEditError.uncertain(snapshot.remotePath)
            }
            try checkSession()
        } catch {
            if !closed { await sendCloseUncancellable(handle: opened.handle, channel: channel) }
            // No destructive cleanup on an unknown outcome; retain the snapshot and journal.
            throw error
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
        
        let advertisedWriteLimit = coordinator.currentServerLimits?.maxWriteLen ?? UInt64(256 * 1024)
        guard advertisedWriteLimit > 0 else {
            throw NSError(domain: "TransportMultiplexer", code: 21, userInfo: [NSLocalizedDescriptionKey: "SFTP server advertised a zero write limit"])
        }
        let effectiveChunkSize = min(256 * 1024, Int(advertisedWriteLimit))
        let windowCapacity = 16
        var offset: UInt64 = startOffset
        var confirmedBytes = startOffset
        var activeInflight = 0
        
        do {
            try await withThrowingTaskGroup(of: Range<UInt64>.self) { group in
                while activeInflight < windowCapacity && offset < totalSize {
                    let toRead = min(effectiveChunkSize, Int(totalSize - offset))
                    guard let chunk = try fileHandle.read(upToCount: toRead), !chunk.isEmpty else {
                        break
                    }
                    
                    let writeOffset = offset
                    offset += UInt64(chunk.count)
                    
                    guard await budget.acquirePayload(bytes: chunk.count, isInteractive: false) else { throw CancellationError() }
                    let writeReqId = channel.allocateRequestId()
                    let writePkt = packetEngine.createWritePacket(requestId: writeReqId, handle: remoteHandle, offset: writeOffset, data: chunk)
                    
                    group.addTask {
                        defer { budget.releasePayload(bytes: chunk.count) }
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
                    activeInflight += 1
                }
                
                while activeInflight > 0 {
                    if Task.isCancelled { throw CancellationError() }
                    guard let range = try await group.next() else { break }
                    activeInflight -= 1
                    
                    confirmedBytes = max(confirmedBytes, range.upperBound)
                    onRangeConfirmed?(range)
                    onProgress(confirmedBytes)
                    
                    if offset < totalSize {
                        let toRead = min(effectiveChunkSize, Int(totalSize - offset))
                        if let chunk = try fileHandle.read(upToCount: toRead), !chunk.isEmpty {
                            let writeOffset = offset
                            offset += UInt64(chunk.count)
                            
                            guard await budget.acquirePayload(bytes: chunk.count, isInteractive: false) else { throw CancellationError() }
                            let writeReqId = channel.allocateRequestId()
                            let writePkt = packetEngine.createWritePacket(requestId: writeReqId, handle: remoteHandle, offset: writeOffset, data: chunk)
                            
                            group.addTask {
                                defer { budget.releasePayload(bytes: chunk.count) }
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
                            activeInflight += 1
                        }
                    }
                }
            }
            
            // Fsync расширение при поддержке сервером
            if coordinator.hasServerExtension("fsync@openssh.com") {
                let fsyncReqId = channel.allocateRequestId()
                let fsyncPacket = packetEngine.createFsyncPacket(requestId: fsyncReqId, handle: remoteHandle)
                _ = try? await channel.sendRequest(packet: fsyncPacket, requestId: fsyncReqId)
            }
            
            let closeReqId = channel.allocateRequestId()
            let closePacket = packetEngine.createClosePacket(requestId: closeReqId, handle: remoteHandle)
            _ = try? await channel.sendRequest(packet: closePacket, requestId: closeReqId)
            
        } catch {
            await sendCloseUncancellable(handle: remoteHandle, channel: channel)
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
    
    /// T1: SSH_FXP_CLOSE в пути отмены не должен отменяться вместе с задачей, иначе handle утекает на сервере.
    private func sendCloseUncancellable(handle: Data, channel: SFTPChannel) async {
        let reqId = channel.allocateRequestId()
        let packet = packetEngine.createClosePacket(requestId: reqId, handle: handle)
        await Task.detached {
            _ = try? await channel.sendRequest(packet: packet, requestId: reqId, timeoutSeconds: 5)
        }.value
    }

    /// true, если объект существует; false, если его нет (SSH_FX_NO_SUCH_FILE).
    /// Любая другая ошибка пробрасывается: неизвестность не трактуется как «файла нет».
    public func remotePathExists(_ path: String) async throws -> Bool {
        do {
            _ = try await prepareRead(actionId: UUID().uuidString, path: path)
            return true
        } catch let error as NSError
            where error.domain == "TransportMultiplexer" && error.code == Int(SFTPStatusCode.noSuchFile.rawValue) {
            return false
        }
    }

    /// Переименование без перезаписи: если цель уже существует, возвращает false и ничего не меняет.
    /// posix-rename@openssh.com атомарно заменяет цель, поэтому проверка выполняется до него.
    public func executeRename(oldPath: String, newPath: String) async throws -> Bool {
        try await ensureConnected()
        guard let channel = coordinator.interactiveChannel else { return false }
        if try await remotePathExists(newPath) {
            return false
        }

        let sftpOld = toSftpPath(oldPath)
        let sftpNew = toSftpPath(newPath)
        
        // Попытка через posix-rename@openssh.com при наличии
        if coordinator.hasServerExtension("posix-rename@openssh.com") {
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
              coordinator.hasServerExtension("statvfs@openssh.com") else {
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
    
    public func disconnect() {
        coordinator.disconnect()
    }
}
