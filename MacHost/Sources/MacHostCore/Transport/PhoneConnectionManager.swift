import Foundation

public enum ConnectionResult: Sendable {
    case usbSuccess(deviceId: String, host: String, port: UInt16, log: String)
    case wifiSuccess(host: String, port: UInt16, name: String)
    case unauthorized(deviceId: String, log: String)
    case failure(reason: String, log: String)
}

public final class PhoneConnectionManager: @unchecked Sendable {
    public static let shared = PhoneConnectionManager()
    
    public private(set) var lastConnectedDeviceId: String?
    private let lock = NSLock()
    
    private init() {}
    
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
        // 1. В ресурсах текущего бандла
        if let bundleRes = Bundle.main.url(forResource: "app-debug", withExtension: "apk"),
           FileManager.default.fileExists(atPath: bundleRes.path) {
            return bundleRes.path
        }
        
        // 2. В Contents/Resources бандла MacDroid Commander.app
        let execUrl = Bundle.main.bundleURL
        let inBundle = execUrl.appendingPathComponent("Contents/Resources/app-debug.apk").path
        if FileManager.default.fileExists(atPath: inBundle) {
            return inBundle
        }
        
        // 3. В рабочей директории сборки
        let candidates = [
            "build/MacDroid Commander.app/Contents/Resources/app-debug.apk",
            "AndroidCompanion/app/build/outputs/apk/debug/app-debug.apk",
            "../AndroidCompanion/app/build/outputs/apk/debug/app-debug.apk"
        ]
        
        let pwd = FileManager.default.currentDirectoryPath
        for c in candidates {
            let full = (pwd as NSString).appendingPathComponent(c)
            if FileManager.default.fileExists(atPath: full) {
                return full
            }
        }
        
