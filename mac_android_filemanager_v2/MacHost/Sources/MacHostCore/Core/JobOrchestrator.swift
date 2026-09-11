import Foundation
import CryptoKit

public final class JobOrchestrator: @unchecked Sendable {
    private let ledger: IntentLedger
    private let transport: TransportMultiplexer
    private let localFS: LocalFSDriver
    
    public init(ledger: IntentLedger, transport: TransportMultiplexer, localFS: LocalFSDriver) {
        self.ledger = ledger
        self.transport = transport
        self.localFS = localFS
    }
    
    public func executeMovePhoneToMac(
        jobId: String,
        itemId: String,
        remotePath: String,
        localTargetDir: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await executeTransfer(
            isMove: true,
            jobId: jobId,
            itemId: itemId,
            remotePath: remotePath,
            localTargetDir: localTargetDir,
            progress: progress
        )
    }
    
    public func executeCopyPhoneToMac(
        jobId: String,
        itemId: String,
        remotePath: String,
        localTargetDir: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await executeTransfer(
            isMove: false,
            jobId: jobId,
            itemId: itemId,
            remotePath: remotePath,
            localTargetDir: localTargetDir,
            progress: progress
        )
    }
    
    private func executeTransfer(
        isMove: Bool,
        jobId: String,
        itemId: String,
        remotePath: String,
        localTargetDir: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let actionId = UUID().uuidString
        let sm = JobUnitStateMachine(initialState: .planned)
        
        let stat = try await transport.prepareRead(actionId: actionId, path: remotePath)
        let reqHash = "\(remotePath):\(stat.size):\(stat.mtime)"
        
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
        
        let name = URL(fileURLWithPath: remotePath).lastPathComponent.precomposedStringWithCanonicalMapping
        let tempURL = localTargetDir.appendingPathComponent(".\(name).part.\(actionId)")
        let finalURL = localTargetDir.appendingPathComponent(name)
        
        // 1. Потоковая загрузка во временный файл
        do {
            try await transport.downloadFileStreaming(
                actionId: actionId,
                remotePath: remotePath,
                targetURL: tempURL,
                totalSize: stat.size
            ) { bytes in
                let pct = Double(bytes) / Double(max(1, stat.size)) * 0.85
                progress(pct)
            }
        } catch {
            sm.transition(to: .failed, error: error.localizedDescription)
            ledger.recordItemState(
                itemId: itemId,
                jobId: jobId,
                actionId: actionId,
                requestHash: reqHash,
                state: .failed,
                bytes: 0,
                total: stat.size,
                mtime: stat.mtime,
                error: error.localizedDescription
            )
            // Удаляем поврежденный .part
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        
        // 2. Фаза двухфазного коммита: переход в COMMITTING
        sm.transition(to: .committing)
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
        
        // Атомарное переименование .part в целевой файл
        try await localFS.renameItem(from: tempURL.path, to: finalURL.path)
        
        // 3. Независимая проверка результата
        guard FileManager.default.fileExists(atPath: finalURL.path) else {
            sm.transition(to: .indeterminate, error: "Целевой файл не найден после переименования")
            throw NSError(domain: "JobOrchestrator", code: 101, userInfo: [NSLocalizedDescriptionKey: "Commit verification failed"])
        }
        
        // 4. Если это Move — только теперь удаляем оригинал на источнике
        if isMove {
            _ = try await transport.executeDelete(actionId: UUID().uuidString, path: remotePath)
        }
        
        // 5. Завершение
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
    }
}
