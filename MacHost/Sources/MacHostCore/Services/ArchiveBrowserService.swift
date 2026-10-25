import CLibArchive
import Darwin
import Foundation

/// A safe, lightweight description of one member in a ZIP/APK central directory.
public struct ArchiveEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let ordinal: Int
    /// A normalized, relative path using `/` as the separator.
    public let path: String
    public let name: String
    public let size: Int64
    public let isDirectory: Bool

    public init(id: String, ordinal: Int, path: String, name: String, size: Int64, isDirectory: Bool) {
        self.id = id
        self.ordinal = ordinal
        self.path = path
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
    }
}

public enum ArchiveBrowserError: LocalizedError {
    case invalidArchive(String)
    case unsupportedArchive
    case tooManyEntries
    case archiveTooLarge
    case unsafeEntry(String)
    case duplicateEntry(String)
    case encryptedEntry(String)
    case unsupportedEntry(String)
    case entryNotFound
    case destinationUnavailable
    case outputExists(String)
    case sizeMismatch(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArchive(let message): return "Архив повреждён или имеет неверный формат: \(message)"
        case .unsupportedArchive: return "Поддерживаются только ZIP и APK."
        case .tooManyEntries: return "В архиве слишком много объектов (лимит 100 000)."
        case .archiveTooLarge: return "Размер содержимого архива превышает безопасный лимит."
        case .unsafeEntry(let path): return "Небезопасный путь в архиве: \(path)"
        case .duplicateEntry(let path): return "В архиве повторяется путь: \(path)"
        case .encryptedEntry(let path): return "Зашифрованный объект не поддерживается: \(path)"
        case .unsupportedEntry(let path): return "Тип объекта не поддерживается: \(path)"
        case .entryNotFound: return "Объект больше не найден в архиве."
        case .destinationUnavailable: return "Не удалось открыть выбранную папку."
        case .outputExists(let name): return "Файл «\(name)» уже существует. Он не был перезаписан."
        case .sizeMismatch(let path): return "Размер объекта в архиве не совпадает с индексом: \(path)"
        case .io(let message): return "Ошибка чтения или записи: \(message)"
        }
    }
}

/// Indexes ZIP/APK central directories and extracts one selected file without unpacking
/// the rest of the archive. Every operation uses bounded buffers and validates paths.
public enum ArchiveBrowserService {
    public static let maximumEntryCount = 100_000
    public static let maximumEntrySize: Int64 = 1 * 1_024 * 1_024 * 1_024
    public static let maximumTotalUncompressedSize: Int64 = 4 * 1_024 * 1_024 * 1_024
    private static let maximumCentralDirectorySize: UInt64 = 64 * 1_024 * 1_024

