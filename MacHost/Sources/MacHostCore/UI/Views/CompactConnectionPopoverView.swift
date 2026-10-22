import SwiftUI

public struct CompactConnectionPopoverView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    
    @State private var inputHost: String = ""
    @State private var inputPort: String = "2222"
    
    private var historyPhones: [SavedConnection] {
        PairingModalView.loadInitialHistory()
    }
    
    private var allPhones: [SavedConnection] {
        var onlineList: [SavedConnection] = []
        var offlineList: [SavedConnection] = []
        var seen = Set<String>()
        
        for dev in vm.discoveryService.discoveredDevices {
            if ConnectionHostAddress.isIPv4(dev.host) {
                let normHost = ConnectionHostAddress.normalized(dev.host)
                let key = "\(normHost):\(dev.port)"
                if seen.insert(key).inserted {
                    let name = cleanName(dev.name)
                    onlineList.append(SavedConnection(name: name, host: normHost, port: dev.port, date: Date()))
                }
            }
        }
        
        for item in historyPhones {
            let normHost = ConnectionHostAddress.normalized(item.host)
            let key = "\(normHost):\(item.port)"
            if seen.insert(key).inserted {
                let name = resolvedName(for: item)
                offlineList.append(SavedConnection(name: name, host: normHost, port: item.port, date: item.date))
            }
        }
        
        // Телефоны в сети внизу списка
        return offlineList + onlineList
    }
    
    private func resolvedName(for item: SavedConnection) -> String {
        let normHost = ConnectionHostAddress.normalized(item.host)
        if let found = vm.discoveryService.discoveredDevices.first(where: { ConnectionHostAddress.normalized($0.host) == normHost }), !found.name.isEmpty {
            return cleanName(found.name)
        }
        if let devName = PhoneConnectionManager.shared.deviceNameForHost(normHost), devName != "Телефон Android", devName != "Android", !devName.isEmpty {
            return cleanName(devName)
        }
        if let dev = DeviceRegistry.shared.device(matchingHost: normHost), dev.name != "Телефон Android", dev.name != "Android", !dev.name.isEmpty {
            return cleanName(dev.name)
        }
        if item.name != "Телефон Android" && item.name != "Android" && !item.name.isEmpty {
            return cleanName(item.name)
        }
        return "Телефон Android"
    }
    
    private func isOnline(_ item: SavedConnection) -> Bool {
        let normHost = ConnectionHostAddress.normalized(item.host)
        return vm.discoveryService.discoveredDevices.contains { ConnectionHostAddress.normalized($0.host) == normHost }
    }
    
    private func cleanName(_ name: String) -> String {
        var clean = name.replacingOccurrences(of: "(MacDroid)", with: "")
            .trimmingCharacters(in: .whitespaces)
        if clean.hasPrefix("Телефон ") {
            let remainder = String(clean.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            if !remainder.isEmpty && remainder != "Android" {
                clean = remainder
            }
        }
        if clean.contains("2409BRN2CY") || clean.contains("RN") || clean.lowercased().contains("redmi") {
            clean = clean.replacingOccurrences(of: "Xiaomi", with: "Redmi")
        }
        return clean.isEmpty ? "Телефон Android" : clean
    }
    
    private func isConnectedPhone(_ item: SavedConnection) -> Bool {
        let curHost = ConnectionHostAddress.normalized(SessionCoordinator.shared.host)
        let itemHost = ConnectionHostAddress.normalized(item.host)
        return vm.isPhoneConnected && vm.remoteDriver.isConnected && curHost == itemHost
    }


    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if allPhones.isEmpty {
                Text("Нет сохранённых или обнаруженных устройств")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(allPhones) { item in
                    let isConnected = isConnectedPhone(item)
                    let online = isOnline(item) || isConnected
                    let isSelected = (inputHost == item.host)
                    
                    Button(action: {
                        inputHost = item.host
                        inputPort = "\(item.port)"
                    }) {
                        HStack(spacing: 6) {
                            if isConnected {
                                Circle()
                                    .fill(Color(red: 0.35, green: 0.88, blue: 0.35))
                                    .frame(width: 7, height: 7)
                            } else if online {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 7, height: 7)
                            } else {
                                Circle()
                                    .fill(Color.clear)
                                    .frame(width: 7, height: 7)
                            }
                            
                            let name = item.name
                            if online {
                                Text("\(name) (\(item.host))")
                                    .font(.system(size: 13))
                            } else {
                                Text("\(name) - \(item.host) (не в сети)")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        inputHost = item.host
                        inputPort = "\(item.port)"
                        if isConnectedPhone(item) {
                            vm.disconnectPhone()
                        } else {
                            startConnection()
                        }
                    })
                    .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                    .cornerRadius(4)
                    .contextMenu {
                        Button(role: .destructive) {
                            removeHistoryItem(item)
                        } label: {
                            Label("Удалить из истории", systemImage: "trash")
                        }
                    }
                }
            }
            
            Divider()
                .padding(.vertical, 4)
            HStack(spacing: 12) {
                Spacer()
                
                TextField("IP", text: $inputHost)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.gray.opacity(0.6), lineWidth: 1)
                    )
                    .frame(width: 130)
                
                if vm.isConnectingPhone {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                
                Button("Connect") {
                    startConnection()
                }
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(inputHost.isEmpty || vm.isConnectingPhone)
                
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(width: 350)
        .onAppear {
            vm.discoveryService.startDiscovery()
            if let first = allPhones.first {
                inputHost = first.host
                inputPort = "\(first.port)"
            }
        }
        .onReceive(vm.discoveryService.$discoveredDevices) { _ in
            if inputHost.isEmpty, let first = allPhones.first {
                inputHost = first.host
                inputPort = "\(first.port)"
            }
        }
    }
    
    private func removeHistoryItem(_ item: SavedConnection) {
        let normHost = ConnectionHostAddress.normalized(item.host)
        if let data = UserDefaults.standard.data(forKey: "phoneConnectionHistory"),
           var history = try? JSONDecoder().decode([SavedConnection].self, from: data) {
            history.removeAll { ConnectionHostAddress.normalized($0.host) == normHost }
            if let encoded = try? JSONEncoder().encode(history) {
                UserDefaults.standard.set(encoded, forKey: "phoneConnectionHistory")
            }
        }
        if inputHost == item.host {
            inputHost = ""
        }
    }
    
    private func startConnection() {
        guard !inputHost.isEmpty, !vm.isConnectingPhone else { return }
        let host = inputHost
        let port = UInt16(inputPort) ?? 2222

        vm.connectPhone(
            customHost: host,
            customPort: port,
            forceActivate: true,
            isExplicit: true
        )
    }
}

