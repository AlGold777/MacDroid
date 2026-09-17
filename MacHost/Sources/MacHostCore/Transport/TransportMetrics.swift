import Foundation

/// Анонимизированный сбор телеметрии и метрик производительности транспорта (SFTP / TCP / ADB)
public final class TransportMetrics: @unchecked Sendable {
    public static let shared = TransportMetrics()
    
    public struct Snapshot: Sendable, Equatable {
        public let averageRTTMs: Double
        public let totalBytesDownloaded: UInt64
        public let totalBytesUploaded: UInt64
        public let totalResumeSavedBytes: UInt64
        public let reconnectCount: Int
        public let peakInflightPayload: Int
        public let recentReadSpeedBps: Double
        public let recentWriteSpeedBps: Double
    }
    
    private let lock = NSLock()
    private var rttSamples: [Double] = []
    private var totalDownloaded: UInt64 = 0
    private var totalUploaded: UInt64 = 0
    private var resumeSavedBytes: UInt64 = 0
    private var reconnects: Int = 0
    private var peakPayload: Int = 0
    private var recentReadSpeeds: [Double] = []
    private var recentWriteSpeeds: [Double] = []
    
    private let maxSampleCount = 50
    
    public init() {}
    
    /// Фиксация круглого времени обращения SFTP/SSH пакета (RTT)
    public func recordRTT(milliseconds: Double) {
        guard milliseconds >= 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        rttSamples.append(milliseconds)
        if rttSamples.count > maxSampleCount {
            rttSamples.removeFirst()
        }
    }
    
    /// Фиксация скорости чтения блока данных
    public func recordReadSpeed(bytes: UInt64, durationSeconds: Double) {
        guard durationSeconds > 0 else { return }
        let speed = Double(bytes) / durationSeconds
        lock.lock()
        defer { lock.unlock() }
        totalDownloaded += bytes
        recentReadSpeeds.append(speed)
        if recentReadSpeeds.count > maxSampleCount {
            recentReadSpeeds.removeFirst()
        }
    }
    
    /// Фиксация скорости записи блока данных
    public func recordWriteSpeed(bytes: UInt64, durationSeconds: Double) {
        guard durationSeconds > 0 else { return }
        let speed = Double(bytes) / durationSeconds
        lock.lock()
        defer { lock.unlock() }
        totalUploaded += bytes
        recentWriteSpeeds.append(speed)
        if recentWriteSpeeds.count > maxSampleCount {
            recentWriteSpeeds.removeFirst()
        }
    }
    
    /// Учет текущего объема данных в полете (in-flight network payload)
    public func recordInflightPayload(bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        if bytes > peakPayload {
            peakPayload = bytes
        }
    }
    
    /// Учет события переподключения сессии
    public func recordReconnect() {
        lock.lock()
        defer { lock.unlock() }
        reconnects += 1
    }
    
    /// Учет спасенных байт при возобновлении (resume)
    public func recordResumeSavedBytes(_ bytes: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        resumeSavedBytes += bytes
    }
    
    /// Получение моментального снимка метрик
    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        
        let avgRTT: Double
        if rttSamples.isEmpty {
            avgRTT = 0.0
        } else {
            avgRTT = rttSamples.reduce(0.0, +) / Double(rttSamples.count)
        }
        
        let avgReadSpeed: Double
        if recentReadSpeeds.isEmpty {
            avgReadSpeed = 0.0
        } else {
            avgReadSpeed = recentReadSpeeds.reduce(0.0, +) / Double(recentReadSpeeds.count)
        }
        
        let avgWriteSpeed: Double
        if recentWriteSpeeds.isEmpty {
            avgWriteSpeed = 0.0
        } else {
            avgWriteSpeed = recentWriteSpeeds.reduce(0.0, +) / Double(recentWriteSpeeds.count)
        }
        
        return Snapshot(
            averageRTTMs: avgRTT,
            totalBytesDownloaded: totalDownloaded,
            totalBytesUploaded: totalUploaded,
            totalResumeSavedBytes: resumeSavedBytes,
            reconnectCount: reconnects,
            peakInflightPayload: peakPayload,
            recentReadSpeedBps: avgReadSpeed,
            recentWriteSpeedBps: avgWriteSpeed
        )
    }
    
    /// Сброс всех накопленных метрик (для тестов или новой сессии)
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        rttSamples.removeAll()
        totalDownloaded = 0
        totalUploaded = 0
        resumeSavedBytes = 0
        reconnects = 0
        peakPayload = 0
        recentReadSpeeds.removeAll()
        recentWriteSpeeds.removeAll()
    }
}
