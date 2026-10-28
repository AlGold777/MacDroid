import Foundation
import Network

/// Сообщает о смене сетевого пути Mac: появился доступный путь или изменился набор интерфейсов.
/// Первый снимок пути только запоминается и событием не считается.
@MainActor
public final class NetworkPathWatcher {
    private let onChange: @MainActor () -> Void
    private var monitor: NWPathMonitor?
    private var lastSignature: String?

    public init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    public func start() {
        guard monitor == nil else { return }
        let pathMonitor = NWPathMonitor()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let interfaces = path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
            let signature = "\(satisfied)|\(interfaces)"
            Task { @MainActor [weak self] in
                self?.handle(signature: signature, satisfied: satisfied)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "MacHost.NetworkPathWatcher"))
        monitor = pathMonitor
    }

    public func stop() {
        monitor?.cancel()
        monitor = nil
        lastSignature = nil
    }

    private func handle(signature: String, satisfied: Bool) {
        let previous = lastSignature
        lastSignature = signature
        guard let previous, previous != signature, satisfied else { return }
        onChange()
    }
}
