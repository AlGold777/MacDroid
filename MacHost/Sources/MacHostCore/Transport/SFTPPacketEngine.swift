import Foundation

public enum SFTPMessageType: UInt8, Sendable {
    case initMsg      = 1   // SSH_FXP_INIT
    case version      = 2   // SSH_FXP_VERSION
    case open         = 3   // SSH_FXP_OPEN
    case close        = 4   // SSH_FXP_CLOSE
    case read         = 5   // SSH_FXP_READ
    case write        = 6   // SSH_FXP_WRITE
    case lstat        = 7   // SSH_FXP_LSTAT
    case fstat        = 8   // SSH_FXP_FSTAT
    case setstat      = 9   // SSH_FXP_SETSTAT
    case fsetstat     = 10  // SSH_FXP_FSETSTAT
    case opendir      = 11  // SSH_FXP_OPENDIR
    case readdir      = 12  // SSH_FXP_READDIR
    case remove       = 13  // SSH_FXP_REMOVE
    case mkdir        = 14  // SSH_FXP_MKDIR
    case rmdir        = 15  // SSH_FXP_RMDIR
    case realpath     = 16  // SSH_FXP_REALPATH
    case stat         = 17  // SSH_FXP_STAT
    case rename       = 18  // SSH_FXP_RENAME
    
    // Ответы сервера:
    case status       = 101 // SSH_FXP_STATUS
    case handle       = 102 // SSH_FXP_HANDLE
    case data         = 103 // SSH_FXP_DATA
    case name         = 104 // SSH_FXP_NAME
    case attrs        = 105 // SSH_FXP_ATTRS
    
    // Расширения (Extensions)
    case extended     = 200 // SSH_FXP_EXTENDED
    case extendedReply = 201 // SSH_FXP_EXTENDED_REPLY
}

public enum SFTPStatusCode: UInt32, Sendable {
    case ok                 = 0
    case eof                = 1
    case noSuchFile         = 2
    case permissionDenied   = 3
    case failure            = 4
    case badMessage         = 5
    case noConnection       = 6
    case connectionLost     = 7
    case opUnsupported      = 8
}

public struct SFTPNameEntry: Sendable {
    public let filename: String
    public let longname: String
    /// Исходные байты имени с сервера. Канон для обратных операций (open/remove/rename/stat):
    /// декодированная `filename` может терять байты (не-UTF8, lossy-декод) или меняться
    /// при NFC-нормализации — round-trip по ней такой файл не найдёт.
    public let rawFilename: Data
    public let size: UInt64
    public let mtime: UInt32
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    
    public init(filename: String, longname: String, size: UInt64, mtime: UInt32, isDirectory: Bool, isSymbolicLink: Bool = false, rawFilename: Data? = nil) {
        // Оптимизация: пропускаем NFC-нормализацию для чистых ASCII-имён
        self.filename = filename.utf8.allSatisfy({ $0 < 128 }) ? filename : filename.precomposedStringWithCanonicalMapping
        // longname не требует нормализации, так как используется лишь как служебная строка
        self.longname = longname
        self.rawFilename = rawFilename ?? Data(self.filename.utf8)
        self.size = size
        self.mtime = mtime
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
    }
}

public struct SFTPStatVfs: Sendable {
    public let bsize: UInt64
    public let frsize: UInt64
    public let blocks: UInt64
    public let bfree: UInt64
    public let bavail: UInt64
    public let files: UInt64
    public let ffree: UInt64
    public let favail: UInt64
    public let fsid: UInt64
    public let flag: UInt64
    public let namemax: UInt64
    
    public init(
        bsize: UInt64, frsize: UInt64, blocks: UInt64, bfree: UInt64, bavail: UInt64,
        files: UInt64, ffree: UInt64, favail: UInt64, fsid: UInt64, flag: UInt64, namemax: UInt64
    ) {
        self.bsize = bsize
        self.frsize = frsize
        self.blocks = blocks
        self.bfree = bfree
        self.bavail = bavail
        self.files = files
        self.ffree = ffree
        self.favail = favail
        self.fsid = fsid
        self.flag = flag
        self.namemax = namemax
    }
}

