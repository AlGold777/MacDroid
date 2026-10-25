import AppKit
import SwiftUI

public struct CopyDoneView: View {
    @EnvironmentObject private var vm: DualPaneViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [CopyDoneEntry] = []
    @State private var selected = Set<String>()
    @State private var issues: [String] = []
    @State private var busy = false
    @State private var scanned = false
    @State private var message: String?
    @State private var progress = ""
    @State private var confirming = false
    @State private var task: Task<Void, Never>?
    @State private var session: CopyDoneSession?
    @State private var operationID = UUID()

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Освободить место — copy done", systemImage: "checkmark.shield").font(.headline)
                Spacer()
                Button(busy ? "Остановить" : "Проверить заново") {
                    if busy { task?.cancel() } else { scan() }
                }
                Button("Закрыть") { dismiss() }.disabled(busy)
            }
            Text("Проверяем известные места импорта на Mac: полное содержимое SHA-256, а не только имя и размер.")
                .font(.caption).foregroundColor(.secondary)
            DisclosureGroup("Область проверки: \(vm.copyDoneScopes.count) объектов телефона") {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(Array(vm.copyDoneScopes.enumerated()), id: \.offset) { _, scope in
                            Text(scope.path + (scope.isDirectory ? " (включая вложенные импорты)" : ""))
                        }
                    }.font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 100)
            }
            if busy {
                HStack { ProgressView().controlSize(.small); Text(progress).font(.caption).lineLimit(2) }
            }
            if let message { Text(message).textSelection(.enabled).foregroundColor(.secondary) }
            if scanned {
                Text("На Mac найдены проверенные копии \(entries.count) файлов. Можно освободить \(formattedBytes(entries.reduce(0) { $0 + $1.phone.size })).")
                    .font(.headline)
            }
            Text("Сначала файлы попадут в корзину приложения на телефоне. Место освободится после её отдельной очистки; до этого файлы можно восстановить.")
                .font(.caption).foregroundColor(.secondary)
            if entries.isEmpty {
                Text(scanned ? "Проверенных копий для выбранных объектов не найдено." : busy ? "Подготавливаем проверку…" : "Нажмите «Проверить заново», чтобы обновить список.")
                    .foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    HStack(alignment: .top) {
                        Toggle(isOn: Binding(get: { selected.contains(entry.id) }, set: { value in
                            if value { selected.insert(entry.id) } else { selected.remove(entry.id) }
                        })) { EmptyView() }.labelsHidden().disabled(busy)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(entry.phone.name) · \(formattedBytes(entry.phone.size))").fontWeight(.medium)
                            Text("Телефон: \(entry.phone.path)").font(.caption).textSelection(.enabled)
                            ForEach(entry.macCopies, id: \.path) { copy in
                                HStack(alignment: .top) {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                    Text("Mac: \(copy.path)").textSelection(.enabled)
                                    Spacer(minLength: 4)
                                    Button("В Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: copy.path)]) }
                                        .disabled(busy)
                                }.font(.caption)
                            }
                        }
                    }.padding(.vertical, 5)
                }
            }
            if !issues.isEmpty {
                DisclosureGroup("Не подтверждено / недоступно: \(issues.count)") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in Text(issue) }
                        }.font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                }
            }
            HStack {
                Button(selected.count == entries.count ? "Снять выделение" : "Выбрать все") {
                    selected = selected.count == entries.count ? [] : Set(entries.map(\.id))
                }.disabled(busy || entries.isEmpty)
                Text("Выбрано: \(selected.count) · \(formattedBytes(entries.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.phone.size }))")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("В корзину телефона…", role: .destructive) { confirming = true }
                    .disabled(busy || selected.isEmpty || session == nil)
            }
        }
        .padding(18).frame(minWidth: 780, minHeight: 520)
        .interactiveDismissDisabled(busy)
        .onAppear { scan() }
        .onDisappear { task?.cancel() }
        .alert("Переместить \(selected.count) файлов в корзину телефона?", isPresented: $confirming) {
            Button("В корзину", role: .destructive) { moveSelected() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Содержимое телефона и копий на Mac будет проверено повторно. При изменении файла перенос остановится. Очистка корзины выполняется отдельно.")
        }
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private func updateProgress(_ done: Int, _ total: Int, _ path: String, operation: UUID) {
        guard operationID == operation, busy else { return }
        progress = "\(done) из \(total) · \(path)"
    }

    private func scan() {
        task?.cancel()
        let operation = UUID()
        operationID = operation
        busy = true; scanned = false; message = nil; entries = []; selected = []; issues = []
        progress = "Чтение истории импорта…"
        let scopes = vm.copyDoneScopes
        do {
            let connection = try CopyDoneSession(remote: vm.remoteDriver, transport: vm.transport,
                deviceID: vm.remoteDriver.coordinator.deviceId ?? PhoneConnectionManager.shared.getConnectedDeviceId())
            session = connection
            task = Task {
                do {
                    let result = try await connection.service.findCopies(locations: connection.locations, scopes: scopes) { done, total, path in
                        Task { @MainActor in updateProgress(done, total, path, operation: operation) }
                    }
                    try Task.checkCancellation()
                    entries = result.entries; issues = result.issues; scanned = true
                    if result.candidateCount == 0 { message = "В истории нет завершённых импортов для этой области. Сначала скопируйте файлы на Mac через приложение." }
                } catch is CancellationError { message = "Проверка остановлена. Для переноса нужна новая полная проверка."; session = nil }
                catch { message = error.localizedDescription; session = nil }
                busy = false
            }
        } catch { message = error.localizedDescription; session = nil; busy = false }
    }

    private func moveSelected() {
        guard let connection = session else { return }
        let snapshot = entries, selection = selected
        let operation = UUID()
        operationID = operation
        busy = true; message = nil; progress = "Повторная проверка содержимого…"
        task = Task {
            do {
                let done = try await connection.service.moveSelected(entries: snapshot, selectedIDs: selection,
                    moveToTrash: { item, beforeMove in try await connection.moveToTrash(item, beforeMove: beforeMove) },
                    restore: { entry in try await connection.restore(entry) }) { done, total, path in
                        Task { @MainActor in updateProgress(done, total, path, operation: operation) }
                    }
                message = "В корзину телефона перемещено файлов: \(done.count). Место освободится после очистки корзины."
            } catch let error as CopyDoneCleanupError {
                message = "Подтверждён перенос в корзину: \(error.completedIDs.count) из \(selection.count). \(error.detail) При обрыве связи результат последнего переноса может быть неопределённым — проверьте корзину телефона."
            } catch { message = error.localizedDescription }
            entries = []; selected = []; scanned = false; session = nil; busy = false
            vm.refreshBothPanes()
        }
    }
}
