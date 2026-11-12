import Foundation
import Darwin

public enum ConnectionResult: Sendable {
    case usbSuccess(deviceId: String, host: String, port: UInt16, log: String)
    case wifiSuccess(host: String, port: UInt16, name: String)
    case unauthorized(deviceId: String, log: String)
    /// Служба MacDroid найдена по Wi-Fi, но её ключ не закреплён: нужно сопряжение.
    case wifiUnpaired(hosts: [String], log: String)
    case failure(reason: String, log: String)
}

/// Результат автоматического поиска телефона в Wi-Fi сети.
public enum LanPhoneSearchResult: Sendable, Equatable {
    case paired(host: String, port: UInt16, pinKey: String, name: String)
    case unpaired(hosts: [String])
    case notFound
}

public struct SSHHostKeyObservation: Sendable {
    public let fingerprint: String
    public let knownHostsLine: String
    public let keyAlgorithm: String

    public init(fingerprint: String, knownHostsLine: String, keyAlgorithm: String) {
        self.fingerprint = fingerprint
        self.knownHostsLine = knownHostsLine
        self.keyAlgorithm = keyAlgorithm
    }
}

/// Опознание USB-маршрута по ключу узла, как у Wi-Fi. Чистая политика: adb и ssh-keyscan передаются снаружи,
/// поэтому решения проверяются тестами без сети и без adb.
public enum UsbRoutePolicy {
    public enum ProbeOutcome: Equatable, Sendable {
        /// Ключ узла совпал с закреплённым: pinKey и отпечаток.
        case pinned(pinKey: String, fingerprint: String)
        /// Ключ не закреплён или сервис на телефоне не отвечает.
        case notPinned
    }

    public enum BackgroundDecision: Equatable, Sendable {
        case connect(serial: String)
        /// Пауза повторов по ключу usb:<серийник>.
        case pause
        /// Запись известна и автоподключение выключено.
        case skip
    }

    /// Фоновое автоподключение для одного авторизованного серийника.
    /// Подключение только после пробы: ключ узла должен совпасть с закреплённым, и запись должна иметь autoConnect.
    /// Известный реестру серийник проверяется так же, как неизвестный: серийник — лишь маршрут, а ключ может смениться.
    /// knownAutoConnect == false — запись с выключенным автоподключением не подключается, проба не нужна (.skip).
    public static func backgroundDecision(
        serial: String,
        knownAutoConnect: Bool?,
        probe: () -> ProbeOutcome,
        autoConnectFor: (_ pinKey: String, _ fingerprint: String) -> Bool?
    ) -> BackgroundDecision {
        if knownAutoConnect == false {
            return .skip
        }
        switch probe() {
        case .notPinned:
            return .pause
        case .pinned(let pinKey, let fingerprint):
            return autoConnectFor(pinKey, fingerprint) == true ? .connect(serial: serial) : .pause
        }
    }

    /// PHONE после пустого Wi-Fi поиска: первый серийник, опознанный пробой по закреплённому ключу.
    /// Неопознанный серийник никогда не выбирается: establishConnection (установка APK, appops, am start)
    /// запускается только для опознанного телефона. При requireAutoConnect (без явного действия пользователя)
    /// опознанный телефон выбирается только если его запись реестра имеет autoConnect == true.
    public static func phoneUsbSerial(
        authorized: [String],
        requireAutoConnect: Bool,
        probe: (String) -> ProbeOutcome,
        autoConnectFor: (_ pinKey: String, _ fingerprint: String) -> Bool?
    ) -> String? {
        for serial in authorized {
            guard case .pinned(let pinKey, let fingerprint) = probe(serial) else { continue }
            if !requireAutoConnect { return serial }
            if autoConnectFor(pinKey, fingerprint) == true { return serial }
        }
        return nil
    }
}

public final class PhoneConnectionManager: @unchecked Sendable {
    public static let shared = PhoneConnectionManager()
    
    public private(set) var lastConnectedDeviceId: String?
    private var discoveredDevices: [DiscoveredDevice] = []
    private var deviceNamesByHost: [String: String] = [:]
    private let lock = NSLock()
    
    private init() {}
    
    public func registerDevice(host: String, name: String) {
        lock.lock()
        let normHost = ConnectionHostAddress.normalized(host)
        deviceNamesByHost[host] = name
        deviceNamesByHost[normHost] = name
        lock.unlock()
        
        if name != "Телефон Android" && name != "Android" && !name.isEmpty {
            DeviceRegistry.shared.updateDeviceName(matchingHost: normHost, name: name)
            if let data = UserDefaults.standard.data(forKey: "phoneConnectionHistory"),
               var history = try? JSONDecoder().decode([SavedConnection].self, from: data) {
                var changed = false
                for i in 0..<history.count {
                    if ConnectionHostAddress.normalized(history[i].host) == normHost {
                        if history[i].name == "Телефон Android" || history[i].name == "Android" || history[i].name.isEmpty {
                            history[i] = SavedConnection(name: name, host: history[i].host, port: history[i].port, date: history[i].date)
                            changed = true
                        }
                    }
                }
                if changed, let encoded = try? JSONEncoder().encode(history) {
                    UserDefaults.standard.set(encoded, forKey: "phoneConnectionHistory")
                }
            }
        }
    }
    
    public func deviceNameForHost(_ host: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return deviceNamesByHost[host]
    }
    
    public func setLastConnectedDevice(_ id: String?) {
        lock.lock()
        defer { lock.unlock() }
        lastConnectedDeviceId = id
    }
    