public struct SFTPLimits: Sendable {
    public let maxPacketLen: UInt64
    public let maxReadLen: UInt64
    public let maxWriteLen: UInt64
    public let maxOpenHandles: UInt64
    
    public init(maxPacketLen: UInt64, maxReadLen: UInt64, maxWriteLen: UInt64, maxOpenHandles: UInt64) {
        self.maxPacketLen = maxPacketLen
        self.maxReadLen = maxReadLen
        self.maxWriteLen = maxWriteLen
        self.maxOpenHandles = maxOpenHandles
    }
}

public final class SFTPPacketWriter {
    private var data = Data()
    
    public init() {}
    
    public func appendUInt8(_ value: UInt8) {
        data.append(value)
    }
    
    public func appendUInt32(_ value: UInt32) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }
    
    public func appendUInt64(_ value: UInt64) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }
    
    public func appendString(_ string: String) {
        let utf8 = Data(string.utf8)
        appendUInt32(UInt32(utf8.count))
        data.append(utf8)
    }
    
    public func appendData(_ bytes: Data) {
        appendUInt32(UInt32(bytes.count))
        data.append(bytes)
    }
    
    public func buildPacket(type: SFTPMessageType) -> Data {
        var packet = Data()
        // Оптимизация: резервируем точный размер пакета
        packet.reserveCapacity(5 + data.count)
        let totalLength = UInt32(1 + data.count)
        var beLength = totalLength.bigEndian
        withUnsafeBytes(of: &beLength) { packet.append(contentsOf: $0) }
        packet.append(type.rawValue)
        packet.append(data)
        return packet
    }
}

public final class SFTPPacketReader {
    private let data: Data
    private var offset: Int = 0
    
    public init(data: Data) {
        self.data = data
    }
    
    public var hasRemaining: Bool {
        return offset < data.count
    }
    
    public func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw NSError(domain: "SFTPPacketReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected EOF"]) }
        let val = data[data.startIndex + offset] // L3: индексация от startIndex (срезы Data)
        offset += 1
        return val
    }
    
    public func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw NSError(domain: "SFTPPacketReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected EOF reading UInt32"]) }
        // Оптимизация: прямое чтение без аллокации промежуточного Data.subdata
        let val = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian
        }
        offset += 4
        return val
    }
    
    public func readUInt64() throws -> UInt64 {
        guard offset + 8 <= data.count else { throw NSError(domain: "SFTPPacketReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected EOF reading UInt64"]) }
        // Оптимизация: прямое чтение без аллокации промежуточного Data.subdata
        let val = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: offset, as: UInt64.self).bigEndian
        }
        offset += 8
        return val
    }
    
    public func readString() throws -> String {
        let len = Int(try readUInt32())
        guard offset + len <= data.count else { throw NSError(domain: "SFTPPacketReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected EOF reading String"]) }
        let str: String
        if len == 0 {
            str = ""
        } else {
            let start = data.startIndex + offset
            let slice = data[start..<(start + len)]
            // T5: lossy-декод на уровне записи: одно не-UTF-8 имя не валит весь листинг.
            str = String(decoding: slice, as: UTF8.self)
        }
        offset += len
        return str
    }
    
    /// Строка + её исходные байты: для round-trip имён файлов без потерь (не-UTF8, NFD).
    public func readStringWithRaw() throws -> (value: String, raw: Data) {
        let len = Int(try readUInt32())
        guard offset + len <= data.count else { throw NSError(domain: "SFTPPacketReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected EOF reading String"]) }
        let start = data.startIndex + offset
        let slice = data[start..<(start + len)]
        let raw = len == 0 ? Data() : Data(slice)
        let str = len == 0 ? "" : String(decoding: slice, as: UTF8.self)
        offset += len
        return (str, raw)
    }
    
    public func readData() throws -> Data {
        let len = Int(try readUInt32())
        guard offset + len <= data.count else { throw NSError(domain: "SFTPPacketReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected EOF reading Data"]) }
        let sub = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + len)) // L3
        offset += len
        return sub
    }
}

