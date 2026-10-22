import Foundation
import CryptoKit

public enum ClientKeyError: Error, LocalizedError, Sendable {
    /// Ключ сохранён, но не читается/не парсится. Новый ключ НЕ генерируется: иначе сопряжение ломается молча.
    case unreadableKey(String)
    case keychain(OSStatus) // не используется, оставлен для совместимости

    public var errorDescription: String? {
        switch self {
        case .unreadableKey(let reason):
            return "Приватный ключ MacDroid Commander недоступен (\(reason)). Сопряжение нужно повторить вручную."
        case .keychain(let status):
            return "Ошибка Keychain (\(status)) при работе с ключом MacDroid Commander."
        }
    }
}

/// Менеджер клиентских ключей MacHost.
/// Постоянная пара Ed25519 хранится в файле 0600 в Application Support.
/// Устаревшее значение из UserDefaults мигрирует в файл при первом доступе.
public final class ClientKeyManager: @unchecked Sendable {
    public static let shared = ClientKeyManager()

    private static let legacyDefaultsKey = "com.macdroid.commander.client_ed25519_priv"

    private let lock = NSLock()
    private var cachedPrivateKey: Curve25519.Signing.PrivateKey?

    private init() {}

    /// Возвращает постоянный приватный ключ Ed25519. Создаёт новый только при полном отсутствии ключа.
    public func getOrCreatePrivateKey() throws -> Curve25519.Signing.PrivateKey {
        lock.lock()
        defer { lock.unlock() }

        if let key = cachedPrivateKey {
            return key
        }

        // 1. Файл: основное хранилище.
        if let raw = try readKeychain() {
            let key = try Self.parse(raw)
            cachedPrivateKey = key
            // Остаток старого значения в UserDefaults больше не нужен.
            UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
            return key
        }

        // 2. Миграция: UserDefaults -> файл. Удаляем из UserDefaults только после проверки записи.
        if let b64 = UserDefaults.standard.string(forKey: Self.legacyDefaultsKey) {
            guard let raw = Data(base64Encoded: b64) else {
                throw ClientKeyError.unreadableKey("устаревшее значение повреждено")
            }
            let key = try Self.parse(raw)
            try writeKeychain(raw)
            guard let stored = try readKeychain(), stored == raw else {
                throw ClientKeyError.unreadableKey("запись файла ключа не подтвердилась")
            }
            UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
            cachedPrivateKey = key
            return key
        }

        // 3. Ключа нет нигде: создаём впервые.
        let newKey = Curve25519.Signing.PrivateKey()
        try writeKeychain(newKey.rawRepresentation)
        cachedPrivateKey = newKey
        return newKey
    }

    /// Возвращает публичный ключ
    public var publicKey: Curve25519.Signing.PublicKey {
        get throws {
            return try getOrCreatePrivateKey().publicKey
        }
    }

    /// Возвращает публичный ключ в формате OpenSSH ("ssh-ed25519 <Base64> macdroid@mac")
    public var openSSHPublicKeyString: String {
        get throws {
            let pubBytes = try publicKey.rawRepresentation

            let keyType = "ssh-ed25519"
            var wireData = Data()
            var typeLen = UInt32(keyType.utf8.count).bigEndian
            withUnsafeBytes(of: &typeLen) { wireData.append(contentsOf: $0) }
            wireData.append(Data(keyType.utf8))

            var pubLen = UInt32(pubBytes.count).bigEndian
            withUnsafeBytes(of: &pubLen) { wireData.append(contentsOf: $0) }
            wireData.append(pubBytes)

            return "ssh-ed25519 \(wireData.base64EncodedString()) macdroid@mac"
        }
    }

    /// Подпись произвольного бинарного сообщения
    public func sign(data: Data) throws -> Data {
        let priv = try getOrCreatePrivateKey()
        return try priv.signature(for: data)
    }

    // MARK: - Внутреннее

    private static func parse(_ raw: Data) throws -> Curve25519.Signing.PrivateKey {
        do {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        } catch {
            throw ClientKeyError.unreadableKey("неверный формат ключа")
        }
    }

    /// Файл с ключом: Application Support/MacDroidCommander/client_ed25519.key (0600).
    /// Keychain не используется намеренно: приложение подписывается ad-hoc, и после каждой пересборки
    /// системa запрашивала бы доступ к элементу, а отказ ломал бы сопряжение.
    private func keyFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("MacDroidCommander", isDirectory: true)
            .appendingPathComponent("client_ed25519.key")
    }

    /// nil только если файла нет; любая другая ошибка пробрасывается.
    private func readKeychain() throws -> Data? {
        let url = keyFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ClientKeyError.unreadableKey("файл ключа не читается: \(error.localizedDescription)")
        }
    }

    private func writeKeychain(_ raw: Data) throws {
        let url = keyFileURL()
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try raw.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw ClientKeyError.unreadableKey("не удалось сохранить ключ: \(error.localizedDescription)")
        }
    }
}
