import SwiftUI

/// Модальный диалог рекурсивного поиска файлов с отображением результатов и навигацией
public struct SearchResultsView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    @Environment(\.dismiss) var dismiss
    
    @State private var searchQuery: String = ""
    @State private var searchResults: [FileItem] = []
    @State private var isSearching: Bool = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var selectedItemId: String? = nil
    
    public init() {}
    
    private var activePath: String {
        vm.activePane == .left ? vm.leftPath : vm.rightPath
    }
    
    private var activeSource: FileSource {
        vm.activePane == .left ? vm.leftSource : vm.rightSource
    }
    
    public var body: some View {
        VStack(spacing: 12) {
            // Заголовок
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text("Рекурсивный поиск файлов")
                        .font(.headline)
                    Text("Каталог: \(activePath) (\(activeSource.rawValue))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Закрыть") {
                    searchTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal)
            .padding(.top, 12)
            
            Divider()
            
            // Строка поиска
            HStack(spacing: 8) {
                TextField("Введите имя файла или часть названия...", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        startSearch()
                    }
                
                if isSearching {
                    Button("Остановить") {
                        searchTask?.cancel()
                        isSearching = false
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Искать (Enter)") {
                        startSearch()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal)
            
            // Список найденных файлов
            if searchResults.isEmpty {
                VStack(spacing: 10) {
                    if isSearching {
                        ProgressView("Выполняется поиск файлов...")
                            .padding()
                    } else {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text(searchQuery.isEmpty ? "Введите запрос и нажмите «Искать»" : "Ничего не найдено")
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(searchResults, id: \.id, selection: $selectedItemId) { item in
                    HStack {
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundColor(item.isDirectory ? .yellow : .blue)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.system(size: 13, weight: .medium))
                            Text(item.path)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        Text(item.isDirectory ? "<ПАПКА>" : ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        navigateTo(item: item)
                    }
                }
            }
            
            Divider()
            
            // Подвал с информацией и действиями
            HStack {
                Text("Найдено объектов: \(searchResults.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if let sel = selectedItemId, let item = searchResults.first(where: { $0.id == sel }) {
                    Button("Перейти к объекту") {
                        navigateTo(item: item)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
        .frame(minWidth: 600, minHeight: 450)
        .onDisappear {
            searchTask?.cancel()
        }
    }
    
    private func startSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        
        searchTask?.cancel()
        searchResults.removeAll()
        isSearching = true
        
        searchTask = Task {
            do {
                _ = try await SearchService.shared.search(
                    query: query,
                    in: activePath,
                    source: activeSource,
                    localDriver: vm.localDriver,
                    remoteDriver: vm.remoteDriver
                ) { foundItem in
                    Task { @MainActor in
                        searchResults.append(foundItem)
                    }
                }
            } catch {
                // Ignore cancel or errors
            }
            Task { @MainActor in
                isSearching = false
            }
        }
    }
    
    private func navigateTo(item: FileItem) {
        let targetDir = item.isDirectory ? item.path : URL(fileURLWithPath: item.path).deletingLastPathComponent().path
        if vm.activePane == .left {
            vm.leftPath = targetDir
            vm.leftSelection = [item.path]
            vm.refreshPane(side: .left)
        } else {
            vm.rightPath = targetDir
            vm.rightSelection = [item.path]
            vm.refreshPane(side: .right)
        }
        dismiss()
    }
}