public final class SFTPPacketEngine: @unchecked Sendable {
    public static let version: UInt32 = 3
    
    public init() {}
    
    public func createInitPacket() -> Data {
        let writer = SFTPPacketWriter()
        writer.appendUInt32(Self.version)
        return writer.buildPacket(type: .initMsg)
    }
    
    public func createOpenDirPacket(requestId: UInt32, path: String) -> Data {
        let writer = SFTPPacketWriter()
        writer.appendUInt32(requestId)
        writer.appendString(path)
        return writer.buildPacket(type: .opendir)
    }
    
    public func createReadDirPacket(requestId: UInt32, handle: Data) -> Data {
        let writer = SFTPPacketWriter()
        writer.appendUInt32(requestId)
        writer.appendData(handle)
        return writer.buildPacket(type: .readdir)
    }
    
    public func createClosePacket(requestId: UInt32, handle: Data) -> Data {
        let writer = SFTPPacketWriter()
        writer.appendUInt32(requestId)
        writer.appendData(handle)
        return writer.buildPacket(type: .close)
    }
    
    public func createMkdirPacket(requestId: UInt32, path: String) -> Data {
        let writer = SFTPPacketWriter()
        writer.appendUInt32(requestId)
        writer.appendString(path)
        writer.appendUInt32(0) // Dummy attrs flag
        return writer.buildPacket(type: .mkdir)
    }
    
    public func createRemovePacket(requestId: UInt32, path: String) -> Data {
        let writer = SFTPPacketWriter()
        writer.appendUInt32(requestId)
        writer.appendString(path)
        return writer.buildPacket(type: .remove)
    }
    
    public func createRenamePacket(requestId: UInt32, oldPath: String, newPath: String) -> Data {
        let writer = SFTPPacketWriter()
        writer.appendUInt32(requestId)
        writer.appendString(oldPath)
        writer.appendString(newPath)
        return writer.buildPacket(type: .rename)
    }
    
    public func createOpenPacket(requestId: UInt32, path: String, pflags: UInt32 = 0x00000001) -> Data {
        // SSH_FXF_READ = 0x00000001, SSH_FXF_WRITE = 0x00000002
        let writer = SFTPPacketWriter()
        writer.appendUInt32(requestId)
        writer.appendString(path)
        writer.appendUInt32(pflags)
        writer.appendUInt32(0) // dummy attrs
        return writer.buildPacket(type: .open)
    }
    
    public func createReadPacket(requestId: UInt32, handle: Data, offset: UInt64, length: UInt32 = 262144) -> Data {
        let writer = SFTPPacketWriter()
        writer.appendUInt32(requestId)
        writer.appendData(handle)
        writer.appendUInt64(offset)
        writer.appendUInt32(length)
        return writer.buildPacket(type: .read)
    }
    
    public func createWritePacket(requestId: UInt32, handle: Data, offset: UInt64, data: Data) -> Data {
        let writer = SFTPPacketWriter()
        writer.appendUInt32(requestId)
        writer.appendData(handle)
        writer.appendUInt64(offset)
        writer.appendData(data)
        return writer.buildPacket(type: .write)
    }
    
    public func createSetstatMtimePacket(requestId: UInt32, path: String, mtime: UInt32) -> Data {
        let writer = SFTPPacketWriter()
        writer.appendUInt32(requestId)
        writer.appendString(path)
        // Флаг SSH_FILEXFER_ATTR_ACMODTIME = 0x00000008
        writer.appendUInt32(0x00000008)
        writer.appendUInt32(mtime)
        writer.appendUInt32(mtime)
        return writer.buildPacket(type: .setstat)
    }
    
    public func createStatPacket(requestId: UInt32, path: String) -> Data {
        let writer = SFTPPacketWriter()
        writer.appendUInt32(requestId)
        writer.appendString(path)
        return writer.buildPacket(type: .stat)
    }
    