    public static func index(archiveURL: URL) async throws -> [ArchiveEntry] {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try validateZipDirectoryBounds(at: archiveURL)
            return try indexSynchronously(archiveURL: archiveURL)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public static func extract(entry: ArchiveEntry, from archiveURL: URL, toDirectory directoryURL: URL) async throws -> URL {
        guard !entry.isDirectory else { throw ArchiveBrowserError.unsupportedEntry(entry.path) }
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try validateZipDirectoryBounds(at: archiveURL)
            return try extractSynchronously(entry: entry, archiveURL: archiveURL, directoryURL: directoryURL)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func indexSynchronously(archiveURL: URL) throws -> [ArchiveEntry] {
        let reader = try makeReader(for: archiveURL)
        defer { _ = archive_read_free(reader) }

        var entries: [ArchiveEntry] = []
        var seen = Set<String>()
        var totalSize: Int64 = 0
        while true {
            try Task.checkCancellation()
            var rawEntry: OpaquePointer?
            let result = archive_read_next_header(reader, &rawEntry)
            if result == ARCHIVE_EOF { break }
            guard result == ARCHIVE_OK, let rawEntry else { throw archiveError(reader) }
            guard entries.count < maximumEntryCount else { throw ArchiveBrowserError.tooManyEntries }

            let path = try safePath(rawEntry)
            guard seen.insert(path).inserted else { throw ArchiveBrowserError.duplicateEntry(path) }
            try checkNotEncrypted(rawEntry, path: path)

            let fileType = archive_entry_filetype(rawEntry)
            let isDirectory = fileType == mode_t(S_IFDIR) || path.hasSuffix("/")
            guard fileType == mode_t(S_IFREG) || fileType == mode_t(S_IFDIR) else {
                throw ArchiveBrowserError.unsupportedEntry(path)
            }
            guard archive_entry_size_is_set(rawEntry) != 0 else {
                throw ArchiveBrowserError.invalidArchive("не задан размер объекта \(path)")
            }
            let rawSize = archive_entry_size(rawEntry)
            guard rawSize >= 0, rawSize <= maximumEntrySize else { throw ArchiveBrowserError.archiveTooLarge }
            let size = isDirectory ? 0 : rawSize
            let (nextTotal, overflow) = totalSize.addingReportingOverflow(size)
            guard !overflow, nextTotal <= maximumTotalUncompressedSize else { throw ArchiveBrowserError.archiveTooLarge }
            totalSize = nextTotal

            let name = path.split(separator: "/").last.map(String.init) ?? path
            entries.append(ArchiveEntry(
                id: "\(entries.count):\(path)",
                ordinal: entries.count,
                path: path,
                name: name,
                size: size,
                isDirectory: isDirectory
            ))
            let skipResult = archive_read_data_skip(reader)
            guard skipResult == ARCHIVE_OK else { throw archiveError(reader) }
        }
        return entries
    }

    private static func extractSynchronously(entry: ArchiveEntry, archiveURL: URL, directoryURL: URL) throws -> URL {
        let directoryFD = directoryURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryFD >= 0 else { throw ArchiveBrowserError.destinationUnavailable }
        defer { _ = close(directoryFD) }

        let outputName = entry.name
        guard !outputName.isEmpty, outputName != ".", outputName != "..", !outputName.contains("/") else {
            throw ArchiveBrowserError.unsafeEntry(entry.path)
        }
        let outputFD = outputName.withCString {
            openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard outputFD >= 0 else {
            if errno == EEXIST { throw ArchiveBrowserError.outputExists(outputName) }
            throw ArchiveBrowserError.io(String(cString: strerror(errno)))
        }
        var keepOutput = false
        var outputFDClosed = false
        defer {
            if !outputFDClosed { _ = close(outputFD) }
            if !keepOutput { _ = outputName.withCString { unlinkat(directoryFD, $0, 0) } }
        }

        let reader = try makeReader(for: archiveURL)
        defer { _ = archive_read_free(reader) }
        var currentOrdinal = 0
        var selected = false
        while true {
            try Task.checkCancellation()
            var rawEntry: OpaquePointer?
            let result = archive_read_next_header(reader, &rawEntry)
            if result == ARCHIVE_EOF { break }
            guard result == ARCHIVE_OK, let rawEntry else { throw archiveError(reader) }
            guard currentOrdinal == entry.ordinal else {
                currentOrdinal += 1
                guard archive_read_data_skip(reader) == ARCHIVE_OK else { throw archiveError(reader) }
                continue
            }

            let actualPath = try safePath(rawEntry)
            guard actualPath == entry.path,
                  archive_entry_filetype(rawEntry) == mode_t(S_IFREG),
                  archive_entry_size_is_set(rawEntry) != 0,
                  archive_entry_size(rawEntry) == entry.size else {
                throw ArchiveBrowserError.entryNotFound
            }
            try checkNotEncrypted(rawEntry, path: actualPath)
            try streamSelectedEntry(reader: reader, outputFD: outputFD, entry: entry)
            selected = true
            break
        }
        guard selected else { throw ArchiveBrowserError.entryNotFound }
        guard fsync(outputFD) == 0 else { throw ArchiveBrowserError.io(String(cString: strerror(errno))) }
        let closeResult = close(outputFD)
        outputFDClosed = true
        guard closeResult == 0 else { throw ArchiveBrowserError.io(String(cString: strerror(errno))) }
        keepOutput = true
        return directoryURL.appendingPathComponent(outputName, isDirectory: false)
    }

    private static func streamSelectedEntry(reader: OpaquePointer, outputFD: Int32, entry: ArchiveEntry) throws {
        let bufferSize = 64 * 1_024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var writtenTotal: Int64 = 0

        while true {
            try Task.checkCancellation()
            let amount = archive_read_data(reader, buffer, bufferSize)
            if amount == 0 { break }
            guard amount > 0 else { throw archiveError(reader) }
            let (nextTotal, overflow) = writtenTotal.addingReportingOverflow(Int64(amount))
            guard !overflow, nextTotal <= entry.size, nextTotal <= maximumEntrySize else {
                throw ArchiveBrowserError.sizeMismatch(entry.path)
            }
            var offset = 0
            while offset < amount {
                try Task.checkCancellation()
                let result = write(outputFD, buffer.advanced(by: offset), amount - offset)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw ArchiveBrowserError.io(String(cString: strerror(errno)))
                }
                guard result > 0 else { throw ArchiveBrowserError.io("запись вернула нулевой размер") }
                offset += result
            }
            writtenTotal = nextTotal
        }
        guard writtenTotal == entry.size else { throw ArchiveBrowserError.sizeMismatch(entry.path) }
    }

    private static func makeReader(for url: URL) throws -> OpaquePointer {
        guard let reader = archive_read_new() else { throw ArchiveBrowserError.io("не удалось создать читатель архива") }
        guard archive_read_support_filter_none(reader) == ARCHIVE_OK,
              archive_read_support_format_zip_seekable(reader) == ARCHIVE_OK else {
            let error = archiveError(reader)
            _ = archive_read_free(reader)
            throw error
        }
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return archive_read_open_filename(reader, path, 64 * 1_024)
        }
        guard result == ARCHIVE_OK else {
            let error = archiveError(reader)
            _ = archive_read_free(reader)
            throw error
        }
        return reader
    }

    private static func safePath(_ entry: OpaquePointer) throws -> String {
        guard archive_entry_symlink(entry) == nil, archive_entry_hardlink(entry) == nil,
              let raw = archive_entry_pathname_utf8(entry) else {
            throw ArchiveBrowserError.unsafeEntry("<неверный UTF-8 или ссылка>")
        }
        let source = String(cString: raw)
        guard !source.isEmpty, source.utf8.count <= 4_096 else { throw ArchiveBrowserError.unsafeEntry(source) }
        let path = source.replacingOccurrences(of: "\\", with: "/")
        guard !path.hasPrefix("/"), !path.hasPrefix("~"),
              !(path.count >= 2 && path[path.index(after: path.startIndex)] == ":") else {
            throw ArchiveBrowserError.unsafeEntry(source)
        }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ArchiveBrowserError.unsafeEntry(source)
        }
        return trimmed
    }

