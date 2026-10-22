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
    
    /// Считывание активных IP-адресов локальной сети из системной таблицы ARP
    public static func fetchActiveLanIps() -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        proc.arguments = ["-an"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
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
