import SwiftUI

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

public struct PairingModalView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    @Environment(\.dismiss) var dismiss
    
    @State private var inputHost: String = ""
    @State private var inputPort: String = "2222"
    @State private var pairingStatus: String = "Готов к сопряжению"
    @State private var isConnecting: Bool = false
    @State private var history: [SavedConnection] = []
    @State private var currentFingerprint: String = "SHA256:Ed25519_Xiaomi14Ultra_DaemonFingerprint"
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.blue)
                VStack(alignment: .leading) {
                    Text("Безопасное сопряжение (Ed25519)")
                        .font(.headline)
                    Text("Установка доверенной криптографической связи Mac ↔ Xiaomi 14 Ultra")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            // Выпадающий список: история подключений и обнаруженные устройства
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("История подключений и устройства в сети:")
                        .font(.caption)
                        .fontWeight(.bold)
                    
                    Spacer()
                    
                    if vm.discoveryService.isSearching {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                            Text("Поиск...")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Menu {
                    // 1. Обнаруженные устройства через mDNS
                    let discovered = vm.discoveryService.discoveredDevices
                    if !discovered.isEmpty {
                        Section("Обнаруженные в сети (mDNS)") {
                            ForEach(discovered) { dev in
                                Button(action: {
                                    selectConnection(name: dev.name, host: dev.host, port: dev.port)
                                }) {
                                    HStack {
                                        Label("\(dev.name) — \(dev.host):\(dev.port)", systemImage: "wifi")
                                        if inputHost == dev.host && inputPort == String(dev.port) {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    
                    // 2. История предыдущих подключений
                    if !history.isEmpty {
                        if !discovered.isEmpty { Divider() }
                        Section("История подключений") {
                            ForEach(history) { item in
                                Button(action: {
                                    selectConnection(name: item.name, host: item.host, port: item.port)
                                }) {
                                    HStack {
                                        Label("\(item.name) — \(item.host):\(item.port)", systemImage: "clock")
                                        if inputHost == item.host && inputPort == String(item.port) {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button("Очистить историю подключений", role: .destructive) {
                                clearHistory()
                            }
                        }
                    }
                    
                    if discovered.isEmpty && history.isEmpty {
                        Text("Нет сохранённых или обнаруженных устройств")
                    }
                } label: {
                    HStack {
                        Image(systemName: "iphone.and.arrow.forward")
                            .foregroundColor(.accentColor)
                        Text(currentSelectionTitle)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal)
            
            Divider()
            
            // Ручное подключение (fallback)
            VStack(alignment: .leading, spacing: 12) {
                Text("Ручное подключение (если mDNS недоступен):")
                    .font(.caption)
                    .fontWeight(.bold)
                
                HStack {
                    Text("IP-адрес телефона:")
                        .font(.caption)
                        .frame(width: 140, alignment: .leading)
                    TextField("192.168.x.x", text: $inputHost)
                        .textFieldStyle(.roundedBorder)
                }
                
                HStack {
                    Text("Порт SFTP/SSH:")
                        .font(.caption)
                        .frame(width: 140, alignment: .leading)
                    TextField("2222", text: $inputPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Отпечаток хост-ключа телефона:")
                        .font(.caption)
                        .fontWeight(.bold)
                    Text(currentFingerprint)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(6)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(4)
                }
                
                Text(pairingStatus)
                    .font(.caption)
                    .foregroundColor(pairingStatus.hasPrefix("✓") ? .green : pairingStatus.hasPrefix("⚠") ? .red : .blue)
            }
            .padding(.horizontal)
            
            Divider()
            
            HStack(spacing: 12) {
                Button("Отмена") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                if isConnecting {
                    ProgressView()
                        .scaleEffect(0.8)
                }
                
                Button("Подключиться и сохранить ключ (TOFU)") {
                    guard !inputHost.isEmpty else {
                        pairingStatus = "⚠️ Введите IP-адрес телефона"
                        return
                    }
                    let portInt = Int(inputPort) ?? 2222
                    isConnecting = true
                    
                    // Сохраняем последний успешный адрес и историю
                    UserDefaults.standard.set(inputHost, forKey: "lastConnectedHost")
                    UserDefaults.standard.set(inputPort, forKey: "lastConnectedPort")
                    saveToHistory(host: inputHost, port: portInt)
                    
                    vm.updateRemoteEndpoint(host: inputHost, port: UInt16(portInt))
                    
                    let fp = PhoneConnectionManager.shared.fetchHostFingerprint(host: inputHost, port: UInt16(portInt))
                        ?? "SHA256:Ed25519_Xiaomi14Ultra_DaemonFingerprint"
                    currentFingerprint = fp
                    
                    let res = HostKeyStore.shared.verifyOrPin(
                        host: inputHost,
                        port: portInt,
                        fingerprint: fp
                    )
                    
                    isConnecting = false
                    switch res {
                    case .trusted:
                        pairingStatus = "✓ Устройство уже доверенное"
                    case .pinnedNew:
                        pairingStatus = "✓ Новый ключ успешно зафиксирован в хранилище"
                    case .mismatchWarning:
                        pairingStatus = "⚠️ ВНИМАНИЕ: Ключ не совпадает с сохраненным ранее!"
                    }
                    
                    if vm.rightSource != .remotePhone && vm.leftSource != .remotePhone {
                        vm.changeSource(to: .remotePhone, side: .right)
                    } else {
                        if vm.leftSource == .remotePhone { vm.refreshPane(side: .left) }
                        if vm.rightSource == .remotePhone { vm.refreshPane(side: .right) }
                    }
                    vm.refreshDetectedVolumes()
                    vm.statusMessage = "✓ Телефон подключен по Wi-Fi (\(inputHost):\(portInt))"
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(inputHost.isEmpty || isConnecting)
            }
        }
        .padding(24)
        .frame(minWidth: 520)
        .onAppear {
            loadHistory()
            // Авто-определение активного IP или восстановление сохранённого
            if let liveIp = PhoneConnectionManager.shared.discoverPhoneIpOnLan() {
                inputHost = liveIp
            } else if let savedHost = UserDefaults.standard.string(forKey: "lastConnectedHost"), !savedHost.isEmpty {
                inputHost = savedHost
            } else if let first = history.first {
                inputHost = first.host
            } else {
                inputHost = "192.168.1.18"
            }
            if let savedPort = UserDefaults.standard.string(forKey: "lastConnectedPort"), !savedPort.isEmpty {
                inputPort = savedPort
            } else if let first = history.first {
                inputPort = String(first.port)
            }
        }
    }
    
    private var currentSelectionTitle: String {
        if let found = vm.discoveryService.discoveredDevices.first(where: { $0.host == inputHost && String($0.port) == inputPort }) {
            return "\(found.name) — \(found.host):\(found.port)"
        }
        if let foundHist = history.first(where: { $0.host == inputHost && String($0.port) == inputPort }) {
            return "\(foundHist.name) — \(foundHist.host):\(foundHist.port)"
        }
        if !inputHost.isEmpty {
            return "\(inputHost):\(inputPort)"
        }
        return "— Выберите устройство из истории / сети —"
    }
    
    private func selectConnection(name: String, host: String, port: Int) {
        inputHost = host
        inputPort = String(port)
    }
    
    private func saveToHistory(host: String, port: Int) {
        var updated = history.filter { !($0.host == host && $0.port == port) }
        let name = vm.discoveryService.discoveredDevices.first(where: { $0.host == host && $0.port == port })?.name ?? "Xiaomi 14 Ultra"
        updated.insert(SavedConnection(name: name, host: host, port: port, date: Date()), at: 0)
        if updated.count > 25 {
            updated = Array(updated.prefix(25))
        }
        history = updated
        if let data = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(data, forKey: "phoneConnectionHistory")
        }
    }
    
    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: "phoneConnectionHistory"),
           let saved = try? JSONDecoder().decode([SavedConnection].self, from: data) {
            history = saved
        } else if let savedHost = UserDefaults.standard.string(forKey: "lastConnectedHost"), !savedHost.isEmpty {
            let savedPort = Int(UserDefaults.standard.string(forKey: "lastConnectedPort") ?? "2222") ?? 2222
            history = [SavedConnection(name: "Xiaomi 14 Ultra", host: savedHost, port: savedPort, date: Date())]
        }
    }
    
    private func clearHistory() {
        history.removeAll()
        UserDefaults.standard.removeObject(forKey: "phoneConnectionHistory")
    }
}
