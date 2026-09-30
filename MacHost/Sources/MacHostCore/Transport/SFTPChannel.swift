import Foundation

/// Отдельный изолированный SFTP канал поверх процесса OpenSSH с собственным Read Loop и сериализованным Writer
public final class SFTPChannel: @unchecked Sendable {
    public let channelId: String
    public let isInteractive: Bool
    
    private let process: Process
    private let inHandle: FileHandle
    private let outHandle: FileHandle
    private let diagnosticMessage: @Sendable () -> String
    private let waitForDiagnostics: @Sendable (TimeInterval) -> String
    
    private let writerQueue: DispatchQueue
    private let readerQueue: DispatchQueue
    
    private let lock = NSLock()
    private var isClosed = false
    private var nextReqId: UInt32 = 1
    private var consecutiveRequestTimeouts = 0
    private var lastResponseUptime = ProcessInfo.processInfo.systemUptime
    
    private enum PendingEntry {
        case active(continuation: CheckedContinuation<(type: SFTPMessageType, payload: Data), Error>)
        case cancelled
    }
    
    private var pendingRequests: [UInt32: PendingEntry] = [:]
    private var requestTimeoutWorkItems: [UInt32: DispatchWorkItem] = [:]
    private var initContinuation: CheckedContinuation<(type: SFTPMessageType, payload: Data), Error>?
    private var initTimeoutWorkItem: DispatchWorkItem?
    
    public static let maxPacketLength: Int = 4 * 1024 * 1024 // 4 MiB жесткий потолок
    
