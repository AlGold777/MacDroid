import Foundation

enum SSHTransportLog {
    private static let lock = NSLock()

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacDroidCommander/transport.log")
    }

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }

        let url = fileURL
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? NSNumber,
               size.intValue > 2 * 1024 * 1024 {
                let existing = (try? Data(contentsOf: url)) ?? Data()
                let retained = Data(existing.suffix(1024 * 1024))
                try retained.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            let oneLineMessage = message.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(oneLineMessage)\n"
            let data = Data(line.utf8)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            NSLog("MacDroid transport log write failed: %@", error.localizedDescription)
        }
    }
}