public struct PopoverBubbleShape: Shape {
    public var cornerRadius: CGFloat = 8
    public var arrowWidth: CGFloat = 12
    public var arrowHeight: CGFloat = 20
    public var arrowYOffset: CGFloat = 16
    
    public init(cornerRadius: CGFloat = 8, arrowWidth: CGFloat = 12, arrowHeight: CGFloat = 20, arrowYOffset: CGFloat = 16) {
        self.cornerRadius = cornerRadius
        self.arrowWidth = arrowWidth
        self.arrowHeight = arrowHeight
        self.arrowYOffset = arrowYOffset
    }
    
    public func path(in rect: CGRect) -> Path {
        var path = Path()
        
        let bodyRect = CGRect(x: arrowWidth, y: 0, width: rect.width - arrowWidth, height: rect.height)
        path.addRoundedRect(in: bodyRect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        
        let arrow = Path { p in
            p.move(to: CGPoint(x: arrowWidth, y: arrowYOffset - arrowHeight / 2))
            p.addLine(to: CGPoint(x: 0, y: arrowYOffset))
            p.addLine(to: CGPoint(x: arrowWidth, y: arrowYOffset + arrowHeight / 2))
            p.closeSubpath()
        }
        
        path.addPath(arrow)
        return path
    }
}
