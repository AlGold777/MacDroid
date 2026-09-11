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

@MainActor
public final class DiscoveryService: ObservableObject {
    @Published public var discoveredDevices: [DiscoveredDevice] = []
    @Published public var isSearching: Bool = false
    
    private var browser: NWBrowser?
    
    public init() {}
    
    public func startDiscovery() {
        guard browser == nil else { return }
        
        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_macphone_sftp._tcp", domain: "local.")
        let newBrowser = NWBrowser(for: descriptor, using: params)
        self.browser = newBrowser
        
        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.isSearching = (state == .ready)
            }
        }
        
        newBrowser.browseResultsChangedHandler = { [weak self] results, changes in
            var devices: [DiscoveredDevice] = []
            for result in results {
                if case .service(let name, let type, let domain, _) = result.endpoint {
                    let defaultHost = UserDefaults.standard.string(forKey: "lastConnectedHost") ?? "192.168.1.18"
                    devices.append(DiscoveredDevice(
                        id: "\(name).\(type)\(domain)",
                        name: name,
                        host: defaultHost,
                        port: 2222
                    ))
                }
            }
            Task { @MainActor [weak self] in
                // Сохраняем добавленные вручную устройства
                let manuals = self?.discoveredDevices.filter { $0.isManual } ?? []
                self?.discoveredDevices = manuals + devices
            }
        }
        
        newBrowser.start(queue: .main)
    }
    
    public func addManualDevice(name: String, host: String, port: Int) {
        let manual = DiscoveredDevice(
            id: "manual_\(host)_\(port)",
            name: name.isEmpty ? "Xiaomi 14 Ultra (Прямой IP)" : name,
            host: host,
            port: port,
            isManual: true
        )
        if !discoveredDevices.contains(where: { $0.id == manual.id }) {
            discoveredDevices.append(manual)
        }
    }
    
    public func stopDiscovery() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }
}
