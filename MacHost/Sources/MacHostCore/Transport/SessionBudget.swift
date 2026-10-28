import Foundation

/// Управление совокупным бюджетом сетевого конвейера, буферов записи и файловых дескрипторов
public final class SessionBudget: @unchecked Sendable {
    public static let defaultMaxNetworkPayload: Int = 8 * 1024 * 1024 // 8 MiB
    public static let defaultMaxWriteBuffers: Int = 8 * 1024 * 1024  // 8 MiB
    public static let defaultMaxHandles: Int = 32
    public static let defaultInteractiveReserve: Int = 1 * 1024 * 1024 // 1 MiB
    
    private let maxNetworkPayload: Int
    private let maxWriteBuffers: Int
    private let maxHandles: Int
    private let interactiveReserve: Int
    
    private let lock = NSLock()
    private var inFlightNetworkPayload: Int = 0
    private var inFlightWriteBuffers: Int = 0
    private var openHandles: Int = 0
    
    private struct PayloadWaiter {
        let id: UUID
        let neededPayload: Int
        let isInteractive: Bool
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var waiters: [PayloadWaiter] = []
    
    public init(
        maxNetworkPayload: Int = defaultMaxNetworkPayload,
        maxWriteBuffers: Int = defaultMaxWriteBuffers,
        maxHandles: Int = defaultMaxHandles,
        interactiveReserve: Int = defaultInteractiveReserve
    ) {
        self.maxNetworkPayload = maxNetworkPayload
        self.maxWriteBuffers = maxWriteBuffers
        self.maxHandles = maxHandles
        self.interactiveReserve = interactiveReserve
    }
    
    /// Текущее использование
    public var currentSnapshot: (networkBytes: Int, writeBytes: Int, handles: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (inFlightNetworkPayload, inFlightWriteBuffers, openHandles)
    }
    
    /// Резервирование дескриптора файла (open handle)
    public func acquireHandle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if openHandles < maxHandles {
            openHandles += 1
            return true
        }
        return false
    }
    
    /// Резервирование дескриптора с ожиданием освобождения: при пике одновременных передач
    /// операция ждёт свой слот, а не падает сразу с «Exceeded max handles»
    public func acquireHandle(waitingUpTo timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if acquireHandle() { return true }
            if Task.isCancelled || Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Освобождение дескриптора файла
    public func releaseHandle() {
        lock.lock()
        defer { lock.unlock() }
        if openHandles > 0 {
            openHandles -= 1
        }
    }
    
    /// Резервирование байтового бюджета для запроса
    public func acquirePayload(bytes: Int, isInteractive: Bool) async -> Bool {
        guard bytes > 0 else { return true }
        let id = UUID()
        let acquired = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    lock.lock()
                    if Task.isCancelled {
                        lock.unlock()
                        continuation.resume(returning: false)
                        return
                    }
                    let availableLimit = isInteractive ? maxNetworkPayload : (maxNetworkPayload - interactiveReserve)
                    if inFlightNetworkPayload + bytes <= availableLimit {
                        inFlightNetworkPayload += bytes
                        lock.unlock()
                        continuation.resume(returning: true)
                        return
                    }
                    waiters.append(PayloadWaiter(id: id, neededPayload: bytes, isInteractive: isInteractive, continuation: continuation))
                    lock.unlock()
                }
            } onCancel: {
                self.lock.lock()
                let index = self.waiters.firstIndex(where: { $0.id == id })
                let waiter = index.map { self.waiters.remove(at: $0) }
                self.lock.unlock()
                waiter?.continuation.resume(returning: false)
            }
        if acquired && Task.isCancelled {
            releasePayload(bytes: bytes)
            return false
        }
        return acquired
    }
    
    /// Освобождение байтового бюджета после завершения или отмены запроса
    public func releasePayload(bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        inFlightNetworkPayload = max(0, inFlightNetworkPayload - bytes)
        
        // Проверяем ждущих: полный проход по очереди (best-fit scan).
        // Строгий FIFO с break на первом несоответствии приводил к convoy deadlock:
        // ожидающие задачи за «застрявшим» крупным waiter блокировались навсегда
        // даже если бюджет покрывал их запросы. Полный проход устраняет convoy.
        var toResume: [CheckedContinuation<Bool, Never>] = []
        var i = 0
        while i < waiters.count {
            let waiter = waiters[i]
            let limit = waiter.isInteractive ? maxNetworkPayload : (maxNetworkPayload - interactiveReserve)
            if inFlightNetworkPayload + waiter.neededPayload <= limit {
                inFlightNetworkPayload += waiter.neededPayload
                toResume.append(waiter.continuation)
                waiters.remove(at: i)
                // не инкрементируем i: следующий элемент сместился на текущую позицию
            } else {
                i += 1
            }
        }
        lock.unlock()
        
        for c in toResume {
            c.resume(returning: true)
        }
    }
    
    /// Сброс всех бюджетов при разрыве сессии
    public func reset() {
        lock.lock()
        inFlightNetworkPayload = 0
        inFlightWriteBuffers = 0
        openHandles = 0
        let toResume = waiters.map { $0.continuation }
        waiters.removeAll()
        lock.unlock()
        
        for c in toResume {
            c.resume(returning: false)
        }
    }
}