        return nil
    }
    
    @discardableResult
    public func runCommand(executable: String, arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (-1, error.localizedDescription)
        }
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
        guard !paths.isEmpty else { return }
        // Сканируем порциями, чтобы не перегружать adb
        for path in paths {
            let escaped = Self.shellEscape("file://" + path)
            _ = executeAdbShell(
                command: "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(escaped)",
                deviceId: deviceId
            )
        }
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
    
    public func establishConnection() async -> ConnectionResult {
        var logs: [String] = []
        logs.append("==================================================")
        logs.append("  MacDroid Commander - Установка связи с телефоном")
        logs.append("==================================================")
        
        // Шаг 1: Проверка наличия ADB
        if let adb = findAdbBinary() {
            let (_, versionOut) = runCommand(executable: adb, arguments: ["version"])
            let firstLine = versionOut.components(separatedBy: "\n").first ?? versionOut
            logs.append("Используется ADB: \(firstLine)")
            
            // Шаг 2: Поиск подключенных Android-устройств
            let (_, devicesOut) = runCommand(executable: adb, arguments: ["devices"])
            logs.append("Поиск подключенных Android-устройств через ADB...")
        
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
            let dev = unauthorizedDevices[0]
            logs.append("⚠️ Устройство '\(dev)' подключено, но не авторизовано.")
            logs.append("   Пожалуйста, подтвердите RSA-ключ на экране смартфона.")
            return .unauthorized(
                deviceId: dev,
                log: logs.joined(separator: "\n")
            )
        }
        
        // Шаг 4: Найдено авторизованное устройство по USB / ADB
        if let dev = authorizedDevices.first {
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
                        arguments: ["-s", dev, "install", "-r", "-d", "-g", apkPath]
                    )
                    if instStatus == 0 && instOut.contains("Success") {
                        logs.append("✓ [OK] Компаньон успешно установлен на смартфон")
                    } else {
                        logs.append("⚠️ Предупреждение установки APK: \(instOut)")
                    }
                } else {
                    logs.append("⚠️ Файл app-debug.apk не найден в бандле приложения.")
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
            
            // 4.3 Проброс портов
            logs.append("Настройка проброса портов (Host 127.0.0.1:2222 <-> Phone:2222)...")
            let (fwdStatus, fwdOut) = runCommand(executable: adb, arguments: ["-s", dev, "forward", "tcp:2222", "tcp:2222"])
            if fwdStatus != 0 {
                logs.append("⚠️ Ошибка 'adb forward': \(fwdOut)")
            } else {
                logs.append("✓ [OK] Порт 2222 (forward) успешно перенаправлен")
            }
            
            let (revStatus, revOut) = runCommand(executable: adb, arguments: ["-s", dev, "reverse", "tcp:2222", "tcp:2222"])
            if revStatus != 0 {
                logs.append("⚠️ Предупреждение 'adb reverse': \(revOut)")
            } else {
                logs.append("✓ [OK] Порт 2222 (reverse) успешно перенаправлен")
            }
            
            // 4.4 Фоновый запуск сервиса/приложения на смартфоне
            logs.append("Запуск приложения и демона FileDaemonService на телефоне...")
            _ = runCommand(executable: adb, arguments: ["-s", dev, "shell", "am", "start", "-n", "com.macandroid.filemanager/.ui.MainActivity"])
            _ = runCommand(executable: adb, arguments: ["-s", dev, "shell", "am", "start-foreground-service", "com.macandroid.filemanager/.runtime.FileDaemonService"])
            
            // Небольшая задержка для готовности сокета SFTP на телефоне
            try? await Task.sleep(nanoseconds: 350_000_000)
            
            logs.append("✓ Соединение с телефоном через USB (127.0.0.1:2222) готово к работе!")
            return .usbSuccess(
                deviceId: dev,
                host: "127.0.0.1",
                port: 2222,
                log: logs.joined(separator: "\n")
            )
        }
        } else {
            logs.append("ℹ️ Утилита 'adb' не найдена в системе, проверка USB пропущена.")
        }
        
        // Шаг 5: Устройства по USB не обнаружены — проверяем подключение по Wi-Fi
        logs.append("ℹ️ Устройства по USB не обнаружены. Автоматический поиск телефона в локальной сети (Wi-Fi)...")
        
        if let foundIp = discoverPhoneIpOnLan() {
            logs.append("✓ [OK] Телефон найден и доступен по Wi-Fi (\(foundIp):2222)")
            return .wifiSuccess(
                host: foundIp,
                port: 2222,
                name: "Xiaomi 14"
            )
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
    
    /// Автоматическое обнаружение IP-адреса телефона в локальной сети (ARP + port 2222)
    public func discoverPhoneIpOnLan() -> String? {
        var priorities: [String] = []
        if let saved = UserDefaults.standard.string(forKey: "lastConnectedHost"), !saved.isEmpty {
            priorities.append(saved)
        }
        if !priorities.contains("192.168.1.18") {
            priorities.append("192.168.1.18")
        }
        if !priorities.contains("192.168.1.19") {
            priorities.append("192.168.1.19")
        }
        for ip in priorities {
            if isHostPortReachable(host: ip, port: 2222, timeoutSeconds: 1) {
                return ip
            }
        }
        
        // Сканируем устройства из локальной ARP-таблицы macOS
        let (status, arpOut) = runCommand(executable: "/usr/sbin/arp", arguments: ["-an"])
        if status == 0 {
            let lines = arpOut.components(separatedBy: "\n")
            for line in lines {
                guard line.contains("(") && line.contains(")") else { continue }
                guard let start = line.firstIndex(of: "("),
                      let end = line.firstIndex(of: ")"),
                      start < end else { continue }
                let ip = String(line[line.index(after: start)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !priorities.contains(ip) && isHostPortReachable(host: ip, port: 2222, timeoutSeconds: 1) {
                    return ip
                }
            }
        }
        return nil
    }
    
    /// Быстрая проверка доступности сетевого порта хоста (для проверки Wi-Fi связи)
    public func isHostPortReachable(host: String, port: UInt16, timeoutSeconds: Int = 1) -> Bool {
        let (status, _) = runCommand(
            executable: "/usr/bin/nc",
            arguments: ["-zv", "-G", String(timeoutSeconds), host, String(port)]
        )
        return status == 0
    }
}
