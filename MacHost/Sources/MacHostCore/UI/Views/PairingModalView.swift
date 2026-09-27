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
                        .font(.system(size: 14))
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
                    let liveIPv4Devices = vm.discoveryService.discoveredDevices
                        .filter { ConnectionHostAddress.isIPv4($0.host) }
                    let discovered = Array(liveIPv4Devices.prefix(10))

                    // 1. История предыдущих подключений
                    if !history.isEmpty {
                        Section("История подключений") {
                            ForEach(history) { item in
                                let isLive = liveIPv4Devices.contains(where: { $0.host == item.host })
                                let matchingLive = liveIPv4Devices.first(where: { $0.name == item.name && $0.host != item.host })
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

                    // 2. Обнаруженные устройства через mDNS: показываем только IPv4 и не более 10.
                    if !discovered.isEmpty {
                        if !history.isEmpty { Divider() }
                        Section("Обнаруженные в сети (mDNS).") {
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

                if !ConnectionController.shared.lastConnectionDiagnostics.isEmpty {
                    DisclosureGroup("Подробности диагностики") {
                        ScrollView {
                            Text(ConnectionController.shared.lastConnectionDiagnostics)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 110)
                    }
                    .font(.caption)
                }
                
                if pairingStatus.contains("Host Key") || pairingStatus.contains("не совпадает") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Если на телефоне был сгенерирован новый ключ или переустановлен демон, можно обновить сохранённый ключ:")
                            .font(.caption2)
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
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 2)
                }
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
                    startConnection()
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
            
            // Сначала подставляем последний успешно использованный IP телефона.
            let lastSuccessfulHost = UserDefaults.standard.string(forKey: "lastSuccessfulPhoneHost")
            let previousHost = UserDefaults.standard.string(forKey: "lastConnectedHost")
            if let host = lastSuccessfulHost, !host.isEmpty {
                inputHost = ConnectionHostAddress.normalized(host)
                inputPort = String(UserDefaults.standard.integer(forKey: "lastSuccessfulPhonePort") == 0
                    ? 2222
                    : UserDefaults.standard.integer(forKey: "lastSuccessfulPhonePort"))
            } else if let host = previousHost, !host.isEmpty, host != "127.0.0.1" {
                inputHost = ConnectionHostAddress.normalized(host)
                inputPort = UserDefaults.standard.string(forKey: "lastConnectedPort") ?? "2222"
            }
            // Если успешный IP ещё не сохранён, используем актуальное обнаружение.
            else if let firstDiscovered = vm.discoveryService.discoveredDevices.first {
                inputHost = firstDiscovered.host
                inputPort = String(firstDiscovered.port)
            }
            // 2. Сканирование последнего успешного IP, истории и обнаруженных адресов.
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
            updateFingerprintDisplay()
        }
        .onChange(of: inputHost) { _ in
            updateFingerprintDisplay()
        }
        .onChange(of: inputPort) { _ in
            updateFingerprintDisplay()
        }
        .onReceive(vm.discoveryService.$discoveredDevices) { devices in
            guard let live = devices.first else { return }
            // Автозаполнение только пустого поля сохраняет выбранный последний успешный IP.
            if inputHost.isEmpty {
                inputHost = live.host
                inputPort = String(live.port)
            }
            updateFingerprintDisplay()
        }
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
            inputHost = ConnectionHostAddress.normalized(host)
            inputPort = String(port)
        }
        updateFingerprintDisplay()
    }
    
    private func saveToHistory(host: String, port: Int) {
        let normalizedHost = ConnectionHostAddress.normalized(host)
        var updated = history.filter { !(ConnectionHostAddress.normalized($0.host) == normalizedHost && $0.port == port) }
        let name = vm.discoveryService.discoveredDevices.first(where: { ConnectionHostAddress.normalized($0.host) == normalizedHost && $0.port == port })?.name
            ?? PhoneConnectionManager.shared.deviceNameForHost(normalizedHost)
            ?? "Телефон Android"
        updated.insert(SavedConnection(name: name, host: normalizedHost, port: port, date: Date()), at: 0)
        updated = Array(updated.prefix(4))
        history = updated
        if let data = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(data, forKey: "phoneConnectionHistory")
        }
    }
    
    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: "phoneConnectionHistory"),
           let saved = try? JSONDecoder().decode([SavedConnection].self, from: data) {
            var seen = Set<String>()
            history = saved.compactMap { item in
                let host = ConnectionHostAddress.normalized(item.host)
                let key = "\(host):\(item.port)"
                guard seen.insert(key).inserted else { return nil }
                return SavedConnection(name: item.name, host: host, port: item.port, date: item.date)
            }.prefix(4).map { $0 }
            if let normalized = try? JSONEncoder().encode(history) {
                UserDefaults.standard.set(normalized, forKey: "phoneConnectionHistory")
            }
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
