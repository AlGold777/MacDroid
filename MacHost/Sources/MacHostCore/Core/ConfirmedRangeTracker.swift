import Foundation

/// Отслеживает непрерывно подтвержденные диапазоны байт и обеспечивает строгий учет прогресса без дыр
public struct ConfirmedRangeTracker: Sendable, Equatable {
    /// Список упорядоченных непересекающихся диапазонов [start, end)
    public private(set) var ranges: [Range<UInt64>] = []
    
    public init() {}
    
    public init(ranges: [Range<UInt64>]) {
        for r in ranges {
            addRange(r)
        }
    }
    
    /// Добавление подтвержденного диапазона с автоматическим слиянием пересечений и смежных областей
    public mutating func addRange(_ range: Range<UInt64>) {
        guard !range.isEmpty else { return }
        
        var newRanges: [Range<UInt64>] = []
        var merged = range
        var inserted = false
        
        for existing in ranges {
            if existing.upperBound < merged.lowerBound {
                // Существующий строго левее
                newRanges.append(existing)
            } else if existing.lowerBound > merged.upperBound {
                // Существующий строго правее
                if !inserted {
                    newRanges.append(merged)
                    inserted = true
                }
                newRanges.append(existing)
            } else {
                // Пересекаются или примыкают (contiguous)
                let newLower = min(existing.lowerBound, merged.lowerBound)
                let newUpper = max(existing.upperBound, merged.upperBound)
                merged = newLower..<newUpper
            }
        }
        
        if !inserted {
            newRanges.append(merged)
        }
        
        self.ranges = newRanges
    }
    
    public mutating func addRange(offset: UInt64, length: UInt64) {
        guard length > 0 else { return }
        addRange(offset..<(offset + length))
    }
    
    /// Непрерывный фронтир от 0 без дыр
    public var contiguousFrontier: UInt64 {
        guard let first = ranges.first, first.lowerBound == 0 else {
            return 0
        }
        return first.upperBound
    }
    
    /// Суммарный объем подтвержденных байт (может содержать дыры)
    public var totalConfirmedBytes: UInt64 {
        ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }
    
    /// Проверка, покрыт ли файл целиком от 0 до expectedSize без дыр
    public func isFullyCovered(expectedSize: UInt64) -> Bool {
        if expectedSize == 0 {
            return true
        }
        guard let first = ranges.first else { return false }
        return ranges.count == 1 && first.lowerBound == 0 && first.upperBound >= expectedSize
    }
    
    /// Возвращает список непокрытых диапазонов (дыр) до expectedSize
    public func holes(upTo expectedSize: UInt64) -> [Range<UInt64>] {
        if expectedSize == 0 { return [] }
        var result: [Range<UInt64>] = []
        var cursor: UInt64 = 0
        
        for r in ranges {
            if r.lowerBound > cursor {
                let holeEnd = min(r.lowerBound, expectedSize)
                if cursor < holeEnd {
                    result.append(cursor..<holeEnd)
                }
            }
            cursor = max(cursor, r.upperBound)
            if cursor >= expectedSize {
                break
            }
        }
        
        if cursor < expectedSize {
            result.append(cursor..<expectedSize)
        }
        return result
    }
    
    /// Сериализация для SQLite журнала: "0-1048576,2097152-3145728"
    public func serialize() -> String {
        return ranges.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ",")
    }
    
    /// Десериализация из строки SQLite журнала
    public static func deserialize(_ string: String) -> ConfirmedRangeTracker {
        var tracker = ConfirmedRangeTracker()
        let parts = string.split(separator: ",")
        for part in parts {
            let bounds = part.split(separator: "-")
            if bounds.count == 2,
               let lower = UInt64(bounds[0].trimmingCharacters(in: .whitespaces)),
               let upper = UInt64(bounds[1].trimmingCharacters(in: .whitespaces)),
               lower < upper {
                tracker.addRange(lower..<upper)
            }
        }
        return tracker
    }
}
