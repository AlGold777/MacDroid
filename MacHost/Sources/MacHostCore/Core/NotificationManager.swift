import Foundation
import UserNotifications

/// Менеджер macOS системных уведомлений для MacDroid Commander.
/// Отправляет уведомления после завершения фоновых операций (длительностью > 30 секунд).
public final class NotificationManager: @unchecked Sendable {
    public static let shared = NotificationManager()
    
    private var isAuthorized = false
    
    private init() {
        requestAuthorization()
    }
    
    /// Запрос разрешения на отправку уведомлений
    private func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            self.isAuthorized = granted
            if let error = error {
                print("Ошибка запроса разрешений уведомлений: \(error.localizedDescription)")
            }
        }
    }
    
    private var currentSleepActivity: NSObjectProtocol?
    private let sleepLock = NSLock()
    
    /// Блокировка ухода Mac в спящий режим во время активной передачи данных
    public func beginSleepPrevention(reason: String = "MacDroid Commander: Передача файлов") {
        sleepLock.lock()
        defer { sleepLock.unlock() }
        if currentSleepActivity == nil {
            currentSleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: reason
            )
        }
    }
    
    /// Снятие блокировки ухода в спящий режим
    public func endSleepPrevention() {
        sleepLock.lock()
        defer { sleepLock.unlock() }
        if let activity = currentSleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            currentSleepActivity = nil
        }
    }
    
    /// Отправить уведомление о завершении операции.
    /// Вызывается только если операция длилась > minDuration секунд.
    public func notifyOperationCompleted(
        succeeded: Int,
        failed: Int,
        totalBytes: UInt64,
        duration: TimeInterval,
        minDuration: TimeInterval = 30.0
    ) {
        guard Bundle.main.bundleIdentifier != nil, isAuthorized, duration >= minDuration else { return }
        
        let content = UNMutableNotificationContent()
        content.title = failed == 0 ? "MacDroid Commander" : "MacDroid Commander: Ошибки передачи"
        
        let sizeString = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
        let durationMin = Int(duration) / 60
        let durationSec = Int(duration) % 60
        let timeStr = durationMin > 0 ? "\(durationMin) мин \(durationSec) с" : "\(durationSec) с"
        
        if failed == 0 {
            content.body = "Скопировано \(succeeded) файлов (\(sizeString)) за \(timeStr)"
        } else {
            content.body = "Успешно: \(succeeded), ошибок: \(failed) (\(sizeString)) за \(timeStr)"
        }
        
        content.sound = .default
        content.categoryIdentifier = "TRANSFER_COMPLETE"
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Немедленная доставка
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Ошибка отправки уведомления: \(error.localizedDescription)")
            }
        }
    }
    
    /// Отправить уведомление об ошибке подключения
    public func notifyConnectionLost(deviceName: String = "Android") {
        guard isAuthorized else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Подключение потеряно"
        content.body = "Устройство \(deviceName) недоступно"
        content.sound = .default
        content.categoryIdentifier = "CONNECTION_LOST"
        
        let request = UNNotificationRequest(
            identifier: "connection_lost_\(deviceName)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
