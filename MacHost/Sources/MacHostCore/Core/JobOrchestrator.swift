import Foundation
import CryptoKit

public enum TransferExecutionResult: Sendable, Equatable {
    case transferred
    case skipped(reason: String)
    case transferredWithoutSourceDeletion(reason: String)
}

public enum JobOrchestratorError: LocalizedError, Sendable {
    case insufficientSpace(required: UInt64, available: UInt64)
    case commitVerificationFailed(path: String)
    case transferInterrupted(reason: String)
    case unsupportedAtomicReplace(path: String)
    case indeterminate(reason: String)
    
    public var errorDescription: String? {
        switch self {
        case .insufficientSpace(let req, let avail):
            let reqStr = ByteCountFormatter.string(fromByteCount: Int64(req), countStyle: .file)
            let availStr = ByteCountFormatter.string(fromByteCount: Int64(avail), countStyle: .file)
            return "Недостаточно места на диске. Требуется: \(reqStr) (включая 5% запас), доступно: \(availStr)."
        case .commitVerificationFailed(let path):
            return "Верификация коммита не удалась: файл «\(path)» отсутствует или поврежден после переименования."
        case .transferInterrupted(let reason):
            return "Передача прервана: \(reason)."
        case .unsupportedAtomicReplace(let path):
            return "Сервер не поддерживает атомарное замещение posix-rename для «\(path)». Операция отклонена для предотвращения потери данных."
        case .indeterminate(let reason):
            return "Неопределенный результат операции: \(reason)."
        }
    }
}

public final class JobOrchestrator: @unchecked Sendable {
    private let ledger: IntentLedger
    public let transport: TransportMultiplexer
    private let localFS: LocalFSDriver
    
    public private(set) var activeLocalPartURLs: Set<URL> = []
    public private(set) var activeRemotePartPaths: Set<String> = []
    private let activePartsLock = NSLock()
    
    public init(ledger: IntentLedger, transport: TransportMultiplexer, localFS: LocalFSDriver) {
        self.ledger = ledger
        self.transport = transport
        self.localFS = localFS
    }
    
    public func registerActiveLocalPart(url: URL) {
        activePartsLock.lock()
        defer { activePartsLock.unlock() }
        activeLocalPartURLs.insert(url)
    }
    
    public func unregisterActiveLocalPart(url: URL) {
        activePartsLock.lock()
        defer { activePartsLock.unlock() }
        activeLocalPartURLs.remove(url)
    }
    
    public func registerActiveRemotePart(path: String) {
        activePartsLock.lock()
        defer { activePartsLock.unlock() }
        activeRemotePartPaths.insert(path)
    }
    
    public func unregisterActiveRemotePart(path: String) {
        activePartsLock.lock()
        defer { activePartsLock.unlock() }
        activeRemotePartPaths.remove(path)
    }
    
    private func extractAndClearActiveParts() -> (Set<URL>, Set<String>) {
        activePartsLock.lock()
        defer { activePartsLock.unlock() }
        let local = activeLocalPartURLs
        let remote = activeRemotePartPaths
        activeLocalPartURLs.removeAll()
        activeRemotePartPaths.removeAll()
        return (local, remote)
    }
    
    /// Безопасная немедленная зачистка всех активных недокачанных .part файлов
    public func cleanAllActivePartFiles() async {
        let (localToClean, remoteToClean) = extractAndClearActiveParts()
        for url in localToClean {
            try? FileManager.default.removeItem(at: url)
        }
        for remotePath in remoteToClean {
            _ = try? await transport.executeDelete(actionId: UUID().uuidString, path: remotePath)
        }
    }
    
