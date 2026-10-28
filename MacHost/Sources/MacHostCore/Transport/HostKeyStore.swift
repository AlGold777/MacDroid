import Foundation
import Darwin

public enum HostKeyStatus: Sendable {
    case trusted
    case pinnedNew
    case mismatchWarning(expected: String, actual: String)
    /// Ключ не закреплён за устройством: подключение запрещено до явного сопряжения.
    case notPinned
}

public enum HostKeyStoreError: Error, LocalizedError, Sendable {
    case hostKeyMismatch(expected: String, actual: String)
    case notPaired
    case fingerprintUnavailable(host: String, port: UInt16)
    case fingerprintNotConfirmed(expected: String, actual: String)
    case invalidDeviceId
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .hostKeyMismatch(let expected, let actual):
            return "Ключ телефона не совпадает с сохранённым (ожидался \(expected), получен \(actual)). Возможна подмена узла. Подключение отклонено."
        case .notPaired:
            return "Устройство не сопряжено: отпечаток ключа не подтверждён. Требуется сопряжение."
        case .fingerprintUnavailable(let host, let port):
            return "Не удалось получить отпечаток ключа узла \(host):\(port)."
        case .fingerprintNotConfirmed(let expected, let actual):
            return "Отпечаток ключа изменился после показа (показан \(expected), сейчас \(actual)). Повторите сопряжение."
        case .invalidDeviceId:
            return "Не задан идентификатор устройства."
        case .persistenceFailed(let reason):
            return "Не удалось сохранить доверенные ключи: \(reason)"
        }
    }
}

/// Состояние хранилища после загрузки. При повреждении файл переносится в резервную копию,
/// хранилище становится пустым и требуется повторное сопряжение (fail-closed).
public enum HostKeyStoreIntegrity: Sendable, Equatable {
    case healthy
    case corruptedQuarantined(backupPath: String)
}

/// Закреплённый отпечаток ключа хоста, привязанный к стабильному идентификатору устройства.
public struct HostKeyPin: Codable, Sendable, Equatable {
    public let deviceId: String
    public var host: String
    public var port: UInt16
    public var fingerprint: String

    public init(deviceId: String, host: String, port: UInt16, fingerprint: String) {
        self.deviceId = deviceId
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
    }
}

private struct HostKeyStoreFileV2: Codable {
    let version: Int
    let pins: [HostKeyPin]
}

public final class HostKeyStore: @unchecked Sendable {
    public static let shared = HostKeyStore()
    private let lock = NSLock()
    /// deviceId -> закреплённый отпечаток. Для устаревших вызовов без deviceId ключ имеет вид "host:port".
    private var pins: [String: HostKeyPin] = [:]
    private var integrityState: HostKeyStoreIntegrity = .healthy
    private let storageURL: URL

