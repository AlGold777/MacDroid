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
    @State private var hoveredTabId: UUID? = nil
    @State private var isConnectHovered: Bool = false
    @State private var isPhoneHovered: Bool = false
    @State private var lastTabClickTime: Date = .distantPast
    @State private var lastClickedTabId: UUID? = nil
    @FocusState private var isPathInputFocused: Bool
    @State private var pullProgress: CGFloat = 0
    @State private var showPullIndicator: Bool = false
    
    public init(side: PaneSide) {
        self.side = side
    }
    
    private var isActive: Bool {
        vm.activePane == side
    }
    
    private var tabs: [PanelTab] {
        side == .left ? vm.leftTabs : vm.rightTabs
    }
    
    private var visibleTabs: [PanelTab] {
        vm.visibleTabs(for: side)
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
        return isRemote && staleFlag && !vm.isConnectingPhone
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
                case .tags:
                    return [KeyPathComparator(\FileItem.tagSortKey, order: order)]
                case .type:
                    return [KeyPathComparator(\FileItem.fileType, order: order)]
                case .status:
                    return [KeyPathComparator(\FileItem.name, order: order)]
                }
            },
            set: { newOrder in
                guard let first = newOrder.first else { return }
                let field: SortField
                if first.keyPath == \FileItem.size {
                    field = .size
                } else if first.keyPath == \FileItem.mtime {
                    field = .date
                } else if first.keyPath == \FileItem.tagSortKey {
                    field = .tags
                } else if first.keyPath == \FileItem.fileType {
                    field = .type
                } else {
                    field = .name
                }
                let currentField = (side == .left) ? vm.leftSortField : vm.rightSortField
                let targetAsc: Bool
                if field == currentField {
                    targetAsc = (first.order == .forward)
                } else {
                    targetAsc = (field == .size || field == .date) ? false : true
                }
                DispatchQueue.main.async {
                    if side == .left {
                        vm.leftSortField = field
                        vm.leftSortAscending = targetAsc
                    } else {
                        vm.rightSortField = field
                        vm.rightSortAscending = targetAsc
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
                    if !newSelection.isEmpty && vm.activePane != .left {
                        vm.activePane = .left
                    }
                    vm.leftSelection = newSelection
                    if !newSelection.isEmpty && !vm.isFileDiffActive {
                        if !vm.rightSelection.isEmpty {
                            vm.rightSelection.removeAll()
                            TableDoubleClickHandler.HandlerView.rightTableView?.deselectAll(nil)
                        }
                    }
                } else {
                    if !newSelection.isEmpty && vm.activePane != .right {
                        vm.activePane = .right
                    }
                    vm.rightSelection = newSelection
                    if !newSelection.isEmpty && !vm.isFileDiffActive {
                        if !vm.leftSelection.isEmpty {
                            vm.leftSelection.removeAll()
                            TableDoubleClickHandler.HandlerView.leftTableView?.deselectAll(nil)
                        }
                    }
                }
            }
        )
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Вкладки панели (Tabs) и кнопки выбора источников (слева)
            HStack(spacing: 0) {
                // 1. Кнопки источников (дисков) слева от вкладок: Mac, Phone и USB (Вариант 3: Подчеркивание)
                HStack(spacing: 6) {
                    let currentSrc = (side == .left ? vm.leftSource : vm.rightSource)
                    let currentP = (side == .left ? vm.leftPath : vm.rightPath)
                    let activeUsb = vm.detectedUsbDrives.first(where: { currentP.hasPrefix($0.path) })
                    // Кнопки источников — такие же «вкладки»: подсвечены, только когда панель показывает корень источника
                    // (или вкладок на экране нет); при активной вкладке подсвечена она, а не кнопка
                    let buttonsOwnHighlight = vm.isRootMode(side: side) || vm.visibleTabs(for: side).isEmpty
                    let isMacActive = (currentSrc == .localMac && activeUsb == nil && buttonsOwnHighlight)
                    let isPhoneActive = (sourceBinding.wrappedValue == .remotePhone && activeUsb == nil && buttonsOwnHighlight)
                    let isUsbActive = (activeUsb != nil && buttonsOwnHighlight)
                    
                    // Кнопка Mac
                    DriveTabToolbarButton(
                        isActive: isMacActive,
                        tooltip: "Локальные файлы Mac"
                    ) {
                        vm.changeSource(to: .localMac, side: side)
                    } content: {
                        MacToolbarIconView(size: 20)
                    }
                    
                    // Кнопка Phone (минималистичная иконка смартфона)
                    DriveTabToolbarButton(
                        isActive: isPhoneActive,
                        tooltip: vm.connectedPhoneTooltip ?? "Смартфон"
                    ) {
                        vm.changeSource(to: .remotePhone, side: side)
                    } content: {
                        PhoneToolbarIconView(size: 18.6)
                    }
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear {
                                let f = geo.frame(in: .named("MainContentSpace"))
                                if side == .left {
                                    vm.phoneButtonFrameLeft = f
                                } else {
                                    vm.phoneButtonFrameRight = f
                                }
                            }
                            .onChange(of: geo.frame(in: .named("MainContentSpace"))) { newFrame in
                                if side == .left {
                                    vm.phoneButtonFrameLeft = newFrame
                                } else {
                                    vm.phoneButtonFrameRight = newFrame
                                }
                            }
                    })
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        vm.failedConnectionSide = side
                    })
                    .popover(
                        isPresented: Binding(
                            get: { vm.failedConnectionSide == side },
                            set: { isPresented in
                                if !isPresented && vm.failedConnectionSide == side {
                                    vm.failedConnectionSide = nil
                                }
                            }
                        ),
                        arrowEdge: .bottom
                    ) {
                        CompactConnectionPopoverView()
                            .environmentObject(vm)
                    }
                    .onHover { hovering in
                        isPhoneHovered = hovering
                        if hovering {
                            vm.hoveredPhoneButtonSide = side
                        } else if vm.hoveredPhoneButtonSide == side {
                            vm.hoveredPhoneButtonSide = nil
                        }
                    }
                    .contextMenu {
                        if vm.isPhoneConnected && vm.remoteDriver.isConnected {
                            Button(action: {
                                vm.disconnectPhone()
                            }) {
                                Label("Disconnect", systemImage: "link.badge.slash")
                            }
                        } else {
                            Button(action: {
                                if currentSrc != .remotePhone {
                                    vm.changeSource(to: .remotePhone, side: side)
                                }
                                vm.connectPhone(forceActivate: false, isExplicit: true)
                            }) {
                                Label("Connect", systemImage: "link")
                            }
                            .disabled(vm.isConnectingPhone)
                        }
                        
                        Divider()
                        
                        Button(action: {
                            vm.showPairingDialog = true
                        }) {
                            Label("Настройки подключения (SFTP)...", systemImage: "gearshape")
                        }
                    }
                    
                    // Автоматическая кнопка USB при наличии внешних накопителей
                    if !vm.detectedUsbDrives.isEmpty {
                        if vm.detectedUsbDrives.count == 1, let singleUsb = vm.detectedUsbDrives.first {
                            DriveTabToolbarButton(
                                isActive: isUsbActive,
                                tooltip: "Внешний USB накопитель: \(singleUsb.name)"
                            ) {
                                vm.switchToUsbDrive(singleUsb, side: side)
                            } content: {
                                Image(systemName: "externaldrive")
                                    .font(.system(size: 14))
                            }
                        } else {
                            Menu {
                                ForEach(vm.detectedUsbDrives) { usb in
                                    Button(action: {
                                        vm.switchToUsbDrive(usb, side: side)
                                    }) {
                                        HStack {
                                            Text(usb.name)
                                            if activeUsb?.id == usb.id {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                let usbColor: Color = isUsbActive ? .primary : .secondary
                                let usbLineColor: Color = isUsbActive ? .primary : inactiveUnderlineColor
                                VStack(spacing: 1.31) {
                                    Image(systemName: "externaldrive")
                                        .font(.system(size: 14))
                                        .frame(width: 20, height: 20)
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(usbLineColor)
                                        .frame(width: 22, height: 2)
                                }
                                .padding(.horizontal, 6)
                                .padding(.top, 2)
                                .padding(.bottom, 1)
                                .foregroundColor(usbColor)
                                .contentShape(Rectangle())
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Выбор внешнего USB накопителя")
                        }
                    }
                }
                .padding(.leading, 6)
                .padding(.trailing, 3)
                
                // Тонкий вертикальный разделитель между кнопками дисков и вкладками (только если есть видимые вкладки)
                if !visibleTabs.isEmpty {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.35))
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, 1.5)
                }
                
                // Список вкладок со скроллом и кнопка добавления новой вкладки
                ZStack(alignment: .trailing) {
                    if !visibleTabs.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 3) {
                                ForEach(visibleTabs) { tab in
                                HStack(spacing: 4) {
                                    if editingTabId == tab.id {
                                        TextField("", text: $editingTabTitle, onCommit: {
                                            commitTabRename(tab: tab)
                                        })
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 14, weight: .bold))
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
                                            .font(.system(size: 14, weight: .regular))
                                            .lineLimit(1)
                                    }
                                    
                                    if tab.isPinned {
                                        TabPinButton(isPinned: true) {
                                            vm.togglePinTab(id: tab.id, side: side)
                                        }
                                    } else if editingTabId != tab.id && hoveredTabId == tab.id {
                                        TabPinButton(isPinned: false) {
                                            if tab.id != activeTabId {
                                                if vm.activePane != side { vm.activePane = side }
                                                vm.switchTab(id: tab.id, side: side)
                                            }
                                            vm.togglePinTab(id: tab.id, side: side)
                                        }
                                    }
                                    
                                    if !tab.isPinned && editingTabId != tab.id && hoveredTabId == tab.id {
                                        Button(action: { vm.closeTab(id: tab.id, side: side) }) {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 9))
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Закрыть вкладку")
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background((tab.id == activeTabId && !vm.isRootMode(side: side)) ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor).opacity(0.5))
                                .cornerRadius(4)
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    if hovering {
                                        hoveredTabId = tab.id
                                    } else if hoveredTabId == tab.id {
                                        hoveredTabId = nil
                                    }
                                }
                                .onTapGesture {
                                    let now = Date()
                                    let isDoubleClick = (lastClickedTabId == tab.id && now.timeIntervalSince(lastTabClickTime) < 0.35)
                                    lastTabClickTime = now
                                    lastClickedTabId = tab.id
                                    
                                    if isDoubleClick {
                                        startTabRename(tab: tab)
                                    } else if editingTabId != tab.id {
                                        if vm.activePane != side {
                                            vm.activePane = side
                                        }
                                        // Клик по уже активной закреплённой вкладке возвращает панель в её папку,
                                        // если пользователь успел уйти из неё внутри панели
                                        let panePath = (side == .left) ? vm.leftPath : vm.rightPath
                                        let paneSource = (side == .left) ? vm.leftSource : vm.rightSource
                                        if tab.id != activeTabId || vm.isRootMode(side: side) || tab.path != panePath || tab.source != paneSource {
                                            vm.switchTab(id: tab.id, side: side)
                                        }
                                    }
                                }
                                .onDrag {
                                    vm.draggedTabInfo = (side: side, id: tab.id)
                                    return NSItemProvider(object: tab.id.uuidString as NSString)
                                }
                                .onDrop(of: [UTType.text.identifier, UTType.plainText.identifier], delegate: TabReorderDropDelegate(targetTab: tab, side: side, vm: vm))
                                .contextMenu {
                                    if tab.source == .remotePhone {
                                        if vm.isPhoneConnected && vm.remoteDriver.isConnected {
                                            Button(action: {
                                                vm.disconnectPhone()
                                            }) {
                                                Label("Disconnect", systemImage: "link.badge.slash")
                                            }
                                        } else {
                                            Button(action: {
                                                if vm.activePane != side { vm.activePane = side }
                                                vm.switchTab(id: tab.id, side: side)
                                                vm.connectPhone(forceActivate: false, isExplicit: true)
                                            }) {
                                                Label("Connect", systemImage: "link")
                                            }
                                            .disabled(vm.isConnectingPhone)
                                        }
                                        
                                        Divider()
                                    }
                                    Button(action: { startTabRename(tab: tab) }) {
                                        Label("Переименовать вкладку...", systemImage: "pencil")
                                    }
                                    Divider()
                                    Button(action: { vm.togglePinTab(id: tab.id, side: side) }) {
                                        Label(tab.isPinned ? "Открепить вкладку" : "Закрепить вкладку", systemImage: tab.isPinned ? "pin.slash" : "pin")
                                    }
                                    Button(action: { vm.addTab(side: side) }) {
                                        Label("Новая вкладка", systemImage: "plus")
                                    }
                                    Button(role: .destructive, action: { vm.closeTab(id: tab.id, side: side) }) {
                                        Label("Закрыть вкладку", systemImage: "xmark")
                                    }
                                    .disabled(tab.isPinned)
                                    Divider()
                                    Button(action: { vm.saveTabsWithSavePanel() }) {
                                        Label("Save tabs...", systemImage: "square.and.arrow.up")
                                    }
                                    Button(action: { vm.importTabsWithOpenPanel(mode: .replace) }) {
                                        Label("Import tabs...", systemImage: "square.and.arrow.down")
                                    }
                                    Button(action: { vm.importTabsWithOpenPanel(mode: .append) }) {
                                        Label("Add tabs...", systemImage: "plus.square.dashed")
                                    }
                                }
                            }
                        }
                        .padding(.leading, 3)
                        .padding(.trailing, 28)
                    }
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: 27)
                }
                    
                    // Закрепленная справа иконка '+' (вкладки могут прокручиваться под неё)
                    Button(action: { vm.addTab(side: side) }) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .cornerRadius(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Новая вкладка (Cmd+T)")
                    .padding(.trailing, 4)
                }
                
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            // Блок строки пути (Breadcrumbs / Manual Input)
            HStack(spacing: 6) {
                let isEditingPath = (side == .left) ? vm.isEditingLeftPath : vm.isEditingRightPath
                if isEditingPath {
                    HStack(spacing: 2) {
                        TextField("Путь...", text: $vm.manualPathInput, onCommit: {
                            vm.commitManualPath(side: side)
                        })
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, design: .monospaced))
                        .padding(.horizontal, 4)
                        .focused($isPathInputFocused)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                isPathInputFocused = true
                            }
                        }
                        
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
                    .contextMenu { pathContextMenu }
                } else {
                    VStack(spacing: 0) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 3) {
                                let source = (side == .left ? vm.leftSource : vm.rightSource)
                                let crumbs = vm.breadcrumbs(for: currentPath, source: source)
                                ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                                    Button(action: {
                                        vm.navigateTo(path: crumb.fullPath, side: side)
                                    }) {
                                        HStack(spacing: 5) {
                                            if source == .remotePhone && crumb.isRoot {
                                                PhoneConnectionIndicatorView(
                                                    isConnected: vm.isPhoneConnected && vm.remoteDriver.isConnected,
                                                    isConnecting: vm.isConnectingPhone,
                                                    size: 7.5
                                                )
                                            }
                                            Text(crumb.title)
                                                .font(.system(size: 14, weight: crumb.isRoot ? .semibold : .medium))
                                                .foregroundColor(.primary)
                                        }
                                    }
                                    .buttonStyle(.plain)

                                    if index < crumbs.count - 1 {
                                        Text("›")
                                            .font(.system(size: 14, weight: .regular))
                                            .foregroundColor(.primary)
                                    }
                                }
                            }
                            .padding(.horizontal, 2)
                            .padding(.vertical, 1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { beginPathEditing() }
                        .padding(.top, 4)
                        .offset(y: -2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) {
                        Color.clear
                            .frame(height: 4)
                            .contentShape(Rectangle())
                            .onTapGesture { beginPathEditing() }
                    }
                    .contextMenu { pathContextMenu }
                    .help("Нажмите над крошками, чтобы ввести путь; нажмите на папку, чтобы перейти")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(nsColor: .windowBackgroundColor))

            if vm.isComparing {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundColor(.accentColor)
                    Text("Сравнение: \(vm.comparisonResult.different.count) отл., \(vm.comparisonResult.onlyLeft.count) только слева, \(vm.comparisonResult.onlyRight.count) только справа (\(vm.comparisonResult.identical.count) одинаковых)")
                        .font(.system(size: 12))
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Button(action: { vm.selectDifferences() }) {
                        Label("Выделить различия", systemImage: "checkmark.circle")
                            .font(.system(size: 12))
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
                            .font(.system(size: 12))
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.mini)
                    
                    Toggle("Только различия", isOn: $vm.hideIdenticalInComparison)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    
                    Button(action: { vm.comparePanes() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Закрыть сравнение")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12))
            }
            
            Divider()
            
            ZStack(alignment: .top) {
                Group {
                    if vm.isQuickViewActive && vm.activePane != side {
                        QuickViewPaneView(item: vm.quickViewItem)
                    } else if (side == .left ? vm.leftViewMode : vm.rightViewMode) == .grid {
                        // Режим графического просмотрщика папок (Сетка / Галерея)
                        VStack(spacing: 0) {
                            GridSettingsBarView(side: side)
                            Divider()
                            FileGridPaneView(side: side)
                        }
                    } else {
                // Таблица списка файлов с Drag & Drop и сравнением
                Table(items, selection: selectionBinding, sortOrder: sortOrderBinding) {
                    TableColumn("Имя", value: \FileItem.name) { item in
                        let isHoverFolder = (item.isDirectory && vm.dragHoverSide == side && vm.dragHoverFolderId == item.id)
                        
                        HStack(spacing: 6) {
                            FileItemIconView(isDirectory: item.isDirectory, fileName: item.name, size: 14)
                            
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
                                    .offset(x: max(10, 5 + baseNameWidth + 6), y: -14)
                                }
                                .zIndex(100)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name)
                                        .font(.system(size: 14))
                                    let query = (side == .left ? vm.leftSearchQuery : vm.rightSearchQuery).trimmingCharacters(in: .whitespaces)
                                    if vm.isSearchActive(for: side) && !query.isEmpty {
                                        let parentPath = URL(fileURLWithPath: item.path).deletingLastPathComponent().path
                                        Text(parentPath)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
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
                            
                            if vm.isComparing {
                                comparisonBadge(for: item.name)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4, bottomTrailingRadius: 0, topTrailingRadius: 0)
                                .fill(isHoverFolder ? Color.accentColor.opacity(0.35) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            print("DUAL_PANE: Cell double tap on \(item.name)")
                            vm.openItem(item: item, side: side)
                        })
                        .onDrag {
                            vm.createDragItemProvider(for: item, side: side)
                        } preview: {
                            Color.clear.frame(width: 1, height: 1)
                        }
                        .contextMenu {
                            rowContextMenu(for: item)
                        }
                    }
                    .width(min: 120)
                    
                    TableColumn("Размер", value: \FileItem.size) { item in
                        let isHoverFolder = (item.isDirectory && vm.dragHoverSide == side && vm.dragHoverFolderId == item.id)
                        
                        HStack {
                            if item.isDirectory {
                                if vm.calculatingFolderPaths.contains(item.path) {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .scaleEffect(0.7)
                                } else if let size = vm.calculatedFolderSizes[item.path] {
                                    Text(formatColumnBytes(size))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.primary)
                                } else {
                                    Text("")
                                }
                            } else {
                                Text(formatColumnBytes(item.size))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Rectangle()
                                .fill(isHoverFolder ? Color.accentColor.opacity(0.35) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            print("DUAL_PANE: Cell double tap on \(item.name)")
                            vm.openItem(item: item, side: side)
                        })
                    }
                    .width(min: 55, ideal: 106, max: 130)
                    
                    TableColumn("", value: \FileItem.tagSortKey) { item in
                        let isHoverFolder = (item.isDirectory && vm.dragHoverSide == side && vm.dragHoverFolderId == item.id)
                        
                        HStack(spacing: 3) {
                            Spacer(minLength: 0)
                            if !item.tags.isEmpty {
                                ForEach(item.tags.prefix(3), id: \.self) { tagName in
                                    if let tag = FileTag.tag(for: tagName) {
                                        Circle()
                                            .fill(tag.color)
                                            .frame(width: 9, height: 9)
                                    } else {
                                        Circle()
                                            .fill(Color.secondary)
                                            .frame(width: 9, height: 9)
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            Rectangle()
                                .fill(isHoverFolder ? Color.accentColor.opacity(0.35) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            print("DUAL_PANE: Cell double tap on \(item.name)")
                            vm.openItem(item: item, side: side)
                        })
                        .onDrag {
                            vm.createDragItemProvider(for: item, side: side)
                        } preview: {
                            Color.clear.frame(width: 1, height: 1)
                        }
                        .contextMenu {
                            rowContextMenu(for: item)
                        }
                    }
                    .width(min: 17, ideal: 35, max: 35)
                    
                    TableColumn("Дата изменения", value: \FileItem.mtime) { item in
                        let isHoverFolder = (item.isDirectory && vm.dragHoverSide == side && vm.dragHoverFolderId == item.id)
                        
                        HStack {
                            Text(formatDate(item.mtime))
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Rectangle()
                                .fill(isHoverFolder ? Color.accentColor.opacity(0.35) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            print("DUAL_PANE: Cell double tap on \(item.name)")
                            vm.openItem(item: item, side: side)
                        })
                    }
                    .width(min: 90, ideal: 141, max: 180)
                    
                    TableColumn("Тип", value: \FileItem.fileType) { item in
                        let isHoverFolder = (item.isDirectory && vm.dragHoverSide == side && vm.dragHoverFolderId == item.id)
                        
                        HStack {
                            Text(item.fileType)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                        .padding(.leading, 10.5)
                        .padding(.trailing, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 4, topTrailingRadius: 4)
                                .fill(isHoverFolder ? Color.accentColor.opacity(0.35) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            print("DUAL_PANE: Cell double tap on \(item.name)")
                            vm.openItem(item: item, side: side)
                        })
                    }
                    .width(58)
                }
                .id("\(side)-\(vm.splitViewResetId)")
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
                .onDrop(of: [DualPaneViewModel.dragUTType, UTType.fileURL.identifier, UTType.utf8PlainText.identifier], delegate: PaneTableDropDelegate(side: side, vm: vm, items: items))
                .overlay {
                    let query = (side == .left ? vm.leftSearchQuery : vm.rightSearchQuery).trimmingCharacters(in: .whitespaces)
                    let isSearching = (side == .left ? vm.isLeftSearching : vm.isRightSearching)
                    if vm.isSearchActive(for: side) && !query.isEmpty && items.isEmpty {
                        VStack(spacing: 8) {
                            if isSearching {
                                ProgressView("Поиск файлов...")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                            } else {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.system(size: 28))
                                    .foregroundColor(.secondary.opacity(0.6))
                                Text("Ничего не найдено по запросу «\(query)»")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.65))
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        
        // Плавающий индикатор pull-to-refresh
        let isRefreshing = (side == .left ? vm.leftIsRefreshing : vm.rightIsRefreshing)
        if pullProgress > 0.15 || showPullIndicator {
            HStack(spacing: 6) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                    Text("Обновление...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                } else {
                    Image(systemName: pullProgress >= 1.0 ? "arrow.clockwise" : "arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(pullProgress >= 1.0 ? .accentColor : .secondary)
                        .rotationEffect(.degrees(pullProgress >= 1.0 ? 180 : 0))
                    Text(pullProgress >= 1.0 ? "Отпустите для обновления" : "Потяните для обновления")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(pullProgress >= 1.0 ? .primary : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 2)
            )
            .padding(.top, 6)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
    .scrollBounceBehavior(.always, axes: .vertical)
    .background(
        TrackpadSwipeRefreshView(
            side: side,
            vm: vm,
            onPullProgress: { progress in
                withAnimation(.easeOut(duration: 0.1)) {
                    pullProgress = progress
                }
            },
            onRefreshTriggered: {
                withAnimation(.easeOut(duration: 0.2)) {
                    showPullIndicator = true
                }
            }
        )
    )
    .onChange(of: (side == .left ? vm.leftIsRefreshing : vm.rightIsRefreshing)) { _, refreshing in
        if !refreshing {
            withAnimation(.easeOut(duration: 0.3)) {
                showPullIndicator = false
                pullProgress = 0
            }
        }
    }
            
            Divider()
            
            // Подвал панели: объекты, выделение, свободное место и зеркальное отражение
            HStack(spacing: 0) {
                if side == .right {
                    PaneMirrorButton(arrow: "⇨", tooltip: "Отразить левую панель в правой (⇨)") {
                        vm.mirrorPane(from: .left, to: .right)
                    }
                    .padding(.trailing, 8)
                }
                
                let selectedIds = (side == .left) ? vm.leftSelection : vm.rightSelection
                if selectedIds.isEmpty {
                    Text("\(items.count) объектов")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    let selectedItems = items.filter { selectedIds.contains($0.id) || selectedIds.contains($0.path) }
                    let selectedBytes = vm.selectedBytes(for: side)
                    let isCalculating = vm.isCalculatingSelectedFolderSizes(for: side)
                    
                    HStack(spacing: 4) {
                        Text("Выделено: \(selectedItems.count) из \(items.count) (\(formatBytes(selectedBytes)))")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        if isCalculating {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.6)
                                .frame(width: 10, height: 10)
                        }
                    }
                }
                
                Spacer(minLength: 8)
                
                if freeSpace.total > 0 {
                    Text("Свободно: \(formatBytes(freeSpace.free)) из \(formatBytes(freeSpace.total))")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                
                if side == .left {
                    PaneMirrorButton(arrow: "⇦", tooltip: "Отразить правую панель в левой (⇦)") {
                        vm.mirrorPane(from: .right, to: .left)
                    }
                    .padding(.leading, 8)
                } else {
                    ToolButton(
                        systemImage: "trash",
                        tooltip: "Корзина телефона",
                        isActive: vm.showPhoneTrash,
                        isEnabled: !vm.isPhoneTrashBusy,
                        width: 24,
                        height: 20,
                        iconSize: 14
                    ) {
                        vm.openPhoneTrash()
                    }
                    .accessibilityLabel("Корзина телефона")
                    .padding(.leading, 8)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            if vm.activePane != side {
                vm.activePane = side
                TableDoubleClickHandler.HandlerView.setActiveSide(side)
                TableDoubleClickHandler.HandlerView.ensureTableViewsDiscovered()
                let tv = (side == .left) ? TableDoubleClickHandler.HandlerView.leftTableView : TableDoubleClickHandler.HandlerView.rightTableView
                let win = tv?.window ?? NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
                if let tv = tv {
                    win?.makeFirstResponder(tv)
                }
            }
        })
    }
    
    @ViewBuilder
    private func comparisonBadge(for name: String) -> some View {
        if side == .left {
            if vm.comparisonResult.onlyLeft.contains(name) {
                Text("Только слева")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.2))
                    .foregroundColor(.green)
                    .cornerRadius(3)
            } else if vm.comparisonResult.different.contains(name) {
                Text("Различается")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.2))
                    .foregroundColor(.orange)
                    .cornerRadius(3)
            }
        } else {
            if vm.comparisonResult.onlyRight.contains(name) {
                Text("Только справа")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.blue.opacity(0.2))
                    .foregroundColor(.blue)
                    .cornerRadius(3)
            } else if vm.comparisonResult.different.contains(name) {
                Text("Различается")
                    .font(.system(size: 10, weight: .bold))
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
    
    // Keep localized numbers, but use stable lowercase Latin units in the Size column.
    private static let columnSizeFormats: [(formatter: ByteCountFormatter, suffix: String)] = {
        let units: [(ByteCountFormatter.Units, String)] = [
            (.useBytes, "b"), (.useKB, "kb"), (.useMB, "mb"), (.useGB, "gb"),
            (.useTB, "tb"), (.usePB, "pb"), (.useEB, "eb")
        ]
        return units.map { unit, suffix in
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowedUnits = unit
            formatter.includesUnit = false
            formatter.allowsNonnumericFormatting = false
            return (formatter, suffix)
        }
    }()

    private func formatColumnBytes(_ bytes: UInt64) -> String {
        var index = 0
        var scaled = bytes
        while scaled >= 1_000 && index < Self.columnSizeFormats.count - 1 {
            scaled /= 1_000
            index += 1
        }
        let format = Self.columnSizeFormats[index]
        return "\(format.formatter.string(fromByteCount: Int64(clamping: bytes))) \(format.suffix)"
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
        let contextItems = vm.contextMenuItems(for: item, side: side)
        let combinedTags = Array(Set(contextItems.flatMap { $0.tags }))
        
        let query = (side == .left ? vm.leftSearchQuery : vm.rightSearchQuery).trimmingCharacters(in: .whitespaces)
        if vm.isSearchActive(for: side) && !query.isEmpty {
            Button(action: {
                vm.revealInFolder(item: item, side: side)
            }) {
                Label("Показать в папке", systemImage: "folder")
            }
            Divider()
        }
        
        ControlGroup {
            ForEach(FileTag.allTags) { tag in
                let isSelected = combinedTags.contains { FileTag.isTagMatching($0, tagIdOrName: tag.id) }
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
        Toggle("Показывать скрытые файлы", isOn: Binding(
            get: { side == .left ? vm.leftShowHidden : vm.rightShowHidden },
            set: { newValue in
                let showHidden = side == .left ? vm.leftShowHidden : vm.rightShowHidden
                if newValue != showHidden { vm.toggleShowHidden(side: side) }
            }
        ))
    }

    @ViewBuilder
    private var pathContextMenu: some View {
        if (side == .left ? vm.leftSource : vm.rightSource) == .remotePhone {
            Button("Освободить место — copy done") { vm.openCopyDone(side: side) }
                .disabled(!vm.canStartCopyDone)
            Divider()
        }
        Button("Скопировать путь") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(currentPath, forType: .string)
        }
        Button("Вставить") {
            guard let pastedPath = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !pastedPath.isEmpty else { return }
            vm.manualPathInput = pastedPath
            vm.commitManualPath(side: side)
        }
        .disabled(NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
    }

    private func beginPathEditing() {
        vm.startEditingPath(side: side)
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
        let currentField = (side == .left) ? vm.leftSortField : vm.rightSortField
        let currentAsc = (side == .left) ? vm.leftSortAscending : vm.rightSortAscending
        let newAsc: Bool
        if currentField == field {
            newAsc = !currentAsc
        } else {
            newAsc = (field == .size || field == .date) ? false : true
        }
        if side == .left {
            vm.leftSortField = field
            vm.leftSortAscending = newAsc
        } else {
            vm.rightSortField = field
            vm.rightSortAscending = newAsc
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

// MARK: - In-place Inline Renaming Text Field
public final class CustomRenameNSTextField: NSTextField {
    public var isDirectory: Bool = false
    
    public override var isBezeled: Bool {
        get { false }
        set { }
    }
    
    public static weak var activeInstance: CustomRenameNSTextField?

    public override var isBordered: Bool {
        get { false }
        set { }
    }
    
    public override var focusRingType: NSFocusRingType {
        get { .none }
        set { }
    }
    
    public override func drawFocusRingMask() {}
    
    public override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        CustomRenameNSTextField.activeInstance = self
        if let editor = self.currentEditor() as? NSTextView {
            editor.focusRingType = .none
            editor.drawsBackground = false
            editor.backgroundColor = .clear
        }
        return result
    }
    
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            // Поднимаем zPosition родительского NSTableRowView, чтобы всплывающая иконка не перекрывалась строкой выше
            var curr: NSView? = self
            while let v = curr {
                v.wantsLayer = true
                v.layer?.masksToBounds = false
                if let rowView = v as? NSTableRowView {
                    rowView.wantsLayer = true
                    rowView.layer?.zPosition = 200
                    rowView.layer?.masksToBounds = false
                    break
                }
                curr = v.superview
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.window != nil else { return }
                if self.currentEditor() == nil {
                    window.makeFirstResponder(self)
                    self.selectBaseName()
                }
            }
        }
    }
    
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            var curr: NSView? = self
            while let v = curr {
                if let rowView = v as? NSTableRowView {
                    rowView.layer?.zPosition = 0
                    break
                }
                curr = v.superview
            }
        }
    }
    
    public func selectBaseName() {
        CustomRenameNSTextField.activeInstance = self
        if let editor = self.currentEditor() as? NSTextView {
            editor.focusRingType = .none
            editor.drawsBackground = false
            editor.backgroundColor = .clear
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(red: 0x6c/255.0, green: 0x9d/255.0, blue: 0xcc/255.0, alpha: 1.0),
                .foregroundColor: NSColor.white
            ]
            editor.insertionPointColor = NSColor(ConflictColors.nameText)
            
            let name = self.stringValue
            if !self.isDirectory && name.contains(".") && !name.hasPrefix(".") {
                let nsName = name as NSString
                let ext = nsName.pathExtension
                let baseLen = name.count - ext.count - 1
                if baseLen > 0 {
                    editor.selectedRange = NSRange(location: 0, length: baseLen)
                    return
                }
            }
            editor.selectedRange = NSRange(location: 0, length: name.count)
        }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if KeyCommandMonitor.handleEvent(event, targetResponder: self) == nil {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Inline Rename Helpers & Copy Fragment Button
public enum InlineRenameHelper {
    public static func baseName(for fullName: String, isDirectory: Bool) -> String {
        if !isDirectory && fullName.contains(".") && !fullName.hasPrefix(".") {
            let nsName = fullName as NSString
            let ext = nsName.pathExtension
            let baseLen = fullName.count - ext.count - 1
            if baseLen > 0 {
                return String(fullName.prefix(baseLen))
            }
        }
        return fullName
    }
    
    public static func textWidth(for text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return ceil(size.width)
    }
    
    public static func currentFragment(for fullName: String, isDirectory: Bool) -> String {
        if let tf = CustomRenameNSTextField.activeInstance,
           let editor = tf.currentEditor() as? NSTextView,
           editor.selectedRange().length > 0 {
            let range = editor.selectedRange()
            let ns = (editor.string as NSString)
            if range.location + range.length <= ns.length {
                return ns.substring(with: range)
            }
        }
        return baseName(for: fullName, isDirectory: isDirectory)
    }
}

public final class CopyFragmentButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isCopied: Bool = false
    public var onCopy: (() -> Void)?
    
    public override var acceptsFirstResponder: Bool { false }
    public override var canBecomeKeyView: Bool { false }
    
    public override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        setup()
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        self.isBordered = false
        self.bezelStyle = .regularSquare
        self.refusesFirstResponder = true
        self.toolTip = "Скопировать выделенный фрагмент"
        self.wantsLayer = true
        self.layer?.cornerRadius = 5.0
        self.layer?.borderWidth = 1.2
        self.layer?.borderColor = NSColor(white: 0.35, alpha: 1.0).cgColor
        self.layer?.backgroundColor = NSColor.white.cgColor
        self.layer?.shadowColor = NSColor.black.withAlphaComponent(0.20).cgColor
        self.layer?.shadowOpacity = 1.0
        self.layer?.shadowRadius = 2.0
        self.layer?.shadowOffset = CGSize(width: 0, height: -1)
        self.layer?.zPosition = 500
        updateIcon()
    }
    
    public func setCopiedState() {
        self.isCopied = true
        updateIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            self.isCopied = false
            self.updateIcon()
        }
    }
    
    private func updateIcon(isHovered: Bool = false) {
        let symbolName = isCopied ? "checkmark" : "doc.on.doc"
        let tintColor: NSColor
        if isCopied {
            tintColor = .systemGreen
        } else if isHovered {
            tintColor = .black
        } else {
            tintColor = NSColor(white: 0.22, alpha: 1.0)
        }
        
        let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold)
            .applying(.init(paletteColors: [tintColor]))
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            self.image = img
        }
    }
    
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea {
            removeTrackingArea(ta)
        }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(ta)
        self.trackingArea = ta
    }
    
    public override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }
    
    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSCursor.pointingHand.set()
        updateIcon(isHovered: true)
        self.layer?.borderColor = NSColor(white: 0.15, alpha: 1.0).cgColor
    }
    
    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.arrow.set()
        updateIcon(isHovered: false)
        self.layer?.borderColor = NSColor(white: 0.35, alpha: 1.0).cgColor
    }
    
    public override func mouseDown(with event: NSEvent) {
        onCopy?()
        setCopiedState()
    }
}

