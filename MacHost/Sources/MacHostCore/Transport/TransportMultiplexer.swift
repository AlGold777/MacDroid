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
    private var sshClient: SSHControlClient
    private let packetEngine = SFTPPacketEngine()
    private var isSftpInitialized = false
    private let lock = NSLock()
    private var nextReqId: UInt32 = 1
    
    private var activeConnectTask: Task<Void, Error>?
    
    public init(host: String = "127.0.0.1", port: UInt16 = 2222) {
        self.sshClient = SSHControlClient(host: host, port: port)
    }
    
    public func updateEndpoint(host: String, port: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        self.sshClient = SSHControlClient(host: host, port: port)
        self.isSftpInitialized = false
        self.activeConnectTask = nil
    }
    
    public func invalidateSession() {
        lock.lock()
        self.isSftpInitialized = false
        self.activeConnectTask = nil
        lock.unlock()
        Task {
            await sshClient.disconnect()
        }
    }
    
    private func getNextRequestId() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        let req = nextReqId
        nextReqId = (nextReqId == UInt32.max) ? 1 : nextReqId + 1
        return req
    }
    
    /// Гарантирует активное подключение и инициализацию SFTP-подсистемы без гонок конкурентных вызовов
    public func ensureConnected() async throws {
        lock.lock()
        if isSftpInitialized {
            lock.unlock()
            return
        }
        if let existing = activeConnectTask {
            lock.unlock()
            try await existing.value
            return
        }
        
        let connectTask = Task { [weak self] () -> Void in
            guard let self = self else { return }
            do {
                try await self.sshClient.connect()
                // Отправляем SSH_FXP_INIT
                let initPacket = self.packetEngine.createInitPacket()
                let (respType, _) = try await self.sshClient.sendSFTPPacket(packet: initPacket)
                guard respType == .version else {
                    throw NSError(
                        domain: "TransportMultiplexer",
                        code: 10,
                        userInfo: [NSLocalizedDescriptionKey: "Unexpected SFTP init response: \(respType)"]
                    )
                }
                
                // Авто-определение структуры корня SFTP:
                let statReqId = self.getNextRequestId()
                let statPacket = self.packetEngine.createStatPacket(requestId: statReqId, path: "/emulated/0")
                if let (statResp, _) = try? await self.sshClient.sendSFTPPacket(packet: statPacket) {
                    self.rootIsEmulatedZero = (statResp != .attrs)
                }
                
                self.lock.lock()
                self.isSftpInitialized = true
                self.lock.unlock()
            } catch {
                self.lock.lock()
                self.isSftpInitialized = false
                self.lock.unlock()
                throw error
            }
        }
        self.activeConnectTask = connectTask
        lock.unlock()
        
        defer {
            lock.lock()
            if self.activeConnectTask == connectTask {
                self.activeConnectTask = nil
            }
            lock.unlock()
        }
        try await connectTask.value
    }
    
    public var rootIsEmulatedZero: Bool = false
    
    public func toSftpPath(_ path: String) -> String {
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
    
    public func prepareRead(actionId: String, path: String) async throws -> RemoteStat {
        let reqId = getNextRequestId()
        var sftpPath = toSftpPath(path)
        
        try await ensureConnected()
        let statPacket = packetEngine.createStatPacket(requestId: reqId, path: sftpPath)
        var (respType, payload) = try await sshClient.sendSFTPPacket(packet: statPacket)
        
        // Автоматическое переключение альтернативного сопоставления корня (/emulated/0 <-> /)
        if respType == .status, let (_, code, _) = try? packetEngine.parseStatusResponse(data: payload), code == .noSuchFile {
            let altPath: String
            if sftpPath.hasPrefix("/emulated/0") {
                let sub = String(sftpPath.dropFirst("/emulated/0".count))
                altPath = sub.isEmpty ? "/" : sub
            } else {
                altPath = "/emulated/0" + (sftpPath == "/" ? "" : sftpPath)
            }
            let altReqId = getNextRequestId()
            let altPacket = packetEngine.createStatPacket(requestId: altReqId, path: altPath)
            if let (altResp, altPayload) = try? await sshClient.sendSFTPPacket(packet: altPacket), altResp == .attrs {
                self.rootIsEmulatedZero = sftpPath.hasPrefix("/emulated/0")
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
        var sftpPath = toSftpPath(remotePath)
        try await ensureConnected()
        
        let openReqId = getNextRequestId()
        let openPacket = packetEngine.createOpenPacket(requestId: openReqId, path: sftpPath, pflags: 0x00000001) // SSH_FXF_READ
        var (openRespType, openPayload) = try await sshClient.sendSFTPPacket(packet: openPacket)
        
        if openRespType != .handle {
            let altPath: String
            if sftpPath.hasPrefix("/emulated/0") {
                let sub = String(sftpPath.dropFirst("/emulated/0".count))
                altPath = sub.isEmpty ? "/" : sub
            } else {
                altPath = "/emulated/0" + (sftpPath == "/" ? "" : sftpPath)
            }
            let altReqId = getNextRequestId()
            let altPacket = packetEngine.createOpenPacket(requestId: altReqId, path: altPath, pflags: 0x00000001)
            if let (altResp, altData) = try? await sshClient.sendSFTPPacket(packet: altPacket), altResp == .handle {
                self.rootIsEmulatedZero = sftpPath.hasPrefix("/emulated/0")
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
        
        let readReqId = getNextRequestId()
        let readPacket = packetEngine.createReadPacket(requestId: readReqId, handle: fileHandle, offset: offset, length: length)
        do {
            let (readRespType, readPayload) = try await sshClient.sendSFTPPacket(packet: readPacket)
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
        
        let closeReqId = getNextRequestId()
        let closePacket = packetEngine.createClosePacket(requestId: closeReqId, handle: fileHandle)
        _ = try? await sshClient.sendSFTPPacket(packet: closePacket)
        
        if let err = readError {
            throw err
        }
        return resultData
    }
    
    public func downloadFileStreaming(
        actionId: String,
        remotePath: String,
        targetURL: URL,
        totalSize: UInt64,
        startOffset: UInt64 = 0,
        onProgress: @escaping @Sendable (UInt64) -> Void
    ) async throws {
        // Гарантируем существование директории для локального файла
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        // Подготовка локального файла
        let handle: FileHandle
        if startOffset == 0 || !FileManager.default.fileExists(atPath: targetURL.path) {
            FileManager.default.createFile(atPath: targetURL.path, contents: nil)
            handle = try FileHandle(forWritingTo: targetURL)
        } else {
            handle = try FileHandle(forWritingTo: targetURL)
            try handle.seek(toOffset: startOffset)
        }
        defer { try? handle.close() }
        
        var written: UInt64 = startOffset
        let chunkSize: UInt32 = 256 * 1024 // 256 KB SFTP chunks
        let sftpPath = toSftpPath(remotePath)
        
        do {
            try await ensureConnected()
            
            // 1. Открываем удалённый файл на чтение (SSH_FXF_READ = 0x00000001)
            let openReqId = getNextRequestId()
            var currentSftpPath = sftpPath
            let openPacket = packetEngine.createOpenPacket(requestId: openReqId, path: currentSftpPath, pflags: 0x00000001)
            var (openRespType, openPayload) = try await sshClient.sendSFTPPacket(packet: openPacket)
            
            // Если файл не найден, проверяем альтернативное сопоставление корня (/emulated/0 <-> /)
            if openRespType != .handle {
                let altPath: String
                if currentSftpPath.hasPrefix("/emulated/0") {
                    let sub = String(currentSftpPath.dropFirst("/emulated/0".count))
                    altPath = sub.isEmpty ? "/" : sub
                } else {
                    altPath = "/emulated/0" + (currentSftpPath == "/" ? "" : currentSftpPath)
                }
                let altReqId = getNextRequestId()
                let altPacket = packetEngine.createOpenPacket(requestId: altReqId, path: altPath, pflags: 0x00000001)
                if let (altResp, altData) = try? await sshClient.sendSFTPPacket(packet: altPacket), altResp == .handle {
                    self.rootIsEmulatedZero = currentSftpPath.hasPrefix("/emulated/0")
                    currentSftpPath = altPath
                    openRespType = altResp
                    openPayload = altData
                }
            }
            
            guard openRespType == .handle else {
                var detail = "Response type: \(openRespType)"
                if openRespType == .status, let (_, code, msg) = try? packetEngine.parseStatusResponse(data: openPayload) {
                    detail = "\(msg) (code \(code.rawValue))"
                }
                throw NSError(
                    domain: "TransportMultiplexer",
                    code: 20,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to open remote file \(sftpPath): \(detail)"]
                )
            }
            let (_, fileHandle) = try packetEngine.parseHandleResponse(data: openPayload)
            
            // 2. Читаем файл потоково со скользящим окном (SFTP Pipelining - 4 пакета / 1 МБ in-flight)
            let windowCapacity = 4
            var inFlight = 0
            var requestOffset = startOffset
            var pendingReads: [UInt32: (offset: UInt64, length: UInt32)] = [:]
            
            while inFlight < windowCapacity && requestOffset < totalSize {
                let toRead = UInt32(min(UInt64(chunkSize), totalSize - requestOffset))
                let readReqId = getNextRequestId()
                let readPacket = packetEngine.createReadPacket(
                    requestId: readReqId,
                    handle: fileHandle,
                    offset: requestOffset,
                    length: toRead
                )
                try await sshClient.writeRawPacket(packet: readPacket)
                pendingReads[readReqId] = (offset: requestOffset, length: toRead)
                requestOffset += UInt64(toRead)
                inFlight += 1
            }
            
            // Обрабатываем ответы и непрерывно досылаем новые запросы в конвейер
            while written < totalSize && inFlight > 0 {
                if Task.isCancelled {
                    let closeReqId = getNextRequestId()
                    let closePacket = packetEngine.createClosePacket(requestId: closeReqId, handle: fileHandle)
                    _ = try? await sshClient.sendSFTPPacket(packet: closePacket)
                    throw CancellationError()
                }
                
                let (readRespType, readPayload) = try await sshClient.readRawResponse()
                inFlight -= 1
                
                if readRespType == .data {
                    let (respReqId, chunkData) = try packetEngine.parseDataResponse(data: readPayload)
                    guard !chunkData.isEmpty else { break }
                    if let req = pendingReads.removeValue(forKey: respReqId) {
                        try handle.seek(toOffset: req.offset)
                    }
                    handle.write(chunkData)
                    written += UInt64(chunkData.count)
                    onProgress(written)
                } else if readRespType == .status {
                    let (respReqId, code, _) = try packetEngine.parseStatusResponse(data: readPayload)
                    pendingReads.removeValue(forKey: respReqId)
                    if code == .eof { break }
                    throw NSError(
                        domain: "TransportMultiplexer",
                        code: Int(code.rawValue),
                        userInfo: [NSLocalizedDescriptionKey: "SFTP read error code \(code.rawValue)"]
                    )
                } else {
                    break
                }
                
                // Досылаем следующий запрос, поддерживая заполненность конвейера
                if requestOffset < totalSize {
                    let toRead = UInt32(min(UInt64(chunkSize), totalSize - requestOffset))
                    let readReqId = getNextRequestId()
                    let readPacket = packetEngine.createReadPacket(
                        requestId: readReqId,
                        handle: fileHandle,
                        offset: requestOffset,
                        length: toRead
                    )
                    try await sshClient.writeRawPacket(packet: readPacket)
                    pendingReads[readReqId] = (offset: requestOffset, length: toRead)
                    requestOffset += UInt64(toRead)
                    inFlight += 1
                }
            }
            
            // 3. Закрываем дескриптор файла
            let closeReqId = getNextRequestId()
            let closePacket = packetEngine.createClosePacket(requestId: closeReqId, handle: fileHandle)
            _ = try? await sshClient.sendSFTPPacket(packet: closePacket)
            
        } catch {
            // В Production режиме при реальном сбое сокета мы не генерируем фейковые 0x5A байты,
            // а явно пробрасываем ошибку для корректной изоляции и фиксации в журнале (Zero Data Loss invariant)
            throw error
        }
        
        try handle.synchronize()
        guard written == totalSize else {
            throw NSError(
                domain: "TransportMultiplexer",
                code: 416,
                userInfo: [NSLocalizedDescriptionKey: "Incomplete download: received \(written) of \(totalSize) bytes"]
            )
        }
    }
    
    public func uploadFileStreaming(
        actionId: String,
        localURL: URL,
        remotePath: String,
        startOffset: UInt64 = 0,
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
        
        // При startOffset > 0 открываем без флага TRUNC (0x10), чтобы продолжить запись
        let pflags: UInt32 = (startOffset > 0)
            ? (0x00000002 | 0x00000008) // WRITE | CREAT
            : (0x00000002 | 0x00000008 | 0x00000010) // WRITE | CREAT | TRUNC
            
        let openReqId = getNextRequestId()
        let openPacket = packetEngine.createOpenPacket(requestId: openReqId, path: sftpPath, pflags: pflags)
        let (openRespType, openPayload) = try await sshClient.sendSFTPPacket(packet: openPacket)
        
        guard openRespType == .handle else {
            throw NSError(
                domain: "TransportMultiplexer",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "Failed to open remote file for writing: \(sftpPath)"]
            )
        }
        let (_, fileHandleRemote) = try packetEngine.parseHandleResponse(data: openPayload)
        
        var offset: UInt64 = startOffset
        let chunkSize: Int = 256 * 1024 // 256 KB SFTP chunks
        let windowCapacity = 4 // Pipelining window: до 1 МБ данных в конвейере
        var inFlight = 0
        
        while offset < totalSize {
            if Task.isCancelled {
                let closeReqId = getNextRequestId()
                let closePacket = packetEngine.createClosePacket(requestId: closeReqId, handle: fileHandleRemote)
                _ = try? await sshClient.sendSFTPPacket(packet: closePacket)
                throw CancellationError()
            }
            let dataChunk = fileHandle.readData(ofLength: chunkSize)
            if dataChunk.isEmpty { break }
            
            let writeReqId = getNextRequestId()
            let writePacket = packetEngine.createWritePacket(
                requestId: writeReqId,
                handle: fileHandleRemote,
                offset: offset,
                data: dataChunk
            )
            try await sshClient.writeRawPacket(packet: writePacket)
            inFlight += 1
            offset += UInt64(dataChunk.count)
            
            // Если окно заполнено — считываем подтверждения с сервера
            while inFlight >= windowCapacity {
                let (writeRespType, writePayload) = try await sshClient.readRawResponse()
                inFlight -= 1
                if writeRespType == .status {
                    let (_, code, msg) = try packetEngine.parseStatusResponse(data: writePayload)
                    if code != .ok {
                        throw NSError(domain: "TransportMultiplexer", code: Int(code.rawValue), userInfo: [NSLocalizedDescriptionKey: "SFTP write error: \(msg)"])
                    }
                }
                let confirmedBytes = offset > UInt64(inFlight * chunkSize) ? offset - UInt64(inFlight * chunkSize) : offset
                onProgress(confirmedBytes)
            }
        }
        
        // Вычитываем оставшиеся подтверждения в конвейере
        while inFlight > 0 {
            let (writeRespType, writePayload) = try await sshClient.readRawResponse()
            inFlight -= 1
            if writeRespType == .status {
                let (_, code, msg) = try packetEngine.parseStatusResponse(data: writePayload)
                if code != .ok {
                    throw NSError(domain: "TransportMultiplexer", code: Int(code.rawValue), userInfo: [NSLocalizedDescriptionKey: "SFTP write error: \(msg)"])
                }
            }
        }
        onProgress(offset)
        
        let closeReqId = getNextRequestId()
        let closePacket = packetEngine.createClosePacket(requestId: closeReqId, handle: fileHandleRemote)
        _ = try? await sshClient.sendSFTPPacket(packet: closePacket)
        
        guard offset == totalSize else {
            throw NSError(
                domain: "TransportMultiplexer",
                code: 416,
                userInfo: [NSLocalizedDescriptionKey: "Incomplete upload: sent \(offset) of \(totalSize) bytes"]
            )
        }
    }
    
    public func executeRename(oldPath: String, newPath: String) async throws -> Bool {
        let reqId = getNextRequestId()
        let sftpOld = toSftpPath(oldPath)
        let sftpNew = toSftpPath(newPath)
        do {
            try await ensureConnected()
            let renamePacket = packetEngine.createRenamePacket(requestId: reqId, oldPath: sftpOld, newPath: sftpNew)
            let (respType, payload) = try await sshClient.sendSFTPPacket(packet: renamePacket)
            if respType == .status {
                let (_, code, _) = try packetEngine.parseStatusResponse(data: payload)
                return code == .ok
            }
        } catch {
            return false
        }
        return false
    }
    
    public func getRemoteFileDigest(actionId: String, path: String) async throws -> String {
        // 1. Попытка через ADB sha256sum (мгновенно и аппаратно ускорено на телефоне)
        let escaped = PhoneConnectionManager.shellEscape(path)
        let (status, out) = PhoneConnectionManager.shared.executeAdbShell(command: "sha256sum -- \(escaped)")
        if status == 0, !out.isEmpty {
            let parts = out.split(whereSeparator: { $0.isWhitespace })
            if let first = parts.first, first.count == 64 {
                return String(first)
            }
        }
        
        // 2. Если ADB недоступен — читаем через SFTP и вычисляем SHA-256 потоково
        try await ensureConnected()
        let stat = try await prepareRead(actionId: actionId, path: path)
        let readLen = min(stat.size, 1024 * 1024) // До 1 МБ для контрольного отпечатка
        let chunk = try await readChunk(remotePath: path, offset: 0, length: UInt32(readLen))
        let hash = SHA256.hash(data: chunk)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    public func executeDelete(actionId: String, path: String) async throws -> Bool {
        let reqId = getNextRequestId()
        let sftpPath = toSftpPath(path)
        do {
            try await ensureConnected()
            let removePacket = packetEngine.createRemovePacket(requestId: reqId, path: sftpPath)
            let (respType, payload) = try await sshClient.sendSFTPPacket(packet: removePacket)
            if respType == .status {
                let (_, code, _) = try packetEngine.parseStatusResponse(data: payload)
                return code == .ok || code == .noSuchFile
            }
        } catch {
            return false
        }
        return false
    }
    
    public func setRemoteMtime(path: String, mtime: Int64) async throws -> Bool {
        let reqId = getNextRequestId()
        let sftpPath = toSftpPath(path)
        do {
            try await ensureConnected()
            let setstatPacket = packetEngine.createSetstatMtimePacket(requestId: reqId, path: sftpPath, mtime: UInt32(max(0, mtime)))
            let (respType, payload) = try await sshClient.sendSFTPPacket(packet: setstatPacket)
            if respType == .status {
                let (_, code, _) = try packetEngine.parseStatusResponse(data: payload)
                return code == .ok
            }
        } catch {
            return false
        }
        return false
    }
    
    public func disconnect() {
        Task {
            await sshClient.disconnect()
        }
        isSftpInitialized = false
    }
}
