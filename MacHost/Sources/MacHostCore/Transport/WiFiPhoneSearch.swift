import Foundation

/// An address is a route to a phone, never its identity. Keep the advertised port with it.
public struct WiFiEndpoint: Hashable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = ConnectionHostAddress.normalized(host)
        self.port = port
    }
}

public struct WiFiSearchCandidate: Sendable {
    public let endpoint: WiFiEndpoint
    public let isBonjour: Bool

    public init(endpoint: WiFiEndpoint, isBonjour: Bool = false) {
        self.endpoint = endpoint
        self.isBonjour = isBonjour
    }
}

public enum WiFiProbeResult: Sendable {
    case paired(pinKey: String, name: String)
    case unpaired
    case unavailable
}

/// Shared search policy, with injectable I/O so wake-up, DHCP and late Bonjour are reproducible.
public enum WiFiPhoneSearch {
    public static func search(
        deep: Bool,
        preferredDeviceId: String? = nil,
        discoveryWaitSeconds: Double = 6,
        retryIntervalNanoseconds: UInt64 = 250_000_000,
        candidates: @Sendable () async -> [WiFiSearchCandidate],
        fallbackCandidates: @Sendable () async -> [WiFiSearchCandidate],
        probe: @escaping @Sendable (WiFiSearchCandidate) async -> WiFiProbeResult
    ) async -> LanPhoneSearchResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(0, discoveryWaitSeconds)))
        var fallback: [WiFiSearchCandidate] = []
        var scannedFallback = false
        var unpaired = Set<WiFiEndpoint>()
        var otherPaired: LanPhoneSearchResult?

        repeat {
            guard !Task.isCancelled else { return .notFound }
            // Take a fresh snapshot every pass: an address checked before wake-up must be retried.
            let current = await candidates()
            var seen = Set<WiFiEndpoint>()
            let ordered = (current + fallback).filter { seen.insert($0.endpoint).inserted }
            let results = await probeCandidates(ordered, probe: probe)
            guard !Task.isCancelled else { return .notFound }
            unpaired.removeAll()
            otherPaired = nil
            for (candidate, result) in zip(ordered, results) {
                switch result {
                case .paired(let pinKey, let name):
                    let match = LanPhoneSearchResult.paired(
                        host: candidate.endpoint.host, port: candidate.endpoint.port, pinKey: pinKey, name: name
                    )
                    if preferredDeviceId == nil || preferredDeviceId == pinKey { return match }
                    if otherPaired == nil { otherPaired = match }
                case .unpaired:
                    // An arbitrary open port/SSH server on the LAN is not a MacDroid phone.
                    if candidate.isBonjour { unpaired.insert(candidate.endpoint) }
                case .unavailable:
                    break
                }
            }
            guard deep else { break }
            if !scannedFallback {
                fallback = await fallbackCandidates()
                scannedFallback = true
                // Always inspect the scan result, even if the scan consumed the discovery budget.
                continue
            }
            guard clock.now < deadline else { break }
            do { try await Task.sleep(nanoseconds: retryIntervalNanoseconds) }
            catch { return .notFound }
        } while !Task.isCancelled

        guard !Task.isCancelled else { return .notFound }
        if let otherPaired { return otherPaired }
        let hosts = unpaired.sorted {
            $0.host == $1.host ? $0.port < $1.port : $0.host < $1.host
        }.map { $0.port == 2222 ? $0.host : "\($0.host):\($0.port)" }
        return hosts.isEmpty ? .notFound : .unpaired(hosts: hosts)
    }

    private static func probeCandidates(
        _ candidates: [WiFiSearchCandidate],
        probe: @escaping @Sendable (WiFiSearchCandidate) async -> WiFiProbeResult
    ) async -> [WiFiProbeResult] {
        var results = Array(repeating: WiFiProbeResult.unavailable, count: candidates.count)
        // Limit concurrent ssh-keyscan processes. Results retain candidate priority, not completion order.
        await withTaskGroup(of: (Int, WiFiProbeResult).self) { group in
            var next = 0
            while next < min(4, candidates.count), !Task.isCancelled {
                let index = next
                group.addTask { (index, await probe(candidates[index])) }
                next += 1
            }
            for await (index, result) in group {
                results[index] = result
                if Task.isCancelled { group.cancelAll(); continue }
                if next < candidates.count {
                    let index = next
                    group.addTask { (index, await probe(candidates[index])) }
                    next += 1
                }
            }
        }
        return results
    }
}
