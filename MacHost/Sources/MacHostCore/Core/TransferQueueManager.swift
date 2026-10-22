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
    // O(1) индексация задач по UUID вместо O(N) линейного поиска
    private var taskIndex: [UUID: Int] = [:]
    // Троттлинг обновлений прогресса (макс. 15 Гц)
    private var lastProgressUpdate: [UUID: CFAbsoluteTime] = [:]
    private let progressThrottleInterval: CFAbsoluteTime = 1.0 / 15.0  // ~67ms
    @Published public var isProcessing: Bool = false
    @Published public var isGlobalPaused: Bool = false
    @Published public private(set) var cancelledTaskIds: Set<UUID> = []
    
    public var onTaskCancelled: (@MainActor (UUID) -> Void)?
    public var onTaskPaused: (@MainActor (UUID) -> Void)?
    public var onTaskResumed: (@MainActor (UUID) -> Void)?
    public var onGlobalCancel: (@MainActor () -> Void)?
    
    public init() {}
    
    /// Пересоздаёт индекс O(1) lookup после структурных изменений массива tasks
    private func rebuildIndex() {
        taskIndex.removeAll(keepingCapacity: true)
        for (idx, task) in tasks.enumerated() {
            taskIndex[task.id] = idx
        }
    }
    
    /// O(1) поиск индекса задачи по UUID
    private func indexOf(_ id: UUID) -> Int? {
        guard let idx = taskIndex[id], idx < tasks.count, tasks[idx].id == id else {
            // Фоллбэк на линейный поиск при рассинхронизации
            if let found = tasks.firstIndex(where: { $0.id == id }) {
                taskIndex[id] = found
                return found
            }
            return nil
        }
        return idx
    }
    
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
        taskIndex[task.id] = tasks.count
        tasks.append(task)
        return task.id
    }
    
    public func enqueueTasks(_ newTasks: [TransferTask]) {
        guard !newTasks.isEmpty else { return }
        objectWillChange.send()
        tasks.reserveCapacity(tasks.count + newTasks.count)
        taskIndex.reserveCapacity(taskIndex.count + newTasks.count)
        let baseIndex = tasks.count
        for (i, task) in newTasks.enumerated() {
            taskIndex[task.id] = baseIndex + i
        }
        tasks.append(contentsOf: newTasks)
    }
    
    public func pauseTask(id: UUID) {
        if let idx = indexOf(id) {
            tasks[idx].status = .paused
            tasks[idx].speed = 0
            tasks[idx].eta = nil
            onTaskPaused?(id)
        }
    }
    
    public func resumeTask(id: UUID) {
        if let idx = indexOf(id) {
            tasks[idx].status = .queued
            onTaskResumed?(id)
        }
    }
    
    public func cancelTask(id: UUID) {
        cancelledTaskIds.insert(id)
        if let idx = indexOf(id) {
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
        // Троттлинг: обновляем UI не чаще 15 раз/сек (вместо ~400 раз/сек)
        let now = CFAbsoluteTimeGetCurrent()
        let isCompletion = progress >= 1.0
        if !isCompletion, let lastUpdate = lastProgressUpdate[id],
           now - lastUpdate < progressThrottleInterval {
            return
        }
        lastProgressUpdate[id] = now
        
        if let idx = indexOf(id) {
            let oldProgress = tasks[idx].progress
            let oldStatus = tasks[idx].status
            let newStatus: TransferTaskStatus = isCompletion ? .completed : (tasks[idx].status == .queued ? .running : tasks[idx].status)
            
            // Предотвращаем лишние перерисовки SwiftUI, если прогресс практически не изменился
            if !isCompletion && abs(oldProgress - progress) < 0.005 && oldStatus == newStatus {
                return
            }
            
            tasks[idx].progress = progress
            tasks[idx].bytesTransferred = bytesTransferred
            tasks[idx].speed = speed
            tasks[idx].eta = eta
            tasks[idx].status = newStatus
            if isCompletion {
                tasks[idx].speed = 0
                tasks[idx].eta = nil
                lastProgressUpdate.removeValue(forKey: id)
            }
        }
    }
    
    public func markFailed(id: UUID, error: String) {
        if let idx = indexOf(id) {
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
            lastProgressUpdate.removeValue(forKey: id)
        }
        tasks.removeAll(where: { $0.status == .completed || $0.status == .cancelled })
        rebuildIndex()
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