    @discardableResult
    public func executeMovePhoneToMac(
        jobId: String,
        itemId: String,
        remotePath: String,
        localTargetDir: URL,
        destinationFileName: String? = nil,
        strategy: ConflictResolutionStrategy = .overwrite,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TransferExecutionResult {
        return try await executeTransfer(
            isMove: true,
            jobId: jobId,
            itemId: itemId,
            remotePath: remotePath,
            localTargetDir: localTargetDir,
            destinationFileName: destinationFileName,
            strategy: strategy,
            progress: progress
        )
    }
    
    @discardableResult
    public func executeCopyPhoneToMac(
        jobId: String,
        itemId: String,
        remotePath: String,
        localTargetDir: URL,
        destinationFileName: String? = nil,
        strategy: ConflictResolutionStrategy = .overwrite,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TransferExecutionResult {
        return try await executeTransfer(
            isMove: false,
            jobId: jobId,
            itemId: itemId,
            remotePath: remotePath,
            localTargetDir: localTargetDir,
            destinationFileName: destinationFileName,
            strategy: strategy,
            progress: progress
        )
    }
    
    private func executeTransfer(
        isMove: Bool,
        jobId: String,
        itemId: String,
        remotePath: String,
        localTargetDir: URL,
        destinationFileName: String? = nil,
        strategy: ConflictResolutionStrategy,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TransferExecutionResult {
        let actionId = UUID().uuidString
        let sm = JobUnitStateMachine(initialState: .planned)
        SSHTransportLog.write("ORCH_TRANSFER_START remotePath=\(remotePath) targetDir=\(localTargetDir.path) isMove=\(isMove)")
        
        // 0. Гарантируем существование целевой директории
        try FileManager.default.createDirectory(at: localTargetDir, withIntermediateDirectories: true)
        
        let stat = try await transport.prepareRead(actionId: actionId, path: remotePath)
        SSHTransportLog.write("ORCH_PREPARE_READ_OK remotePath=\(remotePath) size=\(stat.size) isDir=\(stat.isDirectory)")
        let reqHash = "\(remotePath):\(stat.size):\(stat.mtime)"
        
        // 1. Pre-flight проверка свободного места (+ 5% запас надежности)
        let space = try await localFS.checkFreeSpace(at: localTargetDir.path)
        SSHTransportLog.write("ORCH_FREE_SPACE_OK free=\(space.free)")
        let requiredWithMargin = stat.size + (stat.size / 20)
        if space.free > 0 && space.free < requiredWithMargin {
            SSHTransportLog.write("ORCH_INSUFFICIENT_SPACE required=\(requiredWithMargin) available=\(space.free)")
            throw JobOrchestratorError.insufficientSpace(required: requiredWithMargin, available: space.free)
        }
        
        var name = (destinationFileName ?? URL(fileURLWithPath: remotePath).lastPathComponent).precomposedStringWithCanonicalMapping
        var finalURL = localTargetDir.appendingPathComponent(name)
        
        // Обработка конфликтов при существовании целевого файла
        if FileManager.default.fileExists(atPath: finalURL.path) {
            let existingVals = try? finalURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let existingSize = UInt64(existingVals?.fileSize ?? 0)
            let existingMtime = Int64(existingVals?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            
            switch strategy {
            case .skip:
                progress(1.0)
                return .skipped(reason: "Файл уже существует")
            case .skipIfIdentical:
                if existingSize == stat.size && abs(existingMtime - stat.mtime) < 2 {
                    progress(1.0)
                    return .skipped(reason: "Идентичный файл уже существует")
                }
            case .overwriteIfNewer:
                if existingMtime >= stat.mtime {
                    progress(1.0)
                    return .skipped(reason: "Существующий файл новее или такой же")
                }
            case .autoRename:
                let ext = finalURL.pathExtension
                let base = finalURL.deletingPathExtension().lastPathComponent
                var counter = 1
                while FileManager.default.fileExists(atPath: finalURL.path) {
                    let newName = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
                    name = newName
                    finalURL = localTargetDir.appendingPathComponent(newName)
                    counter += 1
                }
            case .customRename, .overwrite:
                break
            }
        }
        
        ledger.recordItemState(
            itemId: itemId,
            jobId: jobId,
            actionId: actionId,
            requestHash: reqHash,
            state: .running,
            bytes: 0,
            total: stat.size,
            mtime: stat.mtime
        )
        sm.transition(to: .running)
        
        // 1. Prepare: Формируем имя временного файла и регистрируем в TransferJournal
        let deviceId = PhoneConnectionManager.shared.getConnectedDeviceId() ?? "phone"
        let sessionIdentity = "\(deviceId):\(transport.coordinator.host):\(transport.coordinator.port)"
        let srcKey = "\(deviceId):\(remotePath):\(stat.size):\(stat.mtime)"
        let fingerprint = SHA256.hash(data: Data(srcKey.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
        let tempURL = localTargetDir.appendingPathComponent(".\(name).\(fingerprint).mcdpart")
        registerActiveLocalPart(url: tempURL)
        defer {
            unregisterActiveLocalPart(url: tempURL)
        }
        
        let journal = TransferJournal.shared
        var rangeTracker = ConfirmedRangeTracker()
        var currentOffset: UInt64 = 0
        
        // Поиск возобновляемой сессии в TransferJournal
        if let resumable = journal.findResumableTransfer(
            sessionIdentity: sessionIdentity,
            sourcePath: remotePath,
            sourceSize: stat.size,
            sourceMtime: stat.mtime,
            direction: "download"
        ) {
            let loadedTracker = ConfirmedRangeTracker.deserialize(resumable.rangesBlob)
            let frontier = loadedTracker.contiguousFrontier
            if frontier > 0, FileManager.default.fileExists(atPath: tempURL.path) {
                // Проверяем соответствие префикса
                let prefixLen = min(frontier, 4096)
                var prefixValid = false
                if let handle = try? FileHandle(forReadingFrom: tempURL) {
                    let localPrefix = try? handle.read(upToCount: Int(prefixLen))
                    try? handle.close()
                    if let localPrefix = localPrefix, localPrefix.count == Int(prefixLen) {
                        if let remotePrefix = try? await transport.readChunk(remotePath: remotePath, offset: 0, length: UInt32(prefixLen)),
                           remotePrefix == localPrefix {
                            prefixValid = true
                        }
                    }
                }
                if prefixValid {
                    rangeTracker = loadedTracker
                    currentOffset = frontier
                } else {
                    try? FileManager.default.removeItem(at: tempURL)
                    rangeTracker = ConfirmedRangeTracker()
                    currentOffset = 0
                }
            }
        } else if FileManager.default.fileExists(atPath: tempURL.path) {
            // Старый .mcdpart без журнала не считается доказательством покрытия
            try? FileManager.default.removeItem(at: tempURL)
        }
        
        try? journal.registerTransfer(
            transferId: actionId,
            sessionIdentity: sessionIdentity,
            direction: "download",
            sourcePath: remotePath,
            sourceSize: stat.size,
            sourceMtime: stat.mtime,
            sourceHash: nil,
            targetFinalPath: finalURL.path,
            targetTempPath: tempURL.path,
            expectedSize: stat.size,
            initialFrontier: currentOffset,
            initialRanges: rangeTracker.serialize(),
            state: "transferring"
        )
        
        // 2. Transfer: Потоковая загрузка с отслеживанием диапазонов
        var attempts = 0
        let maxAttempts = 3
        var downloadSuccess = false
        var lastError: Error?
        
        while attempts < maxAttempts && !downloadSuccess {
            if Task.isCancelled {
                throw CancellationError()
            }
            attempts += 1
            do {
                try await transport.downloadFileStreaming(
                    actionId: actionId,
                    remotePath: remotePath,
                    targetURL: tempURL,
                    totalSize: stat.size,
                    startOffset: currentOffset,
                    rangeTracker: rangeTracker,
                    onRangeConfirmed: { confirmedRange in
                        rangeTracker.addRange(confirmedRange)
                        try? journal.checkpointProgress(
                            transferId: actionId,
                            frontier: rangeTracker.contiguousFrontier,
                            ranges: rangeTracker.serialize(),
                            durabilityEvidence: true
                        )
                    },
                    onProgress: { bytes in
                        let pct = Double(bytes) / Double(max(1, stat.size)) * 0.85
                        progress(pct)
                    }
                )
                downloadSuccess = true
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                lastError = error
                currentOffset = rangeTracker.contiguousFrontier
                if attempts < maxAttempts {
                    let delaySec = UInt64(attempts)
                    try? await Task.sleep(nanoseconds: delaySec * 1_000_000_000)
                }
            }
        }
        
        guard downloadSuccess else {
            let finalError = lastError ?? NSError(domain: "JobOrchestrator", code: 2, userInfo: [NSLocalizedDescriptionKey: "Download failed after \(maxAttempts) attempts"])
            sm.transition(to: .failed, error: finalError.localizedDescription)
            try? journal.updateState(transferId: actionId, state: "failed", errorMessage: finalError.localizedDescription)
            ledger.recordItemState(
                itemId: itemId,
                jobId: jobId,
                actionId: actionId,
                requestHash: reqHash,
                state: .failed,
                bytes: 0,
                total: stat.size,
                mtime: stat.mtime,
                error: finalError.localizedDescription
            )
            throw finalError
        }
        
        // 3. Verify: Проверка целостности и покрытия перед коммитом
        guard rangeTracker.isFullyCovered(expectedSize: stat.size) else {
            throw JobOrchestratorError.transferInterrupted(reason: "Обнаружены непокрытые диапазоны байт (дыры) перед коммитом")
        }
        
        let tempVals = try? tempURL.resourceValues(forKeys: [.fileSizeKey])
        let tempSize = UInt64(tempVals?.fileSize ?? 0)
        guard tempSize == stat.size else {
            throw JobOrchestratorError.transferInterrupted(reason: "Размер загруженного файла (\(tempSize)) не совпадает с оригиналом (\(stat.size))")
        }
        
        // Повторная проверка источника (snapshot identity)
        if let statAfter = try? await transport.prepareRead(actionId: actionId, path: remotePath) {
            if statAfter.size != stat.size || statAfter.mtime != stat.mtime {
                throw JobOrchestratorError.transferInterrupted(reason: "Источник изменился во время передачи")
            }
        }
        
        // 4. Commit: COMMITTING
        sm.transition(to: .committing)
        try? journal.updateState(transferId: actionId, state: "committing")
        ledger.recordItemState(
            itemId: itemId,
            jobId: jobId,
            actionId: actionId,
            requestHash: reqHash,
            state: .committing,
            bytes: stat.size,
            total: stat.size,
            mtime: stat.mtime
        )
        
        do {
            try await localFS.renameItem(from: tempURL.path, to: finalURL.path)
        } catch {
            sm.transition(to: .indeterminate, error: "Ошибка при локальном переименовании: \(error.localizedDescription)")
            try? journal.updateState(transferId: actionId, state: "indeterminate", errorMessage: error.localizedDescription)
            throw error
        }
        
        let origMtime = Date(timeIntervalSince1970: TimeInterval(stat.mtime))
        try? FileManager.default.setAttributes([.modificationDate: origMtime], ofItemAtPath: finalURL.path)
        
        // Верификация коммита
        let finalVals = try? finalURL.resourceValues(forKeys: [.fileSizeKey])
        let finalSize = UInt64(finalVals?.fileSize ?? 0)
        guard FileManager.default.fileExists(atPath: finalURL.path) && finalSize == stat.size else {
            sm.transition(to: .indeterminate, error: "Целевой файл поврежден или имеет неверный размер после переименования")
            try? journal.updateState(transferId: actionId, state: "indeterminate", errorMessage: "Commit verification failed")
            throw JobOrchestratorError.commitVerificationFailed(path: finalURL.path)
        }
        
        // 5. Удаление оригинала при Move с подтверждением
        var sourceDeletionFailed = false
        var sourceDeletionReason = ""
        if isMove {
            var deleted = (try? await transport.executeDelete(actionId: UUID().uuidString, path: remotePath)) ?? false
            if !deleted {
                let escaped = PhoneConnectionManager.shellEscape(remotePath)
                let adbRes = PhoneConnectionManager.shared.executeAdbShell(command: "rm -f -- \(escaped)")
                if adbRes.status == 0 {
                    deleted = true
                }
            }
            if !deleted {
                // Контрольная проверка: если файл уже отсутствует (удален компаньоном/системой),
                // prepareRead выбросит ошибку noSuchFile -> удаление оригинала фактически состоялось.
                do {
                    _ = try await transport.prepareRead(actionId: UUID().uuidString, path: remotePath)
                    sourceDeletionFailed = true
                    sourceDeletionReason = "Файл успешно загружен на Mac, но не удалось удалить оригинал на телефоне"
                } catch {
                    deleted = true
                }
            }
        }
        
        // 6. Успех
        sm.transition(to: .completed)
        ledger.recordItemState(
            itemId: itemId,
            jobId: jobId,
            actionId: actionId,
            requestHash: reqHash,
            state: .completed,
            bytes: stat.size,
            total: stat.size,
            mtime: stat.mtime
        )
        progress(1.0)
        if sourceDeletionFailed {
            return .transferredWithoutSourceDeletion(reason: sourceDeletionReason)
        }
        return .transferred
    }
    
    @discardableResult
    public func executeCopyMacToPhone(
        jobId: String,
        itemId: String,
        localSourceURL: URL,
        remoteTargetDir: String,
        destinationFileName: String? = nil,
        strategy: ConflictResolutionStrategy = .overwrite,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TransferExecutionResult {
        return try await executeUpload(
            isMove: false,
            jobId: jobId,
            itemId: itemId,
            localSourceURL: localSourceURL,
            remoteTargetDir: remoteTargetDir,
            destinationFileName: destinationFileName,
            strategy: strategy,
            progress: progress
        )
    }
    
    @discardableResult
    public func executeMoveMacToPhone(
        jobId: String,
        itemId: String,
        localSourceURL: URL,
        remoteTargetDir: String,
        destinationFileName: String? = nil,
        strategy: ConflictResolutionStrategy = .overwrite,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TransferExecutionResult {
        return try await executeUpload(
            isMove: true,
            jobId: jobId,
            itemId: itemId,
            localSourceURL: localSourceURL,
            remoteTargetDir: remoteTargetDir,
            destinationFileName: destinationFileName,
            strategy: strategy,
            progress: progress
        )
    }
    
    private func executeUpload(
        isMove: Bool,
        jobId: String,
        itemId: String,
        localSourceURL: URL,
        remoteTargetDir: String,
        destinationFileName: String? = nil,
        strategy: ConflictResolutionStrategy,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TransferExecutionResult {
        guard FileManager.default.fileExists(atPath: localSourceURL.path) else {
            throw NSError(domain: "JobOrchestrator", code: 404, userInfo: [NSLocalizedDescriptionKey: "Source file not found: \(localSourceURL.path)"])
        }
        
        let actionId = UUID().uuidString
        let sm = JobUnitStateMachine(initialState: .planned)
        let fileSize = UInt64((try? localSourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let mtime = Int64((try? localSourceURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? Date().timeIntervalSince1970)
        let reqHash = "\(localSourceURL.path):\(fileSize):\(mtime)"
        
        var fileName = (destinationFileName ?? localSourceURL.lastPathComponent).precomposedStringWithCanonicalMapping
        var remoteFinalPath = (remoteTargetDir as NSString).appendingPathComponent(fileName).precomposedStringWithCanonicalMapping
        
        // Проверка конфликтов на удалённом устройстве (только если стратегия не .overwrite)
        if strategy != .overwrite, let existingStat = try? await transport.prepareRead(actionId: actionId, path: remoteFinalPath) {
            switch strategy {
            case .skip:
                progress(1.0)
                return .skipped(reason: "Файл уже существует на телефоне")
            case .skipIfIdentical:
                if existingStat.size == fileSize && abs(existingStat.mtime - mtime) < 2 {
                    progress(1.0)
                    return .skipped(reason: "Идентичный файл уже существует на телефоне")
                }
            case .overwriteIfNewer:
                if existingStat.mtime >= mtime {
                    progress(1.0)
                    return .skipped(reason: "Файл на телефоне новее или такой же")
                }
            case .autoRename:
                let ext = (fileName as NSString).pathExtension
                let base = (fileName as NSString).deletingPathExtension
                var counter = 1
                while (try? await transport.prepareRead(actionId: actionId, path: remoteFinalPath)) != nil {
                    let newName = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
                    fileName = newName
                    remoteFinalPath = (remoteTargetDir as NSString).appendingPathComponent(newName).precomposedStringWithCanonicalMapping
                    counter += 1
                }
            case .customRename, .overwrite:
                break
            }
        }
        
        sm.transition(to: .running)
        ledger.recordItemState(
            itemId: itemId,
            jobId: jobId,
            actionId: actionId,
            requestHash: reqHash,
            state: .running,
            bytes: 0,
            total: fileSize,
            mtime: mtime
        )
        
        let deviceId = PhoneConnectionManager.shared.getConnectedDeviceId() ?? "phone"
        let sessionIdentity = "\(deviceId):\(transport.coordinator.host):\(transport.coordinator.port)"
        let srcKey = "\(deviceId):\(localSourceURL.path):\(fileSize):\(mtime)"
        let fingerprint = SHA256.hash(data: Data(srcKey.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
        let remoteTempPath = (remoteTargetDir as NSString).appendingPathComponent(".\(fileName).\(fingerprint).mcdpart").precomposedStringWithCanonicalMapping
        registerActiveRemotePart(path: remoteTempPath)
        defer {
            unregisterActiveRemotePart(path: remoteTempPath)
        }
        
        let journal = TransferJournal.shared
        var rangeTracker = ConfirmedRangeTracker()
        var startOffset: UInt64 = 0
        
        // Проверяем возможность возобновления через TransferJournal
        if let resumable = journal.findResumableTransfer(
            sessionIdentity: sessionIdentity,
            sourcePath: localSourceURL.path,
            sourceSize: fileSize,
            sourceMtime: mtime,
            direction: "upload"
        ) {
            let loadedTracker = ConfirmedRangeTracker.deserialize(resumable.rangesBlob)
            let frontier = loadedTracker.contiguousFrontier
            if frontier > 0, let remoteStat = try? await transport.prepareRead(actionId: actionId, path: remoteTempPath), remoteStat.size >= frontier {
                // Префиксная проверка целостности первых байтов перед Resume
                let prefixLen = min(frontier, 4096)
                var prefixValid = false
                if let handle = try? FileHandle(forReadingFrom: localSourceURL) {
                    let localPrefix = try? handle.read(upToCount: Int(prefixLen))
                    try? handle.close()
                    if let localPrefix = localPrefix, localPrefix.count == Int(prefixLen) {
                        if let remotePrefix = try? await transport.readChunk(remotePath: remoteTempPath, offset: 0, length: UInt32(prefixLen)),
                           remotePrefix == localPrefix {
                            prefixValid = true
                        }
                    }
                }
                if prefixValid {
                    rangeTracker = loadedTracker
                    startOffset = frontier
                } else {
                    _ = try? await transport.executeDelete(actionId: actionId, path: remoteTempPath)
                    rangeTracker = ConfirmedRangeTracker()
                    startOffset = 0
                }
            }
        } else if let _ = try? await transport.prepareRead(actionId: actionId, path: remoteTempPath) {
            // Неизвестный .mcdpart без журнала удаляем перед новой передачей
            _ = try? await transport.executeDelete(actionId: actionId, path: remoteTempPath)
        }
        
        try? journal.registerTransfer(
            transferId: actionId,
            sessionIdentity: sessionIdentity,
            direction: "upload",
            sourcePath: localSourceURL.path,
            sourceSize: fileSize,
            sourceMtime: mtime,
            sourceHash: nil,
            targetFinalPath: remoteFinalPath,
            targetTempPath: remoteTempPath,
            expectedSize: fileSize,
            initialFrontier: startOffset,
            initialRanges: rangeTracker.serialize(),
            state: "transferring"
        )
        
        do {
            try await transport.uploadFileStreaming(
                actionId: actionId,
                localURL: localSourceURL,
                remotePath: remoteTempPath,
                startOffset: startOffset,
                rangeTracker: rangeTracker,
                onRangeConfirmed: { confirmedRange in
                    rangeTracker.addRange(confirmedRange)
                    try? journal.checkpointProgress(
                        transferId: actionId,
                        frontier: rangeTracker.contiguousFrontier,
                        ranges: rangeTracker.serialize(),
                        durabilityEvidence: true
                    )
                },
                onProgress: { bytes in
                    let pct = Double(bytes) / Double(max(1, fileSize)) * 0.90
                    progress(pct)
                }
            )
            
            // 3. Verify: Проверка покрытия перед коммитом
            guard rangeTracker.isFullyCovered(expectedSize: fileSize) else {
                throw JobOrchestratorError.transferInterrupted(reason: "Обнаружены непокрытые диапазоны при выгрузке (дыры)")
            }
            
            guard let tempStat = try? await transport.prepareRead(actionId: actionId, path: remoteTempPath),
                  tempStat.size == fileSize else {
                throw JobOrchestratorError.transferInterrupted(reason: "Размер загруженного на телефон файла не совпадает с оригиналом")
            }
            
            // Проверка поддержки атомарного замещения при существовании целевого файла
            let targetExists = (try? await transport.prepareRead(actionId: actionId, path: remoteFinalPath)) != nil
            if targetExists && transport.coordinator.serverExtensions["posix-rename@openssh.com"] == nil {
                throw JobOrchestratorError.unsupportedAtomicReplace(path: remoteFinalPath)
            }
            
            // 4. Commit: переименовываем временный .mcdpart файл в финальный
            sm.transition(to: .committing)
            try? journal.updateState(transferId: actionId, state: "committing")
            ledger.recordItemState(
                itemId: itemId,
                jobId: jobId,
                actionId: actionId,
                requestHash: reqHash,
                state: .committing,
                bytes: fileSize,
                total: fileSize,
                mtime: mtime
            )
            
            let renameSuccess = try await transport.executeRename(oldPath: remoteTempPath, newPath: remoteFinalPath)
            guard renameSuccess else {
                sm.transition(to: .indeterminate, error: "Не удалось переименовать временный файл на телефоне")
                try? journal.updateState(transferId: actionId, state: "indeterminate", errorMessage: "Remote rename failed")
                throw NSError(domain: "JobOrchestrator", code: 500, userInfo: [NSLocalizedDescriptionKey: "Remote commit (rename) failed for: \(remoteFinalPath)"])
            }
            
            // 5. Верификация размера файла на телефоне после переименования
            guard let verifiedStat = try? await transport.prepareRead(actionId: actionId, path: remoteFinalPath),
                  verifiedStat.size == fileSize else {
                sm.transition(to: .indeterminate, error: "Целевой файл на телефоне не прошел проверку целостности размера")
                try? journal.updateState(transferId: actionId, state: "indeterminate", errorMessage: "Commit verification failed")
                throw JobOrchestratorError.commitVerificationFailed(path: remoteFinalPath)
            }
            
            // Восстанавливаем оригинальный mtime на телефоне для консистентности и быстрого пропуска идентичных файлов
            _ = try? await transport.setRemoteMtime(path: remoteFinalPath, mtime: mtime)
            
            var sourceDeletionFailed = false
            var sourceDeletionReason = ""
            if isMove {
                do {
                    try FileManager.default.removeItem(at: localSourceURL)
                } catch {
                    sourceDeletionFailed = true
                    sourceDeletionReason = "Файл скопирован на телефон, но не удалось удалить локальный оригинал: \(error.localizedDescription)"
                }
            }
            
            sm.transition(to: .completed)
            ledger.recordItemState(
                itemId: itemId,
                jobId: jobId,
                actionId: actionId,
                requestHash: reqHash,
                state: .completed,
                bytes: fileSize,
                total: fileSize,
                mtime: mtime
            )
            progress(1.0)
            if sourceDeletionFailed {
                return .transferredWithoutSourceDeletion(reason: sourceDeletionReason)
            }
            return .transferred
            
        } catch {
            sm.transition(to: .failed, error: error.localizedDescription)
            ledger.recordItemState(
                itemId: itemId,
                jobId: jobId,
                actionId: actionId,
                requestHash: reqHash,
                state: .failed,
                bytes: 0,
                total: fileSize,
                mtime: mtime,
                error: error.localizedDescription
            )
            // При сбое НЕ удаляем .mcdpart, чтобы позволить продолжить докачку (Resume)
            throw error
        }
    }
    
    @discardableResult
    public func executeCopyMacToMac(
        jobId: String,
        itemId: String,
        localSourceURL: URL,
        localTargetDir: URL,
        destinationFileName: String? = nil,
        strategy: ConflictResolutionStrategy = .overwrite,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TransferExecutionResult {
        let name = (destinationFileName ?? localSourceURL.lastPathComponent).precomposedStringWithCanonicalMapping
        var finalURL = localTargetDir.appendingPathComponent(name)
        
        // Проверка конфликтов для Mac-to-Mac
        if FileManager.default.fileExists(atPath: finalURL.path) {
            let srcVals = try? localSourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let srcSize = UInt64(srcVals?.fileSize ?? 0)
            let srcMtime = Int64(srcVals?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            
            let destVals = try? finalURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let destSize = UInt64(destVals?.fileSize ?? 0)
            let destMtime = Int64(destVals?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            
            switch strategy {
            case .skip:
                progress(1.0)
                return .skipped(reason: "Файл уже существует")
            case .skipIfIdentical:
                if srcSize == destSize && abs(srcMtime - destMtime) < 2 {
                    progress(1.0)
                    return .skipped(reason: "Идентичный файл уже существует")
                }
            case .overwriteIfNewer:
                if destMtime >= srcMtime {
                    progress(1.0)
                    return .skipped(reason: "Существующий файл новее или такой же")
                }
            case .autoRename:
                let ext = finalURL.pathExtension
                let base = finalURL.deletingPathExtension().lastPathComponent
                var counter = 1
                while FileManager.default.fileExists(atPath: finalURL.path) {
                    let newName = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
                    finalURL = localTargetDir.appendingPathComponent(newName)
                    counter += 1
                }
            case .customRename, .overwrite:
                break
            }
        }
        
        let actionId = UUID().uuidString
        let tempURL = localTargetDir.appendingPathComponent(".\(finalURL.lastPathComponent).part.\(actionId)")
        registerActiveLocalPart(url: tempURL)
        defer {
            unregisterActiveLocalPart(url: tempURL)
        }
        
        do {
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try? FileManager.default.removeItem(at: tempURL)
            }
            try FileManager.default.copyItem(at: localSourceURL, to: tempURL)
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: tempURL)
                throw CancellationError()
            }
            try await localFS.renameItem(from: tempURL.path, to: finalURL.path)
            progress(1.0)
            return .transferred
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    @discardableResult
    public func executeMoveMacToMac(
        jobId: String,
        itemId: String,
        localSourceURL: URL,
        localTargetDir: URL,
        destinationFileName: String? = nil,
        strategy: ConflictResolutionStrategy = .overwrite,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TransferExecutionResult {
        let name = (destinationFileName ?? localSourceURL.lastPathComponent).precomposedStringWithCanonicalMapping
        var finalURL = localTargetDir.appendingPathComponent(name)
        
        // Проверка конфликтов для Mac-to-Mac Move
        if FileManager.default.fileExists(atPath: finalURL.path) {
            let srcVals = try? localSourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let srcSize = UInt64(srcVals?.fileSize ?? 0)
            let srcMtime = Int64(srcVals?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            
            let destVals = try? finalURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let destSize = UInt64(destVals?.fileSize ?? 0)
            let destMtime = Int64(destVals?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            
            switch strategy {
            case .skip:
                progress(1.0)
                return .skipped(reason: "Файл уже существует")
            case .skipIfIdentical:
                if srcSize == destSize && abs(srcMtime - destMtime) < 2 {
                    progress(1.0)
                    return .skipped(reason: "Идентичный файл уже существует")
                }
            case .overwriteIfNewer:
                if destMtime >= srcMtime {
                    progress(1.0)
                    return .skipped(reason: "Существующий файл новее или такой же")
                }
            case .autoRename:
                let ext = finalURL.pathExtension
                let base = finalURL.deletingPathExtension().lastPathComponent
                var counter = 1
                while FileManager.default.fileExists(atPath: finalURL.path) {
                    let newName = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
                    finalURL = localTargetDir.appendingPathComponent(newName)
                    counter += 1
                }
            case .customRename, .overwrite:
                break
            }
        }
        
        let actionId = UUID().uuidString
        let tempURL = localTargetDir.appendingPathComponent(".\(finalURL.lastPathComponent).part.\(actionId)")
        registerActiveLocalPart(url: tempURL)
        defer {
            unregisterActiveLocalPart(url: tempURL)
        }
        
        do {
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try? FileManager.default.removeItem(at: tempURL)
            }
            // Безопасный перенос: сначала копируем во временный файл целевой папки
            // (на APFS copyItem выполняет мгновенный clonefile без расхода дискового пространства)
            try FileManager.default.copyItem(at: localSourceURL, to: tempURL)
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: tempURL)
                throw CancellationError()
            }
            try await localFS.renameItem(from: tempURL.path, to: finalURL.path)
            
            // Верифицируем целевой файл перед удалением оригинала
            guard FileManager.default.fileExists(atPath: finalURL.path) else {
                throw JobOrchestratorError.commitVerificationFailed(path: finalURL.path)
            }
            
            do {
                try FileManager.default.removeItem(at: localSourceURL)
            } catch {
                progress(1.0)
                return .transferredWithoutSourceDeletion(reason: "Файл перемещен, но исходный файл не удалось удалить: \(error.localizedDescription)")
            }
            
            progress(1.0)
            return .transferred
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }
    
    /// Сверка и восстановление прерванных транзакций (Reconciliation)
    public func reconcileInterruptedJobs(in directory: URL) async {
        // Очистка зависших временных файлов .part
        cleanDanglingPartFiles(in: directory)
    }
    
    /// Очистка незавершенных .part файлов старше 1 часа
    public func cleanDanglingPartFiles(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }
        let now = Date()
        activePartsLock.lock()
        let activeUrls = activeLocalPartURLs
        activePartsLock.unlock()
        
        for file in files {
            if activeUrls.contains(file) {
                continue
            }
            let name = file.lastPathComponent
            if name.hasPrefix(".") && (name.contains(".part.") || name.contains(".mcdpart")) {
                if let vals = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                   let mdate = vals.contentModificationDate,
                   now.timeIntervalSince(mdate) > 3600 {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }
    
    public struct BatchItemResult: Sendable {
        public let itemId: String
        public let isSuccess: Bool
        public let result: TransferExecutionResult?
        public let errorDescription: String?
        
        public init(itemId: String, result: TransferExecutionResult) {
            self.itemId = itemId
            self.isSuccess = true
            self.result = result
            self.errorDescription = nil
        }
        
        public init(itemId: String, error: Error) {
            self.itemId = itemId
            self.isSuccess = false
            self.result = nil
            self.errorDescription = error.localizedDescription
        }
    }
    
    /// Пакетная передача файлов Phone -> Mac с пулом конкурентности (по умолчанию до 4)
    public func executeBatchPhoneToMac(
        items: [(jobId: String, itemId: String, remotePath: String, localTargetDir: URL, isMove: Bool, strategy: ConflictResolutionStrategy)],
        maxConcurrent: Int = 4,
        onItemProgress: (@Sendable (String, Double) -> Void)? = nil
    ) async -> [BatchItemResult] {
        let concurrency = max(1, min(maxConcurrent, 8))
        var results: [BatchItemResult] = []
        
        await withTaskGroup(of: BatchItemResult.self) { group in
            var submitted = 0
            for item in items {
                if submitted >= concurrency {
                    if let res = await group.next() {
                        results.append(res)
                    }
                }
                submitted += 1
                group.addTask {
                    do {
                        let res = try await self.executeTransfer(
                            isMove: item.isMove,
                            jobId: item.jobId,
                            itemId: item.itemId,
                            remotePath: item.remotePath,
                            localTargetDir: item.localTargetDir,
                            strategy: item.strategy,
                            progress: { p in
                                onItemProgress?(item.itemId, p)
                            }
                        )
                        return BatchItemResult(itemId: item.itemId, result: res)
                    } catch {
                        return BatchItemResult(itemId: item.itemId, error: error)
                    }
                }
            }
            
            for await res in group {
                results.append(res)
            }
        }
        
        return results
    }
    
    /// Пакетная передача файлов Mac -> Phone с пулом конкурентности (по умолчанию до 4)
    public func executeBatchMacToPhone(
        items: [(jobId: String, itemId: String, localSourceURL: URL, remoteTargetDir: String, isMove: Bool, strategy: ConflictResolutionStrategy)],
        maxConcurrent: Int = 4,
        onItemProgress: (@Sendable (String, Double) -> Void)? = nil
    ) async -> [BatchItemResult] {
        let concurrency = max(1, min(maxConcurrent, 8))
        var results: [BatchItemResult] = []
        
        await withTaskGroup(of: BatchItemResult.self) { group in
            var submitted = 0
            for item in items {
                if submitted >= concurrency {
                    if let res = await group.next() {
                        results.append(res)
                    }
                }
                submitted += 1
                group.addTask {
                    do {
                        let res = try await self.executeUpload(
                            isMove: item.isMove,
                            jobId: item.jobId,
                            itemId: item.itemId,
                            localSourceURL: item.localSourceURL,
                            remoteTargetDir: item.remoteTargetDir,
                            strategy: item.strategy,
                            progress: { p in
                                onItemProgress?(item.itemId, p)
                            }
                        )
                        return BatchItemResult(itemId: item.itemId, result: res)
                    } catch {
                        return BatchItemResult(itemId: item.itemId, error: error)
                    }
                }
            }
            
            for await res in group {
                results.append(res)
            }
        }
        
        return results
    }
}
