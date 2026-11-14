import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Чёткий современный слайдер с тёмно-серой шкалой и контуром

public struct CrispModernSlider: View {
    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public let step: Double
    
    @State private var isHovered: Bool = false
    @State private var isDragging: Bool = false
    
    public init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1) {
        self._value = value
        self.range = range
        self.step = step
    }
    
    private var trackColor: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(white: 0.48, alpha: 1.0) : NSColor(white: 0.32, alpha: 1.0)
        }))
    }
    
    private var thumbBorderColor: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(white: 0.65, alpha: 1.0) : NSColor(white: 0.28, alpha: 1.0)
        }))
    }
    
    private var thumbFillColor: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(white: 0.22, alpha: 1.0) : NSColor(white: 0.98, alpha: 1.0)
        }))
    }
    
    public var body: some View {
        GeometryReader { geo in
            let thumbDiameter: CGFloat = 13
            let width = max(1, geo.size.width - thumbDiameter)
            let span = max(0.001, range.upperBound - range.lowerBound)
            let rawFraction = (value - range.lowerBound) / span
            let fraction = max(0, min(1, CGFloat(rawFraction)))
            let thumbOffset = fraction * width
            
            ZStack(alignment: .leading) {
                // Тёмно-серая неразмытая чёткая линия (шкала 2px)
                Rectangle()
                    .fill(trackColor)
                    .frame(height: 2)
                    .padding(.horizontal, thumbDiameter / 2)
                
                // Ползунок с тёмно-серым чётким контуром
                Circle()
                    .fill(thumbFillColor)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .overlay(
                        Circle()
                            .strokeBorder(thumbBorderColor, lineWidth: 1.5)
                    )
                    .shadow(color: .black.opacity(isDragging ? 0.3 : 0.18), radius: isDragging ? 2.5 : 1.5, x: 0, y: 1)
                    .offset(x: thumbOffset)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .onHover { hovering in
                self.isHovered = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        self.isDragging = true
                        updateValue(from: gesture.location.x, trackWidth: width, thumbDiameter: thumbDiameter)
                    }
                    .onEnded { _ in
                        self.isDragging = false
                    }
            )
        }
        .frame(height: 16)
    }
    
    private func updateValue(from touchX: CGFloat, trackWidth: CGFloat, thumbDiameter: CGFloat) {
        guard trackWidth > 0 else { return }
        let adjustedX = touchX - (thumbDiameter / 2)
        let fraction = max(0, min(1, adjustedX / trackWidth))
        var newValue = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
        if step > 0 {
            let steps = round((newValue - range.lowerBound) / step)
            newValue = range.lowerBound + (steps * step)
        }
        newValue = max(range.lowerBound, min(range.upperBound, newValue))
        if newValue != value {
            value = newValue
        }
    }
}

// MARK: - Современный компактный элемент управления слайдером с бейджем и сбросом

public struct ModernGridSliderControl: View {
    public let icon: String
    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public let step: Double
    public let defaultValue: Double
    public let displayFormat: (Double) -> String
    public let helpText: String
    
    public init(
        icon: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        defaultValue: Double,
        displayFormat: @escaping (Double) -> String,
        helpText: String
    ) {
        self.icon = icon
        self._value = value
        self.range = range
        self.step = step
        self.defaultValue = defaultValue
        self.displayFormat = displayFormat
        self.helpText = helpText
    }
    
    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            
            CrispModernSlider(value: $value, in: range, step: step)
                .frame(width: 82)
            
            Text(displayFormat(value))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary.opacity(0.85))
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                )
            
            if Int(value) != Int(defaultValue) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        value = defaultValue
                    }
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Сбросить на значение по умолчанию (\(Int(defaultValue)) px)")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: .controlColor).opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .help(helpText)
    }
}

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
                        let cur = (side == .left ? vm.leftSortField : vm.rightSortField)
                        let defaultAsc = (field == .size || field == .date) ? false : true
                        if side == .left {
                            vm.leftSortField = field
                            if cur != field {
                                vm.leftSortAscending = defaultAsc
                            }
                        } else {
                            vm.rightSortField = field
                            if cur != field {
                                vm.rightSortAscending = defaultAsc
                            }
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
                        .font(.system(size: 12, weight: .medium))
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
            Text("\(itemsCount) obj")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            
            Spacer()
            
            // Кнопка «на весь экран» (ровно посередине между счётчиком и ползунком)
            Button(action: {
                vm.openFullscreenGrid(side: side)
            }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .controlColor).opacity(0.22))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("На весь экран")
            
            Spacer()
            
            // 3. Регулировка масштаба эскизов (Слайдер размера)
            ModernGridSliderControl(
                icon: "photo",
                value: thumbnailSizeBinding,
                range: 64...256,
                step: 8,
                defaultValue: 120,
                displayFormat: { "\(Int($0)) px" },
                helpText: "Размер эскизов: \(Int(thumbnailSizeBinding.wrappedValue)) px"
            )
            
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)
            
            // 4. Регулировка расстояния между эскизами (Слайдер интервала до мин. 1 мм)
            ModernGridSliderControl(
                icon: "arrow.left.and.line.vertical.and.arrow.right",
                value: gridSpacingBinding,
                range: 1...32,
                step: 1,
                defaultValue: 3,
                displayFormat: { $0 <= 3 ? "\(Int($0)) px (≈1 мм)" : "\(Int($0)) px" },
                helpText: "Расстояние между эскизами: \(Int(gridSpacingBinding.wrappedValue)) px (мин. 1-3 px ≈ 1 мм)"
            )
            
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)
            
            Button(action: {
                ThumbnailCacheManager.shared.clearCache()
            }) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .controlColor).opacity(0.22))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Сбросить кэш эскизов (очистить память и диск)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }
}