    private static func checkNotEncrypted(_ entry: OpaquePointer, path: String) throws {
        let encrypted = archive_entry_is_encrypted(entry)
        guard encrypted == 0 else { throw ArchiveBrowserError.encryptedEntry(path) }
    }

    private static func archiveError(_ reader: OpaquePointer) -> ArchiveBrowserError {
        let message = archive_error_string(reader).map { String(cString: $0) } ?? "код \(archive_errno(reader))"
        return .invalidArchive(message)
    }

    /// Bounds the central directory before libarchive allocates its seekable index.
    private static func validateZipDirectoryBounds(at url: URL) throws {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw ArchiveBrowserError.io(error.localizedDescription) }
        defer { try? handle.close() }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = (attributes[.size] as? NSNumber)?.uint64Value, fileSize >= 22 else {
            throw ArchiveBrowserError.invalidArchive("файл слишком короткий")
        }
        let tailLength = Int(min(fileSize, 22 + 65_535 + 20 + 56))
        try handle.seek(toOffset: fileSize - UInt64(tailLength))
        guard let tail = try handle.read(upToCount: tailLength), tail.count == tailLength else {
            throw ArchiveBrowserError.invalidArchive("не удалось прочитать конец файла")
        }
        let bytes = [UInt8](tail)
        guard let eocdIndex = findEOCD(in: bytes) else { throw ArchiveBrowserError.unsupportedArchive }
        let disk = u16(bytes, eocdIndex + 4)
        let centralDisk = u16(bytes, eocdIndex + 6)
        let entriesOnDisk = u16(bytes, eocdIndex + 8)
        let entries16 = u16(bytes, eocdIndex + 10)
        let directorySize32 = u32(bytes, eocdIndex + 12)
        let directoryOffset32 = u32(bytes, eocdIndex + 16)
        guard disk == 0, centralDisk == 0, entriesOnDisk == entries16 else {
            throw ArchiveBrowserError.invalidArchive("многотомные ZIP не поддерживаются")
        }

        var count = UInt64(entries16)
        var directorySize = UInt64(directorySize32)
        var directoryOffset = UInt64(directoryOffset32)
        if entries16 == UInt16.max || directorySize32 == UInt32.max || directoryOffset32 == UInt32.max {
            let locatorIndex = eocdIndex - 20
            guard locatorIndex >= 0, u32(bytes, locatorIndex) == 0x07064b50,
                  u32(bytes, locatorIndex + 4) == 0,
                  u32(bytes, locatorIndex + 16) == 1 else {
                throw ArchiveBrowserError.invalidArchive("неверный ZIP64 locator")
            }
            let zip64Offset = u64(bytes, locatorIndex + 8)
            guard zip64Offset <= fileSize, fileSize - zip64Offset >= 56 else {
                throw ArchiveBrowserError.invalidArchive("ZIP64 directory выходит за границы файла")
            }
            try handle.seek(toOffset: zip64Offset)
            guard let record = try handle.read(upToCount: 56), record.count == 56 else {
                throw ArchiveBrowserError.invalidArchive("не удалось прочитать ZIP64 directory")
            }
            let z = [UInt8](record)
            guard u32(z, 0) == 0x06064b50, u32(z, 16) == 0, u32(z, 20) == 0,
                  u64(z, 24) == u64(z, 32) else {
                throw ArchiveBrowserError.invalidArchive("многотомный или повреждённый ZIP64")
            }
            count = u64(z, 32)
            directorySize = u64(z, 40)
            directoryOffset = u64(z, 48)
        }
        guard count <= UInt64(maximumEntryCount) else { throw ArchiveBrowserError.tooManyEntries }
        guard directorySize <= maximumCentralDirectorySize,
              directoryOffset <= fileSize,
              directorySize <= fileSize - directoryOffset else { throw ArchiveBrowserError.archiveTooLarge }
    }

    private static func findEOCD(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        for index in stride(from: bytes.count - 22, through: max(0, bytes.count - 22 - 65_535), by: -1) {
            guard u32(bytes, index) == 0x06054b50 else { continue }
            let commentLength = Int(u16(bytes, index + 20))
            if index + 22 + commentLength == bytes.count { return index }
        }
        return nil
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }
    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(u16(bytes, offset)) | (UInt32(u16(bytes, offset + 2)) << 16)
    }
    private static func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(u32(bytes, offset)) | (UInt64(u32(bytes, offset + 4)) << 32)
    }
}
