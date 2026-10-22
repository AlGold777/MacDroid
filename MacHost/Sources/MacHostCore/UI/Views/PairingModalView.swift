import SwiftUI
import AppKit

public struct PairingModalView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    @Environment(\.dismiss) var dismiss
    
    @State private var inputHost: String
    @State private var inputPort: String
    @State private var pairingStatus: String = "Готов к сопряжению"
    @State private var isConnecting: Bool = false
    @State private var history: [SavedConnection]
    @State private var reachableHosts: Set<String> = []
    @State private var liveDiscoveredDevices: [DiscoveredDevice] = []
    @State private var isScanningPorts: Bool = false
    @State private var menuRefreshId = UUID()
    @State private var currentFingerprint: String = "— Ожидание подключения —"
    @State private var showDiagnostics: Bool = false
    
    public init() {
        let initialHistory = Self.loadInitialHistory()
        _history = State(initialValue: initialHistory)
        
        let lastSuccessfulHost = UserDefaults.standard.string(forKey: "lastSuccessfulPhoneHost")
        let previousHost = UserDefaults.standard.string(forKey: "lastConnectedHost")
        let defaultHost: String
        let defaultPort: String
        
        if let host = lastSuccessfulHost, !host.isEmpty {
            defaultHost = ConnectionHostAddress.normalized(host)
            let savedPort = UserDefaults.standard.integer(forKey: "lastSuccessfulPhonePort")
            defaultPort = String(savedPort == 0 ? 2222 : savedPort)
        } else if let host = previousHost, !host.isEmpty, host != "127.0.0.1" {
            defaultHost = ConnectionHostAddress.normalized(host)
            defaultPort = UserDefaults.standard.string(forKey: "lastConnectedPort") ?? "2222"
        } else if let first = initialHistory.first {
            defaultHost = first.host
            defaultPort = String(first.port)
        } else {
            defaultHost = ""
            defaultPort = "2222"
        }
        
        _inputHost = State(initialValue: defaultHost)
        _inputPort = State(initialValue: defaultPort)
    }
    
    /// Телефоны, которые сейчас доступны в локальной сети (порт 2222 открыт или обнаружены через mDNS)
    private var onlinePhones: [SavedConnection] {
        var result: [SavedConnection] = []
        var seen = Set<String>()
        
        // 1. Телефоны из истории, которые сейчас онлайн
        for item in history {
            let normHost = ConnectionHostAddress.normalized(item.host)
            let key = "\(normHost):\(item.port)"
            if isHostInNetwork(item.host) && seen.insert(key).inserted {
                let name = resolvedDeviceName(for: item)
                result.append(SavedConnection(name: name, host: normHost, port: item.port, date: item.date))
            }
        }
        
        // 2. Обнаруженные живые устройства с открытым портом 2222
        for dev in liveDiscoveredDevices {
            let normHost = ConnectionHostAddress.normalized(dev.host)
            let key = "\(normHost):\(dev.port)"
            if isHostInNetwork(dev.host) && seen.insert(key).inserted {
                result.append(SavedConnection(name: dev.name, host: normHost, port: dev.port, date: Date()))
            }
        }
        
        // 3. Устройства, обнаруженные через mDNS
        for dev in vm.discoveryService.discoveredDevices {
            let normHost = ConnectionHostAddress.normalized(dev.host)
            let key = "\(normHost):\(dev.port)"
            if ConnectionHostAddress.isIPv4(dev.host) && isHostInNetwork(dev.host) && seen.insert(key).inserted {
                result.append(SavedConnection(name: dev.name, host: normHost, port: dev.port, date: Date()))
            }
        }
        
        return result
    }
    
    /// Ранее успешно подключаемые телефоны из истории, которые СЕЙЧАС НЕ В СЕТИ
    private var offlineHistoryPhones: [SavedConnection] {
        var result: [SavedConnection] = []
        var seen = Set<String>()
        
        for item in history {
            let normHost = ConnectionHostAddress.normalized(item.host)
            let key = "\(normHost):\(item.port)"
            // Показываем только те телефоны, которые СЕЙЧАС НЕ В СЕТИ
            if !isHostInNetwork(item.host) && seen.insert(key).inserted {
                let name = resolvedDeviceName(for: item)
                result.append(SavedConnection(name: name, host: normHost, port: item.port, date: item.date))
                if result.count >= 4 { break }
            }
        }
        
        return result
    }
    
    public var body: some View {
        VStack(spacing: 14) {
            // 2. Отображение истории подключений (ТОЛЬКО телефоны, которые сейчас НЕ в сети)
            if !offlineHistoryPhones.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("История подключений (не в сети):")
                        .font(.system(size: 14, weight: .semibold))
                    
                    VStack(spacing: 2) {
                        ForEach(offlineHistoryPhones) { item in
                            let displayName = resolvedDeviceName(for: item)
                            let isSelected = isConnectionSelected(item)
                            
                            ConnectionRowView(
                                item: item,
                                displayName: displayName,
                                isLive: false,
                                isSelected: isSelected,
                                onSelect: {
                                    selectConnection(name: displayName, host: item.host, port: item.port)
                                },
                                onConnect: {
                                    selectConnection(name: displayName, host: item.host, port: item.port)
                                    startConnection()
                                }
                            )
                        }
                    }
                    .padding(4)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                    )
                }
            }
            
            // 1. Отображение телефонов, которые сейчас в сети
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Телефоны в сети:")
                        .font(.system(size: 14, weight: .semibold))
                    
                    Spacer()
                    
                    // Выпадающее меню всех устройств
                    Menu {
                        if !onlinePhones.isEmpty {
                            Section("Телефоны в сети") {
                                ForEach(onlinePhones) { item in
                                    Button(action: {
                                        selectConnection(name: item.name, host: item.host, port: item.port)
                                    }) {
                                        Label {
                                            Text("\(item.name) — \(item.host):\(item.port)")
                                        } icon: {
                                            Image(nsImage: greenDotImage)
                                        }
                                    }
                                }
                            }
                        }

                        if !offlineHistoryPhones.isEmpty {
                            if !onlinePhones.isEmpty { Divider() }
                            Section("История подключений (не в сети)") {
                                ForEach(offlineHistoryPhones) { item in
                                    Button(action: {
                                        selectConnection(name: item.name, host: item.host, port: item.port)
                                    }) {
                                        Text("\(item.name) — \(item.host):\(item.port)")
                                    }
                                }
                                Divider()
                                Button("Очистить историю подключений", role: .destructive) {
                                    clearHistory()
                                }
                            }
                        } else if !history.isEmpty {
                            Divider()
                            Button("Очистить историю подключений", role: .destructive) {
                                clearHistory()
                            }
                        }
                        
                        if onlinePhones.isEmpty && offlineHistoryPhones.isEmpty {
                            Text("Нет сохранённых или обнаруженных устройств")
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .id(menuRefreshId)
                    .help("Выпадающее меню устройств")
                    
                    // Кнопка обновления (только иконка)
                    if isScanningPorts || vm.discoveryService.isSearching {
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 14, height: 14)
                    } else {
                        Button(action: {
                            vm.discoveryService.refresh()
                            checkAllReachability()
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Обновить список устройств")
                    }
                }
                
                // 1. Отображение телефонов, которые сейчас в сети
                VStack(spacing: 2) {
                    if onlinePhones.isEmpty {
                        HStack {
                            Spacer()
                            if isScanningPorts || vm.discoveryService.isSearching {
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.55).frame(width: 14, height: 14)
                                    Text("Поиск телефонов в сети...")
                                }
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .padding(.vertical, 8)
                            } else {
                                Text("Нет доступных телефонов в сети")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                    .padding(.vertical, 8)
                            }
                            Spacer()
                        }
                    } else {
                        ForEach(onlinePhones) { item in
                            let displayName = resolvedDeviceName(for: item)
                            let isSelected = isConnectionSelected(item)
                            
                            ConnectionRowView(
                                item: item,
                                displayName: displayName,
                                isLive: true,
                                isSelected: isSelected,
                                onSelect: {
                                    selectConnection(name: displayName, host: item.host, port: item.port)
                                },
                                onConnect: {
                                    selectConnection(name: displayName, host: item.host, port: item.port)
                                    startConnection()
                                }
                            )
                        }
                    }
                }
                .padding(4)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
                )
            }
            
            // Карточка 2: Настройка вручную
            VStack(alignment: .leading, spacing: 12) {
                Text("Настройка вручную")
                    .font(.system(size: 14, weight: .semibold))
                
                HStack(spacing: 8) {
                    Text("ІР-адрес:")
                        .font(.system(size: 13))
                    
                    TextField("192.168.1.50", text: $inputHost)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: 155)
                    
                    Spacer(minLength: 16)
                    
                    Text("Port:")
                        .font(.system(size: 13))
                    
                    TextField("2222", text: $inputPort)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: 65)
                }
                
                Toggle("Автоматически подключаться при запуске", isOn: Binding(
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
                .font(.system(size: 13))
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
            )
            
            // Строка статуса и раскрытия подробностей диагностики
            VStack(spacing: 6) {
                HStack(alignment: .center) {
                    HStack(spacing: 6) {
                        if isConnecting {
                            ProgressView()
                                .scaleEffect(0.65)
                                .frame(width: 14, height: 14)
                        }
                        Text(pairingStatus)
                            .font(.system(size: 12))
                            .foregroundColor(pairingStatus.hasPrefix("✓") ? .green : pairingStatus.hasPrefix("⚠️") ? .red : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    
                    Spacer()
                    
                    if !ConnectionController.shared.lastConnectionDiagnostics.isEmpty {
                        Button(action: {
                            showDiagnostics.toggle()
                        }) {
                            HStack(spacing: 4) {
                                Text("Подробности диагностики")
                                Image(systemName: showDiagnostics ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9))
                            }
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                if showDiagnostics && !ConnectionController.shared.lastConnectionDiagnostics.isEmpty {
                    ScrollView {
                        Text(ConnectionController.shared.lastConnectionDiagnostics)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 4)
            
            if pairingStatus.contains("Host Key") || pairingStatus.contains("не совпадает") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Если на телефоне был сгенерирован новый ключ или переустановлен демон, можно обновить сохранённый ключ:")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Button(action: {
                        let portInt = Int(inputPort) ?? 2222
                        HostKeyStore.shared.resetHostKey(host: inputHost, port: portInt)
                        HostKeyStore.shared.resetHostKey(host: "127.0.0.1", port: portInt)
                        pairingStatus = "Старый ключ сброшен. Повторное подключение..."
                        startConnection()
                    }) {
                        Label("Сбросить старый ключ и доверять текущему", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundColor(.orange)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                }
                .padding(8)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(6)
            }
            
            // Кнопки Отмена и Connect по центру, без разделительной линии
            HStack(spacing: 14) {
                Button("Отмена") {
                    ConnectionController.shared.cancel(viewModel: vm)
                    dismiss()
                }
                .font(.system(size: 14, weight: .medium))
                .keyboardShortcut(.cancelAction)
                
                if isConnecting {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                
                Button("Connect") {
                    startConnection()
                }
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(inputHost.isEmpty || isConnecting)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 530)
        .onAppear {
            loadHistory()
            vm.discoveryService.startDiscovery()
            checkAllReachability()
            
            if inputHost.isEmpty || !isHostInNetwork(inputHost) {
                if let liveIp = PhoneConnectionManager.shared.discoverPhoneIpOnLan() {
                    inputHost = liveIp
                } else if let firstLive = onlinePhones.first {
                    inputHost = firstLive.host
                    inputPort = String(firstLive.port)
                } else if inputHost.isEmpty, let first = history.first {
                    inputHost = first.host
                    inputPort = String(first.port)
                }
            }
            updateFingerprintDisplay()
        }
        .onChange(of: inputHost) { _, newHost in
            checkReachability(for: newHost)
            updateFingerprintDisplay()
        }
        .onChange(of: inputPort) { _, _ in
            updateFingerprintDisplay()
        }
        .onReceive(vm.discoveryService.$discoveredDevices) { devices in
            for dev in devices {
                reachableHosts.insert(ConnectionHostAddress.normalized(dev.host))
            }
            menuRefreshId = UUID()
            guard let live = devices.first else { return }
            if inputHost.isEmpty {
                inputHost = live.host
                inputPort = String(live.port)
            }
            updateFingerprintDisplay()
        }
    }
    
    /// Точный зеленый индикатор размера 7×7 pt для выпадающего NSMenu
    private var greenDotImage: NSImage {
        let size: CGFloat = 14
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(calibratedRed: 0.35, green: 0.88, blue: 0.35, alpha: 1.0).setFill()
            let circleRect = NSRect(x: 3.5, y: 3.5, width: 7, height: 7)
            let path = NSBezierPath(ovalIn: circleRect)
            path.fill()
            return true
        }
        img.isTemplate = false
        return img
    }
    
    private func isConnectionSelected(_ item: SavedConnection) -> Bool {
        let itemHost = ConnectionHostAddress.normalized(item.host)
        let curHost = ConnectionHostAddress.normalized(inputHost)
        let itemPort = item.port
        let curPort = Int(inputPort) ?? 2222
        return itemHost == curHost && itemPort == curPort
    }
    
    private func isHostInNetwork(_ host: String) -> Bool {
        let normalized = ConnectionHostAddress.normalized(host)
        if reachableHosts.contains(normalized) {
            return true
        }
        let liveHosts = vm.discoveryService.discoveredDevices
            .filter { ConnectionHostAddress.isIPv4($0.host) }
            .map { ConnectionHostAddress.normalized($0.host) }
        if liveHosts.contains(normalized) {
            return true
        }
        if vm.isPhoneConnected, let connectedHost = ConnectionController.shared.currentPath?.host,
           ConnectionHostAddress.normalized(connectedHost) == normalized {
            return true
        }
        return false
    }
    
    /// Мгновенная проверка доступности порта 2222 по локальной сети
    private func checkAllReachability() {
        isScanningPorts = true
        
        var candidates: [String] = history.map { $0.host }
        if !inputHost.isEmpty {
            candidates.append(inputHost)
        }
        for dev in vm.discoveryService.discoveredDevices {
            candidates.append(dev.host)
        }
        for regDev in DeviceRegistry.shared.allDevices() {
            candidates.append(regDev.lastKnownHost)
        }
        let lanIps = NetworkPortReachability.fetchActiveLanIps()
        candidates.append(contentsOf: lanIps)
        
        Task.detached(priority: .userInitiated) {
            let reachable = await NetworkPortReachability.checkReachableHosts(hosts: candidates, port: 2222, timeoutMs: 250)
            
            await MainActor.run {
                self.reachableHosts.formUnion(reachable)
                
                var discovered: [DiscoveredDevice] = []
                for host in reachable {
                    let norm = ConnectionHostAddress.normalized(host)
                    let name = self.vm.discoveryService.discoveredDevices.first(where: { ConnectionHostAddress.normalized($0.host) == norm })?.name
                        ?? DeviceRegistry.shared.device(matchingHost: norm)?.name
                        ?? PhoneConnectionManager.shared.deviceNameForHost(norm)
                        ?? "Телефон Android"
                    discovered.append(DiscoveredDevice(id: norm, name: name, host: norm, port: 2222))
                }
                self.liveDiscoveredDevices = discovered
                
                if self.inputHost.isEmpty || !self.isHostInNetwork(self.inputHost) {
                    if let liveHost = reachable.first {
                        self.inputHost = liveHost
                        self.inputPort = "2222"
                        self.updateFingerprintDisplay()
                    }
                }
                
                self.isScanningPorts = false
                self.menuRefreshId = UUID()
            }
        }
    }
    
    private func checkReachability(for host: String) {
        let norm = ConnectionHostAddress.normalized(host)
        guard !norm.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let ok = NetworkPortReachability.isPortOpen(host: norm, port: 2222, timeoutMs: 250)
            await MainActor.run {
                if ok {
                    self.reachableHosts.insert(norm)
                } else {
                    self.reachableHosts.remove(norm)
                }
                self.menuRefreshId = UUID()
            }
        }
    }
    
    private func resolvedDeviceName(for item: SavedConnection) -> String {
        let normHost = ConnectionHostAddress.normalized(item.host)
        if let found = vm.discoveryService.discoveredDevices.first(where: { ConnectionHostAddress.normalized($0.host) == normHost }), !found.name.isEmpty {
            return found.name
        }
        if item.name != "Телефон Android" && !item.name.isEmpty {
            return item.name
        }
        if let dev = DeviceRegistry.shared.device(matchingHost: normHost), dev.name != "Телефон Android", !dev.name.isEmpty {
            return dev.name
        }
        if let devName = PhoneConnectionManager.shared.deviceNameForHost(normHost), devName != "Телефон Android", !devName.isEmpty {
            return devName
        }
        return item.name
    }
    
    private func startConnection() {
        guard !inputHost.isEmpty else {
            pairingStatus = "⚠️ Введите IP-адрес телефона"
            return
        }
        let host = ConnectionHostAddress.normalized(inputHost)
        inputHost = host
        let portInt = Int(inputPort) ?? 2222
        isConnecting = true
        pairingStatus = "Проверка доступности и авторизация SFTP..."
        
        Task { @MainActor in
            defer { isConnecting = false }
            
            let success = await ConnectionController.shared.connect(
                customHost: host,
                customPort: UInt16(portInt),
                isExplicitUserAction: true,
                viewModel: vm
            )
            
            if success {
                UserDefaults.standard.set(host, forKey: "lastConnectedHost")
                UserDefaults.standard.set(inputPort, forKey: "lastConnectedPort")
                UserDefaults.standard.set(host, forKey: "lastSuccessfulPhoneHost")
                UserDefaults.standard.set(portInt, forKey: "lastSuccessfulPhonePort")
                saveToHistory(host: host, port: portInt)
                
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
    
    private func updateFingerprintDisplay() {
        guard !inputHost.isEmpty else {
            currentFingerprint = "— Введите IP-адрес телефона —"
            return
        }
        let host = inputHost
        let port = UInt16(inputPort) ?? 2222
        currentFingerprint = "Опрос отпечатка узла..."
        Task.detached(priority: .userInitiated) {
            let fp = PhoneConnectionManager.shared.fetchHostFingerprint(host: host, port: port)
            await MainActor.run {
                if let fp = fp {
                    self.currentFingerprint = fp
                } else if let dev = DeviceRegistry.shared.device(matchingHost: host), !dev.pinnedFingerprint.isEmpty {
                    self.currentFingerprint = "\(dev.pinnedFingerprint) (сохраненный)"
                } else {
                    self.currentFingerprint = "— Узел недоступен или порт закрыт —"
                }
            }
        }
    }
    
    private var currentSelectionTitle: String {
        if let found = vm.discoveryService.discoveredDevices.first(where: { $0.host == inputHost && String($0.port) == inputPort }) {
            return "\(found.name) — \(found.host):\(found.port)"
        }
        if let foundHist = history.first(where: { $0.host == inputHost && String($0.port) == inputPort }) {
            let name = resolvedDeviceName(for: foundHist)
            return "\(name) — \(foundHist.host):\(foundHist.port)"
        }
        if !inputHost.isEmpty {
            let name = PhoneConnectionManager.shared.deviceNameForHost(inputHost) ?? "Телефон Android"
            return "\(name) — \(inputHost):\(inputPort)"
        }
        return "— Выберите устройство из истории / сети —"
    }
    
    private func selectConnection(name: String, host: String, port: Int) {
        if let liveDev = vm.discoveryService.discoveredDevices.first(where: { $0.name == name }) {
            inputHost = liveDev.host
            inputPort = String(liveDev.port)
        } else {
            inputHost = ConnectionHostAddress.normalized(host)
            inputPort = String(port)
        }
        checkReachability(for: inputHost)
        updateFingerprintDisplay()
    }
    
    private func saveToHistory(host: String, port: Int) {
        let normalizedHost = ConnectionHostAddress.normalized(host)
        var updated = history.filter { !(ConnectionHostAddress.normalized($0.host) == normalizedHost && $0.port == port) }
        let name = vm.discoveryService.discoveredDevices.first(where: { ConnectionHostAddress.normalized($0.host) == normalizedHost && $0.port == port })?.name
            ?? DeviceRegistry.shared.device(matchingHost: normalizedHost)?.name
            ?? PhoneConnectionManager.shared.deviceNameForHost(normalizedHost)
            ?? "Телефон Android"
        updated.insert(SavedConnection(name: name, host: normalizedHost, port: port, date: Date()), at: 0)
        updated = Array(updated.prefix(4))
        history = updated
        if let data = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(data, forKey: "phoneConnectionHistory")
        }
        menuRefreshId = UUID()
    }
    
    public static func loadInitialHistory() -> [SavedConnection] {
        var loaded: [SavedConnection] = []
        if let data = UserDefaults.standard.data(forKey: "phoneConnectionHistory"),
           let saved = try? JSONDecoder().decode([SavedConnection].self, from: data) {
            var seen = Set<String>()
            loaded = saved.compactMap { item in
                let host = ConnectionHostAddress.normalized(item.host)
                let key = "\(host):\(item.port)"
                guard seen.insert(key).inserted else { return nil }
                return SavedConnection(name: item.name, host: host, port: item.port, date: item.date)
            }
        }
        
        // Дополняем из DeviceRegistry, если меньше 4 записей
        if loaded.count < 4 {
            for dev in DeviceRegistry.shared.allDevices() {
                let host = ConnectionHostAddress.normalized(dev.lastKnownHost)
                guard !host.isEmpty, host != "127.0.0.1" else { continue }
                if !loaded.contains(where: { ConnectionHostAddress.normalized($0.host) == host && $0.port == Int(dev.lastKnownPort) }) {
                    loaded.append(SavedConnection(name: dev.name, host: host, port: Int(dev.lastKnownPort), date: dev.lastSeenDate))
                    if loaded.count >= 4 { break }
                }
            }
        }
        
        // Если всё ещё пусто, но есть последний подключенный хост
        if loaded.isEmpty, let savedHost = UserDefaults.standard.string(forKey: "lastConnectedHost"), !savedHost.isEmpty {
            let savedPort = Int(UserDefaults.standard.string(forKey: "lastConnectedPort") ?? "2222") ?? 2222
            let devName = PhoneConnectionManager.shared.deviceNameForHost(savedHost) ?? "Телефон Android"
            loaded = [SavedConnection(name: devName, host: savedHost, port: savedPort, date: Date())]
        }
        
        return Array(loaded.prefix(4))
    }
    
    private func loadHistory() {
        let loaded = Self.loadInitialHistory()
        history = loaded
        if let normalized = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(normalized, forKey: "phoneConnectionHistory")
        }
        menuRefreshId = UUID()
    }
    
    private func clearHistory() {
        history.removeAll()
        UserDefaults.standard.removeObject(forKey: "phoneConnectionHistory")
        menuRefreshId = UUID()
    }
}

/// Строка подключения в списке: зеленый индикатор для активных устройств, моноширинный хост:порт, подсветка и выбор
private struct ConnectionRowView: View {
    let item: SavedConnection
    let displayName: String
    let isLive: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onConnect: () -> Void
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        HStack(spacing: 8) {
            // Зелёный круглый индикатор (Color(red: 0.35, green: 0.88, blue: 0.35) 7×7 pt), точно как на диске Phone
            if isLive {
                Circle()
                    .fill(Color(red: 0.35, green: 0.88, blue: 0.35))
                    .frame(width: 7, height: 7)
            } else {
                Circle()
                    .fill(Color.clear)
                    .frame(width: 7, height: 7)
            }
            
            // Название телефона (без иконки)
            Text(displayName)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
            
            Text("—")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            
            // Адрес и порт
            Text("\(item.host):\(item.port)")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
            
            Spacer()
            
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : (isHovered ? Color(nsColor: .controlColor).opacity(0.35) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onConnect() })
    }
}
