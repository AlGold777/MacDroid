import Foundation

/// Учёт присутствия USB-серийников ADB между фоновыми опросами.
///
/// Серийник «новый», если его никогда не видели или он отсутствовал в ответах adb дольше `absenceThreshold`.
/// Это гасит флап: повторное появление, пока устройство пропадает ненадолго, новым не считается.
/// Ответ adb без устройств (`[]`) — отсутствие всех ранее виденных серийников.
/// Отсутствие ответа adb (`nil`: сбой, таймаут, нет adb) учёт не меняет.
public struct AdbSerialPresenceTracker: Sendable {
    /// Отсутствие дольше этого срока делает серийник новым при следующем появлении, секунды
    public static let absenceThreshold: TimeInterval = 60

    /// Все серийники, которые когда-либо встречались в непустых опросах
    private var known: Set<String> = []
    /// Момент, с которого серийник отсутствует в непустых опросах (нет записи — присутствует или не наблюдался)
    private var absentSince: [String: Date] = [:]

    public init() {}

    /// Обновляет учёт по опросу adb и возвращает серийники, которые считаются новыми в этом опросе.
    /// `nil` — ответа нет, учёт не меняется. `[]` — adb ответил, устройств нет.
    @discardableResult
    public mutating func update(listing: [String]?, now: Date = Date()) -> Set<String> {
        guard let listing else { return [] }
        let present = Set(listing)
        var newSerials = Set<String>()
        for serial in present {
            if !known.contains(serial) {
                newSerials.insert(serial)
            } else if let since = absentSince[serial], now.timeIntervalSince(since) > Self.absenceThreshold {
                newSerials.insert(serial)
            }
            known.insert(serial)
            absentSince[serial] = nil
        }
        for serial in known where !present.contains(serial) {
            if absentSince[serial] == nil {
                absentSince[serial] = now
            }
        }
        return newSerials
    }
}
