import Foundation
import MacHostCore

// Стенд замера скорости копирования папки Mac ↔ телефон через тот же путь, что и приложение
// (DualPaneViewModel.executeTransfer). Создаёт на телефоне временную папку и удаляет её в конце.
//
// Запуск (телефон уже сопряжён с приложением, известен его deviceId):
//   swift run -c release TransferBench <host> <deviceId> [число файлов=1000] [МБ большого файла=40]

// Имя процесса тестов отключает во VM автоподключение, обнаружение и восстановление вкладок телефона
ProcessInfo.processInfo.processName = "MacHostTests"

struct BenchError: Error, CustomStringConvertible {
    let description: String
}

@MainActor
func runTransfer(_ vm: DualPaneViewModel, paths: [String], from: FileSource, toSide: PaneSide, target: String) async throws -> TimeInterval {
    let start = Date()
    vm.executeTransfer(paths: paths, fromSource: from, toSide: toSide, targetDirPath: target, isMove: false)
    await vm.currentTransferTask?.value
    let elapsed = Date().timeIntervalSince(start)
    guard let report = vm.operationReport else { throw BenchError(description: "нет отчёта о передаче") }
    if !report.failed.isEmpty {
        throw BenchError(description: "ошибок \(report.failed.count) из \(report.succeeded.count + report.failed.count), за \(Int(elapsed)) с: \(report.failed.prefix(2).map { "\($0.path): \($0.error)" })")
    }
    print(String(format: "  файлов: %d, пропущено: %d, время: %.1f с", report.succeeded.count, report.skipped.count, elapsed))
    return elapsed
}

/// Тестовая папка: fileCount файлов 2–32 КБ в 10 подпапках
func makeSourceTree(at root: URL, fileCount: Int) throws -> UInt64 {
    try? FileManager.default.removeItem(at: root)
    var total: UInt64 = 0
    var rng = SystemRandomNumberGenerator()
    for i in 0..<fileCount {
        let dir = root.appendingPathComponent("d\(i % 10)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let size = Int.random(in: 2_048...32_768, using: &rng)
        let data = Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) })
        try data.write(to: dir.appendingPathComponent("f\(i).bin"))
        total += UInt64(size)
    }
    return total
}

/// Побайтовое сравнение деревьев и проверка сохранения даты изменения
func verifyTree(source: URL, copy: URL) throws -> Int {
    let fm = FileManager.default
    // /var и /private/var — один каталог: пути сравниваем после разрешения ссылок
    let sourceRoot = source.resolvingSymlinksInPath().path
    guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]) else {
        throw BenchError(description: "не читается \(source.path)")
    }
    var checked = 0
    for case let url as URL in walker {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        let rel = String(url.resolvingSymlinksInPath().path.dropFirst(sourceRoot.count))
        let other = URL(fileURLWithPath: copy.path + rel)
        guard try Data(contentsOf: url) == Data(contentsOf: other) else {
            throw BenchError(description: "содержимое отличается: \(rel)")
        }
        let m1 = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        let m2 = try other.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantFuture
        if abs(m1.timeIntervalSince(m2)) >= 2 {
            throw BenchError(description: "дата изменения не сохранена: \(rel)")
        }
        checked += 1
    }
    return checked
}

@MainActor
func main() async throws {
    let args = CommandLine.arguments
    guard args.count >= 3 else {
        throw BenchError(description: "использование: TransferBench <host> <deviceId> [файлов] [МБ]")
    }
    let host = args[1]
    let deviceId = args[2]
    let fileCount = args.count > 3 ? Int(args[3]) ?? 1000 : 1000
    let bigMB = args.count > 4 ? Int(args[4]) ?? 40 : 40

    let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MDCTransferBench", isDirectory: true)
    let src = work.appendingPathComponent("src/MDCBench", isDirectory: true)
    let out = work.appendingPathComponent("out", isDirectory: true)
    let bigSrc = work.appendingPathComponent("big", isDirectory: true)
    try? FileManager.default.removeItem(at: work)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bigSrc, withIntermediateDirectories: true)
    let treeBytes = try makeSourceTree(at: src, fileCount: fileCount)
    let bigFile = bigSrc.appendingPathComponent("big.bin")
    FileManager.default.createFile(atPath: bigFile.path, contents: nil)
    let bigHandle = try FileHandle(forWritingTo: bigFile)
    for _ in 0..<bigMB {
        var rng = SystemRandomNumberGenerator()
        try bigHandle.write(contentsOf: Data((0..<1_048_576).map { _ in UInt8.random(in: 0...255, using: &rng) }))
    }
    try bigHandle.close()

    let vm = DualPaneViewModel()
    vm.remoteDriver.updateEndpoint(host: host, port: 2222, deviceId: deviceId)
    vm.remoteDriver.coordinator.setHostKeyAlias(deviceId)
    try await vm.remoteDriver.ensureConnected(allowLegacyFallback: false)
    vm.leftSource = .localMac
    vm.rightSource = .remotePhone

    let remoteBase = "/storage/emulated/0/MDCTransferBench"
    try? await vm.remoteDriver.deleteItem(at: remoteBase, moveToTrash: false)
    try await vm.remoteDriver.createDirectory(at: remoteBase)

    print("Папка: \(fileCount) файлов, \(treeBytes / 1024) КБ, 10 подпапок; большой файл \(bigMB) МБ")
    print("Mac → телефон, папка:")
    let upTree = try await runTransfer(vm, paths: [src.path], from: .localMac, toSide: .right, target: remoteBase)
    print("Телефон → Mac, папка:")
    let downTree = try await runTransfer(vm, paths: [remoteBase + "/MDCBench"], from: .remotePhone, toSide: .left, target: out.path)
    let verified = try verifyTree(source: src, copy: out.appendingPathComponent("MDCBench"))
    print("  проверено побайтово и по дате: \(verified) файлов")

    print("Mac → телефон, большой файл:")
    let upBig = try await runTransfer(vm, paths: [bigFile.path], from: .localMac, toSide: .right, target: remoteBase)
    print("Телефон → Mac, большой файл:")
    let downBig = try await runTransfer(vm, paths: [remoteBase + "/big.bin"], from: .remotePhone, toSide: .left, target: out.path)
    _ = try verifyTree(source: bigSrc, copy: out)

    let mb = Double(bigMB)
    print(String(format: "ИТОГ: папка вверх %.1f с (%.1f файл/с), вниз %.1f с (%.1f файл/с); большой файл вверх %.1f МБ/с, вниз %.1f МБ/с",
                 upTree, Double(fileCount) / upTree, downTree, Double(fileCount) / downTree, mb / upBig, mb / downBig))

    try? await vm.remoteDriver.deleteItem(at: remoteBase, moveToTrash: false)
    try? FileManager.default.removeItem(at: work)
}

do {
    try await main()
    exit(0)
} catch {
    print("ОШИБКА: \(error)")
    exit(1)
}
