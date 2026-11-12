import Foundation

/// Пауза повторов фонового автоподключения по ключам маршрутов.
///
/// Ключи: `lan-scan` (поиск доверенного телефона в Wi-Fi), `lan:<host>` (найденный адрес, исключаемый из поиска),
/// `usb:<serial>` (проба USB-серийника). Тип чистый: время передаётся явно, побочных эффектов нет.
/// События маршрутов (появление сервиса, смена сети, пробуждение, новый серийник) снимают паузу через `resetTiming`.
public struct AutoConnectBackoffTable: Sendable {
    /// Потолок паузы между повторами фоновой попытки, секунды
    public static let maxPause: TimeInterval = 60
    /// Множитель экспоненты: после первой неудачи пауза 5 с, далее удвоение до `maxPause`
    public static let basePause: TimeInterval = 2.5
    /// Событие маршрута снимает паузу группы не чаще, чем раз в этот интервал, секунды
    public static let resetCooldown: TimeInterval = 10

    public static let lanScanKey = "lan-scan"
    public static let lanHostKeyPrefix = "lan:"
    public static let usbKeyPrefix = "usb:"
    /// Группа событий Wi-Fi маршрута (общий поиск и адреса)
    public static let lanGroup = "lan"

    public static func lanKey(host: String) -> String { lanHostKeyPrefix + host }
    public static func usbKey(serial: String) -> String { usbKeyPrefix + serial }

    /// Ключи, которые снимает событие маршрута Wi-Fi: общий поиск и адреса.
    public static func isLanRouteKey(_ key: String) -> Bool {
        key == lanScanKey || key.hasPrefix(lanHostKeyPrefix)
    }

    public struct Entry: Equatable, Sendable {
        public var failures: Int = 0
        public var nextAttemptAt: Date = .distantPast
        /// После ошибки ключа или авторизации: не повторять до ручного действия. Событие маршрута не снимает.
        public var suppressed: Bool = false
    }

    public private(set) var entries: [String: Entry] = [:]
    /// Время последнего применённого сброса по группе: ограничивает частоту событий
    private var lastResetAt: [String: Date] = [:]

    public init() {}

    /// Пауза после n-й неудачи подряд: 5, 10, 20, 40, 60, 60 … секунд
    public static func pause(afterFailures failures: Int) -> TimeInterval {
        min(basePause * pow(2.0, Double(min(failures, 8))), maxPause)
    }

    public func entry(for key: String) -> Entry? {
        entries[key]
    }

    public func isSuppressed(_ key: String) -> Bool {
        entries[key]?.suppressed == true
    }

    public func allowed(_ key: String, now: Date = Date()) -> Bool {
        guard let entry = entries[key] else { return true }
        return !entry.suppressed && now >= entry.nextAttemptAt
    }

    public mutating func recordFailure(_ key: String, now: Date = Date()) {
        var entry = entries[key] ?? Entry()
        entry.failures += 1
        entry.nextAttemptAt = now.addingTimeInterval(Self.pause(afterFailures: entry.failures))
        entries[key] = entry
        SSHTransportLog.event(key: "autoconnect-pause \(key)", signature: "\(Int(Self.pause(afterFailures: entry.failures)))",
                              "AUTOCONNECT пауза ключ=\(key) неудач=\(entry.failures) пауза=\(Int(Self.pause(afterFailures: entry.failures)))с")
    }

    public mutating func suppress(_ key: String) {
        var entry = entries[key] ?? Entry()
        entry.suppressed = true
        entries[key] = entry
        SSHTransportLog.event(key: "autoconnect-pause \(key)", signature: "suppressed",
                              "AUTOCONNECT пропуск ключ=\(key): ошибка доверия, до ручного подключения")
    }

    /// Успешное подключение по ключу: запись полностью убирается.
    public mutating func clear(_ key: String) {
        entries[key] = nil
    }

    /// Явное успешное подключение: убирает все паузы и подавления. `lastResetAt` не трогается.
    public mutating func clearAll() {
        entries.removeAll()
    }

    /// Событие маршрута: снимает срок паузы у подходящих ключей (`nextAttemptAt`), счётчик неудач сохраняется,
    /// поэтому следующая неудача даёт следующую ступень паузы, а не начальную.
    /// Подавление (`suppressed`) не трогается и паузой не считается.
    /// Возвращает true, если была снята действующая пауза.
    @discardableResult
    public mutating func resetTiming(where matches: (String) -> Bool) -> Bool {
        var lifted = false
        for key in Array(entries.keys) where matches(key) {
            guard var entry = entries[key], !entry.suppressed else { continue }
            if entry.nextAttemptAt != .distantPast { lifted = true }
            entry.nextAttemptAt = .distantPast
            entries[key] = entry
        }
        return lifted
    }

    /// Событие маршрута для группы: снимает паузу подходящих ключей не чаще раза в `resetCooldown` секунд.
    /// Событие внутри интервала игнорируется (пауза идёт своим чередом). Интервал запускается только
    /// сбросом, который реально снял паузу: событие без паузы не блокирует следующее.
    /// `force: true` (пробуждение) применяется всегда и интервал не запускает.
    /// Возвращает true, если пауза снята.
    @discardableResult
    public mutating func resetTiming(group: String, now: Date = Date(), force: Bool = false, where matches: (String) -> Bool) -> Bool {
        if !force, let last = lastResetAt[group], now.timeIntervalSince(last) < Self.resetCooldown {
            return false
        }
        let lifted = resetTiming(where: matches)
        if lifted && !force {
            lastResetAt[group] = now
        }
        return lifted
    }
}
