import Foundation
import Darwin

/// Быстрая неблокирующая проверка доступности сетевых портов через POSIX-сокеты
public enum NetworkPortReachability {
    
    /// Результат одной пробы порта: этап отказа и errno, чтобы запрет macOS отличался от молчания телефона.
    public struct ProbeResult: Sendable, Equatable {
        public let isOpen: Bool
        /// ok, resolve, socket, connect (отказ сразу), timeout (нет ответа за отведённое время), so_error (отказ после ожидания)
        public let stage: String
        public let errno: Int32
        public let durationMs: Int

        public var errnoName: String {
            switch errno {
            case 0: return "0"
            case EPERM: return "EPERM"
            case EACCES: return "EACCES"
            case EHOSTUNREACH: return "EHOSTUNREACH"
            case ENETUNREACH: return "ENETUNREACH"
            case ENETDOWN: return "ENETDOWN"
            case EHOSTDOWN: return "EHOSTDOWN"
            case ECONNREFUSED: return "ECONNREFUSED"
            case ETIMEDOUT: return "ETIMEDOUT"
            case ECONNRESET: return "ECONNRESET"
            case EADDRNOTAVAIL: return "EADDRNOTAVAIL"
            case EMFILE: return "EMFILE"
            default: return "errno\(errno)"
            }
        }

        /// Отказ пришёл раньше, чем пакет мог дойти до телефона: так выглядит запрет «Локальная сеть» для адреса своей подсети.
        public var isImmediateRouteDenial: Bool {
            !isOpen && (stage == "connect" || stage == "so_error")
                && [EPERM, EACCES, EHOSTUNREACH, ENETUNREACH, ENETDOWN, EHOSTDOWN].contains(errno)
        }
    }

    /// Проба TCP-порта с этапом отказа и errno. Каждая проба пишется в transport.log
    /// (одинаковый результат для адреса — не чаще раза в минуту).
    public static func probePort(host: String, port: UInt16 = 2222, timeoutMs: Int = 200, log: Bool = true) -> ProbeResult {
        let started = DispatchTime.now().uptimeNanoseconds
        func finish(_ open: Bool, _ stage: String, _ code: Int32) -> ProbeResult {
            let ms = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            let result = ProbeResult(isOpen: open, stage: stage, errno: code, durationMs: ms)
            if log { logProbe(host: host, port: port, timeoutMs: timeoutMs, result: result) }
            return result
        }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return finish(false, "resolve", EINVAL) }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM

        var res: UnsafeMutablePointer<addrinfo>?
        let gai = getaddrinfo(trimmedHost, String(port), &hints, &res)
        guard gai == 0, let addr = res else { return finish(false, "resolve", gai) }
        defer { freeaddrinfo(res) }

        let sock = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
        guard sock >= 0 else { return finish(false, "socket", Darwin.errno) }
        defer { close(sock) }

