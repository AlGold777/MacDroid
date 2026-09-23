import Foundation
import Network

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
        // Разрешаем dual-stack (IPv4 и IPv6) без принудительного ограничения
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
                    case .ipv6(let ip6):
                        // Для IPv6 link-local интерфейс (%en0) обязателен для BSD сокетов и OpenSSH
                        if let iface = ip6.interface?.name, !resolvedIp.contains("%") {
                            resolvedIp = "\(ip6)%\(iface)"
                        } else {
                            resolvedIp = "\(ip6)"
                        }
                    case .name(let hostName, _):
                        resolvedIp = hostName
                    @unknown default:
                        break
                    }
                    resolvedPort = Int(port.rawValue)
                }
                
                conn.cancel()
                
                if !resolvedIp.isEmpty {
                    let dev = DiscoveredDevice(
                        id: serviceId,
                        name: name,
                        host: resolvedIp,
                        port: resolvedPort
                    )
                    PhoneConnectionManager.shared.registerDevice(host: resolvedIp, name: name)
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.resolvingConnections.removeAll { $0 === conn }
                        self.pendingServiceIds.remove(serviceId)
                        guard self.activeServiceIds.contains(serviceId) else { return }
                        self.resolvedServiceIds.insert(serviceId)
                        if let idx = self.discoveredDevices.firstIndex(where: { $0.id == dev.id || $0.name == dev.name }) {
                            self.discoveredDevices[idx] = dev
                        } else {
                            self.discoveredDevices.append(dev)
                        }
                        self.isSearching = false
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
