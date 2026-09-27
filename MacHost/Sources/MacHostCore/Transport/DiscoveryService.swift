import Foundation
import Network
import dnssd
import Darwin

public struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let host: String
    public let port: Int
    public let isManual: Bool
    
    public init(id: String, name: String, host: String, port: Int, isManual: Bool = false) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.isManual = isManual
    }
}

public enum ConnectionHostAddress {
    /// Removes malformed repeated IPv6 scope suffixes while preserving a single interface zone.
    public static func normalized(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "%", omittingEmptySubsequences: true)
        guard parts.count > 1 else { return trimmed }
        return "\(parts[0])%\(parts[1])"
    }

    public static func isIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard !octet.isEmpty,
                  octet.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
                  let value = Int(octet) else { return false }
            return (0...255).contains(value)
        }
    }
}

public struct SavedConnection: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(host):\(port)" }
    public let name: String
    public let host: String
    public let port: Int
    public let date: Date
    
    public init(name: String, host: String, port: Int, date: Date = Date()) {
        self.name = name
        self.host = host
        self.port = port
        self.date = date
    }
}

@MainActor
public final class DiscoveryService: ObservableObject {
    public static let shared = DiscoveryService()
    
    @Published public var discoveredDevices: [DiscoveredDevice] = []
    @Published public var isSearching: Bool = false
    
    private var browser: NWBrowser?
    private var searchTimer: Task<Void, Never>?
    private var resolvingConnections: [NWConnection] = []
    private var pendingServiceIds: Set<String> = []
    private var resolvedServiceIds: Set<String> = []
    private var activeServiceIds: Set<String> = []