    public init(
        channelId: String,
        isInteractive: Bool,
        process: Process,
        inHandle: FileHandle,
        outHandle: FileHandle,
        diagnosticMessage: @escaping @Sendable () -> String = { "" },
        waitForDiagnostics: @escaping @Sendable (TimeInterval) -> String = { _ in "" }
    ) {
        self.diagnosticMessage = diagnosticMessage
        self.waitForDiagnostics = waitForDiagnostics
        self.channelId = channelId
        self.isInteractive = isInteractive
        self.process = process
        self.inHandle = inHandle
        self.outHandle = outHandle
        self.writerQueue = DispatchQueue(label: "com.macdroid.sftp.writer.\(channelId)", qos: isInteractive ? .userInitiated : .default)
        self.readerQueue = DispatchQueue(label: "com.macdroid.sftp.reader.\(channelId)", qos: isInteractive ? .userInitiated : .default)
        
        startReadLoop()
    }
    
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isClosed && process.isRunning
    }

    public var idleDuration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastResponseUptime
    }

    public var sshDiagnosticMessage: String { diagnosticMessage() }
    
    /// Выделение уникального requestId с защитой от wraparound и переиспользования in-flight ID
    public func allocateRequestId() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        while true {
            let req = nextReqId
            nextReqId = (nextReqId == UInt32.max) ? 1 : nextReqId + 1
            if pendingRequests[req] == nil {
                return req
            }
        }
    }
    
    /// Инициализация SFTP подсистемы (ожидание SSH_FXP_VERSION до запуска обработки обычных запросов)
    public func sendInitPacket(packet: Data, timeoutSeconds: TimeInterval = 10) async throws -> (type: SFTPMessageType, payload: Data) {
        try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !isClosed && !Task.isCancelled else {
                lock.unlock()
                continuation.resume(throwing: NSError(domain: "SFTPChannel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Channel is closed"]))
                return
            }
            self.initContinuation = continuation
            let timeout = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock()
                guard let pending = self.initContinuation else {
                    self.lock.unlock()
                    return
                }
                self.initContinuation = nil
                self.lock.unlock()
                pending.resume(throwing: NSError(
                    domain: "SFTPChannel",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "Таймаут инициализации SFTP: SSH не ответил за \(Int(timeoutSeconds)) сек."]
                ))
                self.close()
            }
            self.initTimeoutWorkItem?.cancel()
            self.initTimeoutWorkItem = timeout
            lock.unlock()

            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + timeoutSeconds,
                execute: timeout
            )
            
            writerQueue.async { [weak self] in
                guard let self = self else { return }
                do {
                    try self.inHandle.write(contentsOf: packet)
                } catch {
                    self.lock.lock()
                    let c = self.initContinuation
                    self.initContinuation = nil
                    self.initTimeoutWorkItem?.cancel()
                    self.initTimeoutWorkItem = nil
                    self.lock.unlock()
                    c?.resume(throwing: error)
                }
            }
        }
        } onCancel: {
            self.close()
        }
    }
    
    /// Отправка типизированного запроса с предварительной регистрацией до записи в pipe
    public func sendRequest(
        packet: Data,
        requestId: UInt32,
        timeoutSeconds: TimeInterval = 30
    ) async throws -> (type: SFTPMessageType, payload: Data) {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !Task.isCancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard !isClosed else {
                    lock.unlock()
                    continuation.resume(throwing: NSError(domain: "SFTPChannel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Channel is closed"]))
                    return
                }
                
                // Регистрируем ДО отправки
                pendingRequests[requestId] = .active(continuation: continuation)
                
                func scheduleTimeoutWorkItem() {
                    let timeout = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.lock.lock()
                        // Проверяем: жив ли еще запрос
                        guard let entry = self.pendingRequests[requestId], case .active = entry else {
                            self.requestTimeoutWorkItems.removeValue(forKey: requestId)
                            self.lock.unlock()
                            return
                        }
                        
                        // Проверяем время последней активности канала (inactivity/idle timeout)
                        let timeSinceLastActivity = ProcessInfo.processInfo.systemUptime - self.lastResponseUptime
                        if timeSinceLastActivity < timeoutSeconds {
                            // Канал активно передает данные (другие запросы конвейера успешно завершаются).
                            // Продлеваем ожидание на оставшееся время до реального простоя.
                            let remainingIdle = max(1.0, timeoutSeconds - timeSinceLastActivity)
                            self.lock.unlock()
                            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + remainingIdle) {
                                scheduleTimeoutWorkItem()
                            }
                            return
                        }
                        
                        self.pendingRequests[requestId] = .cancelled
                        self.requestTimeoutWorkItems.removeValue(forKey: requestId)
                        self.consecutiveRequestTimeouts += 1
                        let closeThreshold = 2
                        let shouldClose = self.consecutiveRequestTimeouts >= closeThreshold
                        self.lock.unlock()
                        
                        if case .active(let cont) = entry {
                            cont.resume(throwing: NSError(
                                domain: "SFTPChannel",
                                code: 11,
                                userInfo: [NSLocalizedDescriptionKey: "Таймаут ответа SFTP-запроса (\(Int(timeoutSeconds)) сек.)"]
                            ))
                        }
                        if shouldClose { self.close() }
                    }
                    
                    self.lock.lock()
                    self.requestTimeoutWorkItems[requestId] = timeout
                    self.lock.unlock()
                    
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(
                        deadline: .now() + timeoutSeconds,
                        execute: timeout
                    )
                }
                lock.unlock()
                scheduleTimeoutWorkItem()
                
                // Запись в pipe на выделенной очереди
                writerQueue.async { [weak self] in
                    guard let self = self else { return }
                    do {
                        try self.inHandle.write(contentsOf: packet)
                    } catch {
                        self.lock.lock()
                        let entry = self.pendingRequests.removeValue(forKey: requestId)
                        self.requestTimeoutWorkItems.removeValue(forKey: requestId)?.cancel()
                        self.lock.unlock()
                        if case .active(let cont) = entry {
                            cont.resume(throwing: error)
                        }
                    }
                }
            }
        } onCancel: {
            // При отмене задачи помечаем как cancelled, но не удаляем ID,
            // чтобы ответ сервера не врезался в повторно выделенный ID
            self.lock.lock()
            let entry = self.pendingRequests[requestId]
            if case .active = entry {
                self.pendingRequests[requestId] = .cancelled
            }
            self.requestTimeoutWorkItems.removeValue(forKey: requestId)?.cancel()
            self.lock.unlock()
            if case .active(let continuation) = entry {
                continuation.resume(throwing: CancellationError())
            }
        }
    }
    
    /// Асинхронная запись сырого пакета (например, в streaming конвейере) с предварительной регистрацией
    public func writeStreamingPacket(packet: Data, requestId: UInt32, onResponse: @escaping (Result<(type: SFTPMessageType, payload: Data), Error>) -> Void) {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            onResponse(.failure(NSError(domain: "SFTPChannel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Channel is closed"])))
            return
        }
        
        // Для streaming регистрируем замыкание через синтетическую continuation или callback
        // Реализуем через CheckedContinuation адаптер в Task
        lock.unlock()
        
        Task {
            do {
                let res = try await self.sendRequest(packet: packet, requestId: requestId)
                onResponse(.success(res))
            } catch {
                onResponse(.failure(error))
            }
        }
    }
    
    /// Непрерывный Read Loop: единственный владелец чтения stdout
    private func startReadLoop() {
        readerQueue.async { [weak self] in
            guard let self = self else { return }
            self.runReadLoop()
        }
    }
    
    private func runReadLoop() {
        defer { try? outHandle.close() }
        while true {
            do {
                // 1. Читаем длину пакета (4 байта)
                let lenData = try readExact(count: 4)
                let packetLength = Int(lenData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
                
                guard packetLength >= 1, packetLength <= Self.maxPacketLength else {
                    throw NSError(
                        domain: "SFTPChannel",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid SFTP packet length: \(packetLength) (max: \(Self.maxPacketLength))"]
                    )
                }
                
                // 2. Читаем тип сообщения (1 байт)
                let typeData = try readExact(count: 1)
                guard let msgType = SFTPMessageType(rawValue: typeData[0]) else {
                    throw NSError(
                        domain: "SFTPChannel",
                        code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "Unknown SFTP message type: \(typeData[0])"]
                    )
                }
                
                // 3. Читаем payload
                let payloadLen = packetLength - 1
                let payload = payloadLen > 0 ? try readExact(count: payloadLen) : Data()
                
                // 4. Диспетчеризация
                if msgType == .version {
                    lock.lock()
                    let cont = self.initContinuation
                    self.initContinuation = nil
                    self.initTimeoutWorkItem?.cancel()
                    self.initTimeoutWorkItem = nil
                    lock.unlock()
                    cont?.resume(returning: (msgType, payload))
                    continue
                }
                
                guard payload.count >= 4 else {
                    // Пакет без requestId — игнорируем или логируем
                    continue
                }
                
                let reqId = payload.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                
                lock.lock()
                let entry = pendingRequests.removeValue(forKey: reqId)
                requestTimeoutWorkItems.removeValue(forKey: reqId)?.cancel()
                consecutiveRequestTimeouts = 0
                lastResponseUptime = ProcessInfo.processInfo.systemUptime
                lock.unlock()
                
                switch entry {
                case .active(let continuation):
                    continuation.resume(returning: (msgType, payload))
                case .cancelled:
                    // Запрос был отменен клиентом — безопасно поглощаем ответ сервера
                    break
                case .none:
                    // Неизвестный или дублированный ответ — не ломает другие операции
                    break
                }
            } catch {
                // Ошибка I/O или закрытие соединения — разрываем канал и уведомляем всех ожидающих
                self.teardown(error: error)
                break
            }
        }
    }
    
    private func readExact(count: Int) throws -> Data {
        var accumulated = Data()
        accumulated.reserveCapacity(count)
        while accumulated.count < count {
            lock.lock()
            if isClosed {
                lock.unlock()
                throw NSError(domain: "SFTPChannel", code: 3, userInfo: [NSLocalizedDescriptionKey: "SFTP channel closed"])
            }
            lock.unlock()
            
            let needed = count - accumulated.count
            guard let chunk = try outHandle.read(upToCount: needed), !chunk.isEmpty else {
                let deadline = ProcessInfo.processInfo.systemUptime + 1
                _ = waitForDiagnostics(1)
                while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                let details = diagnosticMessage()
                let status = process.isRunning ? "процесс SSH ещё работает" : "код завершения SSH \(process.terminationStatus)"
                let reason = details.isEmpty ? status : "\(status); SSH: \(details)"
                throw NSError(domain: "SFTPChannel", code: 3, userInfo: [NSLocalizedDescriptionKey: "SFTP connection closed prematurely (\(reason))"])
            }
            accumulated.append(chunk)
        }
        return accumulated
    }
    
    public func close() {
        teardown(error: NSError(domain: "SFTPChannel", code: 0, userInfo: [NSLocalizedDescriptionKey: "Channel closed by client"]))
    }
    
    private func teardown(error: Error) {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        
        let initCont = self.initContinuation
        self.initContinuation = nil
        initTimeoutWorkItem?.cancel()
        initTimeoutWorkItem = nil
        
        let pending = self.pendingRequests
        self.pendingRequests.removeAll()
        let timeouts = self.requestTimeoutWorkItems
        self.requestTimeoutWorkItems.removeAll()
        lock.unlock()
        
        initCont?.resume(throwing: error)
        for (_, entry) in pending {
            if case .active(let cont) = entry {
                cont.resume(throwing: error)
            }
        }
        timeouts.values.forEach { $0.cancel() }

        let exitStatus = process.isRunning ? "running" : String(process.terminationStatus)
        let diagnostics = diagnosticMessage()
        SSHTransportLog.write("SFTP channel teardown channel=\(channelId) exit=\(exitStatus) error=\(error.localizedDescription) stderr=\(diagnostics)")
        
        if process.isRunning {
            process.terminate()
        }
        // The child process closes its pipe on exit; only the reader owns stdout.
        writerQueue.async { [inHandle] in try? inHandle.close() }
    }
}
