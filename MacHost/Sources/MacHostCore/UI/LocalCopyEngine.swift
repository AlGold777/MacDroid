import Foundation
import Darwin

/// Быстрое локальное копирование через copyfile(3) с клонированием APFS (как в Finder).
/// Все методы синхронные и не привязаны к главному актору: вызывать из Task.detached.
public final class LocalCopyCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    public func cancel() { lock.lock(); value = true; lock.unlock() }
}

public struct LocalCopyError: LocalizedError {
    public let path: String
    public let code: Int32
    public var errorDescription: String? {
        "\(String(cString: strerror(code))) (\(path))"
    }
}

public enum LocalCopyEngine {
    /// Подсчёт объектов и байтов в дереве (без перехода по симлинкам).
    public static func measure(path: String) -> (objects: Int, bytes: UInt64) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return (1, 0) }
        if (st.st_mode & S_IFMT) != S_IFDIR { return (1, UInt64(max(0, st.st_size))) }
        var objects = 1
        var bytes: UInt64 = 0
        if let en = FileManager.default.enumerator(atPath: path) {
            for case let rel as String in en {
                objects += 1
                var s = stat()
                if lstat(path + "/" + rel, &s) == 0, (s.st_mode & S_IFMT) != S_IFDIR {
                    bytes += UInt64(max(0, s.st_size))
                }
            }
        }
        return (objects, bytes)
    }

    /// Копирует файл/симлинк/папку. Сначала клон (мгновенно на APFS), иначе обход дерева с copyfile.
    /// `progress` получает накопленное число байтов этого объекта.
    public static func copy(
        from src: String,
        to dst: String,
        cancel: LocalCopyCancelFlag,
        allowClone: Bool = true,
        progress: @escaping (UInt64) -> Void
    ) throws {
        var st = stat()
        guard lstat(src, &st) == 0 else { throw LocalCopyError(path: src, code: errno) }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR

        if isDir {
            // Клон всей папки одним вызовом (CLONE_NOFOLLOW = 1: симлинки остаются симлинками)
            let measured = measure(path: src)
            if allowClone, clonefile(src, dst, 1) == 0 {
                progress(measured.bytes)
                return
            }
            if cancel.isCancelled { throw CancellationError() }
            // Клон не удался (другой том / не APFS): рекурсивное копирование
            var done: UInt64 = 0
            try makeDir(src: src, dst: dst)
            guard let en = FileManager.default.enumerator(atPath: src) else { return }
            for case let rel as String in en {
                if cancel.isCancelled { throw CancellationError() }
                let s = src + "/" + rel
                let d = dst + "/" + rel
                var es = stat()
                guard lstat(s, &es) == 0 else { throw LocalCopyError(path: s, code: errno) }
                if (es.st_mode & S_IFMT) == S_IFDIR {
                    try makeDir(src: s, dst: d)
                } else {
                    let base = done
                    try copyOne(src: s, dst: d, cancel: cancel, allowClone: allowClone) { progress(base + $0) }
                    done += UInt64(max(0, es.st_size))
                    progress(done)
                }
            }
        } else {
            try copyOne(src: src, dst: dst, cancel: cancel, allowClone: allowClone, progress: progress)
        }
    }

    /// Сбрасывает теги у всех вложенных объектов копии.
    public static func clearTagsRecursively(at path: String) {
        guard let en = FileManager.default.enumerator(atPath: path) else { return }
        for case let rel as String in en {
            TagsManager.shared.clearTags(at: path + "/" + rel, source: .localMac)
        }
    }

    private static func makeDir(src: String, dst: String) throws {
        // Без RECURSIVE copyfile создаёт только саму папку с метаданными.
        if copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW)) != 0 {
            throw LocalCopyError(path: src, code: errno)
        }
    }

    private final class Ctx {
        let cancel: LocalCopyCancelFlag
        let progress: (UInt64) -> Void
        var lastReport: CFAbsoluteTime = 0
        init(cancel: LocalCopyCancelFlag, progress: @escaping (UInt64) -> Void) {
            self.cancel = cancel; self.progress = progress
        }
    }

    private static func copyOne(
        src: String, dst: String,
        cancel: LocalCopyCancelFlag,
        allowClone: Bool,
        progress: @escaping (UInt64) -> Void
    ) throws {
        guard let state = copyfile_state_alloc() else { throw LocalCopyError(path: src, code: ENOMEM) }
        defer { copyfile_state_free(state) }

        let ctx = Ctx(cancel: cancel, progress: progress)
        let ctxPtr = Unmanaged.passUnretained(ctx).toOpaque()
        let cb: copyfile_callback_t = { what, stage, st, _, _, c in
            guard let c = c else { return Int32(COPYFILE_CONTINUE) }
            let ctx = Unmanaged<Ctx>.fromOpaque(c).takeUnretainedValue()
            if ctx.cancel.isCancelled { return Int32(COPYFILE_QUIT) }
            if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
                let now = CFAbsoluteTimeGetCurrent()
                if now - ctx.lastReport >= 0.05 {
                    ctx.lastReport = now
                    var copied: off_t = 0
                    if let st = st, copyfile_state_get(st, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
                        ctx.progress(UInt64(max(0, copied)))
                    }
                }
            } else if stage == COPYFILE_ERR {
                return Int32(COPYFILE_QUIT)
            }
            return Int32(COPYFILE_CONTINUE)
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(cb, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), ctxPtr)

        let rc = withExtendedLifetime(ctx) {
            copyfile(src, dst, state, copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW | (allowClone ? COPYFILE_CLONE : 0)))
        }
        if rc != 0 {
            let e = errno
            if cancel.isCancelled { throw CancellationError() }
            throw LocalCopyError(path: src, code: e)
        }
    }
}