    public func getConnectedDeviceId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastConnectedDeviceId
    }
    
    public var isDeviceConnected: Bool {
        return getConnectedDeviceId() != nil
    }
    
    public func findAdbBinary() -> String? {
        // 1. User's Android SDK platform-tools in macOS
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let sdkAdb = (homeDir as NSString).appendingPathComponent("Library/Android/sdk/platform-tools/adb")
        if FileManager.default.isExecutableFile(atPath: sdkAdb) {
            return sdkAdb
        }
        
        // 2. Homebrew Apple Silicon
        let brewArmAdb = "/opt/homebrew/bin/adb"
        if FileManager.default.isExecutableFile(atPath: brewArmAdb) {
            return brewArmAdb
        }
        
        // 3. Homebrew Intel / MacPorts
        let brewIntelAdb = "/usr/local/bin/adb"
        if FileManager.default.isExecutableFile(atPath: brewIntelAdb) {
            return brewIntelAdb
        }
        
        // 4. Check via PATH using /usr/bin/which
        let whichProc = Process()
        whichProc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProc.arguments = ["adb"]
        let pipe = Pipe()
        whichProc.standardOutput = pipe
        try? whichProc.run()
        whichProc.waitUntilExit()
        if whichProc.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        
        return nil
    }
    
    /// Поиск APK-файла компаньона (в бандле приложения или проекте)
    public func findCompanionApk() -> String? {
        // 1. В ресурсах текущего бандла (Contents/Resources)
        if let resources = Bundle.main.resourceURL, let apk = Self.newestCompanionApk(in: resources.path) {
            return apk
        }

        // 2. В Contents/Resources бандла MacDroid Commander.app
        let inBundle = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources").path
        if let apk = Self.newestCompanionApk(in: inBundle) {
            return apk
        }

        // 3. В рабочей директории сборки
        let candidateDirs = [
            "Resources",
            "MacHost/Resources",
            "build/MacDroid Commander.app/Contents/Resources",
            "AndroidCompanion/app/build/outputs/apk/debug",
            "../AndroidCompanion/app/build/outputs/apk/debug"
        ]

        let pwd = FileManager.default.currentDirectoryPath
        for dir in candidateDirs {
            if let apk = Self.newestCompanionApk(in: (pwd as NSString).appendingPathComponent(dir)) {
                return apk
            }
        }

        return nil
    }

    /// Версия компаньона из имени файла `MacDroidCompanion-2.1.14.apk` (nil для старого `app-debug.apk`).
    public static func companionApkVersion(fileName: String) -> [Int]? {
        let prefix = "MacDroidCompanion-"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(".apk") else { return nil }
        let version = fileName.dropFirst(prefix.count).dropLast(".apk".count)
        let parts = version.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }

    /// Самый свежий APK компаньона в каталоге: `MacDroidCompanion-<версия>.apk`, затем старое имя `app-debug.apk`.
    public static func newestCompanionApk(in directory: String) -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let versioned = files.compactMap { name -> (String, [Int])? in
            companionApkVersion(fileName: name).map { (name, $0) }
        }
        if let newest = versioned.max(by: { $0.1.lexicographicallyPrecedes($1.1) }) {
            return (directory as NSString).appendingPathComponent(newest.0)
        }
        if files.contains("app-debug.apk") {
            return (directory as NSString).appendingPathComponent("app-debug.apk")
        }
        return nil
    }
    
    @discardableResult
    public func runCommand(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval = 15
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let timeoutLock = NSLock()
            var timedOut = false
            let timeout = DispatchWorkItem {
                timeoutLock.lock()
                timedOut = true
                timeoutLock.unlock()
                guard process.isRunning else { return }
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
            // Читаем stdout до waitUntilExit, чтобы избежать взаимной блокировки (deadlock)
            // при заполнении 64 КБ буфера системного pipe дочерним процессом (adb ls -la)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            timeout.cancel()
            process.waitUntilExit()
            let out = String(data: data, encoding: .utf8) ?? ""
            timeoutLock.lock()
            let didTimeout = timedOut
            timeoutLock.unlock()
            let timeoutNote = didTimeout ? "\nCommand timed out after \(Int(timeoutSeconds)) seconds." : ""
            return (didTimeout ? -2 : process.terminationStatus, (out + timeoutNote).trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    /// Авторизованные serial-номера из текущего ADB server snapshot.
    public func authorizedAdbDeviceIds() -> [String] {
        authorizedAdbDeviceIdsIfAvailable() ?? []
    }

    /// Авторизованные serial-номера, если adb ответил. `[]` — adb ответил и устройств нет;
    /// `nil` — adb не найден, завершился с ошибкой или не уложился в таймаут (ответа нет).
    public func authorizedAdbDeviceIdsIfAvailable() -> [String]? {
        guard let adb = findAdbBinary() else { return nil }
        let (status, output) = runCommand(executable: adb, arguments: ["devices"], timeoutSeconds: 8)
        guard status == 0 else { return nil }
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t")
            guard fields.count >= 2, fields[1] == "device" else { return nil }
            return String(fields[0])
        }
    }

    /// Неинвазивная проба USB: временный adb forward на свободный порт, ключ узла, сверка с закреплением.
    /// Не ставит APK, не меняет appops и не запускает экран. Forward снимается сразу после пробы.
    public func probeUsbRoute(serial: String) -> UsbRoutePolicy.ProbeOutcome {
        guard let adb = findAdbBinary() else { return .notPinned }
        let (status, out) = runCommand(executable: adb, arguments: ["-s", serial, "forward", "tcp:0", "tcp:2222"], timeoutSeconds: 8)
        guard status == 0, let port = UInt16(out.trimmingCharacters(in: .whitespacesAndNewlines)) else { return .notPinned }
        defer {
            runCommand(executable: adb, arguments: ["-s", serial, "forward", "--remove", "tcp:\(port)"], timeoutSeconds: 8)
        }
        guard let observation = fetchHostKeyObservation(host: "127.0.0.1", port: port),
              let pinKey = HostKeyStore.shared.pinnedDeviceId(matchingFingerprint: observation.fingerprint),
              case .trusted = HostKeyStore.shared.verifyPinned(deviceId: pinKey, fingerprint: observation.fingerprint) else {
            return .notPinned
        }
        return .pinned(pinKey: pinKey, fingerprint: observation.fingerprint)
    }

    /// Серийник для PHONE по USB, когда Wi-Fi не нашёл телефон: только опознанный пробой по закреплённому ключу.
    /// requireAutoConnect == true (без явного действия) — дополнительно требуется autoConnect записи реестра.
    public func chooseUsbSerialForPhone(requireAutoConnect: Bool) -> String? {
        UsbRoutePolicy.phoneUsbSerial(
            authorized: authorizedAdbDeviceIds(),
            requireAutoConnect: requireAutoConnect,
            probe: { self.probeUsbRoute(serial: $0) },
            autoConnectFor: { pinKey, fingerprint in
                DeviceRegistry.shared.device(withId: pinKey, orFingerprint: fingerprint)?.autoConnect
            }
        )
    }

    /// Выполнение произвольной команды adb shell
    @discardableResult
    public func executeAdbShell(command: String, deviceId: String? = nil) -> (status: Int32, output: String) {
        guard let adb = findAdbBinary() else { return (-1, "ADB not found") }
        let targetDev = deviceId ?? getConnectedDeviceId()
        var args: [String] = []
        if let dev = targetDev, !dev.isEmpty {
            args += ["-s", dev]
        }
        args += ["shell", command]
        return runCommand(executable: adb, arguments: args)
    }
    
    /// Безопасное экранирование аргументов для POSIX shell (предотвращает Command Injection)
    public static func shellEscape(_ string: String) -> String {
        return "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    
    /// Быстрое удаление через ADB rm -rf (включая непустые каталоги)
    public func fastDeleteAdb(remotePath: String, deviceId: String? = nil) -> Bool {
        let escaped = Self.shellEscape(remotePath)
        let res = executeAdbShell(command: "rm -rf -- \(escaped)", deviceId: deviceId)
        return res.status == 0
    }
    
    /// Триггер обновления Android MediaStore для списка файлов
    public func notifyMediaScanner(paths: [String], deviceId: String? = nil) {
        guard !paths.isEmpty, let deviceId, !deviceId.isEmpty else { return }
        // Оптимизация: сканируем пачками по 50 файлов в одном adb shell вызове
        // вместо порождения сотен отдельных процессов adb
        let batchSize = 50
        for i in stride(from: 0, to: paths.count, by: batchSize) {
            let chunk = Array(paths[i..<min(i + batchSize, paths.count)])
            let commands = chunk.map { path in
                "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(Self.shellEscape("file://" + path))"
            }.joined(separator: " ; ")
            _ = executeAdbShell(command: commands, deviceId: deviceId)
        }
    }
    
    /// Серверное копирование файла внутри Android устройства без передачи данных на Mac.
    /// Не перезаписывает существующий объект: проверка и cp выполняются одной командой на устройстве.
    /// Возвращает false, если цель уже существует (код выхода 17) или копирование не удалось.
    public func copyFileOnDevice(sourcePath: String, targetPath: String, deviceId: String? = nil) -> Bool {
        let srcEsc = Self.shellEscape(sourcePath)
        let dstEsc = Self.shellEscape(targetPath)
        let command = "if [ -e \(dstEsc) ] || [ -L \(dstEsc) ]; then exit 17; fi; cp -p -- \(srcEsc) \(dstEsc)"
        let (status, _) = executeAdbShell(command: command, deviceId: deviceId)
        return status == 0
    }

    /// Удаление файла на устройстве через adb, строго на устройстве с указанным serial.
    /// Без serial возвращает false: adb без -s адресует «какой-то» подключённый телефон.
    public func removeFileViaAdb(remotePath: String, deviceId: String?) -> Bool {
        guard let deviceId, !deviceId.isEmpty else { return false }
        let escaped = Self.shellEscape(remotePath)
        let res = executeAdbShell(command: "rm -f -- \(escaped)", deviceId: deviceId)
        return res.status == 0
    }
    
    /// Запрос реального объёма свободного и общего места на Android через ADB df
    public func getStorageSpaceAdb(deviceId: String? = nil) -> (free: UInt64, total: UInt64)? {
        let (status, out) = executeAdbShell(command: "df -k /storage/emulated/0", deviceId: deviceId)
        guard status == 0, !out.isEmpty else { return nil }
        
        let lines = out.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }
        
        // Формат: Filesystem 1K-blocks Used Available Use% Mounted on
        let parts = lines[1].split(whereSeparator: { $0.isWhitespace })
        if parts.count >= 4 {
            // parts[1] = Total 1K blocks, parts[3] = Available 1K blocks
            if let totalKb = UInt64(parts[1]), let availKb = UInt64(parts[3]) {
                let totalBytes = totalKb * 1024
                let freeBytes = availKb * 1024
                if totalBytes > 0 {
                    return (free: freeBytes, total: totalBytes)
                }
            }
        }
        return nil
    }
    
    public struct StorageVolume: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let path: String
        public let isPrimary: Bool
        
        public init(id: String, name: String, path: String, isPrimary: Bool) {
            self.id = id
            self.name = name
            self.path = path
            self.isPrimary = isPrimary
        }
    }
    
    /// Обнаружение смонтированных томов (внутренняя память, SD-карта, OTG-флешка)
    public func detectStorageVolumes() -> [StorageVolume] {
        var volumes: [StorageVolume] = [
            StorageVolume(id: "internal", name: "Внутренняя память", path: "/storage/emulated/0", isPrimary: true)
        ]
        
        let (status, output) = executeAdbShell(command: "ls -1 /storage")
        if status == 0 {
            let entries = output.components(separatedBy: CharacterSet.newlines)
            for entry in entries {
                let trimmed = entry.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed == "emulated" || trimmed == "self" || trimmed == "knox" || trimmed == "sdcard0" {
                    continue
                }
                let volPath = "/storage/\(trimmed)"
                volumes.append(StorageVolume(id: trimmed, name: "Внешний накопитель (\(trimmed))", path: volPath, isPrimary: false))
            }
        }
        return volumes
    }
    
    /// Получение реального списка файлов директории телефона напрямую через ADB shell (fallback)
    public func listDirectoryAdb(path: String, deviceId: String? = nil) -> [FileItem]? {
        guard let adb = findAdbBinary() else { return nil }
        let targetDev = deviceId ?? getConnectedDeviceId()
        
        let devId: String?
        if let targetDev = targetDev, !targetDev.isEmpty {
            devId = targetDev
        } else {
            // Быстрая проверка подключенных устройств
            let (status, out) = runCommand(executable: adb, arguments: ["devices"])
            guard status == 0 else { return nil }
            let lines = out.components(separatedBy: "\n")
            var found: String? = nil
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix("List of devices") || trimmed.hasPrefix("*") { continue }
                let parts = trimmed.split(separator: "\t")
                if parts.count >= 2 && parts[1] == "device" {
                    found = String(parts[0])
                    break
                }
            }
            guard let autoDev = found else { return nil }
            setLastConnectedDevice(autoDev)
            devId = autoDev
        }
        
        let nfcPath = path.precomposedStringWithCanonicalMapping
        let escaped = Self.shellEscape(nfcPath)
        
        // 1. Пробуем подробный вывод ls -la (с метаданными, размерами и датами)
        let (statusLa, outLa) = executeAdbShell(command: "ls -la -- \(escaped)", deviceId: devId)
        if statusLa == 0 && !outLa.isEmpty {
            let items = parseAdbLsLongOutput(outLa, parentPath: nfcPath)
            if !items.isEmpty {
                return items
            }
        }
        
        // 2. Если ls -la пуст или дал сбой разбора — используем гарантированный ls -1ap
        let (status1ap, out1ap) = executeAdbShell(command: "ls -1ap -- \(escaped)", deviceId: devId)
        if status1ap == 0 {
            return parseAdbLsSimpleOutput(out1ap, parentPath: nfcPath)
        }
        
        return nil
    }
    
    public func parseAdbLsLongOutput(_ output: String, parentPath: String) -> [FileItem] {
        var results: [FileItem] = []
        let now = Date().timeIntervalSince1970
        let lines = output.components(separatedBy: "\n")
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("total") { continue }
            
            let tokens = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard tokens.count >= 6 else { continue }
            
            let perms = tokens[0]
            guard perms.count >= 10,
                  perms.hasPrefix("-") || perms.hasPrefix("d") || perms.hasPrefix("l") else {
                continue
            }
            let isDir = perms.hasPrefix("d")
            
            // Поиск токена даты YYYY-MM-DD
            var dateIndex = -1
            for (idx, token) in tokens.enumerated() {
                if token.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                    dateIndex = idx
                    break
                }
            }
            
            var size: UInt64 = 0
            var fileName = ""
            
            if dateIndex > 0 {
                // Токен перед датой — размер
                size = UInt64(tokens[dateIndex - 1]) ?? 0
                // После времени (dateIndex + 1) идет имя файла
                let nameStartIndex = dateIndex + 2
                if nameStartIndex < tokens.count {
                    fileName = tokens[nameStartIndex...].joined(separator: " ")
                }
            } else {
                // POSIX-формат (size на позиции 4)
                if tokens.count >= 8 {
                    size = UInt64(tokens[4]) ?? 0
                    fileName = tokens[8...].joined(separator: " ")
                }
            }
            
            if fileName.isEmpty {
                fileName = tokens.last ?? ""
            }
            
            // Если это ссылка `name -> target`, извлекаем только имя ссылки
            if let arrowRange = fileName.range(of: " -> ") {
                fileName = String(fileName[..<arrowRange.lowerBound])
            }
            
            fileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
            if fileName == "." || fileName == ".." || fileName.isEmpty {
                continue
            }
            
            let itemPath = (parentPath as NSString).appendingPathComponent(fileName).precomposedStringWithCanonicalMapping
            results.append(FileItem(
                id: itemPath,
                name: fileName,
                path: itemPath,
                size: size,
                mtime: now,
                isDirectory: isDir,
                source: .remotePhone
            ))
        }
        return results
    }
    
    public func parseAdbLsSimpleOutput(_ output: String, parentPath: String) -> [FileItem] {
        var results: [FileItem] = []
        let now = Date().timeIntervalSince1970
        let lines = output.components(separatedBy: "\n")
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "./" || trimmed == "../" || trimmed == "." || trimmed == ".." {
                continue
            }
            let isDir = trimmed.hasSuffix("/")
            let fileName = isDir ? String(trimmed.dropLast()) : trimmed
            guard !fileName.isEmpty else { continue }
            
            let itemPath = (parentPath as NSString).appendingPathComponent(fileName).precomposedStringWithCanonicalMapping
            results.append(FileItem(
                id: itemPath,
                name: fileName,
                path: itemPath,
                size: 0,
                mtime: now,
                isDirectory: isDir,
                source: .remotePhone
            ))
        }
        return results
    }
    
    public func establishConnection(preferredDeviceId: String? = nil) async -> ConnectionResult {
        var logs: [String] = []
        logs.append("==================================================")
        logs.append("  MacDroid Commander - Установка связи с телефоном")
        logs.append("==================================================")
        
        // Шаг 1: Проверка наличия ADB
        if let adb = findAdbBinary() {
            let (_, versionOut) = runCommand(executable: adb, arguments: ["version"], timeoutSeconds: 8)
            let firstLine = versionOut.components(separatedBy: "\n").first ?? versionOut
            logs.append("Используется ADB: \(firstLine)")
            
            // Шаг 2: Поиск подключенных Android-устройств
            let (devicesStatus, devicesOut) = runCommand(executable: adb, arguments: ["devices"], timeoutSeconds: 8)
            logs.append("Поиск подключенных Android-устройств через ADB...")
            guard devicesStatus == 0 else {
                return .failure(reason: "ADB не ответил при поиске устройств.", log: logs.joined(separator: "\n") + "\n" + devicesOut)
            }
        
        let lines = devicesOut.components(separatedBy: "\n")
        var authorizedDevices: [String] = []
        var unauthorizedDevices: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("List of devices") || trimmed.hasPrefix("*") {
                continue
            }
            let parts = trimmed.split(separator: "\t")
            if parts.count >= 2 {
                let devId = String(parts[0])
                let state = String(parts[1])
                if state == "device" {
                    authorizedDevices.append(devId)
                } else if state == "unauthorized" {
                    unauthorizedDevices.append(devId)
                }
            }
        }
        
        // Шаг 3: Проверка неподтвержденных устройств
        if authorizedDevices.isEmpty && !unauthorizedDevices.isEmpty {
            let unauthorizedTarget = preferredDeviceId.flatMap { preferred in
                unauthorizedDevices.first(where: { $0 == preferred })
            }
            if preferredDeviceId != nil && unauthorizedTarget == nil {
                return .failure(reason: "Выбранное ADB-устройство \(preferredDeviceId!) больше не подключено.", log: logs.joined(separator: "\n"))
            }
            let dev = unauthorizedTarget ?? unauthorizedDevices[0]
            logs.append("⚠️ Устройство '\(dev)' подключено, но не авторизовано.")
            logs.append("   Пожалуйста, подтвердите RSA-ключ на экране смартфона.")
            return .unauthorized(
                deviceId: dev,
                log: logs.joined(separator: "\n")
            )
        }
        
        // Шаг 4: Найдено авторизованное устройство по USB / ADB
        if preferredDeviceId != nil && !authorizedDevices.contains(preferredDeviceId!) {
            return .failure(reason: "Выбранное ADB-устройство \(preferredDeviceId!) не найдено или не авторизовано.", log: logs.joined(separator: "\n"))
        }
        if let dev = preferredDeviceId ?? authorizedDevices.first {
            guard authorizedDevices.contains(dev) else {
                return .failure(reason: "ADB-устройство \(dev) сейчас недоступно.", log: logs.joined(separator: "\n"))
            }
            setLastConnectedDevice(dev)
            logs.append("✓ Найдено устройство: \(dev)")
            
            // 4.1 Plug & Play: Проверка наличия установленного пакета компаньона
            let (pkgStatus, pkgOut) = runCommand(executable: adb, arguments: ["-s", dev, "shell", "pm", "path", "com.macandroid.filemanager"])
            let isInstalled = (pkgStatus == 0 && pkgOut.contains("package:"))
            
            if !isInstalled {
                logs.append("📦 Компаньон com.macandroid.filemanager не найден. Автоматическая установка APK...")
                if let apkPath = findCompanionApk() {
                    logs.append("   Установка из: \(apkPath)")
                    let (instStatus, instOut) = runCommand(
                        executable: adb,
                        arguments: ["-s", dev, "install", "-r", "-d", "-g", apkPath],
                        timeoutSeconds: 120
                    )
                    if instStatus == 0 && instOut.contains("Success") {
                        logs.append("✓ [OK] Компаньон успешно установлен на смартфон")
                    } else {
                        logs.append("⚠️ Предупреждение установки APK: \(instOut)")
                    }
                } else {
                    logs.append("⚠️ APK компаньона (MacDroidCompanion-<версия>.apk) не найден в бандле приложения.")
                }
            } else {
                logs.append("✓ [OK] Приложение-компаньон уже установлено на смартфоне")
            }
            
            // 4.2 Автоматическая выдача разрешения MANAGE_EXTERNAL_STORAGE (Android 11-14 / HyperOS)
            logs.append("Выдача системного разрешения MANAGE_EXTERNAL_STORAGE через appops...")
            let (appopsStatus, appopsOut) = runCommand(
                executable: adb,
                arguments: ["-s", dev, "shell", "appops", "set", "com.macandroid.filemanager", "MANAGE_EXTERNAL_STORAGE", "allow"]
            )
            if appopsStatus == 0 {
                logs.append("✓ [OK] Разрешение MANAGE_EXTERNAL_STORAGE успешно предоставлено")
            } else {
                logs.append("ℹ️ appops: \(appopsOut)")
            }
            
            // 4.3 Проброс портов (с поддержкой динамического порта при конфликтах)
            logs.append("Настройка проброса портов (Host 127.0.0.1 <-> Phone:2222)...")
            var localUsbPort: UInt16 = 2222
            var (fwdStatus, fwdOut) = runCommand(executable: adb, arguments: ["-s", dev, "forward", "--no-rebind", "tcp:2222", "tcp:2222"])
            if fwdStatus != 0 {
                // Если стандартный порт 2222 занят другим процессом, выделяем свободный динамический порт
                let (dynStatus, dynOut) = runCommand(executable: adb, arguments: ["-s", dev, "forward", "--no-rebind", "tcp:0", "tcp:2222"])
                if dynStatus == 0, let p = UInt16(dynOut.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    localUsbPort = p
                    fwdStatus = 0
                    logs.append("✓ [OK] Выделен свободный динамический порт \(localUsbPort) (forward)")
                } else {
                    logs.append("⚠️ Ошибка 'adb forward': \(fwdOut)")
                    return .failure(
                        reason: "Не удалось назначить USB-forward для устройства \(dev). Подключение остановлено, чтобы не использовать порт другого устройства.",
                        log: logs.joined(separator: "\n") + "\n" + dynOut
                    )
                }
            } else {
                logs.append("✓ [OK] Порт \(localUsbPort) (forward) успешно перенаправлен")
            }
            
            // Получаем реальное имя модели смартфона через ADB
            let (_, modelOut) = runCommand(executable: adb, arguments: ["-s", dev, "shell", "getprop", "ro.product.model"])
            let modelName = modelOut.trimmingCharacters(in: .whitespacesAndNewlines)
            if !modelName.isEmpty {
                registerDevice(host: "127.0.0.1", name: modelName)
            }
            
            // 4.4 Фоновый запуск сервиса/приложения на смартфоне
            logs.append("Запуск приложения и демона FileDaemonService на телефоне...")
            _ = runCommand(executable: adb, arguments: ["-s", dev, "shell", "am", "start", "-n", "com.macandroid.filemanager/.ui.MainActivity"])
            _ = runCommand(executable: adb, arguments: ["-s", dev, "shell", "am", "start-foreground-service", "com.macandroid.filemanager/.runtime.FileDaemonService"])
            
            // 4.5 Проверка готовности сокета SFTP (до 8 попыток с интервалом 250мс)
            var socketReady = false
            for _ in 0..<8 {
                if isHostPortReachable(host: "127.0.0.1", port: localUsbPort, timeoutSeconds: 1) {
                    socketReady = true
                    break
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            
            if socketReady {
                logs.append("✓ Соединение с телефоном через USB (127.0.0.1:\(localUsbPort)) готово к работе!")
                return .usbSuccess(
                    deviceId: dev,
                    host: "127.0.0.1",
                    port: localUsbPort,
                    log: logs.joined(separator: "\n")
                )
            } else {
                logs.append("⚠️ Служба на телефоне не ответила на порту \(localUsbPort).")
                return .failure(
                    reason: "Служба на телефоне запускается. Пожалуйста, разблокируйте экран телефона.",
                    log: logs.joined(separator: "\n")
                )
            }
        }
        } else {
            logs.append("ℹ️ Утилита 'adb' не найдена в системе, проверка USB пропущена.")
        }
        
        // Шаг 5: Устройства по USB не обнаружены — проверяем подключение по Wi-Fi
        logs.append("ℹ️ Устройства по USB не обнаружены. Автоматический поиск телефона в локальной сети (Wi-Fi)...")
        
        switch await findPairedPhoneOnLan(deep: true) {
        case .paired(let foundIp, let port, _, let devName):
            logs.append("✓ [OK] Сопряжённый телефон найден по Wi-Fi (\(foundIp):\(port)), ключ узла совпал")
            return .wifiSuccess(host: foundIp, port: port, name: devName)
        case .unpaired(let hosts):
            logs.append("ℹ️ Служба MacDroid отвечает на \(hosts.joined(separator: ", ")), но её ключ не сопряжён с этим Mac.")
            return .wifiUnpaired(hosts: hosts, log: logs.joined(separator: "\n"))
        case .notFound:
            break
        }
        
        logs.append("⚠️ Телефон не обнаружен ни по USB, ни по Wi-Fi.")
        logs.append("   Для подключения:")
        logs.append("   • По USB: подключите кабель и включите 'Отладку по USB'.")
        logs.append("   • По Wi-Fi: включите экран телефона и откройте приложение MacDroid Companion.")
        
        return .failure(
            reason: "Телефон не отвечает. Включите экран телефона или подключите USB-кабель.",
            log: logs.joined(separator: "\n")
        )
    }
    
    /// Поиск по последним и подтвержденным адресам; новые устройства обнаруживаются через Bonjour.
    public func discoverPhoneIpOnLan() -> String? {
        for ip in knownWifiCandidateHosts() {
            if isHostPortReachable(host: ip, port: 2222, timeoutSeconds: 1) {
                return ip
            }
        }
        return nil
    }

    /// Replaces the live Bonjour snapshot; withdrawn services must not accumulate forever.
    public func replaceDiscoveredDevices(_ devices: [DiscoveredDevice]) {
        lock.lock()
        discoveredDevices = devices
        lock.unlock()
        for device in devices { registerDevice(host: device.host, name: device.name) }
    }

    public func knownWifiCandidateHosts() -> [String] {
        var seen = Set<String>()
        return knownWifiCandidates().map { $0.endpoint.host }.filter { seen.insert($0).inserted }
    }

    /// Preserve ports from every source. Fresh Bonjour routes precede historical addresses;
    /// the verified device identity determines the final selection, rather than a stale IP.
    public func knownWifiCandidates(defaultPort: UInt16 = 2222) -> [WiFiSearchCandidate] {
        lock.lock()
        let discovered = discoveredDevices
        lock.unlock()
        let defaults = UserDefaults.standard
        var candidates: [WiFiSearchCandidate] = []
        var seen = Set<WiFiEndpoint>()
        func append(_ host: String, _ port: Int, bonjour: Bool = false) {
            let host = ConnectionHostAddress.normalized(host)
            guard ConnectionHostAddress.isIPv4(host), !host.hasPrefix("127."), host != "0.0.0.0",
                  let port = UInt16(exactly: port), port > 0 else { return }
            let endpoint = WiFiEndpoint(host: host, port: port)
            if seen.insert(endpoint).inserted {
                candidates.append(WiFiSearchCandidate(endpoint: endpoint, isBonjour: bonjour))
            }
        }
        for device in discovered.sorted(by: { $0.id < $1.id }) {
            append(device.host, device.port, bonjour: !device.isManual)
        }
        for prefix in ["lastSuccessfulPhone", "lastConnected"] {
            if let host = defaults.string(forKey: prefix + "Host") {
                let port = defaults.object(forKey: prefix + "Port") == nil
                    ? Int(defaultPort) : defaults.integer(forKey: prefix + "Port")
                append(host, port)
            }
        }
        if let data = defaults.data(forKey: "phoneConnectionHistory"),
           let history = try? JSONDecoder().decode([SavedConnection].self, from: data) {
            for item in history { append(item.host, item.port) }
        }
        for device in DeviceRegistry.shared.allDevices() {
            append(device.lastKnownHost, Int(device.lastKnownPort))
        }
        return candidates
    }

    /// PHONE waits for Bonjour and retries phones that are waking up. Background searches
    /// inspect only known routes and apply per-device eligibility before choosing a result.
    public func findPairedPhoneOnLan(
        deep: Bool,
        port: UInt16 = 2222,
        autoConnectOnly: Bool = false,
        excludedHosts: Set<String> = []
    ) async -> LanPhoneSearchResult {
        let defaults = UserDefaults.standard
        let preferred = defaults.string(forKey: "lastSuccessfulPhoneDeviceId")
            ?? defaults.string(forKey: "lastSuccessfulPhoneHost").flatMap {
                DeviceRegistry.shared.device(matchingHost: $0)?.id
            }
        let result = await WiFiPhoneSearch.search(
            deep: deep,
            preferredDeviceId: preferred,
            candidates: {
                self.searchCandidates(deep: deep, port: port, excludedHosts: excludedHosts)
            },
            fallbackCandidates: {
                guard !Task.isCancelled else { return [] }
                let hosts = NetworkPortReachability.fetchActiveLanIps() + NetworkPortReachability.localSubnetHosts()
                let open = NetworkPortReachability.scanOpenPort(hosts: hosts, port: port, timeoutMs: 450)
                return open.sorted().filter { !excludedHosts.contains($0) }.map {
                    WiFiSearchCandidate(endpoint: WiFiEndpoint(host: $0, port: port))
                }
            },
            probe: { candidate in
                guard !Task.isCancelled else { return .unavailable }
                let endpoint = candidate.endpoint
                guard let observation = self.fetchHostKeyObservation(host: endpoint.host, port: endpoint.port) else {
                    return .unavailable
                }
                guard !Task.isCancelled else { return .unavailable }
                guard let pinKey = HostKeyStore.shared.pinnedDeviceId(matchingFingerprint: observation.fingerprint),
                      case .trusted = HostKeyStore.shared.verifyPinned(deviceId: pinKey, fingerprint: observation.fingerprint) else {
                    return .unpaired
                }
                // pinKey может быть другим id того же отпечатка: запись реестра ищется и по отпечатку.
                let device = DeviceRegistry.shared.device(withId: pinKey, orFingerprint: observation.fingerprint)
                if autoConnectOnly && device?.autoConnect != true { return .unavailable }
                let name = device?.name ?? self.deviceNameForHost(endpoint.host) ?? "Телефон Android"
                return .paired(pinKey: pinKey, name: name)
            }
        )
        let outcome: String
        switch result {
        case .paired(let host, let foundPort, _, let name): outcome = "найден \(name) \(host):\(foundPort)"
        case .unpaired(let hosts): outcome = "не сопряжён \(hosts)"
        case .notFound: outcome = "не найден"
        }
        SSHTransportLog.event(key: "search \(deep)", signature: outcome,
                              "SEARCH \(deep ? "по кнопке" : "фон") результат=\(outcome) сети_Mac=\(LocalNetworkStatus.macSubnetsDescription())")
        return result
    }

    /// Кандидаты поиска. Адрес вне подсетей Mac — старый маршрут из истории: пакет уйдёт через шлюз
    /// в чужую сеть и повиснет до таймаута. Такие адреса не опрашиваются; адрес из Bonjour проверяется всегда.
    private func searchCandidates(deep: Bool, port: UInt16, excludedHosts: Set<String>) -> [WiFiSearchCandidate] {
        let all = knownWifiCandidates(defaultPort: port)
        var kept: [WiFiSearchCandidate] = []
        var foreign: [String] = []
        var paused: [String] = []
        for candidate in all {
            let host = candidate.endpoint.host
            if excludedHosts.contains(host) {
                paused.append(host)
            } else if !candidate.isBonjour && !LocalNetworkStatus.isOnMacSubnet(host) {
                foreign.append(host)
            } else {
                kept.append(candidate)
            }
        }
        let keptHosts = kept.map { $0.endpoint.host }
        SSHTransportLog.event(
            key: "candidates \(deep)",
            signature: "\(keptHosts)|\(foreign)|\(paused)",
            "CANDIDATES \(deep ? "по кнопке" : "фон") опрос=\(keptHosts) пропуск_чужая_сеть=\(foreign) пропуск_пауза=\(paused) сети_Mac=\(LocalNetworkStatus.macSubnetsDescription())"
        )
        return kept
    }

    /// Известные адреса телефонов, которые сейчас вне подсетей Mac (для сообщения «телефон в другой сети Wi-Fi»).
    public func knownHostsOutsideMacSubnets() -> [String] {
        knownWifiCandidates().filter { !$0.isBonjour && !LocalNetworkStatus.isOnMacSubnet($0.endpoint.host) }
            .map { $0.endpoint.host }
    }

    /// Известные адреса телефонов в подсетях Mac.
    public func knownHostsOnMacSubnets() -> [String] {
        knownWifiCandidates().filter { LocalNetworkStatus.isOnMacSubnet($0.endpoint.host) }.map { $0.endpoint.host }
    }

    /// Получает ключ через ssh-keyscan и возвращает строку known_hosts для строгой проверки самой SSH-сессии.
    public func fetchHostKeyObservation(host: String, port: UInt16) -> SSHHostKeyObservation? {
        let probe = NetworkPortReachability.probePort(host: host, port: port, timeoutMs: 1000)
        if !probe.isOpen {
            // Измерение: при отказе для адреса своей подсети та же проба дочерним процессом.
            if LocalNetworkStatus.isOnMacSubnet(host), !host.hasPrefix("127.") {
                _ = LocalNetworkStatus.childProbe(host: host, port: port)
            }
            return nil
        }
        
        let keyscanProc = Process()
        keyscanProc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
        keyscanProc.arguments = ["-p", String(port), "-T", "2", "--", host]
        let scanPipe = Pipe()
        keyscanProc.standardOutput = scanPipe
        keyscanProc.standardError = FileHandle.nullDevice
        
        // Защита от дедлока: жесткий таймаут 2.5 сек на случай зависания сокета
        let timer = DispatchWorkItem { [weak keyscanProc] in
            if keyscanProc?.isRunning == true {
                keyscanProc?.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5, execute: timer)
        
        do {
            try keyscanProc.run()
            // Читаем stdout ДО waitUntilExit, чтобы исключить блокировку при переполнении буфера
            let scanData = scanPipe.fileHandleForReading.readDataToEndOfFile()
            keyscanProc.waitUntilExit()
            timer.cancel()
            
            guard let scanText = String(data: scanData, encoding: .utf8) else { return nil }
            for scannedLine in scanText.components(separatedBy: .newlines) {
                let trimmedLine = scannedLine.trimmingCharacters(in: .whitespacesAndNewlines)
                let fields = trimmedLine.split(whereSeparator: \.isWhitespace)
                guard fields.count >= 3, !trimmedLine.hasPrefix("#") else { continue }

                let keygenProc = Process()
                keygenProc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
                keygenProc.arguments = ["-lf", "-"]
                let inPipe = Pipe()
                let outPipe = Pipe()
                keygenProc.standardInput = inPipe
                keygenProc.standardOutput = outPipe
                keygenProc.standardError = FileHandle.nullDevice

                try keygenProc.run()
                inPipe.fileHandleForWriting.write(Data((trimmedLine + "\n").utf8))
                inPipe.fileHandleForWriting.closeFile()
                let genData = outPipe.fileHandleForReading.readDataToEndOfFile()
                keygenProc.waitUntilExit()
                guard keygenProc.terminationStatus == 0,
                      let output = String(data: genData, encoding: .utf8),
                      let fingerprint = output.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("SHA256:") }) else {
                    continue
                }

                return SSHHostKeyObservation(
                    fingerprint: String(fingerprint),
                    knownHostsLine: trimmedLine,
                    keyAlgorithm: String(fields[1])
                )
            }
        } catch {
            timer.cancel()
            return nil
        }
        return nil
    }

    public func fetchHostFingerprint(host: String, port: UInt16) -> String? {
        fetchHostKeyObservation(host: host, port: port)?.fingerprint
    }
    
    /// Быстрая неблокирующая проверка доступности сетевого порта хоста (для проверки Wi-Fi связи)
    public func isHostPortReachable(host: String, port: UInt16, timeoutSeconds: Int = 1) -> Bool {
        return NetworkPortReachability.isPortOpen(host: host, port: port, timeoutMs: timeoutSeconds * 1000)
    }
}
