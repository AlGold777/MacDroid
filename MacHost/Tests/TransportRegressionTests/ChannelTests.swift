import Foundation
import MacHostCore

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
        try await tests.testSuccessfulVersionResponse()
        print("PASS: handshake timeout, request cancellation, request timeout, VERSION response")
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
}
