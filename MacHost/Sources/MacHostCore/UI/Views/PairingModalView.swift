import SwiftUI

public struct PairingModalView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    @Environment(\.dismiss) var dismiss
    
    @State private var inputHost: String = ""
    @State private var inputPort: String = "2222"
    @State private var pairingStatus: String = "Готов к сопряжению"
    @State private var isConnecting: Bool = false
    @State private var history: [SavedConnection] = []
    @State private var currentFingerprint: String = "— Ожидание подключения —"
    
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
                    Text("Установка доверенной криптографической связи Mac ↔ Android")
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
                    } else {
                        Button(action: {
                            vm.discoveryService.refresh()
                        }) {
                            Label("Обновить", systemImage: "arrow.clockwise")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
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
                                        Label("\(dev.name) — \(dev.host):\(dev.port) (в сети)", systemImage: "wifi")
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
                                let isLive = discovered.contains(where: { $0.host == item.host })
                                let matchingLive = discovered.first(where: { $0.name == item.name && $0.host != item.host })
                                Button(action: {
                                    selectConnection(name: item.name, host: item.host, port: item.port)
                                }) {
                                    HStack {
                                        if let matching = matchingLive {
                                            Label("\(item.name) — \(item.host) ➔ в сети на \(matching.host)", systemImage: "arrow.triangle.turn.up.right.diamond")
                                        } else if isLive {
                                            Label("\(item.name) — \(item.host):\(item.port) (в сети)", systemImage: "wifi")
                                        } else {
                                            Label("\(item.name) — \(item.host):\(item.port)", systemImage: "clock")
                                        }
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
                    TextField("например, 192.168.1.50", text: $inputHost)
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
                
                Toggle("Автоматически подключаться к этому устройству при запуске", isOn: Binding(
                    get: {
                        if let dev = DeviceRegistry.shared.device(matchingHost: inputHost) {
                            return dev.autoConnect
                        }
                        return false
                    },
                    set: { newValue in
                        if let dev = DeviceRegistry.shared.device(matchingHost: inputHost) {
                            DeviceRegistry.shared.setAutoConnect(id: dev.id, enabled: newValue)
                        } else if !inputHost.isEmpty {
                            let devName = currentSelectionTitle.components(separatedBy: " — ").first ?? "Телефон Android"
                            DeviceRegistry.shared.registerOrUpdate(
                                id: "device_\(inputHost)",
                                name: devName,
                                fingerprint: currentFingerprint.hasPrefix("SHA256:") ? currentFingerprint : "",
                                host: inputHost,
                                port: UInt16(Int(inputPort) ?? 2222),
                                autoConnect: newValue
                            )
                        }
                    }
                ))
                .font(.caption)
                .padding(.top, 4)
                
                Text(pairingStatus)
                    .font(.caption)
                    .foregroundColor(pairingStatus.hasPrefix("✓") ? .green : pairingStatus.hasPrefix("⚠️") ? .red : .blue)
            }
            .padding(.horizontal)
            
            Divider()
            
            HStack(spacing: 12) {
                Button("Отмена") {
                    ConnectionController.shared.cancel(viewModel: vm)
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
                    pairingStatus = "Проверка доступности и авторизация SFTP..."
                    
                    Task { @MainActor in
                        defer { isConnecting = false }
                        
                        let success = await ConnectionController.shared.connect(
                            customHost: inputHost,
                            customPort: UInt16(portInt),
                            isExplicitUserAction: true,
                            viewModel: vm
                        )
                        
                        if success {
                            UserDefaults.standard.set(inputHost, forKey: "lastConnectedHost")
                            UserDefaults.standard.set(inputPort, forKey: "lastConnectedPort")
                            saveToHistory(host: inputHost, port: portInt)
                            
                            pairingStatus = "✓ Подключение успешно установлено"
                            if vm.rightSource != .remotePhone && vm.leftSource != .remotePhone {
                                vm.changeSource(to: .remotePhone, side: .right)
                            } else {
                                if vm.leftSource == .remotePhone { vm.refreshPane(side: .left) }
                                if vm.rightSource == .remotePhone { vm.refreshPane(side: .right) }
                            }
                            vm.refreshDetectedVolumes()
                            
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            dismiss()
                        } else {
                            if case .authFailed(let reason) = ConnectionController.shared.phase {
                                pairingStatus = "⚠️ Ошибка авторизации: \(reason)"
                            } else {
                                pairingStatus = "⚠️ Не удалось подключиться к \(inputHost):\(portInt)"
                            }
                        }
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
            vm.discoveryService.startDiscovery()
            
            // Умный приоритет автоподстановки IP:
            // 1. Прямо сейчас обнаруженное через mDNS живое устройство
            if let firstDiscovered = vm.discoveryService.discoveredDevices.first {
                inputHost = firstDiscovered.host
                inputPort = String(firstDiscovered.port)
            }
            // 2. Сканирование живого IP (mDNS кэш -> последний успешный IP -> история -> ARP)
            else if let liveIp = PhoneConnectionManager.shared.discoverPhoneIpOnLan() {
                inputHost = liveIp
                if let savedPort = UserDefaults.standard.string(forKey: "lastConnectedPort"), !savedPort.isEmpty {
                    inputPort = savedPort
                }
            }
            // 3. Последний сохраненный хост (только если доступен в сети прямо сейчас)
            else if let savedHost = UserDefaults.standard.string(forKey: "lastConnectedHost"),
                    !savedHost.isEmpty,
                    PhoneConnectionManager.shared.isHostPortReachable(host: savedHost, port: UInt16(UserDefaults.standard.string(forKey: "lastConnectedPort") ?? "2222") ?? 2222, timeoutSeconds: 1) {
                inputHost = savedHost
                if let savedPort = UserDefaults.standard.string(forKey: "lastConnectedPort"), !savedPort.isEmpty {
                    inputPort = savedPort
                }
            }
            // 4. Первая запись из истории (только если доступна в сети)
            else if let first = history.first,
                    PhoneConnectionManager.shared.isHostPortReachable(host: first.host, port: UInt16(first.port), timeoutSeconds: 1) {
                inputHost = first.host
                inputPort = String(first.port)
            }
            // 5. Если живые устройства не найдены — оставляем поле пустым для ввода
            else {
                inputHost = ""
                inputPort = "2222"
            }
        }
        .onReceive(vm.discoveryService.$discoveredDevices) { devices in
            guard let live = devices.first else { return }
            // Если поле было пустым, либо текущий введенный адрес недоступен,
            // автоматически переключаем на свежеобнаруженный живой IP устройства
            if inputHost.isEmpty {
                inputHost = live.host
                inputPort = String(live.port)
            } else if inputHost != live.host && !PhoneConnectionManager.shared.isHostPortReachable(host: inputHost, port: UInt16(inputPort) ?? 2222, timeoutSeconds: 1) {
                inputHost = live.host
                inputPort = String(live.port)
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
        // Если устройство с таким же именем сейчас обнаружено в mDNS по новому IP,
        // автоматически используем актуальный IP
        if let liveDev = vm.discoveryService.discoveredDevices.first(where: { $0.name == name }) {
            inputHost = liveDev.host
            inputPort = String(liveDev.port)
        } else {
            inputHost = host
            inputPort = String(port)
        }
    }
    
    private func saveToHistory(host: String, port: Int) {
        var updated = history.filter { !($0.host == host && $0.port == port) }
        let name = vm.discoveryService.discoveredDevices.first(where: { $0.host == host && $0.port == port })?.name
            ?? PhoneConnectionManager.shared.deviceNameForHost(host)
            ?? "Телефон Android"
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
            let devName = PhoneConnectionManager.shared.deviceNameForHost(savedHost) ?? "Телефон Android"
            history = [SavedConnection(name: devName, host: savedHost, port: savedPort, date: Date())]
        }
    }
    
    private func clearHistory() {
        history.removeAll()
        UserDefaults.standard.removeObject(forKey: "phoneConnectionHistory")
    }
}
