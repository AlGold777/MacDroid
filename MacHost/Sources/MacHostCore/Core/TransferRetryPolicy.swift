import Foundation

/// Политика повторов передачи (скачивание и загрузка) при сетевом сбое.
/// Чистая логика без ввода-вывода: классификация ошибок и расписание пауз проверяются тестами.
public enum TransferRetryPolicy {
    /// Паузы перед повторами, секунды. Всего 7 повторов после первой попытки.
    public static let pauseSeconds: [UInt64] = [1, 2, 4, 8, 15, 15, 15]

    /// Окно переживания обрыва: от первого сбоя без продвижения передачи.
    public static let windowSeconds: TimeInterval = 60

    public enum Decision: Equatable, Sendable {
        /// Отмена пользователем (задача отменена): повтора нет, ошибка отмены пробрасывается.
        case cancelled
        /// Сетевой или транспортный сбой: повтор с продолжением с подтверждённой границы.
        case retryable
        /// Неустранимая ошибка (нет файла, нет прав, нет места, проверка целостности): повтора нет.
        case fatal
    }

    /// Классификация ошибки попытки передачи.
    /// Отмена пользователем — только `taskCancelled`. `CancellationError` при не отменённой задаче —
    /// это разрыв (SessionBudget.reset при disconnect), его повторяем.
    public static func classify(_ error: Error, taskCancelled: Bool) -> Decision {
        if taskCancelled { return .cancelled }
        if error is CancellationError { return .retryable }
        if error is JobOrchestratorError { return .fatal }
        if error is ClientKeyError { return .fatal }
        if let hostKeyError = error as? HostKeyStoreError {
            // Недоступный ключ узла — временный сбой сети; несовпадение и не сопряжение — постоянные.
            if case .fingerprintUnavailable = hostKeyError { return .retryable }
            return .fatal
        }

        let ns = error as NSError
        switch ns.domain {
        case NSPOSIXErrorDomain:
            // ENOSPC/EDQUOT/EROFS — нет места или только чтение; EPERM/EACCES — нет прав; ENOENT — пропала локальная папка/файл
            return fatalPOSIXCodes.contains(ns.code) ? .fatal : .retryable
        case NSCocoaErrorDomain:
            return fatalCocoaCodes.contains(ns.code) ? .fatal : .retryable
        case "JobOrchestrator":
            // Локальный источник не найден, сбой переименования и прочие ошибки оркестратора
            return .fatal
        case "TransportMultiplexer":
            // Статус, который сервер вернул на запрос (нет файла, нет прав, нет места и т.п.): повтор не поможет.
            // Исключение — транспортные статусы noConnection(6)/connectionLost(7): это обрыв, а не ответ.
            if ns.userInfo[TransportMultiplexer.serverStatusKey] != nil {
                switch ns.code {
                case Int(SFTPStatusCode.noConnection.rawValue), Int(SFTPStatusCode.connectionLost.rawValue):
                    return .retryable
                default:
                    return .fatal
                }
            }
            // 404 = локальный файл загрузки не найден; локальный лимит дескрипторов и прочее — повторяемые
            return ns.code == 404 ? .fatal : .retryable
        case "ConnectionController":
            // 403 — решение о доверии к ключу узла: повтор без действия пользователя не поможет
            return ns.code == 403 ? .fatal : .retryable
        case "SessionCoordinator":
            // 1005 — некорректный адрес/имя пользователя SSH: конфигурация
            return ns.code == 1005 ? .fatal : .retryable
        default:
            // Всё остальное — транспорт (SFTPChannel, SSH-процесс, таймаут, узел недоступен): повторяем в окне
            return .retryable
        }
    }

    private static let fatalPOSIXCodes: Set<Int> = [
        Int(EPERM), Int(EACCES), Int(ENOENT), Int(ENOSPC), Int(EDQUOT), Int(EROFS)
    ]

    private static let fatalCocoaCodes: Set<Int> = [
        4,    // NSFileNoSuchFileError
        257,  // NSFileReadNoPermissionError
        260,  // NSFileReadNoSuchFileError
        513,  // NSFileWriteNoPermissionError
        640,  // NSFileWriteOutOfSpaceError
        642   // NSFileWriteVolumeReadOnlyError
    ]
}

/// Окно повторов одной передачи. Каждый сбой запрашивает паузу; nil означает, что повторов больше нет.
public struct TransferRetryBudget: Sendable {
    public private(set) var retriesUsed = 0
    private var windowStart: Date?

    public init() {}

    /// Пауза перед следующей попыткой в наносекундах или nil, если повтор недоступен.
    /// - Parameters:
    ///   - now: момент сбоя.
    ///   - progressed: предыдущая попытка подтвердила новые байты. Тогда окно начинается заново:
    ///     обрыв после продвижения — это новый обрыв, а не продолжение старого.
    public mutating func nextPauseNanoseconds(now: Date, progressed: Bool) -> UInt64? {
        if progressed {
            retriesUsed = 0
            windowStart = nil
        }
        if windowStart == nil { windowStart = now }
        guard retriesUsed < TransferRetryPolicy.pauseSeconds.count, let start = windowStart else { return nil }
        let pause = TransferRetryPolicy.pauseSeconds[retriesUsed]
        let elapsed = now.timeIntervalSince(start)
        guard elapsed + Double(pause) <= TransferRetryPolicy.windowSeconds else { return nil }
        retriesUsed += 1
        return pause * 1_000_000_000
    }
}