    public static func safeHostKeyAlias(_ value: String) -> String {
        let safe = String(value.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }).lowercased()
        return safe.isEmpty ? "device" : safe
    }

    /// Quotes a value embedded in an OpenSSH `-o Name=value` argument.
    /// OpenSSH tokenizes list-valued options such as UserKnownHostsFile on spaces.
    public static func openSSHConfigValue(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("MacDroidCommander")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageURL = dir.appendingPathComponent("pinned_hosts.json")
        loadFromDisk()
    }

    /// Распознавание устаревших фиктивных отпечатков из ранних тестовых сборок
    public static func isLegacyMockFingerprint(_ fp: String) -> Bool {
        return fp.contains("Xiaomi14Ultra_DaemonFingerprint")
    }

    /// Состояние хранилища (для UI: при `corruptedQuarantined` требуется повторное сопряжение).
    public var integrity: HostKeyStoreIntegrity {
        lock.lock()
        defer { lock.unlock() }
        return integrityState
    }

    // MARK: - Чтение закрепления

    /// Закреплённый отпечаток устройства (nil, если не сопряжено или это устаревший мок).
    public func pinnedFingerprint(deviceId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return Self.validFingerprint(pins[deviceId]?.fingerprint)
    }

    /// Идентификатор устройства, у которого закреплён именно этот отпечаток.
    public func pinnedDeviceId(matchingFingerprint fp: String) -> String? {
        guard !fp.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return pins.values.first(where: { $0.fingerprint == fp && Self.validFingerprint($0.fingerprint) != nil })?.deviceId
    }

    /// Определяет ключ закрепления для подключения. Адрес сам по себе доверия не даёт:
    /// порядок — явный deviceId (USB serial / NSD instance) с собственным закреплением, затем закреплённый ключ
    /// с тем же отпечатком (тот же телефон по другому маршруту, например сопряжённый по Wi-Fi и подключённый кабелем),
    /// затем явный deviceId без закрепления, затем устройство реестра с этим адресом.
    /// Окончательное решение принимает `verifyPinned`.
    public func resolvePinKey(deviceId: String?, host: String, observedFingerprint: String) -> String? {
        let ownPinExists = deviceId.map { !$0.isEmpty && pinnedFingerprint(deviceId: $0) != nil } ?? false
        return Self.resolvePinKey(
            deviceId: deviceId,
            deviceIdHasOwnPin: ownPinExists,
            pinnedIdForFingerprint: pinnedDeviceId(matchingFingerprint: observedFingerprint),
            registryIdForHost: { DeviceRegistry.shared.device(matchingHost: host)?.id }
        )
    }

    /// Чистая политика выбора ключа закрепления (вынесена для проверки без хранилища).
    public static func resolvePinKey(
        deviceId: String?,
        deviceIdHasOwnPin: Bool,
        pinnedIdForFingerprint: String?,
        registryIdForHost: () -> String?
    ) -> String? {
        if let id = deviceId, !id.isEmpty, deviceIdHasOwnPin { return id }
        if let id = pinnedIdForFingerprint { return id }
        if let id = deviceId, !id.isEmpty { return id }
        return registryIdForHost()
    }

    /// Сверка наблюдаемого отпечатка с закреплённым. Ничего не записывает:
    /// неизвестный ключ никогда не закрепляется автоматически.
    public func verifyPinned(deviceId: String, fingerprint: String) -> HostKeyStatus {
        lock.lock()
        defer { lock.unlock() }
        guard !deviceId.isEmpty, let expected = Self.validFingerprint(pins[deviceId]?.fingerprint) else {
            return .notPinned
        }
        return expected == fingerprint ? .trusted : .mismatchWarning(expected: expected, actual: fingerprint)
    }

    // MARK: - Получение отпечатка и сопряжение (без доверия по умолчанию)

    /// Получает ключ узла через ssh-keyscan + ssh-keygen -lf (формат SHA256:base64 без padding).
    /// Ничего не закрепляет; результат предназначен для показа пользователю.
    public func fetchHostKeyObservation(host: String, port: UInt16) async throws -> SSHHostKeyObservation {
        let observation = await Task.detached(priority: .userInitiated) {
            PhoneConnectionManager.shared.fetchHostKeyObservation(host: host, port: port)
        }.value
        guard let observation, !observation.fingerprint.isEmpty else {
            throw HostKeyStoreError.fingerprintUnavailable(host: host, port: port)
        }
        return observation
    }

    /// Отпечаток ключа узла для показа пользователю. Без пина.
    public func fetchHostKeyFingerprint(host: String, port: UInt16) async throws -> String {
        try await fetchHostKeyObservation(host: host, port: port).fingerprint
    }

    /// Закрепляет ключ за устройством только если отпечаток, полученный сейчас, равен подтверждённому пользователем.
    /// Если за устройством уже закреплён другой ключ — отказ (нужен сброс через prepare/commitHostKeyReset).
    @discardableResult
    public func pinHostKey(deviceId: String, host: String, port: UInt16, expectedFingerprint: String) async throws -> String {
        let id = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !expectedFingerprint.isEmpty else { throw HostKeyStoreError.invalidDeviceId }
        let observation = try await fetchHostKeyObservation(host: host, port: port)
        guard observation.fingerprint == expectedFingerprint else {
            throw HostKeyStoreError.fingerprintNotConfirmed(expected: expectedFingerprint, actual: observation.fingerprint)
        }
        try updatePins { working in
            if let existing = Self.validFingerprint(working[id]?.fingerprint), existing != observation.fingerprint {
                throw HostKeyStoreError.hostKeyMismatch(expected: existing, actual: observation.fingerprint)
            }
            working[id] = HostKeyPin(deviceId: id, host: host, port: port, fingerprint: observation.fingerprint)
        }
        do {
            try installOpenSSHHostKey(observation, host: host, port: port, deviceId: id, hostKeyAlias: Self.safeHostKeyAlias(id))
        } catch {
            try? updatePins { working in working.removeValue(forKey: id) }
            throw error
        }
        return observation.fingerprint
    }

    /// Шаг 1 сброса ключа: возвращает закреплённый и текущий отпечатки для показа. Состояние не меняет.
    public func prepareHostKeyReset(deviceId: String, host: String, port: UInt16) async throws -> (old: String, new: String) {
        guard let old = pinnedFingerprint(deviceId: deviceId) else { throw HostKeyStoreError.notPaired }
        let observation = try await fetchHostKeyObservation(host: host, port: port)
        return (old, observation.fingerprint)
    }

    /// Шаг 2 сброса ключа: применяет смену одной транзакцией, только если закреплённый и текущий
    /// отпечатки совпадают с тем, что подтвердил пользователь.
    @discardableResult
    public func commitHostKeyReset(
        deviceId: String,
        host: String,
        port: UInt16,
        expectedOldFingerprint: String,
        expectedNewFingerprint: String
    ) async throws -> String {
        let id = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw HostKeyStoreError.invalidDeviceId }
        let observation = try await fetchHostKeyObservation(host: host, port: port)
        guard observation.fingerprint == expectedNewFingerprint else {
            throw HostKeyStoreError.fingerprintNotConfirmed(expected: expectedNewFingerprint, actual: observation.fingerprint)
        }
        var previous: HostKeyPin?
        try updatePins { working in
            let current = Self.validFingerprint(working[id]?.fingerprint)
            guard current == expectedOldFingerprint else {
                throw HostKeyStoreError.hostKeyMismatch(expected: expectedOldFingerprint, actual: current ?? "")
            }
            previous = working[id]
            working[id] = HostKeyPin(deviceId: id, host: host, port: port, fingerprint: observation.fingerprint)
        }
        do {
            try installOpenSSHHostKey(observation, host: host, port: port, deviceId: id, hostKeyAlias: Self.safeHostKeyAlias(id))
        } catch {
            try? updatePins { working in working[id] = previous }
            throw error
        }
        return observation.fingerprint
    }

    // MARK: - Устаревший API (совместимость; не используется в пути подключения)

    /// Устаревший TOFU-закреп по host:port (или deviceId). Не вызывать из пути подключения.
    public func verifyOrPin(host: String, port: Int, deviceId: String? = nil, fingerprint: String) -> HostKeyStatus {
        lock.lock()
        defer { lock.unlock() }

        let key = legacyPinKey(host: host, port: port, deviceId: deviceId)
        if let existing = Self.validFingerprint(pins[key]?.fingerprint) {
            return existing == fingerprint ? .trusted : .mismatchWarning(expected: existing, actual: fingerprint)
        }
        pins[key] = HostKeyPin(deviceId: key, host: host, port: UInt16(clamping: port), fingerprint: fingerprint)
        try? persistUnderLock()
        return .pinnedNew
    }

    /// Сброс закрепления без подтверждения: удаляет пин и запись known_hosts.
    /// После этого подключение к устройству невозможно до повторного сопряжения (fail-closed).
    public func resetHostKey(host: String, port: Int, deviceId: String? = nil) {
        let key: String
        let previousFingerprint: String?
        lock.lock()
        key = legacyPinKey(host: host, port: port, deviceId: deviceId)
        previousFingerprint = pins[key]?.fingerprint
        lock.unlock()

        var aliases = [Self.safeHostKeyAlias(key)]
        if let previousFingerprint {
            let suffix = previousFingerprint.filter { $0.isLetter || $0.isNumber }.suffix(24)
            aliases.append(Self.safeHostKeyAlias("dev_\(suffix)"))
        }
        if let registered = DeviceRegistry.shared.device(matchingHost: host) {
            aliases.append(Self.safeHostKeyAlias(registered.id))
        }
        for alias in Set(aliases) {
            removeOpenSSHHostKey(alias: alias, port: UInt16(clamping: port))
        }
        unpin(host: host, port: port, deviceId: deviceId)
    }

    public func unpin(host: String, port: Int, deviceId: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let effectiveDeviceId = deviceId ?? PhoneConnectionManager.shared.getConnectedDeviceId()
        let key = legacyPinKey(host: host, port: port, deviceId: deviceId)
        pins.removeValue(forKey: key)
        if host == "127.0.0.1" || host == "localhost" {
            pins.removeValue(forKey: "\(host):\(port)")
            if let dev = effectiveDeviceId, !dev.isEmpty {
                pins.removeValue(forKey: dev)
            }
        }
        try? persistUnderLock()
    }

    /// Удаляет закрепление устройства по его идентификатору.
    public func unpin(deviceId: String) {
        lock.lock()
        defer { lock.unlock() }
        pins.removeValue(forKey: deviceId)
        try? persistUnderLock()
    }

    public func isHostPinned(host: String, port: Int, deviceId: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = legacyPinKey(host: host, port: port, deviceId: deviceId)
        return Self.validFingerprint(pins[key]?.fingerprint) != nil
    }

    public func openSSHKnownHostsURL(host: String, port: UInt16, deviceId: String? = nil) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("MacDroidCommander", isDirectory: true).appendingPathComponent("known_hosts")
    }

    /// Обновляет SSH known_hosts только после успешной проверки отпечатка в HostKeyStore.
    /// Вызывать без удержания внутреннего lock.
    public func installOpenSSHHostKey(_ observation: SSHHostKeyObservation, host: String, port: UInt16, deviceId: String? = nil, hostKeyAlias: String? = nil) throws {
        let observedFields = observation.knownHostsLine.split(whereSeparator: \.isWhitespace)
        guard observedFields.count >= 3 else {
            throw NSError(domain: "HostKeyStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Некорректная строка ключа SSH."])
        }
        let alias = Self.safeHostKeyAlias(hostKeyAlias ?? "mcd-" + String(observation.fingerprint.filter { $0.isLetter || $0.isNumber }.suffix(24)))
        // HostKeyAlias replaces the hostname OpenSSH uses for known_hosts lookup;
        // unlike a literal non-standard-port host, it is stored without [host]:port.
        let knownHostsHost = alias
        let legacyKnownHostsHost = "[\(alias)]:\(port)"
        let knownHostsLine = ([knownHostsHost] + observedFields.dropFirst().map(String.init)).joined(separator: " ")

        lock.lock()
        defer { lock.unlock() }

        let url = openSSHKnownHostsURL(host: host, port: port, deviceId: deviceId)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let existingLines = (try? String(contentsOf: url, encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .map(String.init) ?? []
        let preservedLines = existingLines.filter { line in
            guard let lineHost = line.split(whereSeparator: \.isWhitespace).first else { return false }
            let normalizedHost = lineHost.lowercased()
            return normalizedHost != knownHostsHost.lowercased()
                && normalizedHost != legacyKnownHostsHost.lowercased()
        }
        let updatedContents = (preservedLines + [knownHostsLine]).joined(separator: "\n") + "\n"
        try Self.atomicWrite(Data(updatedContents.utf8), to: url)
    }

    // MARK: - Внутреннее

    private static func validFingerprint(_ fp: String?) -> String? {
        guard let fp, !fp.isEmpty, !isLegacyMockFingerprint(fp) else { return nil }
        return fp
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "localhost"
    }

    /// Вызывать только при удержанном lock (читает текущее подключённое устройство).
    private func legacyPinKey(host: String, port: Int, deviceId: String?) -> String {
        let effectiveDeviceId = deviceId ?? PhoneConnectionManager.shared.getConnectedDeviceId()
        if Self.isLoopback(host), let dev = effectiveDeviceId, !dev.isEmpty {
            return dev
        }
        return "\(host):\(port)"
    }

    /// Транзакционное изменение пинов: при ошибке записи состояние откатывается.
    private func updatePins(_ body: (inout [String: HostKeyPin]) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var working = pins
        try body(&working)
        let snapshot = pins
        pins = working
        do {
            try persistUnderLock()
        } catch {
            pins = snapshot
            throw error
        }
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        guard let data = try? Data(contentsOf: storageURL) else {
            quarantineCorruptedFile(reason: "не удалось прочитать файл")
            return
        }
        if let file = try? JSONDecoder().decode(HostKeyStoreFileV2.self, from: data), file.version == 2 {
            var loaded: [String: HostKeyPin] = [:]
            for pin in file.pins where !pin.deviceId.isEmpty && Self.validFingerprint(pin.fingerprint) != nil {
                loaded[pin.deviceId] = pin
            }
            pins = loaded
            return
        }
        if let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
            // Миграция формата host:port -> deviceId без потери закреплений.
            pins = Self.migrateLegacy(legacy)
            try? persistUnderLock()
            return
        }
        quarantineCorruptedFile(reason: "неизвестный формат")
    }

    private static func migrateLegacy(_ legacy: [String: String]) -> [String: HostKeyPin] {
        var result: [String: HostKeyPin] = [:]
        for (key, fingerprint) in legacy where validFingerprint(fingerprint) != nil {
            if key.hasPrefix("usb_") {
                let deviceId = String(key.dropFirst(4))
                guard !deviceId.isEmpty else { continue }
                result[deviceId] = HostKeyPin(deviceId: deviceId, host: "127.0.0.1", port: 0, fingerprint: fingerprint)
                continue
            }
            guard let colon = key.lastIndex(of: ":"),
                  let port = UInt16(key[key.index(after: colon)...]) else { continue }
            let host = String(key[..<colon])
            let registered = DeviceRegistry.shared.device(matchingFingerprint: fingerprint)
                ?? DeviceRegistry.shared.allDevices().first(where: { $0.lastKnownHost == host && $0.lastKnownPort == port })
            let deviceId = registered?.id ?? "legacy:\(key)"
            result[deviceId] = HostKeyPin(deviceId: deviceId, host: host, port: port, fingerprint: fingerprint)
        }
        return result
    }

    /// Повреждённый файл переносится в .corrupt; хранилище пустое, требуется повторное сопряжение.
    private func quarantineCorruptedFile(reason: String) {
        let backup = storageURL.deletingLastPathComponent()
            .appendingPathComponent(storageURL.lastPathComponent + ".corrupt")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: storageURL, to: backup)
        pins = [:]
        integrityState = .corruptedQuarantined(backupPath: backup.path)
        NSLog("HostKeyStore: pinned_hosts.json поврежден (%@). Требуется повторное сопряжение.", reason)
    }

    /// Вызывать только при удержанном lock.
    private func persistUnderLock() throws {
        let file = HostKeyStoreFileV2(version: 2, pins: pins.values.sorted { $0.deviceId < $1.deviceId })
        let data = try JSONEncoder().encode(file)
        try Self.atomicWrite(data, to: storageURL)
    }

    /// Атомарная запись: временный файл с правами 0600 и rename поверх целевого.
    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw HostKeyStoreError.persistenceFailed("не удалось создать временный файл")
        }
        guard Darwin.rename(tmp.path, url.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: tmp)
            throw HostKeyStoreError.persistenceFailed(reason)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func removeOpenSSHHostKey(alias: String, port: UInt16) {
        lock.lock()
        defer { lock.unlock() }

        let url = openSSHKnownHostsURL(host: "", port: port)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        let entries = Set([alias.lowercased(), "[\(alias)]:\(port)".lowercased()])
        let lines = contents.components(separatedBy: .newlines)
        let retainedLines = lines.filter { line in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard let host = fields.first.map({ String($0).lowercased() }) else { return false }
            return !entries.contains(host)
        }
        let updated = retainedLines.isEmpty ? "" : retainedLines.joined(separator: "\n") + "\n"
        do {
            try Self.atomicWrite(Data(updated.utf8), to: url)
        } catch {
            NSLog("Unable to remove SSH known_hosts entry %@: %@", alias, error.localizedDescription)
        }
    }
}
