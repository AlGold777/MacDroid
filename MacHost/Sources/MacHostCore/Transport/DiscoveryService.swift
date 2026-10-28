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
    
    /// Появился новый Bonjour-сервис или сменился адрес/порт у известного. Без userInfo.
    public static let routeAppearedNotification = Notification.Name("MacHost.DiscoveryService.routeAppeared")

    @Published public var discoveredDevices: [DiscoveredDevice] = []
    @Published public var isSearching: Bool = false
    
    private var browser: NWBrowser?
    private var searchTimer: Task<Void, Never>?
    private var discoveryGeneration: UInt64 = 0
    private var resolvingConnections: [UUID: NWConnection] = [:]
    private var pendingServiceResolutions: [String: UUID] = [:]
    private var activeServiceIds: Set<String> = []

    private final class BonjourResolveContext: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var hostName: String?
        var port: Int?
    }
    
    public init() {}
    
    public func startDiscovery() {
        guard browser == nil else { return }
        beginDiscovery()
    }
    
    public func refresh() {
        // PHONE запрашивает свежие адреса. Старые callbacks не должны менять новый поиск.
        stopDiscovery()
        beginDiscovery()
    }

    private func beginDiscovery() {
        discoveryGeneration &+= 1
        let generation = discoveryGeneration
        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_macphone_sftp._tcp", domain: "local.")
        let newBrowser = NWBrowser(for: descriptor, using: params)
        self.browser = newBrowser
        isSearching = true
        scheduleSearchTimeout(generation: generation)

        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.discoveryGeneration == generation else { return }
                switch state {
                case .failed, .cancelled:
                    self.stopDiscovery()
                default:
                    break
                }
            }
        }
        
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self, self.discoveryGeneration == generation else { return }
                self.updateBrowseResults(results, generation: generation)
            }
        }
        
        newBrowser.start(queue: .main)
    }
    
    private func scheduleSearchTimeout(generation: UInt64) {
        searchTimer?.cancel()
        searchTimer = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 6_000_000_000)
            } catch { return }
            guard let self, self.discoveryGeneration == generation else { return }
            self.isSearching = false
        }
    }
    
    private func updateBrowseResults(_ results: Set<NWBrowser.Result>, generation: UInt64) {
        let services = results.compactMap { result -> (NWEndpoint, String, String)? in
            guard case .service(let name, let type, let domain, _) = result.endpoint else { return nil }
            let serviceId = "\(name).\(type)\(domain)"
            return (result.endpoint, name, serviceId)
        }
        let currentIds = Set(services.map { $0.2 })
        activeServiceIds = currentIds
        let removed = pendingServiceResolutions.filter { !currentIds.contains($0.key) }
        for (serviceId, resolutionId) in removed {
            pendingServiceResolutions.removeValue(forKey: serviceId)
            resolvingConnections.removeValue(forKey: resolutionId)?.cancel()
        }
        discoveredDevices.removeAll { !$0.isManual && !currentIds.contains($0.id) }
        publishDiscoveredDevices()

        // W14: адрес мог смениться после DHCP-обновления без смены имени сервиса,
        // поэтому каждое изменение browse-результатов перерезолвит все текущие сервисы.
        for (endpoint, name, serviceId) in services
        where pendingServiceResolutions[serviceId] == nil {
            let resolutionId = UUID()
            pendingServiceResolutions[serviceId] = resolutionId
            resolveServiceEndpoint(endpoint, name: name, serviceId: serviceId, resolutionId: resolutionId, generation: generation)
        }
    }

    /// Настоящий Bonjour/mDNS резолвинг IP-адреса устройства из сетевого пакета
    private func resolveServiceEndpoint(_ endpoint: NWEndpoint, name: String, serviceId: String, resolutionId: UUID, generation: UInt64) {
        let params = NWParameters.tcp
        let conn = NWConnection(to: endpoint, using: params)
        resolvingConnections[resolutionId] = conn
        
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
                
                // TCP выполнил свою работу. Pending остаётся до окончания DNS fallback;
                // .cancelled этого сокета не должен разрешать вторую параллельную попытку.
                conn.stateUpdateHandler = nil
                conn.cancel()

                if ConnectionHostAddress.isIPv4(resolvedIp) {
                    Task { @MainActor [weak self] in
                        self?.finishServiceResolution(
                            serviceId: serviceId,
                            name: name,
                            host: resolvedIp,
                            port: resolvedPort,
                            resolutionId: resolutionId,
                            generation: generation
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
                                resolutionId: resolutionId,
                                generation: generation
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
                            resolutionId: resolutionId,
                            generation: generation
                        )
                    }
                }
                
            case .failed, .cancelled:
                conn.stateUpdateHandler = nil
                conn.cancel()
                Task { @MainActor [weak self] in
                    guard let self, self.discoveryGeneration == generation,
                          self.pendingServiceResolutions[serviceId] == resolutionId else { return }
                    self.pendingServiceResolutions.removeValue(forKey: serviceId)
                    self.resolvingConnections.removeValue(forKey: resolutionId)
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

    private func finishServiceResolution(serviceId: String, name: String, host: String?, port: Int, resolutionId: UUID, generation: UInt64) {
        guard discoveryGeneration == generation,
              pendingServiceResolutions[serviceId] == resolutionId else { return }
        resolvingConnections.removeValue(forKey: resolutionId)
        pendingServiceResolutions.removeValue(forKey: serviceId)
        guard activeServiceIds.contains(serviceId),
              let host,
              ConnectionHostAddress.isIPv4(host) else { return }

        let device = DiscoveredDevice(id: serviceId, name: name, host: host, port: port)
        let previous = discoveredDevices.first(where: { $0.id == device.id })
        if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[index] = device
        } else {
            discoveredDevices.append(device)
        }
        publishDiscoveredDevices()
        // Новый сервис или новый адрес/порт: маршрут к телефону появился, пауза автоподключения можно снять
        if previous == nil || previous?.host != host || previous?.port != port {
            NotificationCenter.default.post(name: Self.routeAppearedNotification, object: self)
        }
    }

    private func publishDiscoveredDevices() {
        PhoneConnectionManager.shared.replaceDiscoveredDevices(discoveredDevices.filter { !$0.isManual })
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

        // W15: getaddrinfo без собственного таймаута — выполняем с ограничением по времени.
        guard let address = Self.lookupIPv4WithTimeout(hostName, timeout: 2.0) else { return nil }
        return (address, port)
    }

    /// Фоновый getaddrinfo с ограничением по времени. Зависший вызов дорабатывает в фоне,
    /// но не блокирует поток обнаружения.
    nonisolated private static func lookupIPv4WithTimeout(_ hostName: String, timeout: TimeInterval) -> String? {
        final class ResultBox: @unchecked Sendable {
            var address: String?
        }
        let box = ResultBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.address = lookupIPv4(hostName)
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.address
    }

    nonisolated private static func lookupIPv4(_ hostName: String) -> String? {
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
        return String(cString: addressBuffer)
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
        discoveryGeneration &+= 1
        searchTimer?.cancel()
        searchTimer = nil
        for conn in resolvingConnections.values {
            conn.cancel()
        }
        resolvingConnections.removeAll()
        pendingServiceResolutions.removeAll()
        activeServiceIds.removeAll()
        browser?.cancel()
        browser = nil
        discoveredDevices.removeAll { !$0.isManual }
        publishDiscoveredDevices()
        isSearching = false
    }
}