        // Установка неблокирующего режима
        let flags = fcntl(sock, F_GETFL, 0)
        guard flags >= 0 else { return finish(false, "socket", Darwin.errno) }
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        let ret = connect(sock, addr.pointee.ai_addr, addr.pointee.ai_addrlen)
        if ret == 0 { return finish(true, "ok", 0) }
        let connectErrno = Darwin.errno
        guard connectErrno == EINPROGRESS else { return finish(false, "connect", connectErrno) }

        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let pollRes = poll(&pfd, 1, Int32(timeoutMs))
        if pollRes > 0 {
            var socketError: Int32 = 0
            var errorLen = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(sock, SOL_SOCKET, SO_ERROR, &socketError, &errorLen) == 0 {
                return socketError == 0 ? finish(true, "ok", 0) : finish(false, "so_error", socketError)
            }
            return finish(false, "so_error", Darwin.errno)
        }
        return finish(false, "timeout", pollRes < 0 ? Darwin.errno : ETIMEDOUT)
    }

    private static func logProbe(host: String, port: UInt16, timeoutMs: Int, result: ProbeResult) {
        let norm = ConnectionHostAddress.normalized(host)
        guard !norm.hasPrefix("127.") else { return }
        let net = LocalNetworkStatus.isOnMacSubnet(norm) ? "своя" : "чужая"
        SSHTransportLog.event(
            key: "probe \(norm):\(port)",
            signature: "\(result.stage)/\(result.errno)",
            "PROBE \(norm):\(port) \(result.isOpen ? "открыт" : "закрыт") этап=\(result.stage) errno=\(result.errnoName) \(result.durationMs)мс таймаут=\(timeoutMs)мс подсеть=\(net)"
        )
    }

    /// Мгновенная проверка открытости TCP-порта на узле через неблокирующий сокет.
    /// В локальной сети при открытом порте выполняется за 0.5–2 мс.
    public static func isPortOpen(host: String, port: UInt16 = 2222, timeoutMs: Int = 200) -> Bool {
        probePort(host: host, port: port, timeoutMs: timeoutMs).isOpen
    }

    /// Нужна ли перепроверка дочерним процессом: отказ собственной пробы для адреса своей подсети
    /// не доказывает, что телефон молчит, — macOS может отклонять сокеты самого приложения
    /// («Локальная сеть»), а /usr/bin/nc и /usr/bin/ssh при этом проходят.
    /// ECONNREFUSED — ответ самого узла, ему верим.
    static func needsChildCrossCheck(_ probe: ProbeResult, host: String) -> Bool {
        let norm = ConnectionHostAddress.normalized(host)
        guard !probe.isOpen, probe.errno != ECONNREFUSED,
              ConnectionHostAddress.isIPv4(norm), !norm.hasPrefix("127.") else { return false }
        return LocalNetworkStatus.isOnMacSubnet(norm)
    }

    /// Проверка порта для решения «подключаться или нет»: собственная проба, а при её отказе
    /// для адреса своей подсети — та же проба через /usr/bin/nc. Подключение идёт через ssh,
    /// тоже дочерний процесс, поэтому запрет сокетов приложения его не касается.
    public static func isPortReachable(host: String, port: UInt16 = 2222, timeoutMs: Int = 1000) -> Bool {
        let probe = probePort(host: host, port: port, timeoutMs: timeoutMs)
        if probe.isOpen { return true }
        guard needsChildCrossCheck(probe, host: host) else { return false }
        let norm = ConnectionHostAddress.normalized(host)
        guard LocalNetworkStatus.childProbe(host: norm, port: port) == true else { return false }
        logAppSocketDenied(host: norm, port: port, probe: probe)
        return true
    }

    static func logAppSocketDenied(host: String, port: UInt16, probe: ProbeResult) {
        SSHTransportLog.event(
            key: "appdenied \(host):\(port)",
            signature: "\(probe.stage)/\(probe.errno)",
            "APP_SOCKET_DENIED \(host):\(port) проба приложения: этап=\(probe.stage) errno=\(probe.errnoName), nc: открыт — подключение через ssh"
        )
    }

    /// Параллельная неблокирующая проверка доступности порта для группы хостов
    public static func checkReachableHosts(hosts: [String], port: UInt16 = 2222, timeoutMs: Int = 250) async -> Set<String> {
        let uniqueHosts = Array(Set(hosts.compactMap { host -> String? in
            let normalized = ConnectionHostAddress.normalized(host)
            return normalized.isEmpty ? nil : normalized
        }))
        
        return await withTaskGroup(of: (String, Bool).self) { group in
            for host in uniqueHosts {
                group.addTask {
                    let isOpen = isPortOpen(host: host, port: port, timeoutMs: timeoutMs)
                    return (host, isOpen)
                }
            }
            
            var reachable = Set<String>()
            for await (host, isOpen) in group {
                if isOpen {
                    reachable.insert(host)
                }
            }
            return reachable
        }
    }
    
    /// Пакетная проверка порта на множестве IPv4-хостов одним poll(): все сокеты открываются сразу,
    /// поэтому скан /24 подсети занимает ~timeoutMs на пачку, а не timeoutMs на каждый хост.
    /// Пачки ограничены, чтобы не упереться в лимит дескрипторов процесса (по умолчанию 256).
    public static func scanOpenPort(hosts: [String], port: UInt16 = 2222, timeoutMs: Int = 400, batchSize: Int = 96) -> Set<String> {
        var unique: [String] = []
        var seen = Set<String>()
        for host in hosts {
            let norm = ConnectionHostAddress.normalized(host)
            guard ConnectionHostAddress.isIPv4(norm), seen.insert(norm).inserted else { continue }
            unique.append(norm)
        }
        var open = Set<String>()
        var immediateErrors: [Int32: Int] = [:]
        let started = DispatchTime.now().uptimeNanoseconds
        var start = 0
        while start < unique.count && !Task.isCancelled {
            let batch = Array(unique[start..<min(start + batchSize, unique.count)])
            start += batchSize
            open.formUnion(scanBatch(batch, port: port, timeoutMs: timeoutMs, immediateErrors: &immediateErrors))
        }
        let errors = immediateErrors.sorted { $0.key < $1.key }.map { "\($0.key)x\($0.value)" }.joined(separator: ",")
        let ms = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        SSHTransportLog.event(
            key: "scan \(port)",
            signature: "\(unique.count)/\(open.sorted())/\(errors)",
            "SCAN порт=\(port) адресов=\(unique.count) открыто=\(open.sorted()) отказ_сразу_errno=[\(errors)] \(ms)мс"
        )
        // Большинство адресов отклонено сразу и ничего не открыто: сокеты приложения запрещены.
        // Повторяем скан дочерними процессами nc.
        let denied = immediateErrors.values.reduce(0, +)
        if open.isEmpty, shouldRescanWithChild(total: unique.count, deniedImmediately: denied), !Task.isCancelled {
            open = childScanOpenPort(hosts: unique, port: port)
        }
        return open
    }

    static func shouldRescanWithChild(total: Int, deniedImmediately: Int) -> Bool {
        total > 0 && deniedImmediately * 2 >= total
    }

    /// Скан порта дочерними процессами /usr/bin/nc (до 48 одновременно, 1 с на адрес).
    static func childScanOpenPort(hosts: [String], port: UInt16) -> Set<String> {
        let targets = hosts.filter { !$0.hasPrefix("127.") && ConnectionHostAddress.isIPv4($0) }
        guard !targets.isEmpty else { return [] }
        let started = DispatchTime.now().uptimeNanoseconds
        let lock = NSLock()
        var open = Set<String>()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 48
        for host in targets {
            queue.addOperation {
                let (status, _) = PhoneConnectionManager.shared.runCommand(
                    executable: "/usr/bin/nc",
                    arguments: ["-z", "-G", "1", "-w", "1", host, String(port)],
                    timeoutSeconds: 3
                )
                if status == 0 {
                    lock.lock(); open.insert(host); lock.unlock()
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        let ms = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        SSHTransportLog.event(
            key: "childscan \(port)",
            signature: "\(targets.count)/\(open.sorted())",
            "CHILD_SCAN nc порт=\(port) адресов=\(targets.count) открыто=\(open.sorted()) \(ms)мс"
        )
        return open
    }

    private static func scanBatch(_ hosts: [String], port: UInt16, timeoutMs: Int, immediateErrors: inout [Int32: Int]) -> Set<String> {
        var pending: [(fd: Int32, host: String)] = []
        var open = Set<String>()
        defer { pending.forEach { close($0.fd) } }

        for host in hosts {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { continue }
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else { continue }
            var noSigPipe: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(sock, F_GETFL, 0)
            _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
            let ret = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if ret == 0 {
                open.insert(host)
                close(sock)
            } else if errno == EINPROGRESS {
                pending.append((sock, host))
            } else {
                immediateErrors[errno, default: 0] += 1
                close(sock)
            }
        }

        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while !pending.isEmpty && !Task.isCancelled {
            let remainingMs = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            guard remainingMs > 0 else { break }
            var pfds = pending.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
            let res = poll(&pfds, nfds_t(pfds.count), remainingMs)
            guard res > 0 else { break }
            var stillPending: [(fd: Int32, host: String)] = []
            for (i, entry) in pending.enumerated() {
                if pfds[i].revents == 0 {
                    stillPending.append(entry)
                    continue
                }
                var socketError: Int32 = 0
                var errorLen = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(entry.fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLen) == 0 {
                    if socketError == 0 {
                        open.insert(entry.host)
                    } else if [EPERM, EACCES, ENETUNREACH, ENETDOWN].contains(socketError) {
                        immediateErrors[socketError, default: 0] += 1
                    }
                }
                close(entry.fd)
            }
            pending = stillPending
        }
        return open
    }

    /// Частные IPv4-подсети активных интерфейсов en* (Wi-Fi/Ethernet): адрес Mac и маска.
    /// Туннели VPN, мосты виртуалок и AWDL не ведут к телефону в домашней сети.
    public static func macSubnets() -> [(ip: UInt32, mask: UInt32)] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var result: [(ip: UInt32, mask: UInt32)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0,
                  let addrPtr = ifa.pointee.ifa_addr, addrPtr.pointee.sa_family == sa_family_t(AF_INET),
                  let maskPtr = ifa.pointee.ifa_netmask else { continue }
            guard String(cString: ifa.pointee.ifa_name).hasPrefix("en") else { continue }
            let ip = addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            guard isPrivateIPv4(ip), mask != 0 else { continue }
            result.append((ip, mask))
        }
        return result
    }

    public static func ipv4Value(_ host: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, host, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    /// Адреса соседей по локальным IPv4-подсетям активных интерфейсов (Wi-Fi/Ethernet).
    /// Только частные диапазоны; подсеть шире /24 сужается до /24 вокруг собственного адреса,
    /// чтобы скан оставался быстрым. Собственные адреса Mac исключаются.
    public static func localSubnetHosts() -> [String] {
        var ownAddresses = Set<UInt32>()
        var subnets: [(base: UInt32, count: UInt32)] = []
        for (ip, rawMask) in macSubnets() {
            ownAddresses.insert(ip)
            let mask = rawMask < 0xFFFF_FF00 ? 0xFFFF_FF00 : rawMask
            let base = ip & mask
            let count = ~mask
            guard count >= 2 else { continue }
            if !subnets.contains(where: { $0.base == base }) {
                subnets.append((base, count))
            }
        }

        var hosts: [String] = []
        for subnet in subnets {
            for offset in 1..<subnet.count {
                let addr = subnet.base + offset
                guard !ownAddresses.contains(addr) else { continue }
                hosts.append("\(addr >> 24 & 0xFF).\(addr >> 16 & 0xFF).\(addr >> 8 & 0xFF).\(addr & 0xFF)")
            }
        }
        return hosts
    }

    static func isPrivateIPv4(_ ip: UInt32) -> Bool {
        let a = ip >> 24, b = (ip >> 16) & 0xFF
        return a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
    }

    /// Считывание активных IP-адресов локальной сети из системной таблицы ARP
    public static func fetchActiveLanIps() -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        proc.arguments = ["-an"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        let watchdog = DispatchWorkItem { [weak proc] in
            if proc?.isRunning == true { proc?.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: watchdog)
        defer { watchdog.cancel() }
        do {
            try proc.run()
            // Drain before waiting: a large ARP table can fill the pipe and deadlock waitUntilExit.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let str = String(decoding: data, as: UTF8.self)
            var ips: [String] = []
            for line in str.components(separatedBy: "\n") {
                if line.contains("incomplete") { continue }
                if let startIdx = line.firstIndex(of: "("),
                   let endIdx = line.firstIndex(of: ")"),
                   startIdx < endIdx {
                    let ip = String(line[line.index(after: startIdx)..<endIdx])
                    if ConnectionHostAddress.isIPv4(ip) &&
                       !ip.hasPrefix("224.") &&
                       !ip.hasPrefix("239.") &&
                       !ip.hasSuffix(".255") {
                        ips.append(ip)
                    }
                }
            }
            return ips
        } catch {
            return []
        }
    }
}

/// Отношение адреса телефона к сетям Mac и перекрёстная проверка дочерним процессом.
public enum LocalNetworkStatus {
    /// Адрес лежит в одной из подсетей Mac (по настоящей маске интерфейса).
    public static func isOnMacSubnet(_ host: String) -> Bool {
        let norm = ConnectionHostAddress.normalized(host)
        if norm.hasPrefix("127.") { return true }
        guard let value = NetworkPortReachability.ipv4Value(norm) else { return false }
        return NetworkPortReachability.macSubnets().contains { value & $0.mask == $0.ip & $0.mask }
    }

    /// Адреса Mac для журнала и сообщений: «192.168.1.12/24».
    public static func macSubnetsDescription() -> String {
        let list = NetworkPortReachability.macSubnets().map { subnet -> String in
            let ip = subnet.ip
            return "\(ip >> 24 & 0xFF).\(ip >> 16 & 0xFF).\(ip >> 8 & 0xFF).\(ip & 0xFF)/\(subnet.mask.nonzeroBitCount)"
        }
        return list.isEmpty ? "нет сети" : list.joined(separator: ", ")
    }

    /// Та же проба порта, но дочерним процессом /usr/bin/nc: показывает, действует ли отказ только на процесс приложения.
    /// Возвращает nil, если nc не запустился.
    public static func childProbe(host: String, port: UInt16, timeoutSeconds: Int = 2) -> Bool? {
        let started = DispatchTime.now().uptimeNanoseconds
        let (status, output) = PhoneConnectionManager.shared.runCommand(
            executable: "/usr/bin/nc",
            arguments: ["-z", "-G", String(timeoutSeconds), "-w", String(timeoutSeconds), host, String(port)],
            timeoutSeconds: TimeInterval(timeoutSeconds + 2)
        )
        let ms = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        SSHTransportLog.event(
            key: "childprobe \(host):\(port)",
            signature: "\(status)",
            "CHILD_PROBE nc \(host):\(port) status=\(status) \(ms)мс вывод=\(output.suffix(160))"
        )
        return status == -1 ? nil : status == 0
    }
}

