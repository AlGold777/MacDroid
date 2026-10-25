import AppKit
import SwiftUI

public struct ArchiveBrowserView: View {
    public let archiveURL: URL
    public let title: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ArchiveBrowserModel
    @FocusState private var isListFocused: Bool

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
        .onDisappear { model.finishBrowsing() }
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
                        model.selectedID = entry.id
                        isListFocused = true
                    } open: {
                        model.selectedID = entry.id
                        isListFocused = true
                        model.open(entry)
                    }
                    .tag(entry.id)
                    .contextMenu {
                        if entry.isDirectory {
                            Button("Открыть папку") { model.navigate(to: entry.path) }
                        } else {
                            Button("Открыть") { model.open(entry) }
                                .disabled(model.isBusy)
                            Button("Быстрый просмотр") { Task { await model.openPreview(entry) } }
                                .disabled(model.isBusy)
                            Button("Извлечь…") { Task { await extract(entry) } }
                                .disabled(model.isBusy)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .focusable()
            .focused($isListFocused)
            .onKeyPress(.space, phases: .down) { press in
                guard press.modifiers.isEmpty, let entry = model.selectedEntry else { return .ignored }
                if QuickLookBridge.shared.isVisible {
                    model.closePreview()
                } else {
                    Task { await model.openPreview(entry) }
                }
                return .handled
            }
            .background(ArchiveReturnKeyHandler(isEnabled: isListFocused && !model.isBusy) {
                guard let entry = model.selectedItem else { return false }
                model.open(entry)
                return true
            })
            .onChange(of: model.selectedID) { _ in
                if QuickLookBridge.shared.isVisible, let entry = model.selectedEntry {
                    Task { await model.openPreview(entry) }
                }
            }
            .disabled(model.isBusy)
        }
    }

    private var footer: some View {
        HStack {
            if model.isPreparingFile {
                ProgressView().controlSize(.small)
                Text("Подготовка файла…")
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
                Text("Двойной клик — открыть · Пробел — быстрый просмотр")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
    @Published var isPreparingFile = false
    private var previewCopy: ArchiveFilePreview?
    @Published var didLoad = false
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var lastResult: String?

    private let previousNext: (() -> Void)?
    private let previousPrevious: (() -> Void)?

    init(archiveURL: URL) {
        self.archiveURL = archiveURL
        previousNext = QuickLookBridge.shared.onNavigateNext
        previousPrevious = QuickLookBridge.shared.onNavigatePrevious
    }

    var isBusy: Bool { isLoading || isExtracting || isPreparingFile }
    var selectedItem: ArchiveEntry? { visibleEntries.first { $0.id == selectedID } }
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
        isPreparingFile = true
        errorMessage = nil
        defer { isPreparingFile = false }
        do {
            closePreview()
            let copy = try await ArchiveBrowserService.preparePreview(entry: entry, from: archiveURL)
            previewCopy = copy
            QuickLookBridge.shared.onNavigateNext = { [weak self] in self?.movePreview(by: 1) }
            QuickLookBridge.shared.onNavigatePrevious = { [weak self] in self?.movePreview(by: -1) }
            QuickLookBridge.shared.preview(url: copy.url, title: entry.name, onClose: {
                try? copy.cleanup()
            })
        } catch is CancellationError {
            // A dismissed/cancelled preview never leaves a partial file behind.
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func closePreview() {
        if let copy = previewCopy, QuickLookBridge.shared.currentPreviewURL == copy.url {
            QuickLookBridge.shared.close()
        }
        try? previewCopy?.cleanup()
        previewCopy = nil
    }

    func finishBrowsing() {
        closePreview()
        QuickLookBridge.shared.onNavigateNext = previousNext
        QuickLookBridge.shared.onNavigatePrevious = previousPrevious
    }

    private func movePreview(by offset: Int) {
        let files = visibleEntries.filter { !$0.isDirectory }
        guard let index = files.firstIndex(where: { $0.id == selectedID }),
              files.indices.contains(index + offset) else { return }
        selectedID = files[index + offset].id
    }

    func open(_ entry: ArchiveEntry) {
        guard !isBusy else { return }
        if entry.isDirectory {
            navigate(to: entry.path)
        } else {
            Task { await openFile(entry) }
        }
    }

    private func openFile(_ entry: ArchiveEntry) async {
        guard !isBusy else { return }
        isPreparingFile = true
        errorMessage = nil
        defer { isPreparingFile = false }
        do {
            let copy = try await ArchiveBrowserService.preparePreview(entry: entry, from: archiveURL)
            guard NSWorkspace.shared.open(copy.url) else {
                try? copy.cleanup()
                throw ArchiveBrowserError.io("Не удалось открыть файл «\(entry.name)» в программе по умолчанию.")
            }
            // An external application can read lazily, after this archive window closes.
            ArchiveOpenedFiles.shared.retain(copy)
            lastResult = "Открыт файл: \(entry.name)"
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
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
        .accessibilityHint(entry.isDirectory ? "Открыть папку в архиве" : "Двойной клик открывает файл в программе по умолчанию; пробел — быстрый просмотр")
    }
}

/// Keep files alive for external readers after the archive browser is dismissed.
@MainActor
private final class ArchiveOpenedFiles: NSObject {
    static let shared = ArchiveOpenedFiles()
    private var copies: [ArchiveFilePreview] = []

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(cleanup),
            name: NSApplication.willTerminateNotification, object: nil)
    }

    func retain(_ copy: ArchiveFilePreview) { copies.append(copy) }

    @objc private func cleanup() {
        for copy in copies { try? copy.cleanup() }
        copies.removeAll()
    }
}

/// SwiftUI List can consume Return before onKeyPress; route it at the native window boundary.
private struct ArchiveReturnKeyHandler: NSViewRepresentable {
    let isEnabled: Bool
    let openSelection: () -> Bool

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.isEnabled = isEnabled
        view.openSelection = openSelection
        view.installMonitor()
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.isEnabled = isEnabled
        view.openSelection = openSelection
    }

    static func dismantleNSView(_ view: KeyView, coordinator: ()) {
        view.removeMonitor()
    }

    final class KeyView: NSView {
        var isEnabled = false
        var openSelection: (() -> Bool)?
        private var monitor: Any?

        func installMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isEnabled, event.window === self.window,
                      self.window?.isKeyWindow == true,
                      event.keyCode == 36 || event.keyCode == 76,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
                    return event
                }
                if let text = self.window?.firstResponder as? NSTextView, text.isEditable {
                    return event
                }
                if self.window?.firstResponder is NSTextField { return event }
                return self.openSelection?() == true ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
