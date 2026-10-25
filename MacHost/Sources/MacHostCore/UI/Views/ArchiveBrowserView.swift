import AppKit
import SwiftUI
import Quartz

public struct ArchiveBrowserView: View {
    public let archiveURL: URL
    public let title: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ArchiveBrowserModel

    public init(archiveURL: URL, title: String) {
        self.archiveURL = archiveURL
        self.title = title
        _model = StateObject(wrappedValue: ArchiveBrowserModel(archiveURL: archiveURL))
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            navigationBar
            Divider()
            searchBar
            content
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 440)
        .task { await model.loadIfNeeded() }
        .sheet(item: $model.preview, onDismiss: { model.closePreview() }) { preview in
            ArchiveFilePreviewView(url: preview.url)
        }
        .alert("Ошибка работы с архивом", isPresented: $model.showError) {
            Button("ОК", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Неизвестная ошибка")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Просмотр архива")
                    .font(.title3.weight(.semibold))
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                Task { await model.reload() }
            } label: {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
            .disabled(model.isBusy)
            .help("Повторно прочитать список архива")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var navigationBar: some View {
        HStack(spacing: 8) {
            Button {
                model.goUp()
            } label: {
                Image(systemName: "arrow.left")
            }
            .disabled(model.currentDirectory.isEmpty || model.isBusy)
            .help("На уровень выше")
            .accessibilityLabel("На уровень выше")

            Image(systemName: "house")
                .foregroundStyle(.secondary)
            Button("Архив") { model.navigate(to: "") }
                .buttonStyle(.plain)
                .disabled(model.isBusy)

            ForEach(model.breadcrumbs, id: \.self) { crumb in
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button(URL(fileURLWithPath: crumb).lastPathComponent) {
                    model.navigate(to: crumb)
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
            }
            Spacer()
            if model.indexedEntries > 0 {
                Text("\(model.indexedEntries) объектов")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Поиск по имени или пути", text: $model.searchText)
                .textFieldStyle(.plain)
                .disabled(model.isBusy || !model.didLoad)
                .accessibilityLabel("Поиск по архиву")
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Очистить поиск")
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text("Чтение списка архива…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.didLoad {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(model.errorMessage ?? "Не удалось прочитать архив")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Повторить") { Task { await model.reload() } }
                    .disabled(model.isBusy)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleEntries.isEmpty {
            ContentUnavailableView(
                model.searchText.isEmpty ? "Папка пуста" : "Ничего не найдено",
                systemImage: model.searchText.isEmpty ? "folder" : "magnifyingglass",
                description: Text(model.searchText.isEmpty ? "В этой папке нет объектов." : "Попробуйте изменить запрос.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $model.selectedID) {
                ForEach(model.visibleEntries) { entry in
                    ArchiveBrowserRow(entry: entry, isSelected: model.selectedID == entry.id) {
                        if entry.isDirectory {
                            model.navigate(to: entry.path)
                        } else {
                            model.selectedID = entry.id
                        }
                    } open: {
                        if entry.isDirectory {
                            model.navigate(to: entry.path)
                        } else {
                            Task { await model.openPreview(entry) }
                        }
                    }
                    .tag(entry.id)
                    .contextMenu {
                        if entry.isDirectory {
                            Button("Открыть папку") { model.navigate(to: entry.path) }
                        } else {
                            Button("Просмотреть") { Task { await model.openPreview(entry) } }
                                .disabled(model.isBusy)
                            Button("Извлечь…") { Task { await extract(entry) } }
                                .disabled(model.isBusy)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .disabled(model.isBusy)
        }
    }

    private var footer: some View {
        HStack {
            if model.isPreparingPreview {
                ProgressView().controlSize(.small)
                Text("Подготовка просмотра…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.isExtracting {
                ProgressView()
                    .controlSize(.small)
                Text("Извлечение выбранного файла…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let result = model.lastResult {
                Label(result, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(1)
            } else {
                Text("Двойной клик по файлу открывает просмотр.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Просмотреть") {
                if let entry = model.selectedEntry { Task { await model.openPreview(entry) } }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isBusy || !model.didLoad || model.selectedEntry == nil)
            Button("Извлечь выбранный файл…") {
                if let entry = model.selectedEntry { Task { await extract(entry) } }
            }
            .disabled(model.isBusy || !model.didLoad || model.selectedEntry == nil)
            Button("Закрыть") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func extract(_ entry: ArchiveEntry) async {
        let panel = NSOpenPanel()
        panel.title = "Выберите папку для извлечения"
        panel.prompt = "Извлечь сюда"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        await model.extract(entry, to: destination)
    }
}

@MainActor
private final class ArchiveBrowserModel: ObservableObject {
    let archiveURL: URL

    @Published var entries: [ArchiveEntry] = []
    @Published var currentDirectory = ""
    @Published var searchText = ""
    @Published var selectedID: String?
    @Published var isLoading = false
    @Published var isExtracting = false
    @Published var isPreparingPreview = false
    @Published var preview: ArchiveFilePreview?
    private var previewCopy: ArchiveFilePreview?
    @Published var didLoad = false
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var lastResult: String?

    init(archiveURL: URL) { self.archiveURL = archiveURL }

    var isBusy: Bool { isLoading || isExtracting || isPreparingPreview }
    var indexedEntries: Int { entries.count }
    var selectedEntry: ArchiveEntry? { entries.first { $0.id == selectedID && !$0.isDirectory } }

    var breadcrumbs: [String] {
        var result: [String] = []
        var path = ""
        for component in currentDirectory.split(separator: "/") {
            path = path.isEmpty ? String(component) : path + "/" + component
            result.append(path)
        }
        return result
    }

    var visibleEntries: [ArchiveEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let candidates = query.isEmpty ? directChildren() : searchEntries()
        return candidates.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func loadIfNeeded() async {
        guard !didLoad, !isLoading else { return }
        await reload()
    }

    func reload() async {
        guard !isBusy else { return }
        isLoading = true
        errorMessage = nil
        showError = false
        defer { isLoading = false }
        do {
            entries = try await ArchiveBrowserService.index(archiveURL: archiveURL)
            currentDirectory = ""
            selectedID = nil
            didLoad = true
            if entries.isEmpty { lastResult = nil }
        } catch is CancellationError {
            errorMessage = "Чтение архива отменено."
        } catch {
            entries = []
            didLoad = false
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func navigate(to path: String) {
        guard !isBusy else { return }
        currentDirectory = path
        searchText = ""
        selectedID = nil
    }

    func goUp() {
        guard !currentDirectory.isEmpty else { return }
        navigate(to: (currentDirectory as NSString).deletingLastPathComponent)
    }

    func extract(_ entry: ArchiveEntry, to directory: URL) async {
        guard !isBusy else { return }
        isExtracting = true
        lastResult = nil
        errorMessage = nil
        defer { isExtracting = false }
        do {
            let output = try await ArchiveBrowserService.extract(entry: entry, from: archiveURL, toDirectory: directory)
            lastResult = "Извлечено: \(output.lastPathComponent)"
        } catch is CancellationError {
            errorMessage = "Извлечение отменено."
            showError = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func openPreview(_ entry: ArchiveEntry) async {
        guard !isBusy, !entry.isDirectory else { return }
        isPreparingPreview = true
        errorMessage = nil
        defer { isPreparingPreview = false }
        do {
            closePreview()
            let copy = try await ArchiveBrowserService.preparePreview(entry: entry, from: archiveURL)
            previewCopy = copy
            preview = copy
        } catch is CancellationError {
            // A dismissed/cancelled preview never leaves a partial file behind.
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func closePreview() {
        preview = nil
        try? previewCopy?.cleanup()
        previewCopy = nil
    }

    deinit {
        try? previewCopy?.cleanup()
    }

    private func directChildren() -> [ArchiveEntry] {
        let prefix = currentDirectory.isEmpty ? "" : currentDirectory + "/"
        var rows: [String: ArchiveEntry] = [:]
        for entry in entries {
            guard entry.path.hasPrefix(prefix) else { continue }
            let remainder = String(entry.path.dropFirst(prefix.count))
            guard !remainder.isEmpty else { continue }
            let pieces = remainder.split(separator: "/")
            guard let first = pieces.first else { continue }
            if pieces.count > 1 || entry.isDirectory {
                let path = prefix + String(first)
                rows[path] = rows[path] ?? ArchiveEntry(id: "dir:\(path)", ordinal: -1, path: path, name: String(first), size: 0, isDirectory: true)
            } else {
                rows[entry.path] = entry
            }
        }
        return Array(rows.values)
    }

    private func searchEntries() -> [ArchiveEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !query.isEmpty else { return directChildren() }
        var rows: [String: ArchiveEntry] = [:]
        for entry in entries {
            if entry.path.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(query) {
                rows[entry.id] = entry
            }
            let components = entry.path.split(separator: "/")
            guard components.count > 1 else { continue }
            var path = ""
            for component in components.dropLast() {
                path = path.isEmpty ? String(component) : path + "/" + component
                let name = String(component)
                if name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(query) {
                    rows[path] = ArchiveEntry(id: "dir:\(path)", ordinal: -1, path: path, name: name, size: 0, isDirectory: true)
                }
            }
        }
        return Array(rows.values)
    }
}

private struct ArchiveBrowserRow: View {
    let entry: ArchiveEntry
    let isSelected: Bool
    let action: () -> Void
    let open: () -> Void

    var body: some View {
            HStack(spacing: 9) {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                    .frame(width: 19)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !entry.isDirectory {
                        Text(entry.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 12)
                if !entry.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityLabel(entry.isDirectory ? "Папка \(entry.name)" : "Файл \(entry.name), \(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))")
        .accessibilityHint(entry.isDirectory ? "Открыть папку в архиве" : "Двойной клик открывает просмотр файла")
    }
}

/// Embedded Quick Look keeps viewing inside the archive browser without launching a file.
private struct ArchiveFilePreviewView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Button("Закрыть просмотр") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            ArchiveQuickLookView(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

private struct ArchiveQuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem?.previewItemURL ?? nil) != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.previewItem = nil
        view.close()
    }
}