    public func createRmdirPacket(requestId: UInt32, path: String) -> Data {
        let writer = SFTPPacketWriter()
        writer.appendUInt32(requestId)
        writer.appendString(path)
        return writer.buildPacket(type: .rmdir)
    }
    
    public func parseStatusResponse(data: Data) throws -> (requestId: UInt32, code: SFTPStatusCode, message: String) {
        let reader = SFTPPacketReader(data: data)
        let reqId = try reader.readUInt32()
        let rawCode = try reader.readUInt32()
        let code = SFTPStatusCode(rawValue: rawCode) ?? .failure
        let msg = (try? reader.readString()) ?? ""
        return (reqId, code, msg)
    }
    
    public func parseHandleResponse(data: Data) throws -> (requestId: UInt32, handle: Data) {
        let reader = SFTPPacketReader(data: data)
        let reqId = try reader.readUInt32()
        let handle = try reader.readData()
        return (reqId, handle)
    }
    
    public func parseAttrsResponse(data: Data) throws -> (requestId: UInt32, size: UInt64, mtime: UInt32, isDirectory: Bool) {
        let reader = SFTPPacketReader(data: data)
        let reqId = try reader.readUInt32()
        let flags = try reader.readUInt32()
        
        var size: UInt64 = 0
        if (flags & 0x00000001) != 0 {
            size = try reader.readUInt64()
        }
        if (flags & 0x00000002) != 0 {
            _ = try reader.readUInt32()
            _ = try reader.readUInt32()
        }
        var permissions: UInt32 = 0
        if (flags & 0x00000004) != 0 {
            permissions = try reader.readUInt32()
        }
        var mtime: UInt32 = 0
        if (flags & 0x00000008) != 0 {
            _ = try reader.readUInt32()
            mtime = try reader.readUInt32()
        }
        // T8: SSH_FILEXFER_ATTR_EXTENDED — count пар (extended_type, extended_data), пропускаем
        if (flags & 0x80000000) != 0 {
            let extCount = try reader.readUInt32()
            for _ in 0..<extCount {
                _ = try reader.readString()
                _ = try reader.readString()
            }
        }
        let isDir = (permissions & 0o040000) != 0
        return (reqId, size, mtime, isDir)
    }
    
    public func parseDataResponse(data: Data) throws -> (requestId: UInt32, data: Data) {
        let reader = SFTPPacketReader(data: data)
        let reqId = try reader.readUInt32()
        let fileData = try reader.readData()
        return (reqId, fileData)
    }
    
    public func parseNameResponse(data: Data) throws -> [SFTPNameEntry] {
        let reader = SFTPPacketReader(data: data)
        let _ = try reader.readUInt32() // requestId
        let count = try reader.readUInt32()
        var entries: [SFTPNameEntry] = []
        
        for _ in 0..<count {
            let (filename, filenameRaw) = try reader.readStringWithRaw()
            let longname = try reader.readString()
            let flags = try reader.readUInt32()
            
            var size: UInt64 = 0
            if (flags & 0x00000001) != 0 { // SSH_FILEXFER_ATTR_SIZE
                size = try reader.readUInt64()
            }
            if (flags & 0x00000002) != 0 { // SSH_FILEXFER_ATTR_UIDGID
                _ = try reader.readUInt32()
                _ = try reader.readUInt32()
            }
            var permissions: UInt32 = 0
            if (flags & 0x00000004) != 0 { // SSH_FILEXFER_ATTR_PERMISSIONS
                permissions = try reader.readUInt32()
            }
            var mtime: UInt32 = 0
            if (flags & 0x00000008) != 0 { // SSH_FILEXFER_ATTR_ACMODTIME
                _ = try reader.readUInt32() // atime
                mtime = try reader.readUInt32()
            }
            // T8: SSH_FILEXFER_ATTR_EXTENDED — пропускаем пары (extended_type, extended_data)
            if (flags & 0x80000000) != 0 {
                let extCount = try reader.readUInt32()
                for _ in 0..<extCount {
                    _ = try reader.readString()
                    _ = try reader.readString()
                }
            }
            
            let isDir = (permissions & 0o040000) != 0 || longname.hasPrefix("d")
            entries.append(SFTPNameEntry(
                filename: filename,
                longname: longname,
                size: size,
                mtime: mtime,
                isDirectory: isDir,
                isSymbolicLink: (permissions & 0o170000) == 0o120000 || (permissions == 0 && longname.hasPrefix("l")),
                rawFilename: filenameRaw
            ))
        }
        return entries
    }
    
