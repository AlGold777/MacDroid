import SwiftUI
import UniformTypeIdentifiers
import AppKit

public struct PaneView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    public let side: PaneSide
    
    @State private var isDropTarget: Bool = false
    @State private var editingTabId: UUID? = nil
    @State private var editingTabTitle: String = ""
    @FocusState private var isTabTitleFocused: Bool
    
    public init(side: PaneSide) {
        self.side = side
    }
    
    private var isActive: Bool {
        vm.activePane == side
    }
    
    private var tabs: [PanelTab] {
        side == .left ? vm.leftTabs : vm.rightTabs
    }
    
    private var activeTabId: UUID {
        side == .left ? vm.leftActiveTabId : vm.rightActiveTabId
    }
    
    private var sourceBinding: Binding<FileSource> {
        side == .left ? $vm.leftSource : $vm.rightSource
    }
    
    private var currentPath: String {
        side == .left ? vm.leftPath : vm.rightPath
    }
    
    private var isStale: Bool {
        let isRemote = (side == .left ? vm.leftSource : vm.rightSource) == .remotePhone
        let staleFlag = (side == .left ? vm.leftIsStale : vm.rightIsStale)
        return isRemote && staleFlag
    }
    
    private var freeSpace: (free: UInt64, total: UInt64) {
        side == .left ? vm.leftFreeSpace : vm.rightFreeSpace
    }
    
    private var items: [FileItem] {
        vm.displayItems(for: side)
    }
    
    private var sortOrderBinding: Binding<[KeyPathComparator<FileItem>]> {
        Binding(
            get: {
                let sortField = (side == .left) ? vm.leftSortField : vm.rightSortField
                let sortAsc = (side == .left) ? vm.leftSortAscending : vm.rightSortAscending
                let order: SortOrder = sortAsc ? .forward : .reverse
                switch sortField {
                case .name:
                    return [KeyPathComparator(\FileItem.name, order: order)]
                case .size:
                    return [KeyPathComparator(\FileItem.size, order: order)]
                case .date:
                    return [KeyPathComparator(\FileItem.mtime, order: order)]
                }
            },
            set: { newOrder in
                guard let first = newOrder.first else { return }
                let isAsc = (first.order == .forward)
                let field: SortField
                if first.keyPath == \FileItem.size {
                    field = .size
                } else if first.keyPath == \FileItem.mtime {
                    field = .date
                } else {
                    field = .name
                }
                DispatchQueue.main.async {
                    if side == .left {
                        vm.leftSortField = field
                        vm.leftSortAscending = isAsc
                    } else {
                        vm.rightSortField = field
                        vm.rightSortAscending = isAsc
                    }
                }
            }
        )
    }
    
    private var selectionBinding: Binding<Set<String>> {
        Binding(
            get: { side == .left ? vm.leftSelection : vm.rightSelection },
            set: { newSelection in
                if side == .left {
                    vm.leftSelection = newSelection
                    if !newSelection.isEmpty && !vm.rightSelection.isEmpty {
                        vm.rightSelection.removeAll()
                        TableDoubleClickHandler.HandlerView.rightTableView?.deselectAll(nil)
                    }
                } else {
                    vm.rightSelection = newSelection
                    if !newSelection.isEmpty && !vm.leftSelection.isEmpty {
                        vm.leftSelection.removeAll()
                        TableDoubleClickHandler.HandlerView.leftTableView?.deselectAll(nil)
                    }
                }
                if vm.activePane != side {
                    vm.activePane = side
                }
            }
        )
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Вкладки панели (Tabs)
            HStack(spacing: 3) {
                // Навигация: ↑ , ←, → слева от первой tab
                Button(action: {
                    if vm.activePane != side { vm.activePane = side }
                    vm.navigateUp(side: side)
                }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("На уровень выше (Cmd+Up)")
                
                Button(action: {
                    if vm.activePane != side { vm.activePane = side }
                    vm.navigateBack(side: side)
                }) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(vm.canNavigateBack(side: side) ? .primary : .secondary.opacity(0.35))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(!vm.canNavigateBack(side: side))
                .help("Назад (Cmd+[)")
                
                Button(action: {
                    if vm.activePane != side { vm.activePane = side }
                    vm.navigateForward(side: side)
                }) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(vm.canNavigateForward(side: side) ? .primary : .secondary.opacity(0.35))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(!vm.canNavigateForward(side: side))
                .help("Вперёд (Cmd+])")
                
                Divider()
                    .frame(height: 14)
                    .padding(.horizontal, 2)
                
                ForEach(tabs) { tab in
                    HStack(spacing: 4) {
                        if tab.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.orange)
                        }
                        
                        if editingTabId == tab.id {
                            TextField("", text: $editingTabTitle, onCommit: {
                                commitTabRename(tab: tab)
                            })
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .bold))
                            .frame(minWidth: 50, maxWidth: 120)
                            .focused($isTabTitleFocused)
                            .onExitCommand {
                                editingTabId = nil
                            }
                            
                            Button(action: { commitTabRename(tab: tab) }) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.green)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(tab.title)
                                .font(.system(size: 13, weight: tab.id == activeTabId ? .bold : .regular))
                                .lineLimit(1)
                        }
                        
                        if !tab.isPinned && tabs.count > 1 && editingTabId != tab.id {
                            Button(action: { vm.closeTab(id: tab.id, side: side) }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(tab.id == activeTabId ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor).opacity(0.5))
                    .cornerRadius(4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if editingTabId != tab.id {
                            if vm.activePane != side {
                                vm.activePane = side
                            }
                            vm.switchTab(id: tab.id, side: side)
                        }
                    }
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        startTabRename(tab: tab)
                    })
                    .onLongPressGesture(minimumDuration: 0.5) {
                        startTabRename(tab: tab)
                    }
                    .onDrag {
                        vm.draggedTabInfo = (side: side, id: tab.id)
                        return NSItemProvider(object: tab.id.uuidString as NSString)
                    }
                    .onDrop(of: [UTType.text.identifier, UTType.plainText.identifier], delegate: TabReorderDropDelegate(targetTab: tab, side: side, vm: vm))
                    .contextMenu {
                        Button(action: { startTabRename(tab: tab) }) {
                            Label("Переименовать вкладку...", systemImage: "pencil")
                        }
                        Divider()
                        Button(action: { vm.togglePinTab(id: tab.id, side: side) }) {
                            Label(tab.isPinned ? "Открепить вкладку" : "Закрепить вкладку", systemImage: tab.isPinned ? "pin.slash" : "pin")
                        }
                        Button(action: { vm.duplicateTab(id: tab.id, side: side) }) {
                            Label("Дублировать вкладку", systemImage: "plus.square.on.square")
                        }
                        if !tab.isPinned && tabs.count > 1 {
                            Divider()
                            Button(role: .destructive, action: { vm.closeTab(id: tab.id, side: side) }) {
                                Label("Закрыть вкладку", systemImage: "xmark")
                            }
                        }
                    }
                }
                
                Button(action: { vm.addTab(side: side) }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(4)
                }
                .buttonStyle(.plain)
                
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            // Заголовок панели: выбор источника (диска), путь (хлебные крошки), фильтр
            HStack(spacing: 6) {
                // 1. Выбор источника (диска)
                Menu {
                    ForEach(FileSource.allCases) { src in
                        Button(action: {
                            vm.changeSource(to: src, side: side)
                        }) {
                            HStack {
                                Text(src.rawValue)
                                if (side == .left ? vm.leftSource : vm.rightSource) == src {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    if !vm.detectedVolumes.isEmpty {
                        Divider()
                        ForEach(vm.detectedVolumes) { vol in
                            Button(action: {
                                vm.switchToVolume(vol, side: side)
                            }) {
                                HStack {
                                    Text("📱 \(vol.name)")
                                    let currentP = (side == .left ? vm.leftPath : vm.rightPath)
                                    let currentS = (side == .left ? vm.leftSource : vm.rightSource)
                                    if currentS == .remotePhone && currentP.hasPrefix(vol.path) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: (side == .left ? vm.leftSource : vm.rightSource) == .localMac ? "internaldrive" : "iphone")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Text((side == .left ? vm.leftSource : vm.rightSource).rawValue)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                    .cornerRadius(4)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Выбор диска / источника")
                
                // 2. Путь: Переключение между Breadcrumbs и Manual Input (сразу за выбором дисков, без фона)
                let isEditingPath = (side == .left) ? vm.isEditingLeftPath : vm.isEditingRightPath
                if isEditingPath {
                    HStack(spacing: 2) {
                        TextField("Путь...", text: $vm.manualPathInput, onCommit: {
                            vm.commitManualPath(side: side)
                        })
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 4)
                        
                        Button(action: { vm.commitManualPath(side: side) }) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: {
                            if side == .left { vm.isEditingLeftPath = false } else { vm.isEditingRightPath = false }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(4)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 3) {
                            let components = URL(fileURLWithPath: currentPath).pathComponents
                            ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                                Button(action: {
                                    let targetPath: String
                                    if index == 0 {
                                        targetPath = (side == .left ? vm.leftSource : vm.rightSource) == .localMac
                                            ? FileManager.default.homeDirectoryForCurrentUser.path
                                            : "/storage/emulated/0"
                                    } else {
                                        targetPath = "/" + components[1...index].joined(separator: "/")
                                    }
                                    vm.navigateTo(path: targetPath, side: side)
                                }) {
                                    Text(component == "/" ? "⌂" : component)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.accentColor)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if index == 0 {
                                        let bms = vm.quickBookmarks(for: side)
                                        ForEach(bms) { bm in
                                            Button(action: {
                                                vm.navigateTo(path: bm.path, side: side)
                                            }) {
                                                Label(bm.name, systemImage: bm.icon)
                                            }
                                        }
                                    }
                                }
                                if index < components.count - 1 {
                                    Text("›")
                                        .font(.system(size: 13, weight: .regular))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.vertical, 3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture(count: 2) {
                        vm.startEditingPath(side: side)
                    }
                    .help("Двойной клик для ручного ввода пути (Cmd+L)")
                }
                
                // 3. Поле фильтра (с иконкой, кнопкой очистки и очисткой по Esc)
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                    
                    TextField("Фильтр...", text: (side == .left ? $vm.leftFilter : $vm.rightFilter))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onExitCommand {
                            if side == .left {
                                vm.leftFilter = ""
                            } else {
                                vm.rightFilter = ""
                            }
                        }
                    
                    let filterText = (side == .left ? vm.leftFilter : vm.rightFilter)
                    if !filterText.isEmpty {
                        Button(action: {
                            if side == .left {
                                vm.leftFilter = ""
                            } else {
                                vm.rightFilter = ""
                            }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .help("Очистить фильтр (Esc)")
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .frame(width: 120)
            }
            .padding(6)
            .background(Color(nsColor: .windowBackgroundColor))
            
            if isStale {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Телефон не подключен (Offline)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: {
                        vm.connectPhone()
                    }) {
                        if vm.isConnectingPhone {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("Поиск...")
                            }
                        } else {
                            Label("Подключить", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .disabled(vm.isConnectingPhone)
                    
                    Button(action: {
                        vm.showPairingDialog = true
                    }) {
                        Label("Настройки Wi-Fi", systemImage: "wifi")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.yellow.opacity(0.15))
            }
            
            if vm.isComparing {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundColor(.accentColor)
                    Text("Сравнение: \(vm.comparisonResult.different.count) отл., \(vm.comparisonResult.onlyLeft.count) только слева, \(vm.comparisonResult.onlyRight.count) только справа (\(vm.comparisonResult.identical.count) одинаковых)")
                        .font(.system(size: 11))
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Button(action: { vm.selectDifferences() }) {
                        Label("Выделить различия", systemImage: "checkmark.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    
                    Menu {
                        Button("Синхронизировать слева направо (→)") {
                            vm.syncDifferences(direction: .leftToRight)
                        }
                        Button("Синхронизировать справа налево (←)") {
                            vm.syncDifferences(direction: .rightToLeft)
                        }
                    } label: {
                        Label("Синхронизировать", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.mini)
                    
                    Toggle("Только различия", isOn: $vm.hideIdenticalInComparison)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                    
                    Button(action: { vm.comparePanes() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Закрыть сравнение")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12))
            }
            
            Divider()
            
            if vm.isQuickViewActive && vm.activePane != side {
                QuickViewPaneView(item: vm.quickViewItem)
            } else {
                // Таблица списка файлов с Drag & Drop и сравнением
                Table(items, selection: selectionBinding, sortOrder: sortOrderBinding) {
                    TableColumn("Имя", value: \FileItem.name) { item in
                        HStack(spacing: 6) {
                            Image(systemName: item.isDirectory ? "folder.fill" : fileIconName(for: item.name))
                                .foregroundColor(item.isDirectory ? .yellow : .blue)
                            Text(item.name)
                                .font(.system(size: 13))
                            
                            if vm.isComparing {
                                comparisonBadge(for: item.name)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            print("DUAL_PANE: Cell double tap on \(item.name)")
                            vm.openItem(item: item, side: side)
                        })
                        .onDrag {
                            vm.createDragItemProvider(for: item, side: side)
                        }
                        .contextMenu {
                            rowContextMenu(for: item)
                        }
                    }
                    
                    TableColumn("Размер", value: \FileItem.size) { item in
                        HStack {
                            if item.isDirectory {
                                if vm.calculatingFolderPaths.contains(item.path) {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .scaleEffect(0.7)
                                } else if let size = vm.calculatedFolderSizes[item.path] {
                                    Text(formatBytes(size))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.primary)
                                } else {
                                    Text("<ПАПКА>")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Text(formatBytes(item.size))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            print("DUAL_PANE: Cell double tap on \(item.name)")
                            vm.openItem(item: item, side: side)
                        })
                    }
                    .width(min: 80, ideal: 100, max: 120)
                    
                    TableColumn("Дата изменения", value: \FileItem.mtime) { item in
                        HStack {
                            Text(formatDate(item.mtime))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            print("DUAL_PANE: Cell double tap on \(item.name)")
                            vm.openItem(item: item, side: side)
                        })
                    }
                    .width(min: 120, ideal: 140, max: 160)
                }
                .onKeyPress(KeyEquivalent("a"), phases: .down) { press in
                    if press.modifiers.contains(.control) || press.modifiers.contains(.command) {
                        vm.selectAll(side: side)
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.space, phases: .down) { press in
                    if press.modifiers.isEmpty {
                        vm.triggerQuickLook()
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.return, phases: .down) { _ in
                    print("DUAL_PANE: Table onKeyPress .return")
                    vm.openSelected()
                    return .handled
                }
                .onKeyPress(.delete, phases: .down) { press in
                    // Backspace/Delete opens parent directory if no modifiers
                    if press.modifiers.isEmpty {
                        vm.navigateUp()
                        return .handled
                    }
                    return .ignored
                }
                .background(
                    TableDoubleClickHandler(side: side, vm: vm, items: items) { clickedRow in
                        guard clickedRow >= 0 && clickedRow < items.count else { return }
                        let item = items[clickedRow]
                        print("DUAL_PANE: TableDoubleClickHandler on row \(clickedRow), item: \(item.name)")
                        vm.openItem(item: item, side: side)
                    }
                )
                .onDrop(of: [DualPaneViewModel.dragUTType, UTType.fileURL.identifier, UTType.utf8PlainText.identifier], isTargeted: $isDropTarget) { providers in
                    let isMove = NSEvent.modifierFlags.contains(.command)
                    return vm.handleDroppedProviders(providers, toSide: side, isMove: isMove)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 3)
                )
            }
            
            Divider()
            
            // Подвал панели: объекты, выделение и свободное место
            HStack {
                let selectedIds = (side == .left) ? vm.leftSelection : vm.rightSelection
                if selectedIds.isEmpty {
                    Text("\(items.count) объектов")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    let selectedItems = items.filter { selectedIds.contains($0.id) || selectedIds.contains($0.path) }
                    let selectedBytes = selectedItems.reduce(0) { $0 + $1.size }
                    Text("Выделено: \(selectedItems.count) из \(items.count) (\(formatBytes(selectedBytes)))")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)
                }
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
    }
    
    @ViewBuilder
    private func comparisonBadge(for name: String) -> some View {
        if side == .left {
            if vm.comparisonResult.onlyLeft.contains(name) {
                Text("Только слева")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.2))
                    .foregroundColor(.green)
                    .cornerRadius(3)
            } else if vm.comparisonResult.different.contains(name) {
                Text("Различается")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.2))
                    .foregroundColor(.orange)
                    .cornerRadius(3)
            }
        } else {
            if vm.comparisonResult.onlyRight.contains(name) {
                Text("Только справа")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.blue.opacity(0.2))
                    .foregroundColor(.blue)
                    .cornerRadius(3)
            } else if vm.comparisonResult.different.contains(name) {
                Text("Различается")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.2))
                    .foregroundColor(.orange)
                    .cornerRadius(3)
            }
        }
    }
    
    private func fileIconName(for name: String) -> String {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "dng", "webp": return "photo.fill"
        case "mp4", "mov", "mkv": return "film.fill"
        case "mp3", "wav", "flac": return "music.note"
        case "zip", "rar", "7z", "tar", "gz": return "archivebox.fill"
        case "pdf": return "doc.richtext.fill"
        default: return "doc.fill"
        }
    }
    
    private func formatBytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }
    
    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "dd.MM.yy HH:mm"
        return df
    }()
    
    private func formatDate(_ timestamp: Double) -> String {
        guard timestamp > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: timestamp)
        return Self.dateFormatter.string(from: date)
    }
    
    @ViewBuilder
    private func rowContextMenu(for item: FileItem) -> some View {
        Button("Открыть") { vm.openItem(item: item, side: side) }
        
        // Open with...
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
        
        Button("Просмотр (F3)") { vm.triggerQuickLook() }
        Divider()
        
        // Copy & Paste
        Button("Копировать (Cmd+C)") { vm.copyToClipboard(items: [item], side: side) }
        Button("Вставить (Cmd+V)") { vm.pasteFromClipboard(targetSide: side) }
            .disabled(!vm.canPaste)
        
        // Duplicate
        Button("Дублировать (Cmd+Shift+D)") { vm.duplicateItem(item: item, side: side) }
        
        Button("Копировать в другую панель (F5)") { vm.triggerCopy() }
        Button("Переместить (F6)") { vm.triggerMove() }
        Button("Сжать в архив... (Alt+F5)") { vm.triggerCreateArchive(item: item, side: side) }
        Divider()
        
        // Rename
        Button("Переименовать (F2)") { vm.triggerRename(item: item, side: side) }
        Button("Групповое переименование (Ctrl+M)...") { vm.triggerBatchRename() }
        
        // Delete
        Button("Удалить (F8)", role: .destructive) { vm.triggerDelete() }
        Divider()
        
        Button("Свойства (Cmd+I)") { vm.triggerProperties(item: item, side: side) }
        Divider()
        Button("Копировать имя") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.name, forType: .string)
        }
        Button("Копировать путь") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
        }
        if sourceBinding.wrappedValue == .localMac {
            Button("Показать в Finder") { NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "") }
        }
        Divider()
        let showHidden = (side == .left) ? vm.leftShowHidden : vm.rightShowHidden
        Button(action: { vm.toggleShowHidden(side: side) }) {
            Label(showHidden ? "Скрыть скрытые файлы" : "Показывать скрытые файлы", systemImage: showHidden ? "eye.slash" : "eye")
        }
    }
    
    private func startTabRename(tab: PanelTab) {
        editingTabTitle = tab.title
        editingTabId = tab.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isTabTitleFocused = true
        }
    }
    
    private func commitTabRename(tab: PanelTab) {
        let clean = editingTabTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty {
            vm.renameTab(id: tab.id, newTitle: clean, side: side)
        }
        editingTabId = nil
    }
    
    private func toggleSort(field: SortField) {
        if side == .left {
            if vm.leftSortField == field {
                vm.leftSortAscending.toggle()
            } else {
                vm.leftSortField = field
                vm.leftSortAscending = true
            }
        } else {
            if vm.rightSortField == field {
                vm.rightSortAscending.toggle()
            } else {
                vm.rightSortField = field
                vm.rightSortAscending = true
            }
        }
    }
    
    private func sortIndicator(for field: SortField) -> String {
        let currentField = (side == .left) ? vm.leftSortField : vm.rightSortField
        let asc = (side == .left) ? vm.leftSortAscending : vm.rightSortAscending
        if currentField == field {
            return asc ? "▲" : "▼"
        }
        return ""
    }
    
    private var currentSortDescription: String {
        let field = (side == .left) ? vm.leftSortField : vm.rightSortField
        let asc = (side == .left) ? vm.leftSortAscending : vm.rightSortAscending
        return "\(field.rawValue) (\(asc ? "по возрастанию" : "по убыванию"))"
    }
}

