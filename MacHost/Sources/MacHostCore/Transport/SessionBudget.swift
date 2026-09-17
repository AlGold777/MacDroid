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
    
    private var waiters: [(neededPayload: Int, isInteractive: Bool, continuation: CheckedContinuation<Void, Never>)] = []
    
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
    
    /// Освобождение дескриптора файла
    public func releaseHandle() {
        lock.lock()
        defer { lock.unlock() }
        if openHandles > 0 {
            openHandles -= 1
        }
    }
    
    /// Резервирование байтового бюджета для запроса
    public func acquirePayload(bytes: Int, isInteractive: Bool) async {
        guard bytes > 0 else { return }
        
        while true {
            lock.lock()
            let availableLimit = isInteractive ? maxNetworkPayload : (maxNetworkPayload - interactiveReserve)
            if inFlightNetworkPayload + bytes <= availableLimit {
                inFlightNetworkPayload += bytes
                lock.unlock()
                return
            }
            
            await withCheckedContinuation { continuation in
                waiters.append((neededPayload: bytes, isInteractive: isInteractive, continuation: continuation))
                lock.unlock()
            }
        }
    }
    
    /// Освобождение байтового бюджета после завершения или отмены запроса
    public func releasePayload(bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        inFlightNetworkPayload = max(0, inFlightNetworkPayload - bytes)
        
        // Проверяем ждущих
        var toResume: [CheckedContinuation<Void, Never>] = []
        var remainingWaiters: [(neededPayload: Int, isInteractive: Bool, continuation: CheckedContinuation<Void, Never>)] = []
        
        for w in waiters {
            let limit = w.isInteractive ? maxNetworkPayload : (maxNetworkPayload - interactiveReserve)
            if inFlightNetworkPayload + w.neededPayload <= limit {
                inFlightNetworkPayload += w.neededPayload
                toResume.append(w.continuation)
            } else {
                remainingWaiters.append(w)
            }
        }
        waiters = remainingWaiters
        lock.unlock()
        
        for c in toResume {
            c.resume()
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
            c.resume()
        }
    }
}
