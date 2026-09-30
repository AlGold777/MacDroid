import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Строка настроек режима сетки (вместо заголовков столбцов таблицы)

public struct GridSettingsBarView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    public let side: PaneSide
    
    public init(side: PaneSide) {
        self.side = side
    }
    
    private var currentSortField: SortField {
        side == .left ? vm.leftSortField : vm.rightSortField
    }
    
    private var isSortAscending: Bool {
        side == .left ? vm.leftSortAscending : vm.rightSortAscending
    }
    
    private var thumbnailSizeBinding: Binding<Double> {
        Binding(
            get: { side == .left ? vm.leftGridThumbnailSize : vm.rightGridThumbnailSize },
            set: { newSize in
                if side == .left {
                    vm.leftGridThumbnailSize = newSize
                } else {
                    vm.rightGridThumbnailSize = newSize
                }
            }
        )
    }
    
    private var gridSpacingBinding: Binding<Double> {
        Binding(
            get: { side == .left ? vm.leftGridSpacing : vm.rightGridSpacing },
            set: { newSpacing in
                if side == .left {
                    vm.leftGridSpacing = newSpacing
                } else {
                    vm.rightGridSpacing = newSpacing
                }
            }
        )
    }
    
    public var body: some View {
        HStack(spacing: 8) {
            // 1. Меню сортировки (поля и направление)
            Menu {
                ForEach(SortField.allCases, id: \.self) { field in
                    Button(action: {
                        if side == .left {
                            vm.leftSortField = field
                        } else {
                            vm.rightSortField = field
                        }
                    }) {
                        HStack {
                            Text(field.rawValue)
                            if currentSortField == field {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                
                Divider()
                
                Button(action: {
                    if side == .left {
                        vm.leftSortAscending = true
                    } else {
                        vm.rightSortAscending = true
                    }
                }) {
                    HStack {
                        Text("По возрастанию")
                        if isSortAscending {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                
                Button(action: {
                    if side == .left {
                        vm.leftSortAscending = false
                    } else {
                        vm.rightSortAscending = false
                    }
                }) {
                    HStack {
                        Text("По убыванию")
                        if !isSortAscending {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(currentSortField.rawValue) \(isSortAscending ? "↑" : "↓")")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                .cornerRadius(4)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Сортировка объектов в галерее")
            
            // 2. Индикатор объектов
            let itemsCount = vm.displayItems(for: side).count
            Text("\(itemsCount) объектов")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            
            Spacer()
            
            // 3. Регулировка масштаба эскизов (Слайдер размера)
            HStack(spacing: 5) {
                Image(systemName: "photo")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                
                Slider(value: thumbnailSizeBinding, in: 64...256, step: 8)
                    .frame(width: 80)
                    .controlSize(.mini)
                    .help("Размер эскизов: \(Int(thumbnailSizeBinding.wrappedValue)) px")
                
                Image(systemName: "photo.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                // Кнопка быстрого возврата к 120 px
                if Int(thumbnailSizeBinding.wrappedValue) != 120 {
                    Button(action: {
                        thumbnailSizeBinding.wrappedValue = 120
                    }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Сбросить размер на 120 px")
                }
            }
            
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)
            
            // 4. Регулировка расстояния между эскизами (Слайдер интервала до мин. 1 мм)
            HStack(spacing: 5) {
                Image(systemName: "arrow.left.and.line.vertical.and.arrow.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                
                Slider(value: gridSpacingBinding, in: 1...32, step: 1)
                    .frame(width: 75)
                    .controlSize(.mini)
                    .help("Расстояние между эскизами: \(Int(gridSpacingBinding.wrappedValue)) px (мин. 1-3 px ≈ 1 мм)")
                
                let spacingVal = Int(gridSpacingBinding.wrappedValue)
                Text(spacingVal <= 3 ? "\(spacingVal) px (~1 мм)" : "\(spacingVal) px")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: spacingVal <= 3 ? 66 : 32, alignment: .leading)
                
                // Кнопка быстрого возврата к 10 px
                if Int(gridSpacingBinding.wrappedValue) != 10 {
                    Button(action: {
                        gridSpacingBinding.wrappedValue = 10
                    }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Сбросить интервал на 10 px")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(height: 26)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }
}

// MARK: - Графический просмотрщик папок (Сетка файлов)

public struct FileGridPaneView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    public let side: PaneSide
    
    @State private var isDropTarget: Bool = false
    
    public init(side: PaneSide) {
        self.side = side
    }
    
    private var items: [FileItem] {
        vm.displayItems(for: side)
    }
    
    private var thumbnailSize: CGFloat {
        CGFloat(side == .left ? vm.leftGridThumbnailSize : vm.rightGridThumbnailSize)
    }
    
    private var gridSpacing: CGFloat {
        CGFloat(side == .left ? vm.leftGridSpacing : vm.rightGridSpacing)
    }
    
    private var selection: Set<String> {
        side == .left ? vm.leftSelection : vm.rightSelection
    }
    
    public static func cellPadding(for spacing: CGFloat) -> CGFloat {
        if spacing <= 3 {
            return 0
        } else if spacing <= 6 {
            return 1
        } else {
            return min(5, 1 + (spacing - 6) * 0.3)
        }
    }
    
    public var body: some View {
        ScrollView {
            if items.isEmpty {
                VStack(spacing: 12) {
                    Spacer(minLength: 40)
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("Папка пуста")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    clearSelection()
                }
            } else {
                let pad = Self.cellPadding(for: gridSpacing)
                let cellWidth = thumbnailSize + (pad * 2)
                let columns = [
                    GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth), spacing: gridSpacing, alignment: .top)
                ]
                
                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(items) { item in
                        let isSelected = selection.contains(item.id) || selection.contains(item.path)
                        
                        FileGridCell(
                            item: item,
                            side: side,
                            size: thumbnailSize,
                            spacing: gridSpacing,
                            isSelected: isSelected
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleCellTap(item: item)
                        }
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            handleCellDoubleTap(item: item)
                        })
                        .onDrag {
                            vm.createDragItemProvider(for: item, side: side)
                        }
                    }
                }
                .padding(gridSpacing)
                .contentShape(Rectangle())
                .onTapGesture {
                    clearSelection()
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.1))
        .onDrop(of: [DualPaneViewModel.dragUTType, UTType.fileURL.identifier, UTType.utf8PlainText.identifier], delegate: FileGridDropDelegate(side: side, vm: vm, items: items))
        // Клавиатурные команды для сетки
        .onKeyPress(KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!)), phases: .down) { press in
            if KeyCommandMonitor.isTextEditingActive(in: vm) {
                return .ignored
            }
            if press.modifiers.isEmpty {
                vm.triggerRename(side: side)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("a"), phases: .down) { press in
            if KeyCommandMonitor.isTextEditingActive(in: vm) {
                return .ignored
            }
            if press.modifiers.contains(.control) || press.modifiers.contains(.command) {
                vm.selectAll(side: side)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.space, phases: .down) { press in
            if KeyCommandMonitor.isTextEditingActive(in: vm) {
                return .ignored
            }
            if press.modifiers.isEmpty {
                vm.triggerQuickLook(preferNativeQuickLook: true)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.return, phases: .down) { _ in
            if KeyCommandMonitor.isTextEditingActive(in: vm) {
                return .ignored
            }
            vm.openSelected()
            return .handled
        }
        .onKeyPress(.delete, phases: .down) { press in
            if KeyCommandMonitor.isTextEditingActive(in: vm) {
                return .ignored
            }
            if press.modifiers.isEmpty {
                vm.navigateUp(side: side)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.leftArrow, phases: .down) { _ in
            if KeyCommandMonitor.isTextEditingActive(in: vm) {
                return .ignored
            }
            navigateSelection(offset: -1)
            return .handled
        }
        .onKeyPress(.rightArrow, phases: .down) { _ in
            if KeyCommandMonitor.isTextEditingActive(in: vm) {
                return .ignored
            }
            navigateSelection(offset: 1)
            return .handled
        }
        .onKeyPress(.upArrow, phases: .down) { _ in
            if KeyCommandMonitor.isTextEditingActive(in: vm) {
                return .ignored
            }
            navigateSelectionRow(direction: -1)
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { _ in
            if KeyCommandMonitor.isTextEditingActive(in: vm) {
                return .ignored
            }
            navigateSelectionRow(direction: 1)
            return .handled
        }
        .simultaneousGesture(TapGesture().onEnded {
            if vm.activePane != side {
                vm.activePane = side
            }
        })
    }
    
    private func clearSelection() {
        if vm.activePane != side { vm.activePane = side }
        if side == .left {
            vm.leftSelection.removeAll()
            TableDoubleClickHandler.HandlerView.leftTableView?.deselectAll(nil)
        } else {
            vm.rightSelection.removeAll()
            TableDoubleClickHandler.HandlerView.rightTableView?.deselectAll(nil)
        }
    }
    
    private func handleCellTap(item: FileItem) {
        if vm.activePane != side { vm.activePane = side }
        
        let isCmdPressed = NSEvent.modifierFlags.contains(.command)
        let isShiftPressed = NSEvent.modifierFlags.contains(.shift)
        
        if isCmdPressed {
            // Мультивыбор с Cmd
            if side == .left {
                if vm.leftSelection.contains(item.id) || vm.leftSelection.contains(item.path) {
                    vm.leftSelection.remove(item.id)
                    vm.leftSelection.remove(item.path)
                } else {
                    vm.leftSelection.insert(item.id)
                }
                vm.rightSelection.removeAll()
            } else {
                if vm.rightSelection.contains(item.id) || vm.rightSelection.contains(item.path) {
                    vm.rightSelection.remove(item.id)
                    vm.rightSelection.remove(item.path)
                } else {
                    vm.rightSelection.insert(item.id)
                }
                vm.leftSelection.removeAll()
            }
        } else if isShiftPressed {
            // Диапазон с Shift
            let currentItems = items
            if let firstSelId = selection.first,
               let startIdx = currentItems.firstIndex(where: { $0.id == firstSelId || $0.path == firstSelId }),
               let endIdx = currentItems.firstIndex(where: { $0.id == item.id }) {
                let range = min(startIdx, endIdx)...max(startIdx, endIdx)
                let idsToSelect = Set(currentItems[range].map { $0.id })
                if side == .left {
                    vm.leftSelection = idsToSelect
                    vm.rightSelection.removeAll()
                } else {
                    vm.rightSelection = idsToSelect
                    vm.leftSelection.removeAll()
                }
            } else {
                selectSingle(item: item)
            }
        } else {
            // Одиночный выбор
            selectSingle(item: item)
        }
    }
    
    private func selectSingle(item: FileItem) {
        if vm.activePane != side { vm.activePane = side }
        if side == .left {
            vm.leftSelection = [item.id]
            vm.rightSelection.removeAll()
        } else {
            vm.rightSelection = [item.id]
            vm.leftSelection.removeAll()
        }
    }
    
    private func handleCellDoubleTap(item: FileItem) {
        if vm.activePane != side { vm.activePane = side }
        if item.isDirectory {
            vm.openItem(item: item, side: side)
        } else {
            let ext = URL(fileURLWithPath: item.name).pathExtension.lowercased()
            let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff", "tif"]
            if imageExts.contains(ext) {
                // Открываем встроенный полноэкранный фотопросмотрщик
                let allImages = items.filter { !($0.isDirectory) && imageExts.contains(URL(fileURLWithPath: $0.name).pathExtension.lowercased()) }
                let startIndex = allImages.firstIndex(where: { $0.id == item.id || $0.path == item.path }) ?? 0
                vm.viewerImages = allImages
                vm.viewerStartIndex = startIndex
                vm.showImageViewer = true
            } else {
                vm.openItem(item: item, side: side)
            }
        }
    }
    
    private func navigateSelection(offset: Int) {
        guard !items.isEmpty else { return }
        if let currentId = selection.first,
           let currentIdx = items.firstIndex(where: { $0.id == currentId || $0.path == currentId }) {
            let nextIdx = max(0, min(items.count - 1, currentIdx + offset))
            selectSingle(item: items[nextIdx])
        } else {
            selectSingle(item: items[0])
        }
    }
    
    private func navigateSelectionRow(direction: Int) {
        guard !items.isEmpty else { return }
        // Приблизительный шаг по строке (сетка адаптивная)
        let rowStride = max(1, Int(400 / thumbnailSize))
        navigateSelection(offset: direction * rowStride)
    }
}

// MARK: - Карточка элемента в сетке (FileGridCell)

public struct FileGridCell: View {
    @EnvironmentObject var vm: DualPaneViewModel
    public let item: FileItem
    public let side: PaneSide
    public let size: CGFloat
    public let spacing: CGFloat
    public let isSelected: Bool
    
    @State private var thumbnail: NSImage? = nil
    @State private var isLoading: Bool = false
    @State private var isHovered: Bool = false
    @State private var thumbnailReloadToken: Int = 0
    
    public init(item: FileItem, side: PaneSide, size: CGFloat, spacing: CGFloat = 10, isSelected: Bool) {
        self.item = item
        self.side = side
        self.size = size
        self.spacing = spacing
        self.isSelected = isSelected
    }
    
    public var body: some View {
        let pad = FileGridPaneView.cellPadding(for: spacing)
        let imgInset: CGFloat = spacing <= 3 ? 0 : max(0, min(6, (spacing - 3) * 0.6))
        let cornerRad: CGFloat = spacing <= 3 ? 2 : max(4, min(8, spacing * 0.7))
        
        VStack(spacing: spacing <= 3 ? 2 : 4) {
            // 1. Контейнер миниатюры
            ZStack {
                RoundedRectangle(cornerRadius: cornerRad)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.7))
                
                if item.isDirectory {
                    Image(systemName: "folder.fill")
                        .font(.system(size: size * 0.44))
                        .foregroundColor(.yellow)
                        .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                } else if let img = thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: size - (imgInset * 2), maxHeight: size - (imgInset * 2))
                        .cornerRadius(spacing <= 3 ? 2 : 4)
                        .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
                } else if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: fileIconName(for: item.name))
                        .font(.system(size: size * 0.38))
                        .foregroundColor(.blue)
                }
                
                // Бейдж сравнения (если сравнение активно)
                if vm.isComparing {
                    VStack {
                        HStack {
                            Spacer()
                            gridComparisonBadge(for: item.name)
                        }
                        Spacer()
                    }
                    .padding(spacing <= 3 ? 2 : 4)
                }
            }
            .frame(width: size, height: size)
            
            // 2. Имя файла / папки
            if vm.editingItemId == item.id && vm.editingItemSide == side {
                InlineRenameTextField(
                    text: $vm.editingItemName,
                    isDirectory: item.isDirectory,
                    onCommit: {
                        vm.commitInlineRename(item: item, side: side)
                    },
                    onCancel: {
                        vm.cancelInlineRename()
                    }
                )
                .frame(width: size, height: 26)
            } else {
                Text(item.name)
                    .font(.system(size: spacing <= 3 ? 10 : 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .accentColor : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
                    .frame(width: size, height: spacing <= 3 ? 24 : 26, alignment: .top)
                    .onLongPressGesture(minimumDuration: 0.55) {
                        if vm.activePane != side { vm.activePane = side }
                        if side == .left {
                            vm.leftSelection = [item.id]
                        } else {
                            vm.rightSelection = [item.id]
                        }
                        vm.triggerRename(item: item, side: side)
                    }
            }
            
            // 3. Дополнительные метаданные (размер)
            Group {
                if item.isDirectory {
                    if let folderSize = vm.calculatedFolderSizes[item.path] {
                        Text(formatBytes(folderSize))
                    } else {
                        Text("<ПАПКА>")
                    }
                } else {
                    Text(formatBytes(item.size))
                }
            }
            .font(.system(size: spacing <= 3 ? 8 : 9, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
        .padding(pad)
        .background(
            RoundedRectangle(cornerRadius: cornerRad)
                .fill(cellBackgroundFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRad)
                .strokeBorder(cellStrokeColor, lineWidth: (isDragHoverFolder || isSelected) ? 2 : 1)
        )
        .onHover { hovering in
            self.isHovered = hovering
        }
        .onDrop(of: [DualPaneViewModel.dragUTType, UTType.fileURL.identifier, UTType.utf8PlainText.identifier], isTargeted: Binding(
            get: { isDragHoverFolder },
            set: { onFolderTargetChanged($0) }
        )) { providers in
            onFolderDrop(providers: providers)
        }
        .task(id: "\(ThumbnailCacheManager.thumbnailKey(for: item))#\(thumbnailReloadToken)") {
            await loadThumbnailAsync()
        }
        .onReceive(NotificationCenter.default.publisher(for: ThumbnailCacheManager.throttleLiftedNotification)) { _ in
            // Эскиз пропущен во время трансфера — догружаем после его завершения
            if thumbnail == nil && !item.isDirectory {
                thumbnailReloadToken &+= 1
            }
        }
        .contextMenu {
            gridContextMenu(for: item)
        }
    }
    
    private var isDragHoverFolder: Bool {
        vm.dragHoverSide == side && vm.dragHoverFolderId == item.id
    }
    
    private var cellBackgroundFill: Color {
        if vm.editingItemId == item.id && vm.editingItemSide == side {
            return Color.clear
        } else if isDragHoverFolder {
            return Color.accentColor.opacity(0.35)
        } else if isSelected {
            return Color.accentColor.opacity(0.18)
        } else if isHovered {
            return Color.secondary.opacity(0.08)
        } else {
            return Color.clear
        }
    }
    
    private var cellStrokeColor: Color {
        if vm.editingItemId == item.id && vm.editingItemSide == side {
            return Color.clear
        } else if isDragHoverFolder || isSelected {
            return Color.accentColor
        } else if isHovered {
            return Color.secondary.opacity(0.3)
        } else {
            return Color.clear
        }
    }
    
    private func onFolderTargetChanged(_ targeted: Bool) {
        guard item.isDirectory else { return }
        if targeted {
            vm.dragHoverSide = side
            vm.dragHoverFolderId = item.id
            if FileGridDropDelegate.currentSpringLoadFolderId != item.id {
                FileGridDropDelegate.springLoadTimer?.cancel()
                FileGridDropDelegate.currentSpringLoadFolderId = item.id
                let folderToOpen = item
                let work = DispatchWorkItem { [weak vm] in
                    guard let vm = vm else { return }
                    if FileGridDropDelegate.currentSpringLoadFolderId == folderToOpen.id {
                        print("SPRING_LOAD: Grid opening folder '\(folderToOpen.name)' on side \(side)")
                        DispatchQueue.main.async {
                            vm.openItem(item: folderToOpen, side: side)
                            FileGridDropDelegate.currentSpringLoadFolderId = nil
                            FileGridDropDelegate.springLoadTimer = nil
                            vm.clearDragHoverState()
                        }
                    }
                }
                FileGridDropDelegate.springLoadTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
            }
        } else if vm.dragHoverSide == side && vm.dragHoverFolderId == item.id {
            FileGridDropDelegate.springLoadTimer?.cancel()
            FileGridDropDelegate.springLoadTimer = nil
            FileGridDropDelegate.currentSpringLoadFolderId = nil
            vm.clearDragHoverState()
        }
    }
    
    private func onFolderDrop(providers: [NSItemProvider]) -> Bool {
        FileGridDropDelegate.springLoadTimer?.cancel()
        FileGridDropDelegate.springLoadTimer = nil
        FileGridDropDelegate.currentSpringLoadFolderId = nil
        vm.clearDragHoverState()
        let isMove = NSEvent.modifierFlags.contains(.command)
        let targetDir = item.isDirectory ? item.path : nil
        SSHTransportLog.write("DND_GRID_FOLDER_DROP side=\(side) folder=\(item.name) hasPayload=\(vm.currentDragPayload != nil)")
        if vm.currentDragPayload != nil {
            return vm.handleDroppedProviders([], toSide: side, targetDirPath: targetDir, isMove: isMove)
        }
        return vm.handleDroppedProviders(providers, toSide: side, targetDirPath: targetDir, isMove: isMove)
    }
    
    private func loadThumbnailAsync() async {
        if item.isDirectory { return }
        
        let ext = URL(fileURLWithPath: item.name).pathExtension.lowercased()
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff", "tif", "ico", "avif"]
        guard imageExts.contains(ext) else { return }
        
        // Только RAM-кэш в главном потоке; чтение с диска и генерация — в фоне
        if let cached = ThumbnailCacheManager.shared.memoryThumbnail(for: item) {
            self.thumbnail = cached
            return
        }
        
        self.isLoading = true
        let img = await ThumbnailCacheManager.shared.loadThumbnail(
            for: item,
            targetSize: CGSize(width: size * 2, height: size * 2),
            transport: vm.transport
        )
        // Ячейка ушла с экрана или сменила файл — результат не применяем
        guard !Task.isCancelled else { return }
        self.thumbnail = img
        self.isLoading = false
    }
    
    private func fileIconName(for name: String) -> String {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "dng", "webp": return "photo.fill"
        case "mp4", "mov", "mkv", "avi": return "film.fill"
        case "mp3", "wav", "flac", "m4a": return "music.note"
        case "zip", "rar", "7z", "tar", "gz": return "archivebox.fill"
        case "pdf": return "doc.richtext.fill"
        case "apk": return "cube.box.fill"
        default: return "doc.fill"
        }
    }
    
    private func formatBytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }
    
    @ViewBuilder
    private func gridComparisonBadge(for name: String) -> some View {
        if side == .left {
            if vm.comparisonResult.onlyLeft.contains(name) {
                Circle().fill(Color.green).frame(width: 8, height: 8)
            } else if vm.comparisonResult.different.contains(name) {
                Circle().fill(Color.orange).frame(width: 8, height: 8)
            }
        } else {
            if vm.comparisonResult.onlyRight.contains(name) {
                Circle().fill(Color.blue).frame(width: 8, height: 8)
            } else if vm.comparisonResult.different.contains(name) {
                Circle().fill(Color.orange).frame(width: 8, height: 8)
            }
        }
    }
    
    @ViewBuilder
    private func gridContextMenu(for item: FileItem) -> some View {
        let contextItems = vm.contextMenuItems(for: item, side: side)
        Button("Новая папка с выбранными объектами (\(contextItems.count))") {
            vm.prepareNewFolderWithSelection(item: item, side: side)
        }
        Button("Новая папка") { vm.prepareNewFolder(side: side) }

        Menu("Открыть с помощью...") {
            let apps = vm.getApplicationsForFile(item: item)
            if apps.isEmpty {
                Text("Нет ассоциированных программ")
            } else {
                ForEach(apps, id: \.self) { appURL in
                    Button(action: { vm.openFile(item: item, withApplicationURL: appURL) }) {
                        let appName = FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
                        Label(appName, systemImage: "app")
                    }
                }
            }
            Divider()
            Button("Выбрать программу...") {
                vm.chooseCustomApplicationAndOpen(item: item)
            }
        }

        Button("Удалить (F8 / Delete)", role: .destructive) {
            vm.selectContextMenuItems(for: item, side: side)
            vm.triggerDelete()
        }
        Button("Копировать (Cmd+C)") { vm.copyToClipboard(items: contextItems, side: side) }
        Button("Вставить (Cmd+V)") { vm.pasteFromClipboard(targetSide: side) }
            .disabled(!vm.canPaste)
        Button("Дублировать (Cmd+Shift+D)") { vm.duplicateItem(item: item, side: side) }

        Button("Сжать в архив... (Alt+F5)") { vm.triggerCreateArchive(item: item, side: side) }
        Button("Переименовать (F2)") { vm.triggerRename(item: item, side: side) }
        Button("Свойства (Cmd+I)") { vm.triggerProperties(item: item, side: side) }

        Toggle("Показывать скрытые файлы", isOn: Binding(
            get: { side == .left ? vm.leftShowHidden : vm.rightShowHidden },
            set: { newValue in
                let showHidden = side == .left ? vm.leftShowHidden : vm.rightShowHidden
                if newValue != showHidden { vm.toggleShowHidden(side: side) }
            }
        ))
    }
}

public struct FileGridDropDelegate: DropDelegate {
    public let side: PaneSide
    public let vm: DualPaneViewModel
    public let items: [FileItem]
    
    public static var springLoadTimer: DispatchWorkItem?
    public static var currentSpringLoadFolderId: String?
    
    public init(side: PaneSide, vm: DualPaneViewModel, items: [FileItem]) {
        self.side = side
        self.vm = vm
        self.items = items
    }
    
    public func dropEntered(info: DropInfo) {
    }
    
    public func dropUpdated(info: DropInfo) -> DropProposal? {
        let isMove = NSEvent.modifierFlags.contains(.command)
        return DropProposal(operation: isMove ? .move : .copy)
    }
    
    public func dropExited(info: DropInfo) {
        Self.springLoadTimer?.cancel()
        Self.springLoadTimer = nil
        Self.currentSpringLoadFolderId = nil
        vm.clearDragHoverState()
    }
    
    public func performDrop(info: DropInfo) -> Bool {
        Self.springLoadTimer?.cancel()
        Self.springLoadTimer = nil
        Self.currentSpringLoadFolderId = nil
        
        let targetFolderId = vm.dragHoverFolderId
        vm.clearDragHoverState()
        
        let targetDirPath: String?
        if let folderId = targetFolderId, let folder = items.first(where: { $0.id == folderId && $0.isDirectory }) {
            targetDirPath = folder.path
        } else {
            targetDirPath = nil
        }
        
        let isMove = NSEvent.modifierFlags.contains(.command)
        SSHTransportLog.write("DND_GRID_PERFORM_DROP side=\(side) hasPayload=\(vm.currentDragPayload != nil) targetDir=\(targetDirPath ?? "nil")")
        
        // 1. Приоритетный путь для внутреннего Drag & Drop между панелями
        if vm.currentDragPayload != nil {
            return vm.handleDroppedProviders([], toSide: side, targetDirPath: targetDirPath, isMove: isMove)
        }
        
        let customUTType = UTType(exportedAs: DualPaneViewModel.dragUTType, conformingTo: .data)
        let utTypes: [UTType] = [
            customUTType,
            .fileURL,
            .utf8PlainText,
            .plainText,
            .data,
            .item
        ]
        let providers = info.itemProviders(for: utTypes)
        return vm.handleDroppedProviders(providers, toSide: side, targetDirPath: targetDirPath, isMove: isMove)
    }
}