    private final class BonjourResolveContext: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var hostName: String?
        var port: Int?
    }
    
    public init() {}
    
    public func startDiscovery() {
        if browser != nil {
            refresh()
            return
        }
        
        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_macphone_sftp._tcp", domain: "local.")
        let newBrowser = NWBrowser(for: descriptor, using: params)
        self.browser = newBrowser
        
        isSearching = true
        scheduleSearchTimeout()
        
        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .failed, .cancelled:
                    self?.isSearching = false
                default:
                    break
                }
            }
        }
        
        newBrowser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.updateBrowseResults(results)
            }
        }
        
        newBrowser.start(queue: .main)
    }
    
    public func refresh() {
        isSearching = true
        scheduleSearchTimeout()
        
        // Перезапуск браузера для принудительного mDNS запроса в локальную сеть
        browser?.cancel()
        browser = nil
        resolvingConnections.forEach { $0.cancel() }
        resolvingConnections.removeAll()
        pendingServiceIds.removeAll()
        resolvedServiceIds.removeAll()
        activeServiceIds.removeAll()
        
        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_macphone_sftp._tcp", domain: "local.")
        let newBrowser = NWBrowser(for: descriptor, using: params)
        self.browser = newBrowser
        
        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .failed, .cancelled:
                    self?.isSearching = false
                default:
                    break
                }
            }
        }
        
        newBrowser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.updateBrowseResults(results)
            }
        }
        
        newBrowser.start(queue: .main)
    }
    
    private func scheduleSearchTimeout() {
        searchTimer?.cancel()
        searchTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000) // 4 секунды активного поиска
            self?.isSearching = false
        }
    }
    
    private func updateBrowseResults(_ results: Set<NWBrowser.Result>) {
        let services = results.compactMap { result -> (NWEndpoint, String, String, String, String)? in
            guard case .service(let name, let type, let domain, _) = result.endpoint else { return nil }
            let serviceId = "\(name).\(type)\(domain)"
            return (result.endpoint, name, type, domain, serviceId)
        }
        let currentIds = Set(services.map { $0.4 })
        activeServiceIds = currentIds
        pendingServiceIds.formIntersection(currentIds)
        resolvedServiceIds.formIntersection(currentIds)
        discoveredDevices.removeAll { !$0.isManual && !currentIds.contains($0.id) }

        for (endpoint, name, type, domain, serviceId) in services
        where !pendingServiceIds.contains(serviceId) && !resolvedServiceIds.contains(serviceId) {
            pendingServiceIds.insert(serviceId)
            resolveServiceEndpoint(endpoint, name: name, type: type, domain: domain, serviceId: serviceId)
        }
    }

    /// Настоящий Bonjour/mDNS резолвинг IP-адреса устройства из сетевого пакета
    private func resolveServiceEndpoint(_ endpoint: NWEndpoint, name: String, type: String, domain: String, serviceId: String) {
        let params = NWParameters.tcp
        let conn = NWConnection(to: endpoint, using: params)
        resolvingConnections.append(conn)
        
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let conn = conn else { return }
            switch state {
            case .ready:
                var resolvedIp = ""
                var resolvedPort = 2222
                
                if let remote = conn.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = remote {
                    switch host {
                    case .ipv4(let ip4):
                        resolvedIp = "\(ip4)"
                    case .ipv6:
                        break
                    case .name(let hostName, _):
                        // Не используем имя узла в списке mDNS, где показывается только IPv4.
                        resolvedIp = hostName
                    @unknown default:
                        break
                    }
                    resolvedPort = Int(port.rawValue)
                }
                
                conn.cancel()

                if ConnectionHostAddress.isIPv4(resolvedIp) {
                    Task { @MainActor [weak self] in
                        self?.finishServiceResolution(
                            serviceId: serviceId,
                            name: name,
                            host: resolvedIp,
                            port: resolvedPort,
                            connection: conn
                        )
                    }
                } else if case .service(let serviceName, let serviceType, let serviceDomain, let interface) = endpoint {
                    let interfaceIndex = UInt32(interface?.index ?? 0)
                    let fallbackPort = resolvedPort
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        let address = Self.resolveBonjourIPv4(
                            serviceName: serviceName,
                            serviceType: serviceType,
                            serviceDomain: serviceDomain,
                            interfaceIndex: interfaceIndex
                        )
                        Task { @MainActor [weak self] in
                            self?.finishServiceResolution(
                                serviceId: serviceId,
                                name: name,
                                host: address?.host,
                                port: address?.port ?? fallbackPort,
                                connection: conn
                            )
                        }
                    }
                } else {
                    Task { @MainActor [weak self] in
                        self?.finishServiceResolution(
                            serviceId: serviceId,
                            name: name,
                            host: nil,
                            port: resolvedPort,
                            connection: conn
                        )
                    }
                }
                
            case .failed, .cancelled:
                conn.cancel()
                Task { @MainActor [weak self] in
                    self?.pendingServiceIds.remove(serviceId)
                    self?.resolvingConnections.removeAll { $0 === conn }
                }
                
            default:
                break
            }
        }
        
        // Таймаут на резолвинг каждого устройства (2.5 секунды)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { [weak conn] in
            if conn?.state != .cancelled {
                conn?.cancel()
            }
        }
        
        conn.start(queue: DispatchQueue.global(qos: .userInitiated))
    }

    private func finishServiceResolution(serviceId: String, name: String, host: String?, port: Int, connection: NWConnection) {
        resolvingConnections.removeAll { $0 === connection }
        pendingServiceIds.remove(serviceId)
        guard activeServiceIds.contains(serviceId),
              let host,
              ConnectionHostAddress.isIPv4(host) else { return }

        let device = DiscoveredDevice(id: serviceId, name: name, host: host, port: port)
        PhoneConnectionManager.shared.registerDevice(host: host, name: name)
        resolvedServiceIds.insert(serviceId)
        if let index = discoveredDevices.firstIndex(where: { $0.id == device.id || $0.name == device.name }) {
            discoveredDevices[index] = device
        } else {
            discoveredDevices.append(device)
        }
        isSearching = false
    }

    nonisolated private static func resolveBonjourIPv4(
        serviceName: String,
        serviceType: String,
        serviceDomain: String,
        interfaceIndex: UInt32
    ) -> (host: String, port: Int)? {
        let context = BonjourResolveContext()
        var serviceRef: DNSServiceRef?
        let status = DNSServiceResolve(
            &serviceRef,
            0,
            interfaceIndex,
            serviceName,
            serviceType,
            serviceDomain,
            { _, _, _, errorCode, _, hostTarget, networkPort, _, _, rawContext in
                guard let rawContext else { return }
                let context = Unmanaged<BonjourResolveContext>.fromOpaque(rawContext).takeUnretainedValue()
                if errorCode == kDNSServiceErr_NoError {
                    if let hostTarget { context.hostName = String(cString: hostTarget) }
                    context.port = Int(UInt16(bigEndian: networkPort))
                }
                context.semaphore.signal()
            },
            Unmanaged.passUnretained(context).toOpaque()
        )
        guard status == kDNSServiceErr_NoError, let serviceRef else { return nil }
        defer { DNSServiceRefDeallocate(serviceRef) }

        let queue = DispatchQueue.global(qos: .userInitiated)
        guard DNSServiceSetDispatchQueue(serviceRef, queue) == kDNSServiceErr_NoError,
              context.semaphore.wait(timeout: .now() + 2.5) == .success,
              let hostName = context.hostName,
              let port = context.port else { return nil }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostName, nil, &hints, &result) == 0,
              let result else { return nil }
        defer { freeaddrinfo(result) }

        guard let socketAddress = result.pointee.ai_addr else { return nil }
        var ipv4Address = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            $0.pointee.sin_addr
        }
        var addressBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &ipv4Address, &addressBuffer, socklen_t(addressBuffer.count)) != nil else {
            return nil
        }
        return (String(cString: addressBuffer), port)
    }
    
    public func addManualDevice(name: String, host: String, port: Int) {
        let manual = DiscoveredDevice(
            id: "manual_\(host)_\(port)",
            name: name.isEmpty ? "\(host):\(port)" : name,
            host: host,
            port: port,
            isManual: true
        )
        if !discoveredDevices.contains(where: { $0.id == manual.id }) {
            discoveredDevices.append(manual)
        }
    }
    
    public func stopDiscovery() {
        searchTimer?.cancel()
        searchTimer = nil
        for conn in resolvingConnections {
            conn.cancel()
        }
        resolvingConnections.removeAll()
        browser?.cancel()
        browser = nil
        isSearching = false
    }
}