// MARK: - Вспомогательное расширение для условного включения перетаскивания файлов

private extension View {
    @ViewBuilder
    func enableDragIf(_ condition: Bool, provider: @escaping () -> NSItemProvider) -> some View {
        if condition {
            self.onDrag(provider, preview: { Color.clear.frame(width: 1, height: 1) })
        } else {
            self
        }
    }
}

// MARK: - Отслеживание позиций ячеек сетки для выделения рамкой

public struct CellFramePreferenceKey: PreferenceKey {
    public static var defaultValue: [String: CGRect] = [:]
    public static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Графический просмотрщик папок (Сетка файлов)

public struct FileGridPaneView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    public let side: PaneSide
    
    @State private var isDropTarget: Bool = false
    @State private var marqueeRect: CGRect? = nil
    @State private var selectionAnchorId: String? = nil
    @State private var cellFrames: [String: CGRect] = [:]
    
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
        ScrollViewReader { scrollProxy in
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
                            let flags = NSEvent.modifierFlags
                            let isModHeld = flags.contains(.shift) || flags.contains(.control) || flags.contains(.command)
                            let canDrag = isSelected && !isModHeld
                            
                            FileGridCell(
                                item: item,
                                side: side,
                                size: thumbnailSize,
                                spacing: gridSpacing,
                                isSelected: isSelected,
                                canDrag: canDrag,
                                onTap: {
                                    handleCellTap(item: item)
                                },
                                onDoubleTap: {
                                    handleCellDoubleTap(item: item)
                                },
                                onToggleSelection: {
                                    toggleItemSelection(item: item)
                                }
                            )
                            .id(item.id)
                        }
                    }
                    .padding(gridSpacing)
                    
                    // Свободное пространство снизу сетки для сброса выделения кликом
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            clearSelection()
                        }
                }
            }
            .contentShape(Rectangle())
            .coordinateSpace(name: "FileGridCoordinateSpace_\(side)")
            .contextMenu {
                emptyGridContextMenu
            }
            .onPreferenceChange(CellFramePreferenceKey.self) { frames in
                self.cellFrames = frames
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.1))
            .background(
                GridKeyHandler(
                    side: side,
                    vm: vm,
                    items: items,
                    cellFrames: cellFrames,
                    onNavigateOffset: { offset in
                        navigateSelection(offset: offset)
                    },
                    onNavigateRow: { direction in
                        navigateSelectionRow(direction: direction)
                    },
                    onMarqueeChanged: { rect in
                        self.marqueeRect = rect
                    }
                )
            )
            .overlay(
                Group {
                    if let rect = marqueeRect, rect.width > 2 && rect.height > 2 {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.18))
                            .overlay(
                                Rectangle()
                                    .stroke(Color.accentColor, lineWidth: 1)
                            )
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .allowsHitTesting(false)
                    }
                }
            )
            .onDrop(of: [DualPaneViewModel.dragUTType, UTType.fileURL.identifier, UTType.utf8PlainText.identifier], delegate: FileGridDropDelegate(side: side, vm: vm, items: items))
            .simultaneousGesture(TapGesture().onEnded {
                if vm.activePane != side {
                    vm.activePane = side
                }
            })
            .onChange(of: selection) { newSel in
                if let targetId = newSel.first {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        scrollProxy.scrollTo(targetId, anchor: .center)
                    }
                }
            }
        }
    }
    
    private func toggleItemSelection(item: FileItem) {
        if vm.activePane != side { vm.activePane = side }
        selectionAnchorId = item.id
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
    }
    
    private func clearSelection() {
        selectionAnchorId = nil
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
        
        let flags = NSEvent.modifierFlags
        let isToggle = flags.contains(.command) || flags.contains(.control)
        let isShift = flags.contains(.shift)
        
        if isToggle {
            // Мультивыбор с Cmd или Ctrl
            selectionAnchorId = item.id
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
        } else if isShift {
            // Диапазон с Shift: используем стабильный сохранённый якорь
            let currentItems = items
            let anchor = selectionAnchorId ?? selection.first ?? item.id
            if let startIdx = currentItems.firstIndex(where: { $0.id == anchor || $0.path == anchor }),
               let endIdx = currentItems.firstIndex(where: { $0.id == item.id || $0.path == item.id }) {
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
                selectionAnchorId = item.id
                selectSingle(item: item)
            }
        } else {
            // Одиночный выбор
            selectionAnchorId = item.id
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

    @ViewBuilder
    private var emptyGridContextMenu: some View {
        if (side == .left ? vm.leftSource : vm.rightSource) == .remotePhone {
            Button("Освободить место — copy done") { vm.openCopyDone(side: side) }
                .disabled(!vm.canStartCopyDone)
            Divider()
        }
        Button("Новая папка") { vm.prepareNewFolder(side: side) }
        Button("Вставить (Cmd+V)") { vm.pasteFromClipboard(targetSide: side) }
            .disabled(!vm.canPaste)
        Button("Выделить всё (Cmd+A)") { vm.selectAll(side: side) }
        Divider()
        Button("Обновить (Cmd+R)") { vm.refreshPaneToActiveTab(side: side) }
        Button("Рабочие копии файлов телефона...") { vm.showExternalEdits = true }
        Toggle("Показывать скрытые файлы", isOn: Binding(
            get: { side == .left ? vm.leftShowHidden : vm.rightShowHidden },
            set: { newValue in
                let showHidden = side == .left ? vm.leftShowHidden : vm.rightShowHidden
                if newValue != showHidden { vm.toggleShowHidden(side: side) }
            }
        ))
        Divider()
        Button("Скопировать путь к папке") {
            let path = side == .left ? vm.leftPath : vm.rightPath
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
        Button("Свойства (Cmd+I)") { vm.triggerProperties(side: side) }
        Divider()
        Button("Сбросить кэш эскизов") {
            ThumbnailCacheManager.shared.clearCache()
        }
    }
}

// MARK: - Обработчик клавиатурных и мышиных событий для сетки (Quick Look, навигация, операции, выделение рамкой)

public struct GridKeyHandler: NSViewRepresentable {
    public let side: PaneSide
    public let vm: DualPaneViewModel
    public let items: [FileItem]
    public let cellFrames: [String: CGRect]
    public let onNavigateOffset: (Int) -> Void
    public let onNavigateRow: (Int) -> Void
    public let onMarqueeChanged: ((CGRect?) -> Void)?
    
    public init(
        side: PaneSide,
        vm: DualPaneViewModel,
        items: [FileItem],
        cellFrames: [String: CGRect],
        onNavigateOffset: @escaping (Int) -> Void,
        onNavigateRow: @escaping (Int) -> Void,
        onMarqueeChanged: ((CGRect?) -> Void)? = nil
    ) {
        self.side = side
        self.vm = vm
        self.items = items
        self.cellFrames = cellFrames
        self.onNavigateOffset = onNavigateOffset
        self.onNavigateRow = onNavigateRow
        self.onMarqueeChanged = onMarqueeChanged
    }
    
    public func makeNSView(context: Context) -> GridKeyHandlerView {
        let view = GridKeyHandlerView()
        view.side = side
        view.vm = vm
        view.items = items
        view.cellFrames = cellFrames
        view.onNavigateOffset = onNavigateOffset
        view.onNavigateRow = onNavigateRow
        view.onMarqueeChanged = onMarqueeChanged
        return view
    }
    
    public func updateNSView(_ nsView: GridKeyHandlerView, context: Context) {
        nsView.side = side
        nsView.vm = vm
        nsView.items = items
        nsView.cellFrames = cellFrames
        nsView.onNavigateOffset = onNavigateOffset
        nsView.onNavigateRow = onNavigateRow
        nsView.onMarqueeChanged = onMarqueeChanged
    }
    
    public final class GridKeyHandlerView: NSView {
        public override var isFlipped: Bool { true }
        var side: PaneSide = .left
        weak var vm: DualPaneViewModel?
        var items: [FileItem] = []
        var cellFrames: [String: CGRect] = [:]
        var onNavigateOffset: ((Int) -> Void)?
        var onNavigateRow: ((Int) -> Void)?
        var onMarqueeChanged: ((CGRect?) -> Void)?
        
        private var eventMonitor: Any?
        private var mouseMonitor: Any?
        private var isDraggingSelection: Bool = false
        private var didClickOnItem: Bool = false
        private var dragStartWindowPoint: CGPoint = .zero
        private var preDragSelection: Set<String> = []
        
        public override func hitTest(_ point: NSPoint) -> NSView? {
            return nil
        }
        
        deinit {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let mMonitor = mouseMonitor {
                NSEvent.removeMonitor(mMonitor)
            }
        }
        
        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                setupMonitor()
            } else {
                removeMonitor()
            }
        }
        
        public override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                removeMonitor()
            }
        }
        
        private func removeMonitor() {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
            if let mMonitor = mouseMonitor {
                NSEvent.removeMonitor(mMonitor)
                mouseMonitor = nil
            }
        }
        
        private func setupMonitor() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self, let win = self.window, event.window === win else {
                    return event
                }
                guard let vm = self.vm else { return event }
                
                // 1. Не перехватываем ввод, если активно редактирование текста
                if let firstResponder = win.firstResponder, KeyCommandMonitor.isTextEditingResponder(firstResponder) {
                    if KeyCommandMonitor.handleEvent(event, targetResponder: firstResponder) == nil {
                        return nil
                    }
                    return event
                }
                if KeyCommandMonitor.isTextEditingActive(in: vm) {
                    return event
                }
                
                // 2. Обрабатываем только для активной панели
                guard vm.activePane == self.side else {
                    return event
                }
                
                if KeyCommandMonitor.handleEvent(event) == nil {
                    return nil
                }
                
                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                
                // Пробел (KeyCode 49) без модификаторов -> Быстрый просмотр (Quick Look) / размер папки
                if event.keyCode == 49 && modifiers.isEmpty {
                    print("DUAL_PANE: KeyDown Space in Grid on side \(self.side)")
                    self.ensureSelectionBeforeQuickLook()
                    vm.triggerQuickLook(preferNativeQuickLook: true)
                    return nil
                }
                
                // F3 (KeyCode 99) без модификаторов -> Быстрый просмотр (Quick Look)
                if event.keyCode == 99 && modifiers.isEmpty {
                    print("DUAL_PANE: KeyDown F3 in Grid on side \(self.side)")
                    self.ensureSelectionBeforeQuickLook()
                    vm.triggerQuickLook(preferNativeQuickLook: true)
                    return nil
                }
                
                // Return / Enter (36 / 76)
                if (event.keyCode == 36 || event.keyCode == 76) && modifiers.isEmpty {
                    vm.openSelected()
                    return nil
                }
                
                // Delete / Forward Delete / Cmd+Delete (KeyCode 51, 117)
                if event.keyCode == 51 || event.keyCode == 117 {
                    if modifiers.isEmpty || modifiers == .command {
                        vm.triggerDelete()
                        return nil
                    }
                }
                // F8 (KeyCode 100) -> Удалить
                if event.keyCode == 100 && modifiers.isEmpty {
                    vm.triggerDelete()
                    return nil
                }
                
                // Tab (KeyCode 48) -> Смена панели (Tab или Shift+Tab)
                let isTab = (event.keyCode == 48 || event.characters == "\t" || event.charactersIgnoringModifiers == "\t")
                if isTab && (modifiers.isEmpty || modifiers == .shift) {
                    vm.toggleActivePane()
                    return nil
                }
                
                // F2 (KeyCode 120) -> Переименовать
                if event.keyCode == 120 && modifiers.isEmpty {
                    vm.triggerRename(side: self.side)
                    return nil
                }
                
                // F5 (KeyCode 96) -> Копировать / Alt+F5 Создать архив
                if event.keyCode == 96 {
                    if modifiers == .option {
                        vm.triggerCreateArchive()
                    } else if modifiers.isEmpty {
                        vm.triggerCopy()
                    }
                    return nil
                }
                
                // F6 (KeyCode 97) -> Переместить
                if event.keyCode == 97 && modifiers.isEmpty {
                    vm.triggerMove()
                    return nil
                }
                
                // F7 (KeyCode 98) -> Новая папка
                if event.keyCode == 98 && modifiers.isEmpty {
                    vm.prepareNewFolder()
                    return nil
                }
                
                // Cmd+A / Ctrl+A -> Выделить все
                if (event.keyCode == 0 || event.charactersIgnoringModifiers?.lowercased() == "a") && (modifiers == .command || modifiers == .control) {
                    vm.selectAll(side: self.side)
                    return nil
                }
                
                // Ctrl+T / Cmd+T (KeyCode 17 or "t" / "е" / \u{14}) -> Новая вкладка
                let isCtrl = modifiers.contains(.control) && !modifiers.contains(.command) && !modifiers.contains(.option)
                let hasCommand = modifiers.contains(.command) && !modifiers.contains(.option)
                let isCtrlOrCmd = isCtrl || hasCommand
                let chars = event.characters?.lowercased()
                let charsNoMods = event.charactersIgnoringModifiers?.lowercased()
                if isCtrlOrCmd && (event.keyCode == 17 || chars == "\u{14}" || chars == "t" || chars == "е" || charsNoMods == "\u{14}" || charsNoMods == "t" || charsNoMods == "е") {
                    vm.addTab(side: self.side)
                    return nil
                }
                // Ctrl+R / Cmd+R (KeyCode 15 or "r" / "к" / \u{12}) -> Обновление активного tab
                if isCtrlOrCmd && (event.keyCode == 15 || chars == "\u{12}" || chars == "r" || chars == "к" || charsNoMods == "\u{12}" || charsNoMods == "r" || charsNoMods == "к") {
                    vm.refreshPaneToActiveTab(side: self.side)
                    return nil
                }
                
                // Cmd+Up Arrow (KeyCode 126 with .command) -> Наверх (родительская папка)
                if event.keyCode == 126 && modifiers == .command {
                    vm.navigateUp(side: self.side)
                    return nil
                }
                
                // Стрелка влево (123)
                if event.keyCode == 123 && modifiers.isEmpty {
                    self.onNavigateOffset?(-1)
                    return nil
                }
                // Стрелка вправо (124)
                if event.keyCode == 124 && modifiers.isEmpty {
                    self.onNavigateOffset?(1)
                    return nil
                }
                // Стрелка вверх (126)
                if event.keyCode == 126 && modifiers.isEmpty {
                    self.onNavigateRow?(-1)
                    return nil
                }
                // Стрелка вниз (125)
                if event.keyCode == 125 && modifiers.isEmpty {
                    self.onNavigateRow?(1)
                    return nil
                }
                
                return event
            }
            
            guard mouseMonitor == nil else { return }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self = self, let win = self.window, event.window === win else {
                    return event
                }
                guard let vm = self.vm else { return event }
                guard vm.failedConnectionSide == nil else { return event }
                
                let locInSelf = self.convert(event.locationInWindow, from: nil)
                let isInside: Bool
                if let scroll = self.enclosingScrollView {
                    let locInScroll = scroll.convert(event.locationInWindow, from: nil)
                    isInside = scroll.bounds.contains(locInScroll)
                } else {
                    isInside = self.bounds.contains(locInSelf)
                }
                
                if isInside, let hit = win.contentView?.hitTest(event.locationInWindow) {
                    let isGridHit = (hit === self || hit.isDescendant(of: self) || (self.enclosingScrollView != nil && (hit === self.enclosingScrollView || hit.isDescendant(of: self.enclosingScrollView!))))
                    if !isGridHit {
                        return event
                    }
                }
                
                switch event.type {
                case .leftMouseDown:
                    if isInside {
                        if vm.activePane != self.side {
                            vm.activePane = self.side
                        }
                        self.dragStartWindowPoint = event.locationInWindow
                        self.isDraggingSelection = false
                        self.preDragSelection = (self.side == .left ? vm.leftSelection : vm.rightSelection)
                        
                        let currentSel = (self.side == .left ? vm.leftSelection : vm.rightSelection)
                        self.didClickOnItem = self.cellFrames.contains { (id, frame) in
                            currentSel.contains(id) && frame.contains(locInSelf)
                        }
                    }
                    return event
                    
                case .leftMouseDragged:
                    guard isInside || self.isDraggingSelection else { return event }
                    guard !self.didClickOnItem else { return event }
                    let dist = hypot(event.locationInWindow.x - self.dragStartWindowPoint.x,
                                     event.locationInWindow.y - self.dragStartWindowPoint.y)
                    guard dist > 4 else { return event }
                    
                    self.isDraggingSelection = true
                    
                    // Координаты рамки выделения относительно этого контейнера
                    let startPtInSelf = self.convert(self.dragStartWindowPoint, from: nil)
                    let currPtInSelf = locInSelf
                    let marqueeInSelf = CGRect(
                        x: min(startPtInSelf.x, currPtInSelf.x),
                        y: min(startPtInSelf.y, currPtInSelf.y),
                        width: max(1, abs(currPtInSelf.x - startPtInSelf.x)),
                        height: max(1, abs(currPtInSelf.y - startPtInSelf.y))
                    )
                    self.onMarqueeChanged?(marqueeInSelf)
                    
                    // Поиск всех ячеек, пересекающих рамку выделения или находящихся под курсором
                    var hitIds: Set<String> = []
                    for (id, frame) in self.cellFrames {
                        if marqueeInSelf.intersects(frame) || frame.contains(currPtInSelf) {
                            hitIds.insert(id)
                        }
                    }
                    
                    let flags = event.modifierFlags
                    if flags.contains(.option) {
                        var updated = self.preDragSelection
                        updated.subtract(hitIds)
                        if self.side == .left {
                            vm.leftSelection = updated
                        } else {
                            vm.rightSelection = updated
                        }
                    } else if flags.contains(.shift) || flags.contains(.command) || flags.contains(.control) {
                        let updated = self.preDragSelection.union(hitIds)
                        if self.side == .left {
                            vm.leftSelection = updated
                            vm.rightSelection.removeAll()
                        } else {
                            vm.rightSelection = updated
                            vm.leftSelection.removeAll()
                        }
                    } else {
                        if self.side == .left {
                            vm.leftSelection = hitIds
                            vm.rightSelection.removeAll()
                        } else {
                            vm.rightSelection = hitIds
                            vm.leftSelection.removeAll()
                        }
                    }
                    return event
                    
                case .leftMouseUp:
                    if self.isDraggingSelection {
                        self.isDraggingSelection = false
                        self.onMarqueeChanged?(nil)
                        return nil
                    }
                    return event
                    
                default:
                    return event
                }
            }
        }
        
        private func ensureSelectionBeforeQuickLook() {
            guard let vm = vm else { return }
            let sel = (side == .left) ? vm.leftSelection : vm.rightSelection
            if sel.isEmpty, let firstItem = items.first {
                if side == .left {
                    vm.leftSelection = [firstItem.id]
                    vm.rightSelection.removeAll()
                } else {
                    vm.rightSelection = [firstItem.id]
                    vm.leftSelection.removeAll()
                }
            }
        }
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
    public let canDrag: Bool
    public var onTap: (() -> Void)?
    public var onDoubleTap: (() -> Void)?
    public var onToggleSelection: (() -> Void)?
    
    @State private var thumbnail: NSImage? = nil
    @State private var isLoading: Bool = false
    @State private var isHovered: Bool = false
    @State private var thumbnailReloadToken: Int = 0
    
    public init(
        item: FileItem,
        side: PaneSide,
        size: CGFloat,
        spacing: CGFloat = 10,
        isSelected: Bool,
        canDrag: Bool = false,
        onTap: (() -> Void)? = nil,
        onDoubleTap: (() -> Void)? = nil,
        onToggleSelection: (() -> Void)? = nil
    ) {
        self.item = item
        self.side = side
        self.size = size
        self.spacing = spacing
        self.isSelected = isSelected
        self.canDrag = canDrag
        self.onTap = onTap
        self.onDoubleTap = onDoubleTap
        self.onToggleSelection = onToggleSelection
    }
    
    public var body: some View {
        let pad = FileGridPaneView.cellPadding(for: spacing)
        let imgInset: CGFloat = spacing <= 3 ? 0 : max(0, min(6, (spacing - 3) * 0.6))
        let cornerRad: CGFloat = spacing <= 3 ? 2 : max(4, min(8, spacing * 0.7))
        
        VStack(spacing: spacing <= 3 ? 2 : 4) {
            // 1. Контейнер миниатюры
            ZStack(alignment: .bottomTrailing) {
                // Основной блок миниатюры (фон + иконка/картинка)
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
                        FileItemIconView(isDirectory: false, fileName: item.name, size: size * 0.40)
                    }
                }
                .frame(width: size, height: size)
                .contentShape(Rectangle())
                .enableDragIf(canDrag) {
                    vm.createDragItemProvider(for: item, side: side)
                }
                .onTapGesture {
                    onTap?()
                }
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    onDoubleTap?()
                })

                if vm.isFilePinned(item, side: side) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.55))
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .allowsHitTesting(false)
                }
                if vm.canReorderFiles(in: side) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 23, height: 23)
                        .background(Circle().fill(Color.black.opacity(0.58)))
                        .contentShape(Circle())
                        .onDrag { vm.createFileReorderProvider(for: item, side: side) }
                        .help("Перетащите маркер, чтобы изменить порядок")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                
                // Чекбокс / кружочек выделения справа снизу
                let checkboxSize: CGFloat = min(22, max(16, size * 0.16))
                let currentSel = (side == .left ? vm.leftSelection : vm.rightSelection)
                let hasAnySel = !currentSel.isEmpty
                
                Button(action: {
                    onToggleSelection?()
                }) {
                    ZStack {
                        if isSelected {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: checkboxSize, height: checkboxSize)
                                .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                            
                            Image(systemName: "checkmark")
                                .font(.system(size: checkboxSize * 0.52, weight: .bold))
                                .foregroundColor(.white)
                        } else {
                            Circle()
                                .fill(Color.white.opacity(0.92))
                                .frame(width: checkboxSize, height: checkboxSize)
                                .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
                            
                            Circle()
                                .strokeBorder(Color.accentColor, lineWidth: 1.8)
                                .frame(width: checkboxSize, height: checkboxSize)
                        }
                    }
                    .frame(width: checkboxSize, height: checkboxSize)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(isSelected ? 1.0 : (isHovered || hasAnySel ? 1.0 : 0.35))
                .help(isSelected ? "Снять выделение" : "Выделить")
                .padding(spacing <= 3 ? 3 : 5)
            }
            .frame(width: size, height: size)
            .onDrop(of: [DualPaneViewModel.reorderUTType], delegate: FileReorderDropDelegate(item: item, side: side, vm: vm))
            
            // 2 & 3. Имя файла / папки и метаданные (размер)
            VStack(spacing: 1) {
                if vm.editingItemId == item.id && vm.editingItemSide == side {
                    let baseName = InlineRenameHelper.baseName(for: vm.editingItemName, isDirectory: item.isDirectory)
                    let baseNameWidth = InlineRenameHelper.textWidth(for: baseName)
                    
                    HStack(spacing: 0) {
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
                        .frame(height: 18)
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 5)
                    .background(ConflictColors.renameInputBg)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(ConflictColors.inputFocusBorder, lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        CopyFragmentButtonView(baseName: baseName) {
                            let fragment = InlineRenameHelper.currentFragment(for: vm.editingItemName, isDirectory: item.isDirectory)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(fragment, forType: .string)
                            vm.statusMessage = "Скопирован фрагмент: \(fragment)"
                        }
                        .frame(width: 26, height: 26)
                        .offset(x: min(max(10, 5 + baseNameWidth + 6), size - 28), y: -14)
                    }
                    .zIndex(100)
                    .frame(maxWidth: size)
                } else {
                    Text(item.name)
                        .font(.system(size: spacing <= 3 ? 11 : 12, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .accentColor : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .truncationMode(.middle)
                        .frame(width: size)
                        .highPriorityGesture(
                            LongPressGesture(minimumDuration: 0.55).onEnded { _ in
                                if vm.activePane != side { vm.activePane = side }
                                if side == .left {
                                    vm.leftSelection = [item.id]
                                } else {
                                    vm.rightSelection = [item.id]
                                }
                                vm.triggerRename(item: item, side: side)
                            }
                        )
                }
                
                Group {
                    if item.isDirectory {
                        if let folderSize = vm.calculatedFolderSizes[item.path] {
                            Text(formatBytes(folderSize))
                        } else {
                            Text("")
                        }
                    } else {
                        Text(formatBytes(item.size))
                    }
                }
                .font(.system(size: spacing <= 3 ? 9 : 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
            .frame(width: size, height: spacing <= 3 ? 30 : 34, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture {
                onTap?()
            }
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
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: CellFramePreferenceKey.self,
                    value: [item.id: geo.frame(in: .named("FileGridCoordinateSpace_\(side)"))]
                )
            }
        )
        .onDrop(of: [DualPaneViewModel.dragUTType, UTType.fileURL.identifier, UTType.utf8PlainText.identifier], isTargeted: Binding(
            get: { isDragHoverFolder },
            set: { onFolderTargetChanged($0) }
        )) { providers in
            onFolderDrop(providers: providers)
        }
        .onAppear {
            if thumbnail == nil && !item.isDirectory {
                thumbnailReloadToken &+= 1
            }
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
        .onReceive(NotificationCenter.default.publisher(for: ThumbnailCacheManager.cacheClearedNotification)) { _ in
            self.thumbnail = nil
            if !item.isDirectory {
                thumbnailReloadToken &+= 1
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            gridContextMenu(for: item)
        }
    }
    
    private var isDragHoverFolder: Bool {
        vm.dragHoverSide == side && vm.dragHoverFolderId == item.id
    }
    
    private var isMissingInOpposite: Bool {
        guard vm.isComparing else { return false }
        return (side == .left ? vm.comparisonResult.onlyLeft : vm.comparisonResult.onlyRight).contains(item.name)
    }
    
    private var cellBackgroundFill: Color {
        if vm.editingItemId == item.id && vm.editingItemSide == side {
            return Color.clear
        } else if isDragHoverFolder {
            return Color.accentColor.opacity(0.35)
        } else if isSelected {
            return isMissingInOpposite ? Color.red.opacity(0.24) : Color.accentColor.opacity(0.18)
        } else if isMissingInOpposite {
            return Color.red.opacity(0.16)
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
            return isMissingInOpposite ? Color.red.opacity(0.8) : Color.accentColor
        } else if isMissingInOpposite {
            return Color.red.opacity(0.35)
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
        let isInternalDrop = DualPaneViewModel.providersCarryInternalPayload(providers)
            || (NSPasteboard(name: .drag).types?.contains(NSPasteboard.PasteboardType(DualPaneViewModel.dragUTType)) ?? false)
        if vm.consumeInternalDragPayload(isInternalDrop: isInternalDrop) {
            return vm.handleDroppedProviders([], toSide: side, targetDirPath: targetDir, isMove: isMove)
        }
        return vm.handleDroppedProviders(providers, toSide: side, targetDirPath: targetDir, isMove: isMove)
    }
    
    private func loadThumbnailAsync() async {
        if item.isDirectory { return }
        
        let ext = URL(fileURLWithPath: item.name).pathExtension.lowercased()
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff", "tif", "ico", "avif", "dng"]
        guard imageExts.contains(ext) else { return }
        
        // Только RAM-кэш в главном потоке; чтение с диска и генерация — в фоне
        if let cached = ThumbnailCacheManager.shared.memoryThumbnail(for: item) {
            self.thumbnail = cached
            self.isLoading = false
            return
        }
        
        self.isLoading = true
        defer {
            self.isLoading = false
        }
        
        let img = await ThumbnailCacheManager.shared.loadThumbnail(
            for: item,
            targetSize: CGSize(width: size * 2, height: size * 2),
            transport: vm.transport
        )
        // Ячейка ушла с экрана или сменила файл — результат не применяем
        guard !Task.isCancelled else { return }
        self.thumbnail = img
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
    private func gridContextMenu(for item: FileItem) -> some View {
        let contextItems = vm.contextMenuItems(for: item, side: side)
        let activeTags = TagsManager.shared.activeTags(for: contextItems.isEmpty ? [item] : contextItems)
        Button {
            vm.toggleFilePin(item, side: side)
        } label: {
            Label(vm.isFilePinned(item, side: side) ? "Открепить" : "Закрепить сверху",
                  systemImage: vm.isFilePinned(item, side: side) ? "pin.slash" : "pin")
        }
        Divider()
        ControlGroup {
            ForEach(FileTag.allTags) { tag in
                let isSelected = activeTags.contains { FileTag.isTagMatching($0, tagIdOrName: tag.id) }
                Button(action: {
                    vm.toggleTag(tag.id, for: contextItems, side: side)
                }) {
                    ZStack {
                        Circle()
                            .fill(tag.color)
                            .frame(width: 9, height: 9)
                        if isSelected {
                            Circle()
                                .stroke(tag.color, lineWidth: 1.2)
                                .frame(width: 14, height: 14)
                        }
                    }
                    .frame(width: 16, height: 16)
                }
                .help(tag.name)
            }
        }
        ControlGroup {
            Button(action: {
                vm.share(items: contextItems, side: side, target: .telegram)
            }) {
                Image(nsImage: ShareIconDrawer.telegramImage(size: 16))
            }
            .help("Поделиться в Telegram")
            
            Button(action: {
                vm.share(items: contextItems, side: side, target: .whatsapp)
            }) {
                Image(nsImage: ShareIconDrawer.whatsAppImage(size: 16))
            }
            .help("Поделиться в WhatsApp")
            
            Button(action: {
                vm.share(items: contextItems, side: side, target: .gmail)
            }) {
                Image(nsImage: ShareIconDrawer.gmailImage(size: 16))
            }
            .help("Отправить через Gmail / Почту")
        }
        Divider()
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

        if item.source == .remotePhone {
            Button("Освободить место — copy done") { vm.openCopyDone(side: side, item: item) }
                .disabled(!vm.canStartCopyDone)
        }
        Button("Удалить (F8 / Delete)", role: .destructive) {
            vm.selectContextMenuItems(for: item, side: side)
            vm.triggerDelete()
        }
        Button("Копировать (Cmd+C)") { vm.copyToClipboard(items: contextItems, side: side) }
        Button("Вырезать (Ctrl+X)") { vm.cutToClipboard(items: contextItems, side: side) }
        Button("Скопировать полный путь (Shift+Ctrl+Cmd+C)") { vm.copySelectedPath(items: contextItems, side: side) }
        Button("Вставить (Cmd+V)") { vm.pasteFromClipboard(targetSide: side) }
            .disabled(!vm.canPaste)
        Button("Дублировать (Cmd+Shift+D)") { vm.duplicateItem(item: item, side: side) }

        Button("Разархивировать") { vm.unarchive(item: item, side: side) }
            .disabled(item.isDirectory || !vm.isArchive(item: item) || vm.isArchiving)
        Button("Сжать в архив... (Alt+F5)") { vm.triggerCreateArchive(item: item, side: side) }
        Button("Переименовать (F2)") { vm.triggerRename(item: item, side: side) }
        Button("Свойства (Cmd+I)") { vm.triggerProperties(item: item, side: side) }

        Button("Рабочие копии файлов телефона...") { vm.showExternalEdits = true }
        Toggle("Показывать скрытые файлы", isOn: Binding(
            get: { side == .left ? vm.leftShowHidden : vm.rightShowHidden },
            set: { newValue in
                let showHidden = side == .left ? vm.leftShowHidden : vm.rightShowHidden
                if newValue != showHidden { vm.toggleShowHidden(side: side) }
            }
        ))
        
        Divider()
        
        Button("Сбросить кэш эскизов") {
            ThumbnailCacheManager.shared.clearCache()
        }
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
        
        // 1. Приоритетная проверка внутреннего Drag & Drop (межпанельный или внутри панели)
        let customUTType = UTType(exportedAs: DualPaneViewModel.dragUTType, conformingTo: .data)
        let isInternalDrop = info.hasItemsConforming(to: [customUTType])
            || info.hasItemsConforming(to: [DualPaneViewModel.dragUTType])
            || (NSPasteboard(name: .drag).types?.contains(NSPasteboard.PasteboardType(DualPaneViewModel.dragUTType)) ?? false)

        if vm.consumeInternalDragPayload(isInternalDrop: isInternalDrop) {
            return vm.handleDroppedProviders([], toSide: side, targetDirPath: targetDirPath, isMove: isMove)
        }

        // 2. Внешний Drag (Finder, Desktop и др.)
        let utTypes: [UTType] = [
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
