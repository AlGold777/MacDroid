import Foundation
import MacHostCore

private final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var message: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func XCTFail(_ message: String) { fatalError(message) }
func XCTAssertTrue(_ value: Bool) { precondition(value) }
func XCTAssertEqual(_ a: Int, _ b: Int) { precondition(a == b) }

@main
struct ChannelTests {
    static func main() async throws {
        // Independent watchdog makes a leaked continuation fail rather than hang CI.
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { fatalError("Transport regression timed out") }
        let tests = ChannelTests()
        try await tests.testInitTimeoutClosesStalledChannel()
        try await tests.testCancelledRequestCompletesWithoutPeerReply()
        try await tests.testRequestTimeoutCompletesWithoutReply()
        try await tests.testSecondConsecutiveTimeoutClosesChannel()
        try await tests.testPrematureEOFIncludesSSHStderrAndExitCode()
        try await tests.testSuccessfulVersionResponse()
        try tests.testPacketReaderDataSliceIndexing()
        try tests.testExtendedAttributesParsing()
        try await tests.testChannelDesyncThresholdClosesChannel()
        print("PASS: handshake timeout, request cancellation, consecutive timeouts, SSH EOF diagnostics, VERSION response, slice indexing, extended attrs, desync threshold")
    }

    func testSuccessfulVersionResponse() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let channel = SFTPChannel(channelId: "version", isInteractive: true, process: process,
                                  inHandle: input.fileHandleForWriting, outHandle: output.fileHandleForReading)
        defer { channel.close() }
        // Echo a valid server VERSION frame through a real process pipe.
        let response = try await channel.sendInitPacket(packet: Data([0,0,0,5,2,0,0,0,3]), timeoutSeconds: 1)
        precondition(response.type == .version)
        precondition(response.payload == Data([0,0,0,3]))
    }
    // A live process with pipes but no SFTP replies simulates a stalled peer.
    private func stalledChannel() throws -> SFTPChannel {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["20"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        return SFTPChannel(channelId: UUID().uuidString, isInteractive: true,
                           process: process, inHandle: input.fileHandleForWriting,
                           outHandle: output.fileHandleForReading)
    }

    func testInitTimeoutClosesStalledChannel() async throws {
        let channel = try stalledChannel()
        defer { channel.close() }
        do {
            _ = try await channel.sendInitPacket(packet: SFTPPacketEngine().createInitPacket(), timeoutSeconds: 0.05)
            XCTFail("Silent peer must time out")
        } catch { XCTAssertEqual((error as NSError).code, 10) }
    }

    func testCancelledRequestCompletesWithoutPeerReply() async throws {
        let channel = try stalledChannel()
        defer { channel.close() }
        let task = Task {
            do {
                _ = try await channel.sendRequest(packet: Data([0]), requestId: channel.allocateRequestId())
                XCTFail("Cancelled request cannot succeed")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        await task.value
    }

    func testRequestTimeoutCompletesWithoutReply() async throws {
        let channel = try stalledChannel()
        defer { channel.close() }
        do {
            _ = try await channel.sendRequest(packet: Data([0]), requestId: channel.allocateRequestId(), timeoutSeconds: 0.05)
            XCTFail("Silent peer must time out")
        } catch { XCTAssertEqual((error as NSError).code, 11) }
    }

    func testSecondConsecutiveTimeoutClosesChannel() async throws {
        let channel = try stalledChannel()
        defer { channel.close() }
        for _ in 0..<2 {
            do {
                _ = try await channel.sendRequest(packet: Data([0]), requestId: channel.allocateRequestId(), timeoutSeconds: 0.05)
                XCTFail("Silent peer must time out")
            } catch { XCTAssertEqual((error as NSError).code, 11) }
        }
        XCTAssertTrue(!channel.isRunning)
    }

    func testPrematureEOFIncludesSSHStderrAndExitCode() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 'Permission denied (publickey).\\n' >&2; exit 255"]
        let input = Pipe(), output = Pipe(), errorOutput = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput

        let drained = DispatchGroup()
        drained.enter()
        let buffer = StderrBuffer()
        DispatchQueue.global(qos: .utility).async {
            defer { drained.leave() }
            while let chunk = try? errorOutput.fileHandleForReading.read(upToCount: 1024), !chunk.isEmpty {
                buffer.append(chunk)
            }
        }
        try process.run()

        let channel = SFTPChannel(
            channelId: "ssh-eof-diagnostics",
            isInteractive: true,
            process: process,
            inHandle: input.fileHandleForWriting,
            outHandle: output.fileHandleForReading,
            diagnosticMessage: { buffer.message },
            waitForDiagnostics: { timeout in
                _ = drained.wait(timeout: .now() + timeout)
                return buffer.message
            }
        )
        defer { channel.close() }

        do {
            _ = try await channel.sendInitPacket(packet: SFTPPacketEngine().createInitPacket(), timeoutSeconds: 1)
            XCTFail("A process that exits before VERSION must fail initialization")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("255") && message.contains("Permission denied"))
        }
    }

    func testPacketReaderDataSliceIndexing() throws {
        var full = Data([0xFF, 0xFE, 0xFD]) // 3 bytes prefix
        full.append(contentsOf: [0x42]) // readUInt8 -> 0x42
        // UInt32 = 4 (length of string "test")
        full.append(contentsOf: [0, 0, 0, 4])
        full.append(contentsOf: "test".utf8)
        // UInt32 = 3 (length of data [1, 2, 3])
        full.append(contentsOf: [0, 0, 0, 3])
        full.append(contentsOf: [1, 2, 3])
        
        let slice = full.dropFirst(3)
        precondition(slice.startIndex == 3)
        
        let reader = SFTPPacketReader(data: slice)
        let byte = try reader.readUInt8()
        XCTAssertEqual(Int(byte), 0x42)
        
        let (str, raw) = try reader.readStringWithRaw()
        XCTAssertTrue(str == "test")
        XCTAssertEqual(raw.count, 4)
        
        let data = try reader.readData()
        XCTAssertEqual(data.count, 3)
        XCTAssertEqual(Int(data[0]), 1)
    }

    func testExtendedAttributesParsing() throws {
        let engine = SFTPPacketEngine()
        let writer = SFTPPacketWriter()
        writer.appendUInt32(42) // reqId
        // flags: size (0x1) + mtime (0x8) + extended (0x80000000) = 0x80000009
        writer.appendUInt32(0x80000009)
        writer.appendUInt64(1024) // size
        writer.appendUInt32(100) // atime
        writer.appendUInt32(200) // mtime
        writer.appendUInt32(1) // 1 extended pair
        writer.appendString("vendor@attr")
        writer.appendString("custom_value")
        
        let attrsPayload = Data(writer.buildPacket(type: .attrs).dropFirst(5))
        let (reqId, size, mtime, isDir) = try engine.parseAttrsResponse(data: attrsPayload)
        XCTAssertEqual(Int(reqId), 42)
        XCTAssertEqual(Int(size), 1024)
        XCTAssertEqual(Int(mtime), 200)
        XCTAssertTrue(!isDir)
        
        // Name response with extended attribute
        let nameWriter = SFTPPacketWriter()
        nameWriter.appendUInt32(99) // reqId
        nameWriter.appendUInt32(1) // 1 entry
        nameWriter.appendString("file.txt")
        nameWriter.appendString("-rw-r--r-- 1 root root 1024 Jan 1 00:00 file.txt")
        nameWriter.appendUInt32(0x80000009) // flags: size + mtime + extended
        nameWriter.appendUInt64(1024)
        nameWriter.appendUInt32(100)
        nameWriter.appendUInt32(200)
        nameWriter.appendUInt32(1) // 1 extended pair
        nameWriter.appendString("vendor@attr")
        nameWriter.appendString("custom_val")
        
        let namePayload = Data(nameWriter.buildPacket(type: .name).dropFirst(5))
        let entries = try engine.parseNameResponse(data: namePayload)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].filename == "file.txt")
        XCTAssertEqual(Int(entries[0].size), 1024)
        XCTAssertTrue(entries[0].rawFilename == Data("file.txt".utf8))
    }

    func testChannelDesyncThresholdClosesChannel() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let channel = SFTPChannel(channelId: "desync", isInteractive: true, process: process,
                                  inHandle: input.fileHandleForWriting, outHandle: output.fileHandleForReading)
        defer { channel.close() }
        
        var statusPacket = Data([0, 0, 0, 9, 101])
        var reqId: UInt32 = UInt32(999_999).bigEndian
        var statusCode: UInt32 = UInt32(0).bigEndian
        withUnsafeBytes(of: &reqId) { statusPacket.append(contentsOf: $0) }
        withUnsafeBytes(of: &statusCode) { statusPacket.append(contentsOf: $0) }
        
        for _ in 0..<SFTPChannel.maxUnknownResponses {
            try input.fileHandleForWriting.write(contentsOf: statusPacket)
        }
        
        let start = ProcessInfo.processInfo.systemUptime
        while channel.isRunning && ProcessInfo.processInfo.systemUptime - start < 1.0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(!channel.isRunning)
    }
}
