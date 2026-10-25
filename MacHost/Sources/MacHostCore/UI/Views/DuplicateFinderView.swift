import SwiftUI

public struct DuplicateFinderView: View {
    @EnvironmentObject private var vm: DualPaneViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [DuplicateGroup] = []
    @State private var selected = Set<String>()
    @State private var busy = false
    @State private var scanned = false
    @State private var error: String?
    @State private var confirming = false
    @State private var task: Task<Void, Never>?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Точные дубликаты · Mac + Android").font(.headline)
                Spacer()
                Button(busy ? "Остановить" : "Найти") {
                    if busy { task?.cancel() } else { scan() }
                }
                Button("Закрыть") { dismiss() }.disabled(busy)
            }
            Text("Поиск в двух текущих папках и подпапках. Имена и даты могут отличаться; содержимое проверяется SHA-256.")
                .font(.caption).foregroundColor(.secondary)
            Text("Mac/Phone: \(vm.leftPath) ↔ \(vm.rightPath)")
                .font(.caption).lineLimit(2).textSelection(.enabled)
            if busy { ProgressView("Проверка содержимого…").controlSize(.small) }
            if let error { Text(error).foregroundColor(.red).textSelection(.enabled) }
            if groups.isEmpty {
                Text(scanned && !busy ? "Точных дубликатов не найдено" : "Нажмите «Найти», чтобы начать поиск.")
                    .foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups) { group in
                        Section("\(group.items.count) копии · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: group.size), countStyle: .file)) каждая") {
                            ForEach(group.items, id: \.self) { item in
                                Toggle(isOn: Binding(get: { selected.contains(DuplicateCleanupService.itemID(item)) }, set: { value in
                                    let id = DuplicateCleanupService.itemID(item)
                                    if value { selected.insert(id) } else { selected.remove(id) }
                                })) {
                                    VStack(alignment: .leading) {
                                        Text(item.name)
                                        Text("\(item.source.rawValue): \(item.path)").font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                                    }
                                }.disabled(busy)
                            }
                        }
                    }
                }
            }
            HStack {
                Button("Отметить лишние, оставить одну копию") {
                    selected = Set(groups.flatMap { $0.items.dropFirst().map(DuplicateCleanupService.itemID) })
                }.disabled(busy || groups.isEmpty)
                Spacer()
                Button("В корзину (\(selected.count))", role: .destructive) { confirming = true }
                    .disabled(busy || selected.isEmpty)
            }
        }
        .padding(16).frame(minWidth: 720, minHeight: 480)
        .interactiveDismissDisabled(busy)
        .onDisappear { task?.cancel() }
        .alert("Переместить \(selected.count) копий в корзину?", isPresented: $confirming) {
            Button("В корзину", role: .destructive) { removeSelected() }
            Button("Отмена", role: .cancel) {}
        } message: { Text("В каждой группе должна остаться хотя бы одна копия. Перед удалением содержимое будет проверено повторно.") }
    }

    private func scan() {
        task?.cancel()
        busy = true; error = nil; scanned = false; groups = []; selected = []
        let roots = [(vm.leftSource, vm.leftPath), (vm.rightSource, vm.rightPath)].map { source, path in
            FileItem(id: path, name: URL(fileURLWithPath: path).lastPathComponent, path: path,
                     size: 0, mtime: 0, isDirectory: true, source: source)
        }
        let local = vm.localDriver, remote = vm.remoteDriver
        let content = FileContentService(transport: vm.transport)
        task = Task {
            do {
                let finder = DuplicateFinder(listDirectory: { item in
                    if item.source == .localMac { return try await local.listDirectory(at: item.path) }
                    return try await remote.listDirectory(at: item.path, forceRefresh: true)
                }, contentDigest: { item in try await content.digest(item) })
                let result = try await finder.findDuplicates(roots: roots)
                try Task.checkCancellation()
                groups = result; scanned = true
            } catch is CancellationError {
                error = "Поиск остановлен. Полный результат не получен."
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func removeSelected() {
        busy = true; error = nil
        let content = FileContentService(transport: vm.transport)
        let local = vm.localDriver, remote = vm.remoteDriver
        let snapshot = groups, selection = selected
        task = Task {
            do {
                let cleanup = DuplicateCleanupService(contentDigest: { try await content.digest($0) }, moveToTrash: { item in
                    if item.source == .localMac { try await local.deleteItem(at: item.path, moveToTrash: true) }
                    else { try await remote.deleteItem(at: item.path, moveToTrash: true) }
                })
                try await cleanup.removeSelected(groups: snapshot, selectedIDs: selection)
                groups = []; selected = []; scanned = false
                vm.refreshBothPanes()
                error = "Выбранные копии перемещены в корзину. Повторите поиск для обновления списка."
            } catch {
                groups = []; selected = []; scanned = false
                self.error = "Операция остановлена: \(error.localizedDescription) Повторите поиск; часть копий могла быть уже перемещена в корзину."
                vm.refreshBothPanes()
            }
            busy = false
        }
    }
}
