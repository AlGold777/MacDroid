import SwiftUI

public struct PaneView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    public let side: PaneSide
    
    public init(side: PaneSide) {
        self.side = side
    }
    
    private var isActive: Bool {
        vm.activePane == side
    }
    
    private var sourceBinding: Binding<FileSource> {
        side == .left ? $vm.leftSource : $vm.rightSource
    }
    
    private var currentPath: String {
        side == .left ? vm.leftPath : vm.rightPath
    }
    
    private var isStale: Bool {
        side == .left ? vm.leftIsStale : vm.rightIsStale
    }
    
    private var freeSpace: (free: UInt64, total: UInt64) {
        side == .left ? vm.leftFreeSpace : vm.rightFreeSpace
    }
    
    private var items: [FileItem] {
        let raw = (side == .left) ? vm.leftItems : vm.rightItems
        let filter = (side == .left) ? vm.leftFilter : vm.rightFilter
        let sortField = (side == .left) ? vm.leftSortField : vm.rightSortField
        let sortAsc = (side == .left) ? vm.leftSortAscending : vm.rightSortAscending
        
        var filtered = raw
        if !filter.isEmpty {
            filtered = raw.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        }
        
        return filtered.sorted { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory && !b.isDirectory
            }
            switch sortField {
            case .name:
                let cmp = a.name.localizedStandardCompare(b.name)
                return sortAsc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
            case .size:
                return sortAsc ? (a.size < b.size) : (a.size > b.size)
            case .date:
                return sortAsc ? (a.mtime < b.mtime) : (a.mtime > b.mtime)
            }
        }
    }
    
    private var selectionBinding: Binding<Set<String>> {
        side == .left ? $vm.leftSelection : $vm.rightSelection
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Заголовок панели
            HStack(spacing: 6) {
                Picker("", selection: sourceBinding) {
                    ForEach(FileSource.allCases) { src in
                        Text(src.rawValue).tag(src)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
                .onChange(of: sourceBinding.wrappedValue) { _, _ in
                    vm.refreshPane(side: side)
                }
                
                Button(action: { vm.navigateUp() }) {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.bordered)
                .help("На уровень выше")
                
                Text(currentPath)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    .cornerRadius(4)
                
                TextField("Фильтр...", text: (side == .left ? $vm.leftFilter : $vm.rightFilter))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
            .padding(6)
            .background(isActive ? Color.accentColor.opacity(0.14) : Color(nsColor: .windowBackgroundColor))
            
            if isStale {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Данные панели получены не в реальном времени (Offline)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.yellow.opacity(0.15))
            }
            
            Divider()
            
            // Список файлов
            Table(items, selection: selectionBinding) {
                TableColumn("Имя") { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.isDirectory ? "folder.fill" : fileIconName(for: item.name))
                            .foregroundColor(item.isDirectory ? .yellow : .blue)
                        Text(item.name)
                            .font(.system(size: 13))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        vm.navigateInto(item: item, side: side)
                    }
                }
                
                TableColumn("Размер") { item in
                    Text(item.isDirectory ? "<ПАПКА>" : formatBytes(item.size))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .width(min: 80, ideal: 100, max: 120)
                
                TableColumn("Дата изменения") { item in
                    Text(formatDate(item.mtime))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .width(min: 120, ideal: 140, max: 160)
            }
            .onTapGesture {
                vm.activePane = side
            }
            
            Divider()
            
            // Подвал панели
            HStack {
                Text("\(items.count) объектов")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                if freeSpace.total > 0 {
                    Text("Свободно: \(formatBytes(freeSpace.free)) из \(formatBytes(freeSpace.total))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .border(isActive ? Color.accentColor : Color.clear, width: 2)
    }
    
    private func fileIconName(for name: String) -> String {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "dng", "webp":
            return "photo.fill"
        case "mp4", "mov", "mkv":
            return "film.fill"
        case "mp3", "wav", "flac":
            return "music.note"
        case "zip", "rar", "7z", "tar", "gz":
            return "archivebox.fill"
        case "pdf":
            return "doc.richtext.fill"
        default:
            return "doc.fill"
        }
    }
    
    private func formatBytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }
    
    private func formatDate(_ timestamp: Double) -> String {
        guard timestamp > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: timestamp)
        let df = DateFormatter()
        df.dateFormat = "dd.MM.yy HH:mm"
        return df.string(from: date)
    }
}