public struct CopyFragmentButtonView: NSViewRepresentable {
    public let baseName: String
    public let onCopy: () -> Void
    
    public func makeNSView(context: Context) -> CopyFragmentButton {
        let btn = CopyFragmentButton(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        btn.onCopy = onCopy
        return btn
    }
    
    public func updateNSView(_ nsView: CopyFragmentButton, context: Context) {
        nsView.onCopy = onCopy
    }
}

public struct InlineRenameTextField: NSViewRepresentable {
    @Binding public var text: String
    public let isDirectory: Bool
    public let onCommit: () -> Void
    public let onCancel: () -> Void
    
    public init(text: Binding<String>, isDirectory: Bool = false, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self._text = text
        self.isDirectory = isDirectory
        self.onCommit = onCommit
        self.onCancel = onCancel
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public func makeNSView(context: Context) -> CustomRenameNSTextField {
        let textField = CustomRenameNSTextField()
        textField.isDirectory = isDirectory
        textField.stringValue = text
        textField.isBordered = false
        textField.isBezeled = false
        textField.bezelStyle = .squareBezel
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        textField.focusRingType = .none
        textField.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        textField.delegate = context.coordinator
        textField.isEditable = true
        textField.isSelectable = true
        textField.textColor = NSColor(ConflictColors.nameText)
        if let cell = textField.cell as? NSTextFieldCell {
            cell.isBezeled = false
            cell.isBordered = false
            cell.focusRingType = .none
            cell.drawsBackground = false
            cell.backgroundColor = .clear
            cell.wraps = false
            cell.isScrollable = true
        }
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1
        
        DispatchQueue.main.async {
            guard let window = textField.window else { return }
            CustomRenameNSTextField.activeInstance = textField
            if textField.currentEditor() == nil {
                window.makeFirstResponder(textField)
                textField.selectText(nil)
                textField.selectBaseName()
            }
        }
        
        return textField
    }
    
    public func updateNSView(_ nsView: CustomRenameNSTextField, context: Context) {
        if nsView.stringValue != text && nsView.currentEditor() == nil {
            nsView.stringValue = text
        }
    }
    
    public class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineRenameTextField
        private var isHandled = false
        private var createdAt = Date()
        
        init(_ parent: InlineRenameTextField) {
            self.parent = parent
        }
        
        public func controlTextDidChange(_ obj: Notification) {
            if let tf = obj.object as? NSTextField {
                parent.text = tf.stringValue
            }
        }
        
        public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if !isHandled {
                    isHandled = true
                    parent.text = textView.string
                    parent.onCommit()
                }
                return true
            } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if !isHandled {
                    isHandled = true
                    parent.onCancel()
                }
                return true
            }
            return false
        }
        
        public func controlTextDidEndEditing(_ obj: Notification) {
            if let tf = obj.object as? CustomRenameNSTextField, CustomRenameNSTextField.activeInstance === tf {
                CustomRenameNSTextField.activeInstance = nil
            }
            guard !isHandled else { return }
            guard Date().timeIntervalSince(createdAt) > 0.3 else { return }
            isHandled = true
            if let tf = obj.object as? NSTextField {
                parent.text = tf.stringValue
                parent.onCommit()
            }
        }
    }
}

