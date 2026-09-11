import Foundation
import CryptoKit

/// Менеджер клиентских ключей MacHost.
/// Генерирует и сохраняет постоянную ключевую пару Ed25519 для взаимной аутентификации с Android телефоном.
public final class ClientKeyManager: @unchecked Sendable {
    public static let shared = ClientKeyManager()
    
    private let privateKeyTag = "com.macdroid.commander.client_ed25519_priv"
    private let lock = NSLock()
    private var cachedPrivateKey: Curve25519.Signing.PrivateKey?
    
    private init() {}
    
    /// Возвращает или генерирует постоянный приватный ключ Ed25519
    public func getOrCreatePrivateKey() -> Curve25519.Signing.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        
        if let key = cachedPrivateKey {
            return key
        }
        
        // Попытка загрузить из UserDefaults (Base64 raw representation)
        if let b64 = UserDefaults.standard.string(forKey: privateKeyTag),
           let rawData = Data(base64Encoded: b64),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawData) {
            cachedPrivateKey = key
            return key
        }
        
        // Генерация новой ключевой пары
        let newKey = Curve25519.Signing.PrivateKey()
        let b64 = newKey.rawRepresentation.base64EncodedString()
        UserDefaults.standard.set(b64, forKey: privateKeyTag)
        cachedPrivateKey = newKey
        return newKey
    }
    
    /// Возвращает публичный ключ
    public var publicKey: Curve25519.Signing.PublicKey {
        return getOrCreatePrivateKey().publicKey
    }
    
    /// Возвращает публичный ключ в формате OpenSSH ("ssh-ed25519 <Base64> macdroid@mac")
    public var openSSHPublicKeyString: String {
        let pubBytes = publicKey.rawRepresentation
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
    
    /// Подпись произвольного бинарного сообщения
    public func sign(data: Data) throws -> Data {
        let priv = getOrCreatePrivateKey()
        return try priv.signature(for: data)
    }
}
