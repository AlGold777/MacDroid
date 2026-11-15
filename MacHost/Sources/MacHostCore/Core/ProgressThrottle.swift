import Foundation

/// Потокобезопасный троттлер прогресса одного задания.
/// Вызывается из колбэка транспорта (на каждый чанк) и решает, нужно ли вообще переходить на главный актор:
/// пропускает не чаще `minInterval`, но первое и финальное (>= 1.0) значения проходят всегда.
/// Последнее увиденное значение хранится внутри и доступно через `latest`.
public final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let minInterval: TimeInterval
    private let clock: @Sendable () -> CFAbsoluteTime
    private var lastEmit: CFAbsoluteTime?
    private var latestValue: Double = 0
    private var finalEmitted = false

    public init(
        minInterval: TimeInterval = 1.0 / 15.0,
        clock: @escaping @Sendable () -> CFAbsoluteTime = { CFAbsoluteTimeGetCurrent() }
    ) {
        self.minInterval = minInterval
        self.clock = clock
    }

    /// Последнее переданное значение (включая пропущенные)
    public var latest: Double {
        lock.lock(); defer { lock.unlock() }
        return latestValue
    }

    /// Возвращает значение для отправки на главный актор либо nil, если вызов нужно отбросить.
    public func submit(_ value: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        latestValue = value
        if value >= 1.0 {
            guard !finalEmitted else { return nil }
            finalEmitted = true
            lastEmit = clock()
            return value
        }
        let now = clock()
        if let last = lastEmit, now - last < minInterval { return nil }
        lastEmit = now
        return value
    }
}
