import Foundation
import Darwin

/// Быстрая неблокирующая проверка доступности сетевых портов через POSIX-сокеты
public enum NetworkPortReachability {
    
    /// Мгновенная проверка открытости TCP-порта на узле через неблокирующий сокет.
    /// В локальной сети при открытом порте выполняется за 0.5–2 мс.
    public static func isPortOpen(host: String, port: UInt16 = 2222, timeoutMs: Int = 200) -> Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return false }
        
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        
        var res: UnsafeMutablePointer<addrinfo>?
        let portString = String(port)
        guard getaddrinfo(trimmedHost, portString, &hints, &res) == 0, let addr = res else {
            return false
        }
        defer { freeaddrinfo(res) }
        
        let sock = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        
        // Установка неблокирующего режима
        let flags = fcntl(sock, F_GETFL, 0)
        guard flags >= 0 else { return false }
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
        
        let ret = connect(sock, addr.pointee.ai_addr, addr.pointee.ai_addrlen)
        if ret == 0 {
            return true
        }
        
        guard errno == EINPROGRESS else {
            return false
        }
        
        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let pollRes = poll(&pfd, 1, Int32(timeoutMs))
        if pollRes > 0 {
            var socketError: Int32 = 0
            var errorLen = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(sock, SOL_SOCKET, SO_ERROR, &socketError, &errorLen) == 0 {
                return socketError == 0
            }
        }
        
        return false
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
        var start = 0
        while start < unique.count && !Task.isCancelled {
            let batch = Array(unique[start..<min(start + batchSize, unique.count)])
            start += batchSize
            open.formUnion(scanBatch(batch, port: port, timeoutMs: timeoutMs))
        }
        return open
    }

    private static func scanBatch(_ hosts: [String], port: UInt16, timeoutMs: Int) -> Set<String> {
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
                if getsockopt(entry.fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLen) == 0, socketError == 0 {
                    open.insert(entry.host)
                }
                close(entry.fd)
            }
            pending = stillPending
        }
        return open
    }

    /// Адреса соседей по локальным IPv4-подсетям активных интерфейсов (Wi-Fi/Ethernet).
    /// Только частные диапазоны; подсеть шире /24 сужается до /24 вокруг собственного адреса,
    /// чтобы скан оставался быстрым. Собственные адреса Mac исключаются.
    public static func localSubnetHosts() -> [String] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var ownAddresses = Set<UInt32>()
        var subnets: [(base: UInt32, count: UInt32)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0,
                  let addrPtr = ifa.pointee.ifa_addr, addrPtr.pointee.sa_family == sa_family_t(AF_INET),
                  let maskPtr = ifa.pointee.ifa_netmask else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            // Туннели VPN, мосты виртуалок и AWDL не ведут к телефону в домашней сети.
            guard name.hasPrefix("en") else { continue }
            let ip = addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            var mask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            guard isPrivateIPv4(ip) else { continue }
            ownAddresses.insert(ip)
            if mask < 0xFFFF_FF00 { mask = 0xFFFF_FF00 }
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
