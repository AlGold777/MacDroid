import Foundation

/// Калькулятор скользящей скорости передачи данных и ориентировочного времени до завершения (ETA)
public final class TransferSpeedTracker: @unchecked Sendable {
    private struct Sample {
        let timestamp: Date
        let bytes: UInt64
    }
    
    private let windowDuration: TimeInterval
    private var samples: [Sample] = []
    private let lock = NSLock()
    
    public private(set) var totalTransferredBytes: UInt64 = 0
    public private(set) var startTime: Date
    
    public init(windowDuration: TimeInterval = 2.0) {
        self.windowDuration = windowDuration
        self.startTime = Date()
    }
    
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll()
        totalTransferredBytes = 0
        startTime = Date()
    }
    
    /// Обновление текущего значения переданных байт
    public func update(bytesTransferred: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date()
        totalTransferredBytes = bytesTransferred
        samples.append(Sample(timestamp: now, bytes: bytesTransferred))
        
        // Удаляем устаревшие сэмплы за пределами скользящего окна
        let cutoff = now.addingTimeInterval(-windowDuration)
        while let first = samples.first, first.timestamp < cutoff {
            // Оставляем хотя бы 2 сэмпла для расчета
            if samples.count <= 2 { break }
            samples.removeFirst()
        }
    }
    
    /// Текущая скользящая скорость в байтах в секунду
    public var currentSpeedBytesPerSec: Double {
        lock.lock()
        defer { lock.unlock() }
        
        guard samples.count >= 2,
              let oldest = samples.first,
              let newest = samples.last else {
            // Если сэмплов мало, используем общее время
            let elapsed = Date().timeIntervalSince(startTime)
            guard elapsed > 0.1 else { return 0.0 }
            return Double(totalTransferredBytes) / elapsed
        }
        
        let timeDelta = newest.timestamp.timeIntervalSince(oldest.timestamp)
        guard timeDelta > 0.05 else { return 0.0 }
        
        let bytesDelta = (newest.bytes >= oldest.bytes) ? (newest.bytes - oldest.bytes) : 0
        return Double(bytesDelta) / timeDelta
    }
    
    /// Средняя скорость за всё время передачи
    public var averageSpeedBytesPerSec: Double {
        lock.lock()
        defer { lock.unlock() }
        
        let elapsed = Date().timeIntervalSince(startTime)
        guard elapsed > 0.1 else { return 0.0 }
        return Double(totalTransferredBytes) / elapsed
    }
    
    /// Расчет оставшегося времени в секундах
    public func calculateETA(remainingBytes: UInt64) -> TimeInterval? {
        let speed = currentSpeedBytesPerSec
        guard speed > 512 else { // Скорость менее 512 Б/с считаем остановкой/паузой
            return nil
        }
        return Double(remainingBytes) / speed
    }
    
    /// Форматирование скорости: "15.4 МБ/с", "850 КБ/с", "1.2 ГБ/с"
    public static func formatSpeed(_ bytesPerSec: Double) -> String {
        guard bytesPerSec > 0 else { return "0 КБ/с" }
        
        let kb = bytesPerSec / 1024.0
        let mb = kb / 1024.0
        let gb = mb / 1024.0
        
        if gb >= 1.0 {
            return String(format: "%.2f ГБ/с", gb)
        } else if mb >= 1.0 {
            return String(format: "%.1f МБ/с", mb)
        } else if kb >= 1.0 {
            return String(format: "%.0f КБ/с", kb)
        } else {
            return String(format: "%.0f Б/с", bytesPerSec)
        }
    }
    
    /// Форматирование ETA: "~ 45 сек", "1 мин 20 сек", "2 ч 15 мин", "--"
    public static func formatETA(_ eta: TimeInterval?) -> String {
        guard let eta = eta, eta > 0, eta.isFinite else {
            return "--"
        }
        
        let totalSeconds = Int(eta)
        if totalSeconds < 60 {
            return "~ \(totalSeconds) сек"
        } else if totalSeconds < 3600 {
            let minutes = totalSeconds / 60
            let seconds = totalSeconds % 60
            return "\(minutes) мин \(seconds) сек"
        } else {
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            return "\(hours) ч \(minutes) мин"
        }
    }
}
