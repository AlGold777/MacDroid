import Foundation

enum SSHTransportLog {
    private static let lock = NSLock()
    // T7: один форматтер на все записи (создание ISO8601DateFormatter на каждую строку дорого).
    private static let timestampFormatter = ISO8601DateFormatter()
    private static let maxSize: UInt64 = 2 * 1024 * 1024
    private static let retainedSize = 1024 * 1024
    // Файл открыт на всё время работы: раньше каждая строка стоила mkdir, chmod, stat, open и close
    private static var handle: FileHandle?
    private static var currentSize: UInt64 = 0

    /// Подробные строки по каждому файлу и запросу передачи пишутся только при отладке:
    /// `defaults write com.macandroid.MacDroidCommander MacDroidVerboseTransportLog -bool YES`
    /// или переменная окружения MACDROID_VERBOSE_LOG=1.
    static let isVerbose: Bool = ProcessInfo.processInfo.environment["MACDROID_VERBOSE_LOG"] == "1"
        || UserDefaults.standard.bool(forKey: "MacDroidVerboseTransportLog")

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacDroidCommander/transport.log")
    }

    /// Строка отладочного уровня: при выключенной отладке сообщение даже не формируется
    static func verbose(_ message: @autoclosure () -> String) {
        guard isVerbose else { return }
        write(message())
    }

    private static let throttleLock = NSLock()
    private static var throttled: [String: (signature: String, at: Date, skipped: Int)] = [:]

    /// Событие диагностики связи: одна строка на событие, одинаковый результат по одному ключу —
    /// не чаще раза в `interval` секунд. Смена результата пишется сразу; пропущенные повторы считаются.
    static func event(key: String, signature: String, interval: TimeInterval = 60, _ message: @autoclosure () -> String) {
        let now = Date()
        throttleLock.lock()
        var repeats = 0
        if let last = throttled[key], last.signature == signature, now.timeIntervalSince(last.at) < interval {
            throttled[key] = (signature, last.at, last.skipped + 1)
            throttleLock.unlock()
            return
        } else if let last = throttled[key], last.signature == signature {
            repeats = last.skipped
        }
        if throttled.count > 2000 { throttled.removeAll() }
        throttled[key] = (signature, now, 0)
        throttleLock.unlock()
        write(repeats > 0 ? "\(message()) повторов=\(repeats)" : message())
    }

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }

        do {
            let oneLineMessage = message.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            let line = "\(timestampFormatter.string(from: Date())) \(oneLineMessage)\n"
            let data = Data(line.utf8)
            var output = try openHandleIfNeeded()
            if currentSize + UInt64(data.count) > maxSize {
                try rotate(handle: output)
                output = try openHandleIfNeeded()
            }
            try output.write(contentsOf: data)
            currentSize += UInt64(data.count)
        } catch {
            NSLog("MacDroid transport log write failed: %@", error.localizedDescription)
            // Следующая запись откроет файл заново (например, если его удалили)
            try? handle?.close()
            handle = nil
        }
    }

    private static func openHandleIfNeeded() throws -> FileHandle {
        if let handle { return handle }
        let url = fileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let opened = try FileHandle(forWritingTo: url)
        currentSize = try opened.seekToEnd()
        handle = opened
        return opened
    }

    /// Ротация: оставляем последний 1 МБ
    private static func rotate(handle current: FileHandle) throws {
        try? current.close()
        handle = nil
        let url = fileURL
        let existing = (try? Data(contentsOf: url)) ?? Data()
        let retained = Data(existing.suffix(retainedSize))
        try retained.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
