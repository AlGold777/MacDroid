import Foundation

/// Holds an SSH process and its pipes while callers perform blocking I/O.
/// Termination drops the holder's references after stopping the child; active
/// readers and writers retain their own handles until their operation returns.
public final class SSHProcessHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var inHandle: FileHandle?
    private var outHandle: FileHandle?

    public init() {}

    public func set(process: Process, inHandle: FileHandle, outHandle: FileHandle) {
        lock.lock()
        defer { lock.unlock() }
        self.process = process
        self.inHandle = inHandle
        self.outHandle = outHandle
    }

    public func terminateImmediately() {
        lock.lock()
        let process = self.process
        self.process = nil
        inHandle = nil
        outHandle = nil
        lock.unlock()

        if let process, process.isRunning {
            process.terminate()
        }
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true
    }

    public func writeData(_ data: Data) throws {
        lock.lock()
        guard let handle = inHandle, let process, process.isRunning else {
            lock.unlock()
            throw NSError(domain: "SSHProcessHolder", code: 1, userInfo: [NSLocalizedDescriptionKey: "SSH process is not running"])
        }
        lock.unlock()
        try handle.write(contentsOf: data)
    }

    public func readExact(count: Int) throws -> Data {
        guard count >= 0 else {
            throw NSError(domain: "SSHProcessHolder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid read length"])
        }
        var accumulated = Data()
        accumulated.reserveCapacity(count)
        while accumulated.count < count {
            lock.lock()
            guard let handle = outHandle, let process, process.isRunning else {
                lock.unlock()
                throw NSError(domain: "SSHProcessHolder", code: 1, userInfo: [NSLocalizedDescriptionKey: "SSH process is not running"])
            }
            lock.unlock()

            let needed = count - accumulated.count
            guard let chunk = try handle.read(upToCount: needed), !chunk.isEmpty else {
                throw NSError(domain: "SSHProcessHolder", code: 3, userInfo: [NSLocalizedDescriptionKey: "SSH process closed its output"])
            }
            accumulated.append(chunk)
        }
        return accumulated
    }
}