extension NSTableRowView {
    private static var hasSwizzledEmphasized = false
    
    public static func enablePersistentSelectionHighlight() {
        guard !hasSwizzledEmphasized else { return }
        hasSwizzledEmphasized = true
        
        let origEmp = class_getInstanceMethod(NSTableRowView.self, #selector(getter: isEmphasized))
        let swizEmp = class_getInstanceMethod(NSTableRowView.self, #selector(getter: swizzled_isEmphasized))
        if let origEmp = origEmp, let swizEmp = swizEmp {
            method_exchangeImplementations(origEmp, swizEmp)
        }
        
        let origDraw = class_getInstanceMethod(NSTableRowView.self, #selector(drawSelection(in:)))
        let swizDraw = class_getInstanceMethod(NSTableRowView.self, #selector(swizzled_drawSelection(in:)))
        if let origDraw = origDraw, let swizDraw = swizDraw {
            method_exchangeImplementations(origDraw, swizDraw)
        }
    }
    
    private func findParentTableView() -> NSTableView? {
        var current: NSView? = self.superview
        while let v = current {
            if let tv = v as? NSTableView {
                return tv
            }
            current = v.superview
        }
        return nil
    }
    
    @objc private var swizzled_isEmphasized: Bool {
        guard let tv = self.findParentTableView() else {
            return false
        }
        let activeSide = TableDoubleClickHandler.HandlerView.activePaneSide
        let activeTv = (activeSide == .left) ? TableDoubleClickHandler.HandlerView.leftTableView : TableDoubleClickHandler.HandlerView.rightTableView
        return tv === activeTv
    }
    
    @objc private func swizzled_drawSelection(in dirtyRect: NSRect) {
        guard self.isSelected && self.isEmphasized else { return }
        self.swizzled_drawSelection(in: dirtyRect)
    }
}

public struct TableDoubleClickHandler: NSViewRepresentable {
    public let side: PaneSide
    public let vm: DualPaneViewModel
    public let items: [FileItem]
    public let onDoubleClick: (Int) -> Void
    
    public init(side: PaneSide, vm: DualPaneViewModel, items: [FileItem], onDoubleClick: @escaping (Int) -> Void) {
        self.side = side
        self.vm = vm
        self.items = items
        self.onDoubleClick = onDoubleClick
    }
    
    public func makeNSView(context: Context) -> HandlerView {
        let view = HandlerView()
        view.side = side
        view.vm = vm
        view.items = items
        view.onDoubleClick = onDoubleClick
        return view
    }
    
    public func updateNSView(_ nsView: HandlerView, context: Context) {
        nsView.side = side
        nsView.vm = vm
        nsView.items = items
        nsView.onDoubleClick = onDoubleClick
        if let tv = nsView.hookedTableView {
            if side == .left {
                HandlerView.leftTableView = tv
            } else {
                HandlerView.rightTableView = tv
            }
        }
        if vm.activePane == side {
            HandlerView.setActiveSide(side)
        }
    }
    
    public final class HandlerView: NSView {
        public static weak var leftTableView: NSTableView?
        public static weak var rightTableView: NSTableView?
        public static var activePaneSide: PaneSide = .left
        
        public static func setActiveSide(_ side: PaneSide) {
            guard activePaneSide != side else { return }
            activePaneSide = side
            if side == .left {
                rightTableView?.deselectAll(nil)
            } else {
                leftTableView?.deselectAll(nil)
            }
            leftTableView?.enumerateAvailableRowViews { rowView, _ in
                rowView.needsDisplay = true
            }
            leftTableView?.needsDisplay = true
            rightTableView?.enumerateAvailableRowViews { rowView, _ in
                rowView.needsDisplay = true
            }
            rightTableView?.needsDisplay = true
        }
        
        var side: PaneSide = .left
        var vm: DualPaneViewModel?
        var items: [FileItem] = []
        var onDoubleClick: ((Int) -> Void)?
        weak var hookedTableView: NSTableView?
        private var eventMonitor: Any?
        
        deinit {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        
        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NSTableRowView.enablePersistentSelectionHighlight()
            DispatchQueue.main.async { [weak self] in
                self?.hookTableView()
                self?.setupEventMonitor()
            }
        }
        
        public override func layout() {
            super.layout()
            if hookedTableView == nil {
                hookTableView()
            }
        }
        
        private func hookTableView() {
            var current: NSView? = self
            while let v = current {
                if let tv = findTableView(in: v) {
                    attach(to: tv)
                    return
                }
                current = v.superview
            }
        }
        
        private func findTableView(in view: NSView) -> NSTableView? {
            if let tv = view as? NSTableView { return tv }
            if let scroll = view as? NSScrollView, let tv = scroll.documentView as? NSTableView { return tv }
            for sub in view.subviews {
                if sub !== self {
                    if let tv = findTableView(in: sub) { return tv }
                }
            }
            return nil
        }
        
        private func attach(to tv: NSTableView) {
            guard hookedTableView !== tv else { return }
            hookedTableView = tv
            if side == .left {
                HandlerView.leftTableView = tv
            } else {
                HandlerView.rightTableView = tv
            }
            if vm?.activePane == side {
                HandlerView.activePaneSide = side
            }
            tv.target = self
            tv.doubleAction = #selector(onTableDoubleClick(_:))
            tv.allowsMultipleSelection = true
            tv.allowsEmptySelection = true
            setupEventMonitor()
        }
        
        private func setupEventMonitor() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self = self, let tv = self.hookedTableView, event.window == tv.window else {
                    return event
                }
                
                // KeyDown handling
                if event.type == .keyDown {
                    // Если фокус находится в любом поле ввода текста (поле фильтра, пути, модальном окне),
                    // клавиши (Backspace, Space, Enter, стрелки) НЕ должны перехватываться таблицей!
                    if let firstResponder = tv.window?.firstResponder {
                        if firstResponder is NSText || firstResponder is NSTextView || firstResponder is NSTextField {
                            return event
                        }
                    }
                    
                    // Обрабатываем шорткаты таблицы только для активной панели
                    guard HandlerView.activePaneSide == self.side else {
                        return event
                    }
                    
                    // Check if table is first responder or focused in active pane
                    let isFocused = (tv.window?.firstResponder === tv) || (HandlerView.activePaneSide == self.side)
                    if isFocused {
                        // Return / Enter (KeyCodes 36: Return, 76: Enter)
                        if event.keyCode == 36 || event.keyCode == 76 {
                            print("DUAL_PANE: KeyDown Return/Enter on side \(self.side)")
                            self.vm?.openSelected()
                            return nil
                        }
                        // Backspace / Delete (KeyCode 51) without Command/Shift/Alt -> Navigate Up
                        if event.keyCode == 51 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                            print("DUAL_PANE: KeyDown Backspace (Navigate Up) on side \(self.side)")
                            self.vm?.navigateUp()
                            return nil
                        }
                        // Space (KeyCode 49) without Command/Shift/Alt -> QuickLook / Calculate Folder Size
                        if event.keyCode == 49 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                            print("DUAL_PANE: KeyDown Space on side \(self.side)")
                            self.vm?.triggerQuickLook()
                            return nil
                        }
                    }
                    return event
                }
                
                let locationInTable = tv.convert(event.locationInWindow, from: nil)
                guard tv.bounds.contains(locationInTable) else {
                    return event
                }
                
                let clickedRow = tv.row(at: locationInTable)
                
                if event.type == .leftMouseDown {
                    if tv.window?.firstResponder != tv {
                        tv.window?.makeFirstResponder(tv)
                    }
                    HandlerView.setActiveSide(self.side)
                    if let vm = self.vm {
                        if vm.activePane != self.side {
                            vm.activePane = self.side
                        }
                        if self.side == .left {
                            if !vm.rightSelection.isEmpty {
                                vm.rightSelection.removeAll()
                            }
                            HandlerView.rightTableView?.deselectAll(nil)
                        } else {
                            if !vm.leftSelection.isEmpty {
                                vm.leftSelection.removeAll()
                            }
                            HandlerView.leftTableView?.deselectAll(nil)
                        }
                    }
                    
                    if clickedRow >= 0 && clickedRow < self.items.count {
                        let item = self.items[clickedRow]
                        
                        // Check for Double Click
                        if event.clickCount == 2 {
                            print("DUAL_PANE: LeftMouseDown clickCount == 2 on row \(clickedRow), item: \(item.name)")
                            if self.side == .left {
                                self.vm?.leftSelection = [item.id]
                            } else {
                                self.vm?.rightSelection = [item.id]
                            }
                            self.vm?.openItem(item: item, side: self.side)
                            return nil
                        }
                        
                        if let vm = self.vm {
                            if event.modifierFlags.contains(.command) {
                                if self.side == .left {
                                    if vm.leftSelection.contains(item.id) {
                                        vm.leftSelection.remove(item.id)
                                    } else {
                                        vm.leftSelection.insert(item.id)
                                    }
                                } else {
                                    if vm.rightSelection.contains(item.id) {
                                        vm.rightSelection.remove(item.id)
                                    } else {
                                        vm.rightSelection.insert(item.id)
                                    }
                                }
                            } else if event.modifierFlags.contains(.shift) {
                                let currentSelected = tv.selectedRowIndexes
                                let startRow = currentSelected.first ?? clickedRow
                                let minRow = min(startRow, clickedRow)
                                let maxRow = max(startRow, clickedRow)
                                let range = minRow...maxRow
                                let selectedIds = range.compactMap { r -> String? in
                                    guard r >= 0 && r < self.items.count else { return nil }
                                    return self.items[r].id
                                }
                                if self.side == .left {
                                    vm.leftSelection = Set(selectedIds)
                                } else {
                                    vm.rightSelection = Set(selectedIds)
                                }
                            } else {
                                if self.side == .left {
                                    vm.leftSelection = [item.id]
                                } else {
                                    vm.rightSelection = [item.id]
                                }
                            }
                        }
                    } else if clickedRow < 0 {
                        if let vm = self.vm {
                            if self.side == .left {
                                vm.leftSelection.removeAll()
                            } else {
                                vm.rightSelection.removeAll()
                            }
                        }
                    }
                } else if event.type == .rightMouseDown {
                    if tv.window?.firstResponder != tv {
                        tv.window?.makeFirstResponder(tv)
                    }
                    HandlerView.setActiveSide(self.side)
                    if let vm = self.vm {
                        if vm.activePane != self.side {
                            vm.activePane = self.side
                        }
                        if self.side == .left {
                            if !vm.rightSelection.isEmpty {
                                vm.rightSelection.removeAll()
                            }
                            HandlerView.rightTableView?.deselectAll(nil)
                        } else {
                            if !vm.leftSelection.isEmpty {
                                vm.leftSelection.removeAll()
                            }
                            HandlerView.leftTableView?.deselectAll(nil)
                        }
                    }
                    
                    if event.modifierFlags.contains(.control) {
                        if clickedRow >= 0 && clickedRow < self.items.count {
                            let item = self.items[clickedRow]
                            if let vm = self.vm {
                                if self.side == .left {
                                    if vm.leftSelection.contains(item.id) {
                                        vm.leftSelection.remove(item.id)
                                    } else {
                                        vm.leftSelection.insert(item.id)
                                    }
                                } else {
                                    if vm.rightSelection.contains(item.id) {
                                        vm.rightSelection.remove(item.id)
                                    } else {
                                        vm.rightSelection.insert(item.id)
                                    }
                                }
                            }
                            return nil
                        }
                    } else if clickedRow >= 0 && clickedRow < self.items.count {
                        let item = self.items[clickedRow]
                        if let vm = self.vm {
                            let currentSelection = (self.side == .left) ? vm.leftSelection : vm.rightSelection
                            if !currentSelection.contains(item.id) {
                                if self.side == .left {
                                    vm.leftSelection = [item.id]
                                } else {
                                    vm.rightSelection = [item.id]
                                }
                            }
                        }
                    }
                }
                return event
            }
        }
        
        @objc private func onTableDoubleClick(_ sender: NSTableView) {
            HandlerView.setActiveSide(self.side)
            let row = sender.clickedRow
            guard row >= 0 else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onDoubleClick?(row)
            }
        }
    }
}

public struct TabReorderDropDelegate: DropDelegate {
    public let targetTab: PanelTab
    public let side: PaneSide
    public let vm: DualPaneViewModel
    
    public init(targetTab: PanelTab, side: PaneSide, vm: DualPaneViewModel) {
        self.targetTab = targetTab
        self.side = side
        self.vm = vm
    }
    
    public func dropEntered(info: DropInfo) {
        guard let dragged = vm.draggedTabInfo, dragged.side == side, dragged.id != targetTab.id else { return }
        let tabs = (side == .left) ? vm.leftTabs : vm.rightTabs
        guard let from = tabs.firstIndex(where: { $0.id == dragged.id }),
              let to = tabs.firstIndex(where: { $0.id == targetTab.id }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            vm.moveTab(fromIndex: from, toIndex: to, side: side)
        }
    }
    
    public func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }
    
    public func performDrop(info: DropInfo) -> Bool {
        vm.draggedTabInfo = nil
        vm.saveSession()
        return true
    }
}