    // MARK: - SFTP Version & Extensions
    
    public func parseVersionResponse(data: Data) throws -> (version: UInt32, extensions: [String: String]) {
        let reader = SFTPPacketReader(data: data)
        let version = try reader.readUInt32()
        var extensions: [String: String] = [:]
        while reader.hasRemaining {
            if let extName = try? reader.readString(), let extData = try? reader.readString() {
                extensions[extName] = extData
            } else {
                break
            }
        }
        return (version, extensions)
    }
    
    public func createStatVfsPacket(requestId: UInt32, path: String) -> Data {
        let writer = SFTPPacketWriter()
        writer.appendUInt32(requestId)
        writer.appendString("statvfs@openssh.com")
        writer.appendString(path)
        return writer.buildPacket(type: .extended)
    }
    
    public func parseStatVfsResponse(data: Data) throws -> (requestId: UInt32, statvfs: SFTPStatVfs) {
        let reader = SFTPPacketReader(data: data)
        let reqId = try reader.readUInt32()
        let bsize = try reader.readUInt64()
        let frsize = try reader.readUInt64()
        let blocks = try reader.readUInt64()
        let bfree = try reader.readUInt64()
        let bavail = try reader.readUInt64()
        let files = try reader.readUInt64()
        let ffree = try reader.readUInt64()
        let favail = try reader.readUInt64()
        let fsid = try reader.readUInt64()
        let flag = try reader.readUInt64()
        let namemax = try reader.readUInt64()
        let statvfs = SFTPStatVfs(
            bsize: bsize, frsize: frsize, blocks: blocks, bfree: bfree, bavail: bavail,
            files: files, ffree: ffree, favail: favail, fsid: fsid, flag: flag, namemax: namemax
        )
        return (reqId, statvfs)
    }
    
    public func createPosixRenamePacket(requestId: UInt32, oldPath: String, newPath: String) -> Data {
        let writer = SFTPPacketWriter()
        writer.appendUInt32(requestId)
        writer.appendString("posix-rename@openssh.com")
        writer.appendString(oldPath)
        writer.appendString(newPath)
        return writer.buildPacket(type: .extended)
    }
    
    public func createFsyncPacket(requestId: UInt32, handle: Data) -> Data {
        let writer = SFTPPacketWriter()
        writer.appendUInt32(requestId)
        writer.appendString("fsync@openssh.com")
        writer.appendData(handle)
        return writer.buildPacket(type: .extended)
    }
    
    public func createLimitsPacket(requestId: UInt32) -> Data {
        let writer = SFTPPacketWriter()
        writer.appendUInt32(requestId)
        writer.appendString("limits@openssh.com")
        return writer.buildPacket(type: .extended)
    }
    
    public func parseLimitsResponse(data: Data) throws -> (requestId: UInt32, limits: SFTPLimits) {
        let reader = SFTPPacketReader(data: data)
        let reqId = try reader.readUInt32()
        let maxPacket = try reader.readUInt64()
        let maxRead = try reader.readUInt64()
        let maxWrite = try reader.readUInt64()
        let maxHandles = try reader.readUInt64()
        let limits = SFTPLimits(
            maxPacketLen: maxPacket,
            maxReadLen: maxRead,
            maxWriteLen: maxWrite,
            maxOpenHandles: maxHandles
        )
        return (reqId, limits)
    }
}
