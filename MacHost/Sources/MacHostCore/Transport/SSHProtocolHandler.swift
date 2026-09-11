import Foundation
import CryptoKit

/// Коды сообщений SSHv2 протокола (RFC 4250, RFC 4253, RFC 4252, RFC 4254)
public enum SSHMessageType: UInt8, Sendable {
    case disconnect       = 1
    case ignore           = 2
    case unimplemented    = 3
    case debug            = 4
    case serviceRequest   = 5
    case serviceAccept    = 6
    case kexInit          = 20
    case newKeys          = 21
    
    // KEX DH / ECDH
    case kexECDHInit      = 30
    case kexECDHReply     = 31
    
    // User Auth
    case userauthRequest  = 50
    case userauthFailure  = 51
    case userauthSuccess  = 52
    case userauthBanner   = 53
    case userauthPkOk     = 60
    
    // Connection Protocol (Channels)
    case channelOpen          = 90
    case channelOpenConfirm   = 91
    case channelOpenFailure   = 92
    case channelWindowAdjust  = 93
    case channelData          = 94
    case channelExtendedData  = 95
    case channelEof           = 96
    case channelClose         = 97
    case channelRequest       = 98
    case channelSuccess       = 99
    case channelFailure       = 100
}

/// Состояние SSHv2 сессии
public enum SSHSessionState: Sendable {
    case disconnected
    case versionExchanged
    case kexCompleted
    case authenticated
    case sftpChannelReady
    case failed(String)
}

/// Обработчик бинарных SSHv2 пакетов
public final class SSHProtocolHandler: @unchecked Sendable {
    public static let clientVersion = "SSH-2.0-MacDroidCommander_1.0\r\n"
    
    public private(set) var state: SSHSessionState = .disconnected
    public private(set) var serverVersionString: String = ""
    public private(set) var channelId: UInt32 = 0
    public private(set) var serverChannelId: UInt32 = 0
    
    public init() {}
    
    /// Формирует SSHv2 пакет с дополнением случайным padding
    public static func buildPacket(payload: Data) -> Data {
        let minPadding = 4
        let blockSize = 8
        let unpaddedLength = 4 + 1 + payload.count // length(4) + pad_len(1) + payload
        var padLen = blockSize - (unpaddedLength % blockSize)
        if padLen < minPadding {
            padLen += blockSize
        }
        
        let packetLength = UInt32(1 + payload.count + padLen)
        var out = Data()
        var beLen = packetLength.bigEndian
        withUnsafeBytes(of: &beLen) { out.append(contentsOf: $0) }
        out.append(UInt8(padLen))
        out.append(payload)
        
        // Random padding
        for _ in 0..<padLen {
            out.append(UInt8.random(in: 0...255))
        }
        return out
    }
    
    /// Разбирает входящий SSHv2 пакет
    public static func parsePacket(data: Data) throws -> (type: SSHMessageType, payload: Data) {
        guard data.count >= 5 else {
            throw NSError(domain: "SSHProtocolHandler", code: 1, userInfo: [NSLocalizedDescriptionKey: "Packet too short"])
        }
        let padLen = Int(data[4])
        let payloadStart = 5
        let payloadEnd = data.count - padLen
        guard payloadEnd >= payloadStart else {
            throw NSError(domain: "SSHProtocolHandler", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid padding"])
        }
        let payload = data.subdata(in: payloadStart..<payloadEnd)
        guard let rawType = payload.first, let msgType = SSHMessageType(rawValue: rawType) else {
            throw NSError(domain: "SSHProtocolHandler", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unknown SSH message type"])
        }
        let body = payload.subdata(in: 1..<payload.count)
        return (msgType, body)
    }
    
    /// Пакет запроса аутентификации публичным ключом Ed25519
    public func createAuthRequestPacket(user: String = "android") throws -> Data {
        var writer = SFTPPacketWriter()
        writer.appendUInt8(SSHMessageType.userauthRequest.rawValue)
        writer.appendString(user)
        writer.appendString("ssh-connection")
        writer.appendString("publickey")
        writer.appendUInt8(1) // with signature = true
        writer.appendString("ssh-ed25519")
        
        let pubRaw = ClientKeyManager.shared.publicKey.rawRepresentation
        var keyBlob = Data()
        var ktLen = UInt32("ssh-ed25519".utf8.count).bigEndian
        withUnsafeBytes(of: &ktLen) { keyBlob.append(contentsOf: $0) }
        keyBlob.append(Data("ssh-ed25519".utf8))
        var pkLen = UInt32(pubRaw.count).bigEndian
        withUnsafeBytes(of: &pkLen) { keyBlob.append(contentsOf: $0) }
        keyBlob.append(pubRaw)
        writer.appendData(keyBlob)
        
        // Подпись данных запроса
        let signature = try ClientKeyManager.shared.sign(data: keyBlob)
        var sigBlob = Data()
        sigBlob.append(Data("ssh-ed25519".utf8))
        sigBlob.append(signature)
        writer.appendData(sigBlob)
        
        return Self.buildPacket(payload: writer.buildPacket(type: .initMsg).subdata(in: 5..<writer.buildPacket(type: .initMsg).count))
    }
    
    /// Пакет открытия канала "session"
    public func createChannelOpenPacket(localChannelId: UInt32 = 0) -> Data {
        var writer = SFTPPacketWriter()
        writer.appendUInt8(SSHMessageType.channelOpen.rawValue)
        writer.appendString("session")
        writer.appendUInt32(localChannelId)
        writer.appendUInt32(2 * 1024 * 1024) // initial window size (2MB)
        writer.appendUInt32(32768) // max packet size (32KB)
        
        let p = writer.buildPacket(type: .initMsg)
        return Self.buildPacket(payload: p.subdata(in: 5..<p.count))
    }
    
    /// Пакет запроса подсистемы "sftp"
    public func createSubsystemRequestPacket(serverChannelId: UInt32) -> Data {
        var writer = SFTPPacketWriter()
        writer.appendUInt8(SSHMessageType.channelRequest.rawValue)
        writer.appendUInt32(serverChannelId)
        writer.appendString("subsystem")
        writer.appendUInt8(1) // want reply = true
        writer.appendString("sftp")
        
        let p = writer.buildPacket(type: .initMsg)
        return Self.buildPacket(payload: p.subdata(in: 5..<p.count))
    }
    
    /// Инкапсулирует SFTP пакет в SSH_MSG_CHANNEL_DATA
    public func wrapSFTPInChannelData(sftpPacket: Data, serverChannelId: UInt32) -> Data {
        var writer = SFTPPacketWriter()
        writer.appendUInt8(SSHMessageType.channelData.rawValue)
        writer.appendUInt32(serverChannelId)
        writer.appendData(sftpPacket)
        
        let p = writer.buildPacket(type: .initMsg)
        return Self.buildPacket(payload: p.subdata(in: 5..<p.count))
    }
}
