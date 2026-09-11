import Foundation
import Network
import CryptoKit

public actor SSHControlClient {
    private var connection: NWConnection?
    private let host: String
    private let port: UInt16
    
    public init(host: String = "127.0.0.1", port: UInt16 = 2222) {
        self.host = host
        self.port = port
    }
    
    public func connect() async throws {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port) ?? 2222
        let conn = NWConnection(host: nwHost, port: nwPort, using: .tcp)
        self.connection = conn
        
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = ManagedAtomicBool(false)
            
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.compareAndSet(expected: false, new: true) {
                        continuation.resume()
                    }
                case .failed(let error):
                    if resumed.compareAndSet(expected: false, new: true) {
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if resumed.compareAndSet(expected: false, new: true) {
                        continuation.resume(throwing: NSError(domain: "SSHControlClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Connection cancelled"]))
                    }
                default:
                    break
                }
            }
            conn.start(queue: .global())
        }
    }
    
    public func sendControlCommand(cmd: String, payload: [String: Any]) async throws -> [String: Any] {
        guard let conn = self.connection else {
            throw NSError(domain: "SSHControlClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not connected to Android Daemon"])
        }
        
        var requestDict = payload
        requestDict["cmd"] = cmd
        let data = try JSONSerialization.data(withJSONObject: requestDict)
        
        var length = UInt32(data.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(data)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: packet, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
        
        let lengthData = try await readExact(bytes: 4)
        let responseLength = Int(lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        let responseData = try await readExact(bytes: responseLength)
        
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw NSError(domain: "SSHControlClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response"])
        }
        return json
    }
    
    private func readExact(bytes: Int) async throws -> Data {
        guard let conn = self.connection else {
            throw NSError(domain: "SSHControlClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "No connection"])
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            conn.receive(minimumIncompleteLength: bytes, maximumLength: bytes) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: NSError(domain: "SSHControlClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "Stream closed unexpectedly"]))
                }
            }
        }
    }
    
    public func disconnect() {
        connection?.cancel()
        connection = nil
    }
}

private final class ManagedAtomicBool: @unchecked Sendable {
    private var val: Bool
    private let lock = NSLock()
    
    init(_ val: Bool) {
        self.val = val
    }
    
    func compareAndSet(expected: Bool, new: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if val == expected {
            val = new
            return true
        }
        return false
    }
}
