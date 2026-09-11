import Foundation

public enum TransferTaskStatus: String, CaseIterable, Sendable {
    case queued    = "В очереди"
    case running   = "Выполняется"
    case paused    = "Приостановлено"
    case completed = "Завершено"
    case failed    = "Ошибка"
    case cancelled = "Отменено"
}

public struct TransferTask: Identifiable, Sendable {
    public let id: UUID
    public let sourceItem: FileItem
    public let targetDir: String
    public let isMove: Bool
    public var status: TransferTaskStatus
    public var progress: Double
    public var bytesTransferred: UInt64
    public var totalBytes: UInt64
    public var speed: Double
    public var eta: TimeInterval?
    public var errorMessage: String?
    
    public init(
        id: UUID = UUID(),
        sourceItem: FileItem,
        targetDir: String,
        isMove: Bool,
        status: TransferTaskStatus = .queued,
        progress: Double = 0.0,
        bytesTransferred: UInt64 = 0,
        totalBytes: UInt64 = 0,
        speed: Double = 0.0,
        eta: TimeInterval? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.sourceItem = sourceItem
        self.targetDir = targetDir
        self.isMove = isMove
        self.status = status
        self.progress = progress
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.speed = speed
        self.eta = eta
        self.errorMessage = errorMessage
    }
}

@MainActor
public final class TransferQueueManager: ObservableObject {
    public static let shared = TransferQueueManager()
    
    @Published public var tasks: [TransferTask] = []
    @Published public var isProcessing: Bool = false
    @Published public var isGlobalPaused: Bool = false
    @Published public private(set) var cancelledTaskIds: Set<UUID> = []
    
    public var onTaskCancelled: (@MainActor (UUID) -> Void)?
    public var onTaskPaused: (@MainActor (UUID) -> Void)?
    public var onTaskResumed: (@MainActor (UUID) -> Void)?
    public var onGlobalCancel: (@MainActor () -> Void)?
    
    public init() {}
    
    public func isTaskCancelled(id: UUID) -> Bool {
        return cancelledTaskIds.contains(id)
    }
    
    @discardableResult
    public func enqueue(source: FileItem, targetDir: String, isMove: Bool) -> UUID {
        let task = TransferTask(
            sourceItem: source,
            targetDir: targetDir,
            isMove: isMove,
            totalBytes: source.size
        )
        tasks.append(task)
        return task.id
    }
    
    public func pauseTask(id: UUID) {
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].status = .paused
            tasks[idx].speed = 0
            tasks[idx].eta = nil
            onTaskPaused?(id)
        }
    }
    
    public func resumeTask(id: UUID) {
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].status = .queued
            onTaskResumed?(id)
        }
    }
    
    public func cancelTask(id: UUID) {
        cancelledTaskIds.insert(id)
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].status = .cancelled
            tasks[idx].speed = 0
            tasks[idx].eta = nil
            onTaskCancelled?(id)
        }
    }
    
    public func pauseAll() {
        isGlobalPaused = true
        for i in 0..<tasks.count {
            if tasks[i].status == .running || tasks[i].status == .queued {
                tasks[i].status = .paused
                tasks[i].speed = 0
                tasks[i].eta = nil
            }
        }
    }
    
    public func resumeAll() {
        isGlobalPaused = false
        for i in 0..<tasks.count {
            if tasks[i].status == .paused {
                tasks[i].status = .queued
            }
        }
    }
    
    public func cancelAll() {
        for i in 0..<tasks.count {
            cancelledTaskIds.insert(tasks[i].id)
            if tasks[i].status == .running || tasks[i].status == .queued || tasks[i].status == .paused {
                tasks[i].status = .cancelled
                tasks[i].speed = 0
                tasks[i].eta = nil
            }
        }
        onGlobalCancel?()
    }
    
    public func updateProgress(
        id: UUID,
        progress: Double,
        bytesTransferred: UInt64,
        speed: Double = 0.0,
        eta: TimeInterval? = nil
    ) {
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].progress = progress
            tasks[idx].bytesTransferred = bytesTransferred
            tasks[idx].speed = speed
            tasks[idx].eta = eta
            if progress >= 1.0 {
                tasks[idx].status = .completed
                tasks[idx].speed = 0
                tasks[idx].eta = nil
            } else if tasks[idx].status == .queued {
                tasks[idx].status = .running
            }
        }
    }
    
    public func markFailed(id: UUID, error: String) {
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].status = .failed
            tasks[idx].errorMessage = error
            tasks[idx].speed = 0
            tasks[idx].eta = nil
        }
    }
    
    public func clearCompleted() {
        let toRemove = tasks.filter { $0.status == .completed || $0.status == .cancelled }.map(\.id)
        for id in toRemove {
            cancelledTaskIds.remove(id)
        }
        tasks.removeAll(where: { $0.status == .completed || $0.status == .cancelled })
    }
    
    @discardableResult
    public func retryFailedTasks() -> Int {
        var count = 0
        for i in 0..<tasks.count {
            if tasks[i].status == .failed || tasks[i].status == .cancelled {
                cancelledTaskIds.remove(tasks[i].id)
                tasks[i].status = .queued
                tasks[i].errorMessage = nil
                tasks[i].progress = 0.0
                tasks[i].speed = 0.0
                tasks[i].eta = nil
                count += 1
            }
        }
        return count
    }
}