// MARK: - NSTableRowView Swizzling for Persistent Selection & Full-Row Drop Highlight
extension NSTableRowView {
    private static var hasSwizzledRowView = false
    
    public static func enablePersistentSelectionHighlight() {
        guard !hasSwizzledRowView else { return }
        hasSwizzledRowView = true
        
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
        
        let origBg = class_getInstanceMethod(NSTableRowView.self, #selector(drawBackground(in:)))
        let swizBg = class_getInstanceMethod(NSTableRowView.self, #selector(swizzled_drawBackground(in:)))
        if let origBg = origBg, let swizBg = swizBg {
            method_exchangeImplementations(origBg, swizBg)
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
        if tv === activeTv { return true }
        if let vm = TableDoubleClickHandler.HandlerView.activeVM(for: activeSide), vm.isFileDiffActive {
            return true
        }
        return false
    }
    
    @objc private func swizzled_drawSelection(in dirtyRect: NSRect) {
        guard let tv = self.findParentTableView() else { return }
        let rowIndex = tv.row(for: self)
        let isLeft = (tv === TableDoubleClickHandler.HandlerView.leftTableView)
        let isRight = (tv === TableDoubleClickHandler.HandlerView.rightTableView)
        if isLeft || isRight {
            let side: PaneSide = isLeft ? .left : .right
            if let vm = TableDoubleClickHandler.HandlerView.activeVM(for: side) {
                // Если элемент в этой строке сейчас переименовывается, скрываем синюю плашку выделения
                if let editingId = vm.editingItemId, vm.editingItemSide == side, rowIndex >= 0 {
                    let items = vm.displayItems(for: side)
                    if rowIndex < items.count && items[rowIndex].id == editingId {
                        return
                    }
                }
                
                if vm.dragHoverSide == side, rowIndex >= 0 {
                    let items = (side == .left) ? vm.leftItems : vm.rightItems
                    if rowIndex < items.count && items[rowIndex].isDirectory && vm.dragHoverFolderId == items[rowIndex].id {
                        // Цельная синяя плашка без разрывов между колонками
                        NSGraphicsContext.saveGraphicsState()
                        let highlightRect = NSRect(x: 2, y: 1, width: self.bounds.width - 4, height: self.bounds.height - 2)
                        let path = NSBezierPath(roundedRect: highlightRect, xRadius: 4, yRadius: 4)
                        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
                        path.fill()
                        NSGraphicsContext.restoreGraphicsState()
                        return
                    }
                }
            }
        }
        
        guard self.isSelected && self.isEmphasized else { return }
        self.swizzled_drawSelection(in: dirtyRect)
    }
    
    @objc private func swizzled_drawBackground(in dirtyRect: NSRect) {
        self.swizzled_drawBackground(in: dirtyRect)
        
        guard let tv = self.findParentTableView() else { return }
        let rowIndex = tv.row(for: self)
        guard rowIndex >= 0 else { return }
        
        let isLeft = (tv === TableDoubleClickHandler.HandlerView.leftTableView)
        let isRight = (tv === TableDoubleClickHandler.HandlerView.rightTableView)
        guard isLeft || isRight else { return }
        let side: PaneSide = isLeft ? .left : .right
        
        guard let vm = TableDoubleClickHandler.HandlerView.activeVM(for: side),
              vm.dragHoverSide == side else {
            return
        }
        
        let items = (side == .left) ? vm.leftItems : vm.rightItems
        guard rowIndex < items.count else { return }
        let item = items[rowIndex]
        
        // 1. Подсветка папки при наведении Drag & Drop: цельная синяя плашка на всю строку без разрывов
        if item.isDirectory && vm.dragHoverFolderId == item.id {
            NSGraphicsContext.saveGraphicsState()
            let highlightRect = NSRect(x: 2, y: 1, width: self.bounds.width - 4, height: self.bounds.height - 2)
            let path = NSBezierPath(roundedRect: highlightRect, xRadius: 4, yRadius: 4)
            NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        
        // 2. Синяя линия вставки между строками (цельная линия на всю ширину таблицы)
        if vm.dragHoverFolderId == nil {
            if vm.dragInsertionIndex == rowIndex {
                NSGraphicsContext.saveGraphicsState()
                let lineRect = NSRect(x: 0, y: 0, width: self.bounds.width, height: 2)
                NSColor.controlAccentColor.setFill()
                lineRect.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            if vm.dragInsertionIndex == items.count && rowIndex == items.count - 1 {
                NSGraphicsContext.saveGraphicsState()
                let lineRect = NSRect(x: 0, y: self.bounds.height - 2, width: self.bounds.width, height: 2)
                NSColor.controlAccentColor.setFill()
                lineRect.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
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
    
    private static var hasSwizzledHeaderCentering = false
    public static func installHeaderCellCenteringIfNeeded() {
        guard !hasSwizzledHeaderCentering else { return }
        hasSwizzledHeaderCentering = true
        
        let curFontSel = NSSelectorFromString("_currentFont")
        if let origCurFontMethod = class_getInstanceMethod(NSTableHeaderCell.self, curFontSel) {
            let fontBlock: @convention(block) (AnyObject) -> NSFont = { _ in
                return NSFont.systemFont(ofSize: 12, weight: .regular)
            }
            let newCurFontImp = imp_implementationWithBlock(fontBlock)
            method_setImplementation(origCurFontMethod, newCurFontImp)
        }
        
        let sel = #selector(NSTableHeaderCell.drawInterior(withFrame:in:))
        guard let origMethod = class_getInstanceMethod(NSTableHeaderCell.self, sel) else { return }
        
        typealias DrawInteriorIMP = @convention(c) (AnyObject, Selector, NSRect, NSView) -> Void
        let origImp = unsafeBitCast(method_getImplementation(origMethod), to: DrawInteriorIMP.self)
        
        let block: @convention(block) (AnyObject, NSRect, NSView) -> Void = { obj, frame, view in
            guard let cell = obj as? NSTableHeaderCell else { return }
            if cell.font?.pointSize != 12 {
                cell.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            }
            if cell.stringValue == "Тип" && frame.width >= 40 {
                let title = "Тип"
                let font = cell.font ?? NSFont.systemFont(ofSize: 12, weight: .regular)
                let color = NSColor.headerTextColor
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: color
                ]
                let size = (title as NSString).size(withAttributes: attrs)
                // Режим выравнивания по левому краю с отступом, совпадающим с расширениями в строках:
                let leadingOffset: CGFloat = 11.5
                let x = floor(frame.origin.x + leadingOffset)
                // Сохранённый предыдущий режим (по центру колонки 58 pt):
                // let colWidth = TableColumnLayoutEngine.fixedTypeWidth
                // let x = floor(frame.origin.x + (colWidth - size.width) / 2.0)
                let y = floor(frame.origin.y + (frame.size.height - size.height) / 2.0)
                (title as NSString).draw(in: NSRect(x: x, y: y, width: size.width, height: size.height), withAttributes: attrs)
            } else {
                origImp(obj, sel, frame, view)
            }
        }
        
        let newImp = imp_implementationWithBlock(block)
        method_setImplementation(origMethod, newImp)
    }
    
    public func makeNSView(context: Context) -> HandlerView {
        Self.installHeaderCellCenteringIfNeeded()
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
        if nsView.hookedTableView == nil {
            nsView.hookTableView()
        }
        if let tv = nsView.hookedTableView {
            nsView.installColumnHeader(on: tv)
            for col in tv.tableColumns {
                if col.headerCell.font?.pointSize != 12 {
                    col.headerCell.font = NSFont.systemFont(ofSize: 12, weight: .regular)
                }
            }
            if side == .left {
                HandlerView.leftTableView = tv
                HandlerView.leftVM = vm
            } else {
                HandlerView.rightTableView = tv
                HandlerView.rightVM = vm
            }
        }
        if vm.activePane == side {
            HandlerView.setActiveSide(side)
        }
    }
    
    // MARK: - Right-anchored metadata columns

    public struct TableColumnLayoutEngine {
        public struct Constraint {
            public let min: CGFloat
            public let max: CGFloat
        }

        public static let fixedTypeWidth: CGFloat = 58
        public static let defaultWidths: [CGFloat] = [
            0,   // Name (dynamic)
            106, // Размер
            35,  // Теги
            141, // Дата изменения
            fixedTypeWidth // 58 pt (Тип)
        ]
        // Name fills the remaining space; metadata widths are independent preferences.
        public static let constraints: [Constraint] = [
            Constraint(min: 120, max: .greatestFiniteMagnitude),
            Constraint(min: 55, max: 130),
            Constraint(min: 17, max: 35),
            Constraint(min: 90, max: 180),
            Constraint(min: fixedTypeWidth, max: fixedTypeWidth)
        ]
        public static let minimumTableWidth = constraints.reduce(CGFloat.zero) { $0 + $1.min }
        // Allow room for a non-overlay vertical scrollbar as well as the table.
        public static let minimumPaneWidth = minimumTableWidth + 20

        /// A separator controls the LEFT edge of the metadata column on its right.
        /// Always use the mouse-down snapshot, so clamping never accumulates drift.
        public static func widthsByMovingBoundary(
            initialWidths: [CGFloat], boundaryIndex: Int, translation: CGFloat
        ) -> [CGFloat] {
            guard initialWidths.count == constraints.count,
                  (0...2).contains(boundaryIndex), translation.isFinite else { return initialWidths }
            let index = boundaryIndex + 1
            let limit = constraints[index]
            let available = max(0, initialWidths[0] - constraints[0].min)
            let upper = min(limit.max, initialWidths[index] + available)
            let width = max(limit.min, min(upper, initialWidths[index] - translation))
            var result = initialWidths
            result[index] = width
            result[0] += initialWidths[index] - width
            return result
        }

        public static func adjust(columns: [NSTableColumn], targetWidth: CGFloat) {
            guard columns.count == constraints.count, targetWidth >= minimumTableWidth else { return }
            var widths = columns.map(\.width)
            widths[4] = fixedTypeWidth
            for index in 1...3 {
                widths[index] = max(constraints[index].min, min(constraints[index].max, widths[index]))
            }
            widths[0] = targetWidth - widths[1...4].reduce(0, +)
            if widths[0] < constraints[0].min {
                var deficit = constraints[0].min - widths[0]
                // Only a panel resize may compress other metadata columns.
                for index in [3, 1, 2] {
                    let take = min(deficit, widths[index] - constraints[index].min)
                    widths[index] -= take
                    deficit -= take
                }
                widths[0] = targetWidth - widths[1...4].reduce(0, +)
            }
            apply(widths: widths, to: columns)
        }

        public static func apply(widths: [CGFloat], to columns: [NSTableColumn]) {
            guard widths.count == columns.count else { return }
            for (column, width) in zip(columns, widths) where abs(column.width - width) > 0.001 {
                column.width = width
            }
        }
    }

    /// Intercept only separator hit areas. Keep SwiftUI's original header and
    /// its sorting/accessibility behavior underneath the transparent overlay.
    final class ColumnResizeView: NSView {
        weak var tableView: NSTableView?
        private(set) var isResizingBoundary = false
        private var hoveredBoundary: Int? {
            didSet { if oldValue != hoveredBoundary { needsDisplay = true } }
        }
        private var hoverTrackingArea: NSTrackingArea?
        private let handleRadius: CGFloat = 7
        var onBoundaryDrag: (([CGFloat], Int, CGFloat) -> Void)?
        var onBoundaryDragEnded: (() -> Void)?

        private func boundaryX(_ index: Int) -> CGFloat? {
            guard let header = tableView?.headerView else { return nil }
            return convert(header.headerRect(ofColumn: index), from: header).maxX
        }

        private func boundary(at point: NSPoint) -> Int? {
            guard tableView?.tableColumns.count == 5, bounds.contains(point) else { return nil }
            return (0...3).first { index in
                guard let x = boundaryX(index) else { return false }
                return abs(x - point.x) <= handleRadius
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !isHidden, boundary(at: convert(point, from: superview)) != nil else { return nil }
            return self
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
            let area = NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil
            )
            addTrackingArea(area)
            hoverTrackingArea = area
        }

        override func mouseMoved(with event: NSEvent) {
            let index = boundary(at: convert(event.locationInWindow, from: nil))
            hoveredBoundary = index.flatMap { $0 < 3 ? $0 : nil }
            if hoveredBoundary != nil { NSCursor.resizeLeftRight.set() }
        }

        override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

        override func mouseExited(with event: NSEvent) {
            if !isResizingBoundary { hoveredBoundary = nil }
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let index = hoveredBoundary, let x = boundaryX(index) else { return }
            NSColor.controlAccentColor.withAlphaComponent(0.8).setFill()
            NSRect(x: x - 1.5, y: bounds.minY + 3, width: 3, height: max(0, bounds.height - 6)).fill()
        }

        override func resetCursorRects() {
            guard tableView?.tableColumns.count == 5 else { return }
            for index in 0...2 {
                guard let x = boundaryX(index) else { continue }
                addCursorRect(NSRect(x: x - handleRadius, y: bounds.minY, width: handleRadius * 2, height: bounds.height), cursor: .resizeLeftRight)
            }
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard let boundaryIndex = boundary(at: point), boundaryIndex < 3,
                  let tableView, let window else { return }
            let initialWidths = tableView.tableColumns.map(\.width)
            let startX = event.locationInWindow.x
            hoveredBoundary = boundaryIndex
            isResizingBoundary = true
            NSCursor.resizeLeftRight.push()
            defer {
                isResizingBoundary = false
                hoveredBoundary = nil
                NSCursor.pop()
                onBoundaryDragEnded?()
                window.invalidateCursorRects(for: self)
            }
            while let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture, inMode: .eventTracking, dequeue: true
            ) {
                onBoundaryDrag?(initialWidths, boundaryIndex, next.locationInWindow.x - startX)
                // The active boundary index stays the same while its position changes.
                // Invalidate the overlay itself so the old highlight is erased and
                // redrawn at the actual boundary, including when a width limit is hit.
                needsDisplay = true
                window.displayIfNeeded()
                if next.type == .leftMouseUp { break }
            }
        }
    }

    public final class HandlerView: NSView {
        public static weak var leftTableView: NSTableView?
        public static weak var rightTableView: NSTableView?
        public static weak var leftVM: DualPaneViewModel?
        public static weak var rightVM: DualPaneViewModel?
        public static var activePaneSide: PaneSide = .left
        
        public static func activeVM(for side: PaneSide) -> DualPaneViewModel? {
            return (side == .left) ? leftVM : rightVM
        }
        
        public static func setActiveSide(_ side: PaneSide) {
            guard activePaneSide != side else { return }
            activePaneSide = side
            leftTableView?.enumerateAvailableRowViews { rowView, _ in
                rowView.needsDisplay = true
            }
            leftTableView?.needsDisplay = true
            rightTableView?.enumerateAvailableRowViews { rowView, _ in
                rowView.needsDisplay = true
            }
            rightTableView?.needsDisplay = true
        }
        
        public static func ensureTableViewsDiscovered() {
            guard let win = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow,
                  let contentView = win.contentView else { return }
            
            var tables: [NSTableView] = []
            func findTables(in view: NSView) {
                if let tv = view as? NSTableView {
                    tables.append(tv)
                }
                for sub in view.subviews {
                    findTables(in: sub)
                }
            }
            findTables(in: contentView)
            
            // Сортируем таблицы слева направо по координате X в окне
            tables.sort {
                let rectA = $0.convert($0.bounds, to: nil)
                let rectB = $1.convert($1.bounds, to: nil)
                return rectA.origin.x < rectB.origin.x
            }
            
            if tables.count >= 2 {
                leftTableView = tables[0]
                rightTableView = tables[1]
            } else if tables.count == 1 {
                let rect = tables[0].convert(tables[0].bounds, to: nil)
                if rect.origin.x < (win.frame.width / 2.0) {
                    leftTableView = tables[0]
                } else {
                    rightTableView = tables[0]
                }
            }
        }
        
        public static func focusAndScrollToItem(id: String, side: PaneSide) {
            ensureTableViewsDiscovered()
            setActiveSide(side)
            let performSelect = {
                ensureTableViewsDiscovered()
                let tv = (side == .left) ? leftTableView : rightTableView
                let items = activeVM(for: side)?.displayItems(for: side) ?? []
                let normId = id.precomposedStringWithCanonicalMapping
                guard let index = items.firstIndex(where: {
                    $0.id == id ||
                    $0.path == id ||
                    $0.name == id ||
                    $0.id.precomposedStringWithCanonicalMapping == normId ||
                    $0.path.precomposedStringWithCanonicalMapping == normId ||
                    $0.name.precomposedStringWithCanonicalMapping == normId
                }) else { return }
                if let tv = tv {
                    tv.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                    tv.scrollRowToVisible(index)
                    let win = tv.window ?? NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
                    win?.makeFirstResponder(tv)
                }
            }
            DispatchQueue.main.async {
                performSelect()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                performSelect()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                performSelect()
            }
        }
        
        /// Прокрутка к элементу без перехвата фокуса (окно Quick Look остаётся ключевым)
        public static func scrollToItem(id: String, side: PaneSide) {
            DispatchQueue.main.async {
                let tv = (side == .left) ? leftTableView : rightTableView
                let items = activeVM(for: side)?.displayItems(for: side) ?? []
                guard let index = items.firstIndex(where: { $0.id == id || $0.path == id }) else { return }
                tv?.scrollRowToVisible(index)
            }
        }
        
        var side: PaneSide = .left
        var vm: DualPaneViewModel?
        var items: [FileItem] = []
        var onDoubleClick: ((Int) -> Void)?
        weak var hookedTableView: NSTableView?
        private var eventMonitor: Any?
        private var longPressWorkItem: DispatchWorkItem?
        private var mouseDownLocation: NSPoint = .zero
        private var pendingSingleClickSelection: (id: String, side: PaneSide)? = nil
        private var isAdjustingColumns = false
        private weak var columnResizeView: ColumnResizeView?
        private var preferredMetadataWidths: [CGFloat] = [
            TableColumnLayoutEngine.defaultWidths[1],
            TableColumnLayoutEngine.defaultWidths[2],
            TableColumnLayoutEngine.defaultWidths[3]
        ]
        
        deinit {
            longPressWorkItem?.cancel()
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
            NotificationCenter.default.removeObserver(self)
        }
        
        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NSTableRowView.enablePersistentSelectionHighlight()
            KeyCommandMonitor.installGlobalMonitor()
            DispatchQueue.main.async { [weak self] in
                self?.hookTableView()
                self?.setupEventMonitor()
            }
        }
        
        public override func layout() {
            super.layout()
            if hookedTableView == nil {
                hookTableView()
            } else {
                if let tv = hookedTableView, tv.columnAutoresizingStyle != .noColumnAutoresizing {
                    tv.columnAutoresizingStyle = .noColumnAutoresizing
                }
                adjustTableColumns()
            }
        }
        
        func hookTableView() {
            Self.ensureTableViewsDiscovered()
            if side == .left, let tv = Self.leftTableView {
                attach(to: tv)
                return
            }
            if side == .right, let tv = Self.rightTableView {
                attach(to: tv)
                return
            }
            
            var current: NSView? = self
            while let v = current {
                if v is NSSplitView || v.className.contains("SplitView") {
                    break
                }
                if let tv = findTableView(in: v) {
                    if (side == .right && tv === HandlerView.leftTableView) ||
                       (side == .left && tv === HandlerView.rightTableView) {
                        current = v.superview
                        continue
                    }
                    attach(to: tv)
                    return
                }
                current = v.superview
            }
        }
        
        private func findTableView(in view: NSView) -> NSTableView? {
            if view is NSSplitView || view.className.contains("SplitView") {
                return nil
            }
            if let tv = view as? NSTableView {
                if (side == .right && tv === HandlerView.leftTableView) ||
                   (side == .left && tv === HandlerView.rightTableView) {
                    return nil
                }
                return tv
            }
            if let scroll = view as? NSScrollView, let tv = scroll.documentView as? NSTableView {
                if (side == .right && tv === HandlerView.leftTableView) ||
                   (side == .left && tv === HandlerView.rightTableView) {
                    return nil
                }
                return tv
            }
            for sub in view.subviews {
                if sub !== self && !(sub is NSSplitView) && !sub.className.contains("SplitView") {
                    if let tv = findTableView(in: sub) { return tv }
                }
            }
            return nil
        }
        
        private func attach(to tv: NSTableView) {
            if side == .right && tv === HandlerView.leftTableView {
                return
            }
            if side == .left && tv === HandlerView.rightTableView {
                return
            }
            guard hookedTableView !== tv else { return }
            hookedTableView = tv
            if side == .left {
                HandlerView.leftTableView = tv
                HandlerView.leftVM = vm
            } else {
                HandlerView.rightTableView = tv
                HandlerView.rightVM = vm
            }
            if vm?.activePane == side {
                HandlerView.activePaneSide = side
            }
            tv.target = self
            tv.doubleAction = #selector(onTableDoubleClick(_:))
            tv.allowsMultipleSelection = true
            tv.allowsEmptySelection = true
            tv.allowsColumnReordering = false
            tv.allowsColumnResizing = false
            installColumnHeader(on: tv)
            if #available(macOS 11.0, *) {
                tv.style = .plain
            }
            tv.intercellSpacing = NSSize(width: 0, height: tv.intercellSpacing.height)
            tv.columnAutoresizingStyle = .noColumnAutoresizing
            tv.postsFrameChangedNotifications = true
            tv.postsBoundsChangedNotifications = true
            
            if let scroll = tv.enclosingScrollView {
                scroll.hasHorizontalScroller = false
                scroll.horizontalScrollElasticity = .none
                scroll.autohidesScrollers = true
            }
            
            let cols = tv.tableColumns
            for col in cols {
                col.headerCell.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            }
            if cols.count >= 5 {
                cols[1].width = preferredMetadataWidths[0]
                cols[2].width = preferredMetadataWidths[1]
                cols[3].width = preferredMetadataWidths[2]
                cols[4].minWidth = TableColumnLayoutEngine.fixedTypeWidth
                cols[4].maxWidth = TableColumnLayoutEngine.fixedTypeWidth
                cols[4].width = TableColumnLayoutEngine.fixedTypeWidth
                cols[4].resizingMask = []
                tv.headerView?.needsDisplay = true
            }
            
            NotificationCenter.default.removeObserver(self, name: NSTableView.selectionDidChangeNotification, object: tv)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onTableSelectionDidChange(_:)),
                name: NSTableView.selectionDidChangeNotification,
                object: tv
            )
            
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: tv)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onTableFrameDidChange(_:)),
                name: NSView.frameDidChangeNotification,
                object: tv
            )
            
            if let clipView = tv.enclosingScrollView?.contentView {
                clipView.postsBoundsChangedNotifications = true
                clipView.postsFrameChangedNotifications = true
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clipView)
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(onTableFrameDidChange(_:)),
                    name: NSView.boundsDidChangeNotification,
                    object: clipView
                )
                NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: clipView)
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(onTableFrameDidChange(_:)),
                    name: NSView.frameDidChangeNotification,
                    object: clipView
                )
            }
            
            NotificationCenter.default.removeObserver(self, name: NSTableView.columnDidResizeNotification, object: tv)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onTableColumnDidResize(_:)),
                name: NSTableView.columnDidResizeNotification,
                object: tv
            )
            
            adjustTableColumns()
            setupEventMonitor()
        }
        
        fileprivate func installColumnHeader(on table: NSTableView) {
            guard let nativeHeader = table.headerView else { return }
            let overlay = nativeHeader.subviews.compactMap { $0 as? ColumnResizeView }.first
                ?? ColumnResizeView(frame: nativeHeader.bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.tableView = table
            overlay.setAccessibilityElement(false)
            overlay.onBoundaryDrag = { [weak self, weak table] initialWidths, boundary, translation in
                guard let self, let table, !self.isAdjustingColumns else { return }
                self.isAdjustingColumns = true
                defer { self.isAdjustingColumns = false }
                let widths = TableColumnLayoutEngine.widthsByMovingBoundary(
                    initialWidths: initialWidths, boundaryIndex: boundary, translation: translation
                )
                TableColumnLayoutEngine.apply(widths: widths, to: table.tableColumns)
                self.preferredMetadataWidths = [widths[1], widths[2], widths[3]]
                table.headerView?.needsDisplay = true
            }
            overlay.onBoundaryDragEnded = { [weak self] in self?.adjustTableColumns() }
            if overlay.superview !== nativeHeader { nativeHeader.addSubview(overlay) }
            columnResizeView = overlay
            table.allowsColumnResizing = false
        }

        @objc public func adjustTableColumns() {
            guard !isAdjustingColumns else { return }
            guard let tv = hookedTableView else { return }
            guard columnResizeView?.isResizingBoundary != true else { return }
            let columns = tv.tableColumns
            guard columns.count == 5 else { return }

            let clipWidth = tv.enclosingScrollView?.contentView.bounds.width ?? tv.bounds.width
            guard clipWidth >= TableColumnLayoutEngine.minimumTableWidth else { return }
            
            isAdjustingColumns = true
            defer { isAdjustingColumns = false }
            
            let targetWidth = floor(clipWidth)
            if columns[4].width != TableColumnLayoutEngine.fixedTypeWidth || columns[4].resizingMask != [] {
                columns[4].minWidth = TableColumnLayoutEngine.fixedTypeWidth
                columns[4].maxWidth = TableColumnLayoutEngine.fixedTypeWidth
                columns[4].width = TableColumnLayoutEngine.fixedTypeWidth
                columns[4].resizingMask = []
                tv.headerView?.needsDisplay = true
            }
            let preferredSum = preferredMetadataWidths.reduce(0, +) + TableColumnLayoutEngine.fixedTypeWidth
            if targetWidth >= TableColumnLayoutEngine.constraints[0].min + preferredSum {
                columns[1].width = preferredMetadataWidths[0]
                columns[2].width = preferredMetadataWidths[1]
                columns[3].width = preferredMetadataWidths[2]
            }
            TableColumnLayoutEngine.adjust(columns: columns, targetWidth: targetWidth)
            
            if abs(tv.frame.size.width - targetWidth) > 0.5 {
                tv.setFrameSize(NSSize(width: targetWidth, height: tv.frame.height))
            }
        }
        
        @objc private func onTableFrameDidChange(_ notification: Notification) {
            adjustTableColumns()
        }
        
        @objc private func onTableColumnDidResize(_ notification: Notification) {
            // Programmatic/SwiftUI changes are not user boundary drags.
            adjustTableColumns()
        }
        
        @objc private func onTableSelectionDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTableView, tv === hookedTableView else { return }
            let selectedIndexes = tv.selectedRowIndexes
            guard !selectedIndexes.isEmpty else { return }
            var selectedIds: Set<String> = []
            for idx in selectedIndexes {
                if idx >= 0 && idx < items.count {
                    selectedIds.insert(items[idx].id)
                }
            }
            guard !selectedIds.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let vm = self.vm else { return }
                if vm.activePane != self.side {
                    vm.activePane = self.side
                }
                if self.side == .left {
                    if vm.leftSelection != selectedIds {
                        vm.leftSelection = selectedIds
                    }
                } else {
                    if vm.rightSelection != selectedIds {
                        vm.rightSelection = selectedIds
                    }
                }
            }
        }
        
        private func setupEventMonitor() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self = self, let tv = self.hookedTableView, event.window == tv.window else {
                    return event
                }
                guard self.vm?.failedConnectionSide == nil else {
                    return event
                }
                
                // KeyDown handling
                if event.type == .keyDown {
                    self.longPressWorkItem?.cancel()
                    self.longPressWorkItem = nil
                    
                    // Если фокус находится в любом поле ввода текста (поле фильтра, пути, модальном окне, переименовании),
                    // передаем событие в KeyCommandMonitor (для Ctrl+C/V/X/A и Cmd+C/V/X/A в тексте)
                    // и ГАРАНТИРУЕМ, что текстовый ввод (пробел, буквы, цифры, backspace, return) не перехватывается шорткатами таблицы!
                    if let firstResponder = tv.window?.firstResponder, KeyCommandMonitor.isTextEditingResponder(firstResponder) {
                        if KeyCommandMonitor.handleEvent(event, targetResponder: firstResponder) == nil {
                            return nil
                        }
                        return event
                    }
                    
                    // Если пользователь находится в процессе редактирования текста (переименование, модальные окна, фильтр и т.д.),
                    // не перехватываем пробел, ввод или другие клавиши шорткатами таблицы!
                    if KeyCommandMonitor.isTextEditingActive(in: self.vm) {
                        return event
                    }
                    
                    // Обрабатываем шорткаты таблицы только для активной панели
                    guard HandlerView.activePaneSide == self.side else {
                        return event
                    }
                    
                    // Check if table or active pane view is focused
                    let firstResponder = tv.window?.firstResponder
                    let isFocused = (firstResponder === tv || ((firstResponder as? NSView)?.isDescendant(of: tv) ?? false) || !KeyCommandMonitor.isTextEditingResponder(firstResponder))
                    if isFocused {
                        if KeyCommandMonitor.handleEvent(event) == nil {
                            return nil
                        }
                        // Return / Enter (KeyCodes 36: Return, 76: Enter)
                        if event.keyCode == 36 || event.keyCode == 76 {
                            print("DUAL_PANE: KeyDown Return/Enter on side \(self.side)")
                            self.vm?.openSelected()
                            return nil
                        }
                        // Delete / Forward Delete / Cmd+Delete (KeyCode 51: Delete on Mac, KeyCode 117: Forward Delete ⌦)
                        if event.keyCode == 51 || event.keyCode == 117 {
                            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                            if modifiers.isEmpty || modifiers == .command {
                                print("DUAL_PANE: KeyDown Delete on side \(self.side)")
                                if (self.side == .left ? self.vm?.leftSelection.isEmpty : self.vm?.rightSelection.isEmpty) ?? true {
                                    let selectedRow = tv.selectedRow
                                    if selectedRow >= 0 && selectedRow < self.items.count {
                                        let item = self.items[selectedRow]
                                        if self.side == .left {
                                            self.vm?.leftSelection = [item.id]
                                        } else {
                                            self.vm?.rightSelection = [item.id]
                                        }
                                    }
                                }
                                self.vm?.triggerDelete()
                                return nil
                            }
                        }
                        // Cmd+Up Arrow (KeyCode 126 with .command): Navigate Up (Mac standard)
                        if event.keyCode == 126 && event.modifierFlags.contains(.command) {
                            self.vm?.navigateUp()
                            return nil
                        }
                        // Space (KeyCode 49) without Command/Shift/Alt -> QuickLook / Calculate Folder Size
                        if event.keyCode == 49 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                            print("DUAL_PANE: KeyDown Space on side \(self.side)")
                            self.vm?.triggerQuickLook(preferNativeQuickLook: true)
                            return nil
                        }
                        // Tab (KeyCode 48) -> Switch Pane
                        let isTab = (event.keyCode == 48 || event.characters == "\t" || event.charactersIgnoringModifiers == "\t")
                        let tabMods = event.modifierFlags.intersection([.command, .option, .control, .shift])
                        if isTab && (tabMods.isEmpty || tabMods == .shift) {
                            self.vm?.toggleActivePane()
                            return nil
                        }
                        // F5 (KeyCode 96): Copy / Alt+F5 Create Archive
                        if event.keyCode == 96 {
                            if event.modifierFlags.contains(.option) {
                                self.vm?.triggerCreateArchive()
                            } else {
                                self.vm?.triggerCopy()
                            }
                            return nil
                        }
                        // F6 (KeyCode 97): Move
                        if event.keyCode == 97 {
                            self.vm?.triggerMove()
                            return nil
                        }
                        // F7 (KeyCode 98): New Folder
                        if event.keyCode == 98 {
                            self.vm?.prepareNewFolder()
                            return nil
                        }
                        // F8 (KeyCode 100): Delete
                        if event.keyCode == 100 {
                            if (self.side == .left ? self.vm?.leftSelection.isEmpty : self.vm?.rightSelection.isEmpty) ?? true {
                                let selectedRow = tv.selectedRow
                                if selectedRow >= 0 && selectedRow < self.items.count {
                                    let item = self.items[selectedRow]
                                    if self.side == .left {
                                        self.vm?.leftSelection = [item.id]
                                    } else {
                                        self.vm?.rightSelection = [item.id]
                                    }
                                }
                            }
                            self.vm?.triggerDelete()
                            return nil
                        }
                        // F2 (KeyCode 120): Rename
                        if event.keyCode == 120 {
                            self.vm?.triggerRename(side: self.side)
                            return nil
                        }
                        // F3 (KeyCode 99): QuickLook
                        if event.keyCode == 99 {
                            self.vm?.triggerQuickLook(preferNativeQuickLook: true)
                            return nil
                        }
                    }
                    return event
                }
                
                if event.type == .leftMouseUp {
                    self.longPressWorkItem?.cancel()
                    self.longPressWorkItem = nil
                    if let pending = self.pendingSingleClickSelection, let vm = self.vm {
                        if pending.side == .left {
                            vm.leftSelection = [pending.id]
                        } else {
                            vm.rightSelection = [pending.id]
                        }
                    }
                    self.pendingSingleClickSelection = nil
                    return event
                }
                
                if event.type == .leftMouseDragged {
                    self.pendingSingleClickSelection = nil
                    let currLoc = event.locationInWindow
                    let dist = hypot(currLoc.x - self.mouseDownLocation.x, currLoc.y - self.mouseDownLocation.y)
                    if dist > 4 {
                        self.longPressWorkItem?.cancel()
                        self.longPressWorkItem = nil
                        
                        // Если начался Drag & Drop выделенных файлов — гарантируем, что в NSPasteboard drag
                        // записан полный список системных путей/URL для внешних приложений (Finder, Desktop, Telegram и т.д.)
                        if let vm = self.vm, let payload = vm.currentDragPayload, payload.paths.count > 1 {
                            vm.populateDragPasteboard(paths: payload.paths, payload: payload)
                        }
                    }
                    return event
                }
                
                let locationInTable = tv.convert(event.locationInWindow, from: nil)
                let isClickInPaneArea: Bool
                if let scroll = tv.enclosingScrollView {
                    let locInScroll = scroll.convert(event.locationInWindow, from: nil)
                    isClickInPaneArea = scroll.bounds.contains(locInScroll)
                } else {
                    isClickInPaneArea = tv.bounds.contains(locationInTable)
                }
                
                if (event.type == .leftMouseDown || event.type == .rightMouseDown) && isClickInPaneArea {
                    HandlerView.setActiveSide(self.side)
                    if let vm = self.vm, vm.activePane != self.side {
                        vm.activePane = self.side
                    }
                }
                
                guard tv.bounds.contains(locationInTable) else {
                    return event
                }
                
                let clickedRow = tv.row(at: locationInTable)
                
                if event.type == .leftMouseDown {
                    self.longPressWorkItem?.cancel()
                    self.longPressWorkItem = nil
                    self.mouseDownLocation = event.locationInWindow
                    
                    // Если пользователь кликает по элементу, имя которого сейчас редактируется:
                    if let editingId = self.vm?.editingItemId, clickedRow >= 0 && clickedRow < self.items.count, self.items[clickedRow].id == editingId {
                        // Позволяем клику пройти в текстовое поле редактирования
                        return event
                    }
                    
                    // Если редактировался другой элемент и пользователь кликнул вне него:
                    if self.vm?.editingItemId != nil {
                        self.vm?.commitInlineRename()
                    }
                    
                    if tv.window?.firstResponder != tv {
                        tv.window?.makeFirstResponder(tv)
                    }
                    HandlerView.setActiveSide(self.side)
                    if let vm = self.vm {
                        if vm.activePane != self.side {
                            vm.activePane = self.side
                        }
                    }
                    
                    if clickedRow >= 0 && clickedRow < self.items.count {
                        let item = self.items[clickedRow]
                        
                        // Check for Double Click
                        if event.clickCount == 2 {
                            self.longPressWorkItem?.cancel()
                            self.longPressWorkItem = nil
                            print("DUAL_PANE: LeftMouseDown clickCount == 2 on row \(clickedRow), item: \(item.name)")
                            if self.side == .left {
                                self.vm?.leftSelection = [item.id]
                            } else {
                                self.vm?.rightSelection = [item.id]
                            }
                            self.vm?.openItem(item: item, side: self.side)
                            return nil
                        } else if event.clickCount == 1 {
                            // Проверяем клик на колонку с именем файла (колонка 0)
                            let clickedCol = tv.column(at: locationInTable)
                            if clickedCol <= 0 {
                                let itemToRename = item
                                let currentPaneSide = self.side
                                let work = DispatchWorkItem { [weak self] in
                                    guard let self = self, let vm = self.vm else { return }
                                    print("DUAL_PANE: Long press detected on file name '\(itemToRename.name)' -> triggering rename")
                                    DispatchQueue.main.async {
                                        if currentPaneSide == .left {
                                            vm.leftSelection = [itemToRename.id]
                                        } else {
                                            vm.rightSelection = [itemToRename.id]
                                        }
                                        vm.triggerRename(item: itemToRename, side: currentPaneSide)
                                    }
                                }
                                self.longPressWorkItem = work
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
                            }
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
                                let currentSelection = (self.side == .left) ? vm.leftSelection : vm.rightSelection
                                if currentSelection.contains(item.id) || currentSelection.contains(item.path) {
                                    // Элемент уже входит в текущее выделение (возможно множественное) ->
                                    // НЕ сбрасываем выделение прямо сейчас, чтобы не ломать перетаскивание (Drag & Drop) нескольких файлов!
                                    // Если перетаскивания не будет, одиночное выделение применится в .leftMouseUp.
                                    self.pendingSingleClickSelection = (id: item.id, side: self.side)
                                } else {
                                    self.pendingSingleClickSelection = nil
                                    if self.side == .left {
                                        vm.leftSelection = [item.id]
                                    } else {
                                        vm.rightSelection = [item.id]
                                    }
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
                    self.longPressWorkItem?.cancel()
                    self.longPressWorkItem = nil
                    
                    if tv.window?.firstResponder != tv {
                        tv.window?.makeFirstResponder(tv)
                    }
                    HandlerView.setActiveSide(self.side)
                    if let vm = self.vm {
                        if vm.activePane != self.side {
                            vm.activePane = self.side
                        }
                        if !vm.isFileDiffActive {
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
                    
                    if clickedRow >= 0 && clickedRow < self.items.count {
                        let item = self.items[clickedRow]
                        let contextItems = self.vm?.contextMenuItems(for: item, side: self.side) ?? [item]
                        self.showRowContextMenu(for: item, contextItems: contextItems, with: event, in: tv)
                        return nil
                    } else if clickedRow < 0 {
                        self.showEmptyAreaContextMenu(with: event, in: tv)
                        return nil
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
        
        private func showRowContextMenu(for item: FileItem, contextItems: [FileItem], with event: NSEvent, in tv: NSTableView) {
            guard let vm = self.vm else { return }
            let side = self.side
            let menu = NSMenu(title: "Context Menu")
            
            // 1. Верхний пункт меню: строка цветных кнопок тегов (Red, Orange, Yellow, Green, Blue, Grey)
            let itemTags = item.tags.isEmpty ? TagsManager.shared.getTags(for: item) : item.tags
            let tagMenuView = TagRowMenuView(currentTags: itemTags) { tagId in
                vm.toggleTag(tagId, for: contextItems, side: side)
            }
            let tagMenuItem = NSMenuItem()
            tagMenuItem.view = tagMenuView
            menu.addItem(tagMenuItem)
            
            // 1.1. Строка быстрых действий «Поделиться» (Telegram, WhatsApp, Gmail)
            let shareMenuView = ShareRowMenuView { target in
                let point = tv.convert(event.locationInWindow, from: nil)
                let row = tv.row(at: point)
                let rect = row >= 0 ? tv.rect(ofRow: row) : .zero
                vm.share(items: contextItems, side: side, target: target, sourceView: tv, rect: rect)
            }
            let shareMenuItem = NSMenuItem()
            shareMenuItem.view = shareMenuView
            menu.addItem(shareMenuItem)
            
            menu.addItem(NSMenuItem.separator())
            
            // 2. Стандартные действия контекстного меню
            if item.isDirectory {
                let openInNewTabItem = NSMenuItem(title: "Открыть в новой вкладке", action: #selector(menuActionOpenInNewTab(_:)), keyEquivalent: "")
                openInNewTabItem.target = self
                openInNewTabItem.representedObject = item
                menu.addItem(openInNewTabItem)
                menu.addItem(NSMenuItem.separator())
            }
            
            let newFolderWithSelTitle = "Новая папка с выбранными объектами (\(contextItems.count))"
            let newFolderWithSelItem = NSMenuItem(title: newFolderWithSelTitle, action: #selector(menuActionNewFolderWithSelection(_:)), keyEquivalent: "")
            newFolderWithSelItem.target = self
            newFolderWithSelItem.representedObject = item
            menu.addItem(newFolderWithSelItem)
            
            let newFolderItem = NSMenuItem(title: "Новая папка", action: #selector(menuActionNewFolder(_:)), keyEquivalent: "")
            newFolderItem.target = self
            menu.addItem(newFolderItem)
            
            // Меню "Открыть с помощью..."
            let openWithMenu = NSMenu(title: "Открыть с помощью...")
            let apps = vm.getApplicationsForFile(item: item)
            if apps.isEmpty {
                let noAppsItem = NSMenuItem(title: "Нет ассоциированных программ", action: nil, keyEquivalent: "")
                noAppsItem.isEnabled = false
                openWithMenu.addItem(noAppsItem)
            } else {
                for appURL in apps {
                    let appName = FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
                    let appItem = NSMenuItem(title: appName, action: #selector(menuActionOpenWithApp(_:)), keyEquivalent: "")
                    appItem.target = self
                    appItem.representedObject = (item, appURL)
                    if let icon = NSWorkspace.shared.icon(forFile: appURL.path) as NSImage? {
                        icon.size = NSSize(width: 16, height: 16)
                        appItem.image = icon
                    }
                    openWithMenu.addItem(appItem)
                }
            }
            openWithMenu.addItem(NSMenuItem.separator())
            let chooseAppItem = NSMenuItem(title: "Выбрать программу...", action: #selector(menuActionChooseCustomApp(_:)), keyEquivalent: "")
            chooseAppItem.target = self
            chooseAppItem.representedObject = item
            openWithMenu.addItem(chooseAppItem)
            
            let openWithSubmenuItem = NSMenuItem(title: "Открыть с помощью...", action: nil, keyEquivalent: "")
            openWithSubmenuItem.submenu = openWithMenu
            menu.addItem(openWithSubmenuItem)
            
            menu.addItem(NSMenuItem.separator())
            
            if item.source == .remotePhone {
                let cleanup = NSMenuItem(title: "Освободить место — copy done", action: #selector(menuActionCopyDone(_:)), keyEquivalent: "")
                cleanup.target = self
                cleanup.representedObject = item
                cleanup.isEnabled = vm.canStartCopyDone
                menu.addItem(cleanup)
            }
            let deleteItem = NSMenuItem(title: "Удалить (F8 / Delete)", action: #selector(menuActionDelete(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = item
            menu.addItem(deleteItem)
            
            let copyItem = NSMenuItem(title: "Копировать (Cmd+C)", action: #selector(menuActionCopy(_:)), keyEquivalent: "")
            copyItem.target = self
            copyItem.representedObject = contextItems
            menu.addItem(copyItem)

            let cutItem = NSMenuItem(title: "Вырезать (Ctrl+X)", action: #selector(menuActionCut(_:)), keyEquivalent: "")
            cutItem.target = self
            cutItem.representedObject = contextItems
            menu.addItem(cutItem)
            
            let pasteItem = NSMenuItem(title: "Вставить (Cmd+V)", action: #selector(menuActionPaste(_:)), keyEquivalent: "")
            pasteItem.target = self
            pasteItem.isEnabled = vm.canPaste
            menu.addItem(pasteItem)
            
            let duplicateItem = NSMenuItem(title: "Дублировать (Cmd+Shift+D)", action: #selector(menuActionDuplicate(_:)), keyEquivalent: "")
            duplicateItem.target = self
            duplicateItem.representedObject = item
            menu.addItem(duplicateItem)
            
            menu.addItem(NSMenuItem.separator())

            let unarchiveItem = NSMenuItem(title: "Разархивировать", action: #selector(menuActionUnarchive(_:)), keyEquivalent: "")
            unarchiveItem.target = self
            unarchiveItem.representedObject = item
            unarchiveItem.isEnabled = !item.isDirectory && vm.isArchive(item: item) && !vm.isArchiving
            menu.addItem(unarchiveItem)
            
            let archiveItem = NSMenuItem(title: "Сжать в архив... (Alt+F5)", action: #selector(menuActionArchive(_:)), keyEquivalent: "")
            archiveItem.target = self
            archiveItem.representedObject = item
            menu.addItem(archiveItem)
            
            let renameItem = NSMenuItem(title: "Переименовать (F2)", action: #selector(menuActionRename(_:)), keyEquivalent: "")
            renameItem.target = self
            renameItem.representedObject = item
            menu.addItem(renameItem)
            
            let propItem = NSMenuItem(title: "Свойства (Cmd+I)", action: #selector(menuActionProperties(_:)), keyEquivalent: "")
            propItem.target = self
            propItem.representedObject = item
            menu.addItem(propItem)
            
            menu.addItem(NSMenuItem.separator())
            
            let showHiddenItem = NSMenuItem(title: "Показывать скрытые файлы", action: #selector(menuActionToggleHidden(_:)), keyEquivalent: "")
            showHiddenItem.target = self
            let isHiddenActive = (side == .left) ? vm.leftShowHidden : vm.rightShowHidden
            showHiddenItem.state = isHiddenActive ? .on : .off
            menu.addItem(showHiddenItem)
            
            NSMenu.popUpContextMenu(menu, with: event, for: tv)
        }
        
        private func showEmptyAreaContextMenu(with event: NSEvent, in tv: NSTableView) {
            guard let vm = self.vm else { return }
            let menu = NSMenu(title: "Empty Area Context Menu")
            if (side == .left ? vm.leftSource : vm.rightSource) == .remotePhone {
                let cleanup = NSMenuItem(title: "Освободить место — copy done", action: #selector(menuActionCopyDone(_:)), keyEquivalent: "")
                cleanup.target = self
                cleanup.isEnabled = vm.canStartCopyDone
                menu.addItem(cleanup)
                menu.addItem(.separator())
            }
            
            let newFolderItem = NSMenuItem(title: "Новая папка", action: #selector(menuActionNewFolder(_:)), keyEquivalent: "")
            newFolderItem.target = self
            menu.addItem(newFolderItem)
            
            let pasteItem = NSMenuItem(title: "Вставить (Cmd+V)", action: #selector(menuActionPaste(_:)), keyEquivalent: "")
            pasteItem.target = self
            pasteItem.isEnabled = vm.canPaste
            menu.addItem(pasteItem)
            
            menu.addItem(NSMenuItem.separator())
            
            let refreshItem = NSMenuItem(title: "Обновить (Cmd+R)", action: #selector(menuActionRefresh(_:)), keyEquivalent: "")
            refreshItem.target = self
            menu.addItem(refreshItem)
            
            let selectAllItem = NSMenuItem(title: "Выбрать всё (Cmd+A)", action: #selector(menuActionSelectAll(_:)), keyEquivalent: "")
            selectAllItem.target = self
            menu.addItem(selectAllItem)
            
            menu.addItem(NSMenuItem.separator())
            
            let showHiddenItem = NSMenuItem(title: "Показывать скрытые файлы", action: #selector(menuActionToggleHidden(_:)), keyEquivalent: "")
            showHiddenItem.target = self
            let isHiddenActive = (side == .left) ? vm.leftShowHidden : vm.rightShowHidden
            showHiddenItem.state = isHiddenActive ? .on : .off
            menu.addItem(showHiddenItem)
            
            NSMenu.popUpContextMenu(menu, with: event, for: tv)
        }
        
        @objc private func menuActionNewFolderWithSelection(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? FileItem, let vm = self.vm else { return }
            vm.prepareNewFolderWithSelection(item: item, side: self.side)
        }
        
        @objc private func menuActionOpenInNewTab(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? FileItem, item.isDirectory else { return }
            self.vm?.openFolderInNewTab(path: item.path, source: item.source, side: self.side)
        }
        
        @objc private func menuActionNewFolder(_ sender: NSMenuItem) {
            self.vm?.prepareNewFolder(side: self.side)
        }
        
        @objc private func menuActionOpenWithApp(_ sender: NSMenuItem) {
            guard let (item, appURL) = sender.representedObject as? (FileItem, URL) else { return }
            self.vm?.openFile(item: item, withApplicationURL: appURL)
        }
        
        @objc private func menuActionChooseCustomApp(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? FileItem else { return }
            self.vm?.chooseCustomApplicationAndOpen(item: item)
        }
        
        @objc private func menuActionCopyDone(_ sender: NSMenuItem) {
            guard let vm, vm.canStartCopyDone else { return }
            vm.openCopyDone(side: side, item: sender.representedObject as? FileItem)
        }

        @objc private func menuActionDelete(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? FileItem, let vm = self.vm else { return }
            vm.selectContextMenuItems(for: item, side: self.side)
            vm.triggerDelete()
        }
        
        @objc private func menuActionCopy(_ sender: NSMenuItem) {
            guard let items = sender.representedObject as? [FileItem], let vm = self.vm else { return }
            vm.copyToClipboard(items: items, side: self.side)
        }

        @objc private func menuActionCut(_ sender: NSMenuItem) {
            guard let items = sender.representedObject as? [FileItem], let vm = self.vm else { return }
            vm.cutToClipboard(items: items, side: self.side)
        }
        
        @objc private func menuActionPaste(_ sender: NSMenuItem) {
            self.vm?.pasteFromClipboard(targetSide: self.side)
        }
        
        @objc private func menuActionDuplicate(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? FileItem else { return }
            self.vm?.duplicateItem(item: item, side: self.side)
        }
        
        @objc private func menuActionArchive(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? FileItem else { return }
            self.vm?.triggerCreateArchive(item: item, side: self.side)
        }

        @objc private func menuActionUnarchive(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? FileItem,
                  let vm = self.vm,
                  !item.isDirectory,
                  vm.isArchive(item: item),
                  !vm.isArchiving else { return }
            vm.unarchive(item: item, side: self.side)
        }
        
        @objc private func menuActionRename(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? FileItem else { return }
            self.vm?.triggerRename(item: item, side: self.side)
        }
        
        @objc private func menuActionProperties(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? FileItem else { return }
            self.vm?.triggerProperties(item: item, side: self.side)
        }
        
        @objc private func menuActionToggleHidden(_ sender: NSMenuItem) {
            self.vm?.toggleShowHidden(side: self.side)
        }
        
        @objc private func menuActionRefresh(_ sender: NSMenuItem) {
            self.vm?.refreshPaneToActiveTab(side: self.side)
        }
        
        @objc private func menuActionSelectAll(_ sender: NSMenuItem) {
            self.vm?.selectAll(side: self.side)
        }
    }
}

// MARK: - Контекстное меню: строка цветных кнопок тегов

final class TagCircleButton: NSControl {
    let tagDef: FileTag
    let isTagSelected: Bool
    let onClick: () -> Void
    private var isHovered: Bool = false
    
    init(tag: FileTag, isSelected: Bool, onClick: @escaping () -> Void) {
        self.tagDef = tag
        self.isTagSelected = isSelected
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        toolTip = tag.name
        
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    override var intrinsicContentSize: NSSize {
        NSSize(width: 16, height: 16)
    }
    
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }
    
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }
    
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onClick()
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        // Диаметр круга 9pt — в точности как в левой боковой панели
        let circleSize: CGFloat = 9
        let rect = NSRect(
            x: (bounds.width - circleSize) / 2,
            y: (bounds.height - circleSize) / 2,
            width: circleSize,
            height: circleSize
        )
        let path = NSBezierPath(ovalIn: rect)
        tagDef.nsColor.setFill()
        path.fill()
        
        if isTagSelected {
            let ringRect = rect.insetBy(dx: -2.5, dy: -2.5)
            let ringPath = NSBezierPath(ovalIn: ringRect)
            ringPath.lineWidth = 1.2
            tagDef.nsColor.setStroke()
            ringPath.stroke()
        } else if isHovered {
            let ringRect = rect.insetBy(dx: -2, dy: -2)
            let ringPath = NSBezierPath(ovalIn: ringRect)
            ringPath.lineWidth = 1
            NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke()
            ringPath.stroke()
        }
    }
}

final class TagRowMenuView: NSView {
    private let tags = FileTag.allTags
    private var onSelectTag: ((String) -> Void)?
    private var itemTags: Set<String> = []
    
    init(currentTags: [String], onSelectTag: @escaping (String) -> Void) {
        self.itemTags = Set(currentTags.map { $0.lowercased() })
        self.onSelectTag = onSelectTag
        super.init(frame: NSRect(x: 0, y: 0, width: 190, height: 26))
        
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 20)
        ])
        
        for tag in tags {
            let isSelected = itemTags.contains { FileTag.isTagMatching($0, tagIdOrName: tag.id) }
            let btn = TagCircleButton(tag: tag, isSelected: isSelected) { [weak self] in
                self?.enclosingMenuItem?.menu?.cancelTracking()
                self?.onSelectTag?(tag.id)
            }
            stack.addArrangedSubview(btn)
        }
    }
    
    required init?(coder: NSCoder) { fatalError() }
}

public struct PaneTableDropDelegate: DropDelegate {
    public let side: PaneSide
    public let vm: DualPaneViewModel
    public let items: [FileItem]
    
    private static var springLoadTimer: DispatchWorkItem?
    private static var currentSpringLoadFolderId: String?
    
    public init(side: PaneSide, vm: DualPaneViewModel, items: [FileItem]) {
        self.side = side
        self.vm = vm
        self.items = items
    }
    
    public func dropEntered(info: DropInfo) {
        updateHover(at: info.location)
    }
    
    public func dropUpdated(info: DropInfo) -> DropProposal? {
        updateHover(at: info.location)
        let isMove = NSEvent.modifierFlags.contains(.command)
        return DropProposal(operation: isMove ? .move : .copy)
    }
    
    public func dropExited(info: DropInfo) {
        cleanDropState()
    }
    
    public func performDrop(info: DropInfo) -> Bool {
        Self.springLoadTimer?.cancel()
        Self.springLoadTimer = nil
        Self.currentSpringLoadFolderId = nil
        
        let targetFolderId = vm.dragHoverFolderId
        cleanDropState()
        
        let targetDirPath: String?
        if let folderId = targetFolderId, let folder = items.first(where: { $0.id == folderId && $0.isDirectory }) {
            targetDirPath = folder.path
        } else {
            targetDirPath = nil
        }
        
        let isMove = NSEvent.modifierFlags.contains(.command)
        SSHTransportLog.write("DND_PERFORM_DROP side=\(side) hasPayload=\(vm.currentDragPayload != nil) targetDir=\(targetDirPath ?? "nil")")
        
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

        // 1. Приоритетный путь для внутреннего Drag & Drop между панелями
        // Если payload активен, обрабатываем напрямую без запроса провайдеров из AppKit/NSPasteboard,
        // предотвращая синхронную блокировку главного потока и дедлок.
        // Внутренний drag опознаём по провайдерам: hasItemsConforming(to:) для нашего нестандартного UTI
        // возвращает false, и payload сбрасывался до того, как перенос успевал выполниться.
        // Внешний drop (Finder) сбрасывает устаревший payload и идёт обычным путём (D11).
        let isInternalDrop = DualPaneViewModel.providersCarryInternalPayload(providers)
            || info.hasItemsConforming(to: [DualPaneViewModel.dragUTType])
        if vm.consumeInternalDragPayload(isInternalDrop: isInternalDrop) {
            return vm.handleDroppedProviders([], toSide: side, targetDirPath: targetDirPath, isMove: isMove)
        }

        return vm.handleDroppedProviders(providers, toSide: side, targetDirPath: targetDirPath, isMove: isMove)
    }
    
    private func cleanDropState() {
        Self.springLoadTimer?.cancel()
        Self.springLoadTimer = nil
        Self.currentSpringLoadFolderId = nil
        if let tv = (side == .left ? TableDoubleClickHandler.HandlerView.leftTableView : TableDoubleClickHandler.HandlerView.rightTableView) {
            tv.setDropRow(-1, dropOperation: .on)
            tv.enumerateAvailableRowViews { rowView, _ in
                rowView.needsDisplay = true
            }
            tv.needsDisplay = true
        }
        vm.clearDragHoverState()
    }
    
    private func updateHover(at location: CGPoint) {
        let tv = (side == .left ? TableDoubleClickHandler.HandlerView.leftTableView : TableDoubleClickHandler.HandlerView.rightTableView)
        
        let targetRow: Int
        let isOverFolder: Bool
        let isInsertTop: Bool
        
        if let tv = tv {
            let screenLoc = NSEvent.mouseLocation
            let windowLoc = tv.window?.convertPoint(fromScreen: screenLoc) ?? .zero
            let tableLoc = tv.convert(windowLoc, from: nil)
            let row = tv.row(at: tableLoc)
            
            if row >= 0 && row < items.count {
                let item = items[row]
                let rowRect = tv.rect(ofRow: row)
                let relY = tableLoc.y - rowRect.origin.y
                
                if item.isDirectory && relY >= 4 && relY <= (rowRect.height - 4) {
                    targetRow = row
                    isOverFolder = true
                    isInsertTop = false
                } else {
                    targetRow = row
                    isOverFolder = false
                    isInsertTop = item.isDirectory ? (relY < 4) : (relY < rowRect.height / 2)
                }
            } else {
                targetRow = items.count
                isOverFolder = false
                isInsertTop = false
            }
            tv.setDropRow(isOverFolder ? targetRow : (isInsertTop ? targetRow : targetRow + 1), dropOperation: isOverFolder ? .on : .above)
            tv.enumerateAvailableRowViews { rowView, _ in
                rowView.needsDisplay = true
            }
            tv.needsDisplay = true
        } else {
            // Fallback расчёт по положению курсора в координатах SwiftUI Table
            let headerHeight: CGFloat = 24.0
            let rowHeight: CGFloat = 24.0
            let y = location.y - headerHeight
            if y < 0 {
                targetRow = 0
                isOverFolder = false
                isInsertTop = true
            } else {
                let estimatedRow = Int(y / rowHeight)
                if estimatedRow >= 0 && estimatedRow < items.count {
                    let item = items[estimatedRow]
                    let relY = y - CGFloat(estimatedRow) * rowHeight
                    if item.isDirectory && relY >= 4 && relY <= (rowHeight - 4) {
                        targetRow = estimatedRow
                        isOverFolder = true
                        isInsertTop = false
                    } else {
                        targetRow = estimatedRow
                        isOverFolder = false
                        isInsertTop = (relY < rowHeight / 2)
                    }
                } else {
                    targetRow = items.count
                    isOverFolder = false
                    isInsertTop = false
                }
            }
        }
        
        if targetRow >= 0 && targetRow < items.count {
            let item = items[targetRow]
            if isOverFolder && item.isDirectory {
                // Наведение на конкретную папку: выделяется синим фоном
                vm.dragHoverSide = side
                vm.dragHoverFolderId = item.id
                vm.dragInsertionIndex = nil
                
                // Spring-Loaded Folders: при длительном удерживании (0.8с) папка открывается
                if Self.currentSpringLoadFolderId != item.id {
                    Self.springLoadTimer?.cancel()
                    Self.currentSpringLoadFolderId = item.id
                    let folderToOpen = item
                    let work = DispatchWorkItem { [weak vm] in
                        guard let vm = vm else { return }
                        if Self.currentSpringLoadFolderId == folderToOpen.id {
                            print("SPRING_LOAD: Открытие папки '\(folderToOpen.name)' при наведении на панели \(side)")
                            DispatchQueue.main.async {
                                vm.openItem(item: folderToOpen, side: side)
                                Self.currentSpringLoadFolderId = nil
                                Self.springLoadTimer = nil
                                vm.clearDragHoverState()
                            }
                        }
                    }
                    Self.springLoadTimer = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
                }
            } else {
                // Наведение между файлами (или на обычный файл) -> синяя линия между файлами
                Self.springLoadTimer?.cancel()
                Self.springLoadTimer = nil
                Self.currentSpringLoadFolderId = nil
                
                let insertRow = isInsertTop ? targetRow : targetRow + 1
                vm.dragHoverSide = side
                vm.dragHoverFolderId = nil
                vm.dragInsertionIndex = insertRow
            }
        } else {
            // Пустая область ниже строк
            Self.springLoadTimer?.cancel()
            Self.springLoadTimer = nil
            Self.currentSpringLoadFolderId = nil
            
            let insertRow = items.count
            vm.dragHoverSide = side
            vm.dragHoverFolderId = nil
            vm.dragInsertionIndex = insertRow
        }
        
        // Гарантируем немедленную перерисовку всех строк AppKit NSTableView,
        // чтобы снять подсветку с ранее подсвеченной папки и нарисовать только на текущей
        if let tv = tv {
            tv.enumerateAvailableRowViews { rowView, _ in
                rowView.needsDisplay = true
            }
            tv.needsDisplay = true
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

// MARK: - Кнопка закрепления / открепления вкладки
public struct TabPinButton: View {
    public let isPinned: Bool
    public let action: () -> Void
    @State private var isHovered: Bool = false
    
    public init(isPinned: Bool, action: @escaping () -> Void) {
        self.isPinned = isPinned
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 8.5))
                .foregroundColor(
                    isHovered
                        ? .primary
                        : (isPinned ? Color.secondary.opacity(0.85) : Color.secondary.opacity(0.65))
                )
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(isPinned ? "Открепить вкладку" : "Закрепить вкладку")
    }
}

// MARK: - Современные минималистичные векторные кнопки дисков/источников

// MARK: - Современные минималистичные векторные кнопки дисков/источников (Вариант 3: Подчеркивание)

private let toolbarMacSvgString = """
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
  <rect x="4" y="5" width="16" height="11" rx="1.8"/>
  <path d="M2 19h20"/>
</svg>
"""

private let toolbarPhoneSvgString = """
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
    <rect x="5" y="3.2" width="14" height="17.6" rx="2" ry="2"></rect>
    <circle cx="12" cy="17.2" r="1.3" fill="black" stroke="none"></circle>
</svg>
"""

private func loadToolbarDriveIcon(named name: String) -> NSImage? {
    if let bundlePath = Bundle.main.path(forResource: name, ofType: "svg"),
       let img = NSImage(contentsOfFile: bundlePath) {
        img.isTemplate = true
        return img
    }
    if let bundlePath = Bundle.main.path(forResource: name, ofType: "png"),
       let img = NSImage(contentsOfFile: bundlePath) {
        img.isTemplate = true
        return img
    }
    let fallbackSvg = (name == "toolbar_mac") ? toolbarMacSvgString : toolbarPhoneSvgString
    if let data = fallbackSvg.data(using: .utf8), let img = NSImage(data: data) {
        img.isTemplate = true
        return img
    }
    return nil
}

public struct MacToolbarIconView: View {
    public var size: CGFloat = 20
    
    public init(size: CGFloat = 20) {
        self.size = size
    }
    
    public var body: some View {
        if let img = loadToolbarDriveIcon(named: "toolbar_mac") {
            Image(nsImage: img)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "laptopcomputer")
                .font(.system(size: size * 0.85, weight: .regular))
        }
    }
}

public struct PhoneToolbarIconView: View {
    public var size: CGFloat = 18.6
    
    public init(size: CGFloat = 18.6) {
        self.size = size
    }
    
    public var body: some View {
        if let img = loadToolbarDriveIcon(named: "toolbar_phone") {
            Image(nsImage: img)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "iphone")
                .font(.system(size: size * 0.85, weight: .regular))
        }
    }
}


private let inactiveUnderlineColor = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return isDark
        ? NSColor.white.withAlphaComponent(0.55 * 1.20) // 0.66 alpha white = на 20% светлее в тёмной теме
        : NSColor.black.withAlphaComponent(0.50 * 0.80) // 0.40 alpha black = на 20% светлее в светлой теме
}))

/// Вариант 3: Кнопка источника с подчеркиванием снизу
public struct DriveTabToolbarButton<Content: View>: View {
    public let isActive: Bool
    public let tooltip: String
    public let action: () -> Void
    public let content: () -> Content
    
    @State private var isHovered: Bool = false
    
    public init(
        isActive: Bool,
        tooltip: String,
        action: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isActive = isActive
        self.tooltip = tooltip
        self.action = action
        self.content = content
    }
    
    private var iconColor: Color {
        isActive
            ? Color.primary
            : (isHovered ? Color.primary.opacity(0.85) : Color.secondary)
    }
    
    private var underlineColor: Color {
        if isActive {
            return Color.primary
        } else if isHovered {
            return Color.primary.opacity(0.68)
        } else {
            return inactiveUnderlineColor
        }
    }
    
    public var body: some View {
        Button(action: action) {
            VStack(spacing: 1.31) {
                content()
                    .frame(width: 20, height: 20)
                
                // Подчеркивание снизу, чуть шире иконки (22px).
                // Под активной кнопкой — цвет контура иконки (primary).
                // Под неактивной кнопкой — на 20% светлее.
                RoundedRectangle(cornerRadius: 1)
                    .fill(underlineColor)
                    .frame(width: 22, height: 2)
            }
            .frame(width: 26, height: 27)
            .background(Color.clear)
            .foregroundColor(iconColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .help(tooltip)
    }
}

/// Индикатор состояния подключения телефона (Серый = отключен, Мигающий оранжевый = подключение, Салатовый = подключен)
public struct PhoneConnectionIndicatorView: View {
    public let isConnected: Bool
    public let isConnecting: Bool
    public let size: CGFloat
    
    public init(isConnected: Bool, isConnecting: Bool, size: CGFloat = 7) {
        self.isConnected = isConnected
        self.isConnecting = isConnecting
        self.size = size
    }
    
    public var body: some View {
        if isConnecting {
            PulsingIndicatorCircle(size: size)
        } else {
            Circle()
                .fill(isConnected ? Color(red: 0.35, green: 0.88, blue: 0.35) : Color(nsColor: .systemGray).opacity(0.5))
                .frame(width: size, height: size)
        }
    }
}

private struct PulsingIndicatorCircle: View {
    let size: CGFloat
    @State private var isDimmed: Bool = false
    
    init(size: CGFloat = 7) {
        self.size = size
    }
    
    var body: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: size, height: size)
            .opacity(isDimmed ? 0.2 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    isDimmed = true
                }
            }
    }
}

private struct NavArrowButton: View {
    let systemImage: String
    let tooltip: String
    let isEnabled: Bool
    let color: Color
    let action: () -> Void
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isEnabled ? (isHovered ? Color.primary : color) : color.opacity(0.3))
                .frame(width: 26, height: 24)
                .background(isHovered && isEnabled ? Color(nsColor: .controlColor).opacity(0.35) : Color.clear)
                .cornerRadius(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(tooltip)
    }
}

// MARK: - Кнопка обновления содержимого панели

private struct PaneRefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isRefreshing ? .accentColor : (isHovered ? .primary : .secondary))
                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                .animation(isRefreshing ? Animation.linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                .frame(width: 24, height: 24)
                .background(isHovered ? Color(nsColor: .controlColor).opacity(0.35) : Color.clear)
                .cornerRadius(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Обновить содержимое панели (Cmd+R)")
    }
}

// MARK: - Pull-to-refresh: оттяжка списка вниз двумя пальцами тачпада

/// Слушает не сырые события колеса, а саму прокрутку списка: оттяжка («резинка») выше верхней границы
/// содержимого и есть жест. Обновление срабатывает при отпускании, если оттяжка достигла порога.
/// Нужный `NSScrollView` определяется по уведомлениям `willStartLiveScroll` — без поиска по иерархии и без перехвата событий.
public struct TrackpadSwipeRefreshView: NSViewRepresentable {
    public let side: PaneSide
    public let vm: DualPaneViewModel
    public let onPullProgress: (CGFloat) -> Void
    public let onRefreshTriggered: () -> Void

    public init(
        side: PaneSide,
        vm: DualPaneViewModel,
        onPullProgress: @escaping (CGFloat) -> Void,
        onRefreshTriggered: @escaping () -> Void
    ) {
        self.side = side
        self.vm = vm
        self.onPullProgress = onPullProgress
        self.onRefreshTriggered = onRefreshTriggered
    }

    public func makeNSView(context: Context) -> PullObserverView {
        let view = PullObserverView()
        update(view)
        return view
    }

    public func updateNSView(_ nsView: PullObserverView, context: Context) {
        update(nsView)
    }

    private func update(_ view: PullObserverView) {
        view.side = side
        view.vm = vm
        view.onPullProgress = onPullProgress
        view.onRefreshTriggered = onRefreshTriggered
    }

    public final class PullObserverView: NSView {
        public var side: PaneSide = .left
        public weak var vm: DualPaneViewModel?
        public var onPullProgress: ((CGFloat) -> Void)?
        public var onRefreshTriggered: (() -> Void)?

        /// Оттяжка (pt), с которой отпускание запускает обновление.
        private let triggerOverscroll: CGFloat = 18
        /// Остаток оттяжки (pt), с которого возврат списка считается завершённым.
        private let settledOverscroll: CGFloat = 3

        private weak var trackedScrollView: NSScrollView?
        private var peakOverscroll: CGFloat = 0
        private var didTrigger = false
        private var observers: [NSObjectProtocol] = []
        private var boundsObserver: NSObjectProtocol?

        public override func hitTest(_ point: NSPoint) -> NSView? { nil }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            if window != nil { startObserving() }
        }

        deinit { stopObserving() }

        private func startObserving() {
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: nil, queue: .main) { [weak self] note in
                    guard let sv = note.object as? NSScrollView else { return }
                    MainActor.assumeIsolated { self?.beginTracking(sv) }
                },
                center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: nil, queue: .main) { [weak self] note in
                    guard let sv = note.object as? NSScrollView else { return }
                    MainActor.assumeIsolated { self?.endTracking(sv) }
                }
            ]
        }

        private func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            detachBoundsObserver()
            trackedScrollView = nil
            vm?.setScrollBouncing(false, side: side)
        }

        private func detachBoundsObserver() {
            if let token = boundsObserver { NotificationCenter.default.removeObserver(token) }
            boundsObserver = nil
        }

        /// Прокрутка относится к этой панели, если она в нашем окне, вертикальная и её центр лежит внутри панели.
        private func belongsToPane(_ sv: NSScrollView) -> Bool {
            guard let window, sv.window === window, sv.hasVerticalScroller, !isHidden else { return false }
            let center = NSPoint(x: sv.bounds.midX, y: sv.bounds.midY)
            return bounds.contains(convert(center, from: sv))
        }

        private func overscroll(of sv: NSScrollView) -> CGFloat {
            let clip = sv.contentView
            return max(0, -(clip.bounds.origin.y + clip.contentInsets.top))
        }

        private func beginTracking(_ sv: NSScrollView) {
            guard belongsToPane(sv) else { return }
            detachBoundsObserver()
            trackedScrollView = sv
            peakOverscroll = 0
            didTrigger = false
            sv.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: sv.contentView, queue: .main
            ) { [weak self, weak sv] _ in
                guard let sv else { return }
                MainActor.assumeIsolated { self?.scrolled(sv) }
            }
        }

        /// Отпускание жеста = оттяжка достигла порога и начала возвращаться. Ждать конца всей прокрутки нельзя:
        /// `didEndLiveScroll` приходит только после полного возврата «резинки».
        private func scrolled(_ sv: NSScrollView) {
            let pulled = overscroll(of: sv)
            if pulled < peakOverscroll, peakOverscroll >= triggerOverscroll, !didTrigger {
                triggerRefresh()
            }
            peakOverscroll = max(peakOverscroll, pulled)
            onPullProgress?(didTrigger ? 0 : min(1, pulled / triggerOverscroll))
            // Визуально «резинка» уже на месте задолго до didEndLiveScroll: не ждём её длинный хвост.
            if didTrigger, pulled <= settledOverscroll { vm?.setScrollBouncing(false, side: side) }
        }

        private func endTracking(_ sv: NSScrollView) {
            guard sv === trackedScrollView else { return }
            if peakOverscroll >= triggerOverscroll, !didTrigger { triggerRefresh() }
            vm?.setScrollBouncing(false, side: side)
            detachBoundsObserver()
            trackedScrollView = nil
            peakOverscroll = 0
            onPullProgress?(0)
        }

        private func triggerRefresh() {
            didTrigger = true
            guard let vm else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            if vm.activePane != side { vm.activePane = side }
            vm.setScrollBouncing(true, side: side)
            vm.refreshPaneToActiveTab(side: side)
            onRefreshTriggered?()
        }
    }
}

// MARK: - Кнопка зеркального отражения панелей в подвале

private struct PaneMirrorButton: View {
    let arrow: String
    let tooltip: String
    let action: () -> Void
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: action) {
            Text(arrow)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(isHovered ? .primary : Color(nsColor: .secondaryLabelColor))
                .frame(width: 22, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isHovered ? Color(nsColor: .separatorColor).opacity(0.35) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .help(tooltip)
    }
}

