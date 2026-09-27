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
    @State private var isConnectHovered: Bool = false
    @State private var isPhoneHovered: Bool = false
    @State private var lastTabClickTime: Date = .distantPast
    @State private var lastClickedTabId: UUID? = nil
    @FocusState private var isPathInputFocused: Bool
    
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
                    if !newSelection.isEmpty && vm.activePane != .left {
                        vm.activePane = .left
                    }
                    vm.leftSelection = newSelection
                    if !newSelection.isEmpty {
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
                    if !newSelection.isEmpty {
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
            // Вкладки панели (Tabs)
            HStack(spacing: 3) {
                // Навигация: ↑ , ←, → слева от первой tab
                let navArrowColor = Color(nsColor: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? NSColor(white: 0.85, alpha: 0.7)
                        : NSColor(red: 28/255.0, green: 26/255.0, blue: 26/255.0, alpha: 0.7)
                })
                
                NavArrowButton(
                    systemImage: "chevron.up",
                    tooltip: "На уровень выше (Cmd+Up)",
                    isEnabled: true,
                    color: navArrowColor
                ) {
                    if vm.activePane != side { vm.activePane = side }
                    vm.navigateUp(side: side)
                }
                
                NavArrowButton(
                    systemImage: "chevron.left",
                    tooltip: "Назад (Cmd+[)",
                    isEnabled: vm.canNavigateBack(side: side),
                    color: navArrowColor
                ) {
                    if vm.activePane != side { vm.activePane = side }
                    vm.navigateBack(side: side)
                }
                
                NavArrowButton(
                    systemImage: "chevron.right",
                    tooltip: "Вперёд (Cmd+])",
                    isEnabled: vm.canNavigateForward(side: side),
                    color: navArrowColor
                ) {
                    if vm.activePane != side { vm.activePane = side }
                    vm.navigateForward(side: side)
                }
                
                ForEach(tabs) { tab in
                    HStack(spacing: 4) {
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
                                .font(.system(size: 13, weight: .regular))
                                .lineLimit(1)
                        }
                        
                        if tab.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 6.3))
                                .foregroundColor(.secondary)
                                .rotationEffect(.degrees(30))
                                .offset(x: 1.5, y: -1.5)
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
                            if tab.id != activeTabId {
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
                
                // Переключатель режима отображения: Сетка (галерея) / Список (таблица)
                let currentMode = (side == .left ? vm.leftViewMode : vm.rightViewMode)
                Button(action: {
                    if vm.activePane != side { vm.activePane = side }
                    vm.toggleViewMode(for: side)
                }) {
                    Image(systemName: currentMode == .table ? "square.grid.2x2" : "line.3.horizontal")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(currentMode == .grid ? .accentColor : .secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(currentMode == .table ? "Включить режим сетки (просмотрщик) [Cmd+2]" : "Включить режим списка (таблица) [Cmd+1]")
                .keyboardShortcut(currentMode == .table ? KeyEquivalent("2") : KeyEquivalent("1"), modifiers: .command)
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            // Заголовок панели: выбор источника (диска), путь (хлебные крошки), фильтр
            HStack(spacing: 6) {
                // 1. Выбор источника (диска): кнопки Mac, Phone и автоматически появляющаяся USB
                HStack(spacing: 3) {
                    let currentSrc = (side == .left ? vm.leftSource : vm.rightSource)
                    let currentP = (side == .left ? vm.leftPath : vm.rightPath)
                    let activeUsb = vm.detectedUsbDrives.first(where: { currentP.hasPrefix($0.path) })
                    let isMacActive = (currentSrc == .localMac && activeUsb == nil)
                    let isPhoneActive = (currentSrc == .remotePhone && activeUsb == nil)
                    let isUsbActive = (activeUsb != nil)
                    
                    // Кнопка Mac
                    Button(action: {
                        vm.changeSource(to: .localMac, side: side)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "laptopcomputer")
                                .font(.system(size: 10))
                            Text("Mac")
                                .font(.system(size: 13, weight: isMacActive ? .semibold : .medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.clear)
                        .foregroundColor(isMacActive ? .primary : .secondary)
                        .overlay(alignment: .top) {
                            if isMacActive {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Color.blue)
                                    .frame(height: 3)
                            }
                        }
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("Локальные файлы Mac")
                    
                    // Кнопка Phone
                    Button(action: {
                        vm.changeSource(to: .remotePhone, side: side)
                    }) {
                        HStack(spacing: 4) {
                            PhoneConnectionIndicatorView(
                                isConnected: vm.isPhoneConnected && vm.remoteDriver.isConnected,
                                isConnecting: vm.isConnectingPhone
                            )
                            Text("Phone")
                                .font(.system(size: 13, weight: isPhoneActive ? .semibold : .medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(isPhoneHovered ? Color(nsColor: .controlColor).opacity(0.35) : Color.clear)
                        .foregroundColor(isPhoneActive ? .primary : .secondary)
                        .overlay(alignment: .top) {
                            if isPhoneActive {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Color.blue)
                                    .frame(height: 3)
                            }
                        }
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isPhoneHovered = hovering
                    }
                    .help(vm.isConnectingPhone ? "Подключение к телефону..." : ((vm.isPhoneConnected && vm.remoteDriver.isConnected) ? "Телефон подключен (правый клик: контекстное меню)" : "Телефон не подключен (нажмите для перехода или правый клик: Connect)"))
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
                    
                    // Автоматическая кнопка USB при подключении внешнего накопителя
                    if !vm.detectedUsbDrives.isEmpty {
                        if vm.detectedUsbDrives.count == 1, let singleUsb = vm.detectedUsbDrives.first {
                            Button(action: {
                                vm.switchToUsbDrive(singleUsb, side: side)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "externaldrive.fill")
                                        .font(.system(size: 10))
                                    Text("USB")
                                        .font(.system(size: 13, weight: isUsbActive ? .semibold : .medium))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.clear)
                                .foregroundColor(isUsbActive ? .primary : .secondary)
                                .overlay(alignment: .top) {
                                    if isUsbActive {
                                        RoundedRectangle(cornerRadius: 1.5)
                                            .fill(Color.blue)
                                            .frame(height: 3)
                                    }
                                }
                                .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                            .help("Внешний USB накопитель: \(singleUsb.name)")
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
                                HStack(spacing: 4) {
                                    Image(systemName: "externaldrive.fill")
                                        .font(.system(size: 10))
                                    Text("USB")
                                        .font(.system(size: 13, weight: isUsbActive ? .semibold : .medium))
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 8))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.clear)
                                .foregroundColor(isUsbActive ? .primary : .secondary)
                                .overlay(alignment: .top) {
                                    if isUsbActive {
                                        RoundedRectangle(cornerRadius: 1.5)
                                            .fill(Color.blue)
                                            .frame(height: 3)
                                    }
                                }
                                .cornerRadius(4)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Выбор внешнего USB накопителя")
                        }
                    }
                }
                .fixedSize()
                
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
                                        Text(crumb.isRoot ? "›" : crumb.title)
                                            .font(.system(size: 13, weight: crumb.isRoot ? .regular : .medium))
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)

                                    if index < crumbs.count - 1 {
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
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { beginPathEditing() }
                        .padding(.top, 5)
                        .offset(y: -2.5)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) {
                        Color.clear
                            .frame(height: 5)
                            .contentShape(Rectangle())
                            .onTapGesture { beginPathEditing() }
                    }
                    .contextMenu { pathContextMenu }
                    .help("Нажмите над крошками, чтобы ввести путь; нажмите на папку, чтобы перейти")
                }
                
                // Кнопка быстрого соединения (слева от поля фильтра, без текста)
                Button(action: {
                    if vm.isPhoneConnected && vm.remoteDriver.isConnected {
                        vm.disconnectPhone()
                    } else {
                        let currentSrc = (side == .left ? vm.leftSource : vm.rightSource)
                        let otherSrc = (side == .left ? vm.rightSource : vm.leftSource)
                        if currentSrc != .remotePhone && otherSrc != .remotePhone {
                            vm.changeSource(to: .remotePhone, side: side)
                        }
                        vm.connectPhone(forceActivate: false, isExplicit: true)
                    }
                }) {
                    Group {
                        if vm.isConnectingPhone {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.65)
                                .frame(width: 18, height: 18)
                        } else {
                            Image(systemName: "link")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(isConnectHovered ? Color(nsColor: .controlTextColor) : Color(nsColor: .systemGray))
                                .frame(width: 18, height: 18)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(vm.isConnectingPhone)
                .onHover { hovering in
                    isConnectHovered = hovering
                }
                .help(vm.isConnectingPhone ? "Подключение к телефону..." : ((vm.isPhoneConnected && vm.remoteDriver.isConnected) ? "Телефон подключен (клик: отключить, правый клик: меню)" : "Подключить телефон (Connect)"))
                .contextMenu {
                    if vm.isPhoneConnected && vm.remoteDriver.isConnected {
                        Button(action: {
                            vm.disconnectPhone()
                        }) {
                            Label("Disconnect", systemImage: "link.badge.slash")
                        }
                    } else {
                        Button(action: {
                            let currentSrc = (side == .left ? vm.leftSource : vm.rightSource)
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
                
                // 3. Поле фильтра (с иконкой, кнопкой очистки и очисткой по Esc)
                HStack(spacing: 3) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundColor(.secondary)
                        .font(.system(size: 10))
                    
                    TextField("Фильтр...", text: (side == .left ? $vm.leftFilter : $vm.rightFilter))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
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
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help("Очистить фильтр (Esc)")
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .frame(width: 76)
                .padding(.trailing, 6)
            }
            .padding(6)
            .background(Color(nsColor: .windowBackgroundColor))
            
            if isStale {
                HStack(spacing: 8) {
                    Text("Phone Offline")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Spacer()
                    Button(action: {
                        vm.showPairingDialog = true
                    }) {
                        Label("Connect", systemImage: "wifi")
                            .font(.system(size: 12))
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
            } else if (side == .left ? vm.leftViewMode : vm.rightViewMode) == .grid {
                // Режим графического просмотрщика папок (Сетка / Галерея)
                GridSettingsBarView(side: side)
                Divider()
                FileGridPaneView(side: side)
            } else {
                // Таблица списка файлов с Drag & Drop и сравнением
                Table(items, selection: selectionBinding, sortOrder: sortOrderBinding) {
                    TableColumn("Имя", value: \FileItem.name) { item in
                        let isHoverFolder = (item.isDirectory && vm.dragHoverSide == side && vm.dragHoverFolderId == item.id)
                        let rowIndex = items.firstIndex(where: { $0.id == item.id }) ?? -1
                        let isInsertTop = (vm.dragHoverSide == side && vm.dragHoverFolderId == nil && vm.dragInsertionIndex == rowIndex)
                        let isInsertBottom = (vm.dragHoverSide == side && vm.dragHoverFolderId == nil && vm.dragInsertionIndex == items.count && rowIndex == items.count - 1)
                        
                        HStack(spacing: 6) {
                            Image(systemName: item.isDirectory ? "folder.fill" : fileIconName(for: item.name))
                                .foregroundColor(item.isDirectory ? .yellow : .blue)
                            
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
                                .frame(height: 22)
                            } else {
                                Text(item.name)
                                    .font(.system(size: 13))
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
                        .overlay(alignment: .top) {
                            if isInsertTop {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if isInsertBottom {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                            }
                        }
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
                        let isHoverFolder = (item.isDirectory && vm.dragHoverSide == side && vm.dragHoverFolderId == item.id)
                        let rowIndex = items.firstIndex(where: { $0.id == item.id }) ?? -1
                        let isInsertTop = (vm.dragHoverSide == side && vm.dragHoverFolderId == nil && vm.dragInsertionIndex == rowIndex)
                        let isInsertBottom = (vm.dragHoverSide == side && vm.dragHoverFolderId == nil && vm.dragInsertionIndex == items.count && rowIndex == items.count - 1)
                        
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
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Rectangle()
                                .fill(isHoverFolder ? Color.accentColor.opacity(0.35) : Color.clear)
                        )
                        .overlay(alignment: .top) {
                            if isInsertTop {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if isInsertBottom {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                            }
                        }
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            print("DUAL_PANE: Cell double tap on \(item.name)")
                            vm.openItem(item: item, side: side)
                        })
                    }
                    .width(min: 80, ideal: 100, max: 120)
                    
                    TableColumn("Дата изменения", value: \FileItem.mtime) { item in
                        let isHoverFolder = (item.isDirectory && vm.dragHoverSide == side && vm.dragHoverFolderId == item.id)
                        let rowIndex = items.firstIndex(where: { $0.id == item.id }) ?? -1
                        let isInsertTop = (vm.dragHoverSide == side && vm.dragHoverFolderId == nil && vm.dragInsertionIndex == rowIndex)
                        let isInsertBottom = (vm.dragHoverSide == side && vm.dragHoverFolderId == nil && vm.dragInsertionIndex == items.count && rowIndex == items.count - 1)
                        
                        HStack {
                            Text(formatDate(item.mtime))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 4, topTrailingRadius: 4)
                                .fill(isHoverFolder ? Color.accentColor.opacity(0.35) : Color.clear)
                        )
                        .overlay(alignment: .top) {
                            if isInsertTop {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if isInsertBottom {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                            }
                        }
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
                        vm.triggerQuickLook(preferNativeQuickLook: true)
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.return, phases: .down) { _ in
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
                .onDrop(of: [DualPaneViewModel.dragUTType, UTType.fileURL.identifier, UTType.utf8PlainText.identifier], delegate: PaneTableDropDelegate(side: side, vm: vm, items: items))
            }
            
            Divider()
            
            // Подвал панели: объекты, выделение и свободное место
            HStack {
                let selectedIds = (side == .left) ? vm.leftSelection : vm.rightSelection
                if selectedIds.isEmpty {
                    Text("\(items.count) объектов")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    let selectedItems = items.filter { selectedIds.contains($0.id) || selectedIds.contains($0.path) }
                    let selectedBytes = selectedItems.reduce(0) { $0 + $1.size }
                    Text("Выделено: \(selectedItems.count) из \(items.count) (\(formatBytes(selectedBytes)))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if freeSpace.total > 0 {
                    Text("Свободно: \(formatBytes(freeSpace.free)) из \(formatBytes(freeSpace.total))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            if vm.activePane != side {
                vm.activePane = side
            }
        })
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

        Button("Удалить (F8)", role: .destructive) {
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

    @ViewBuilder
    private var pathContextMenu: some View {
        Button("Скопировать путь") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(currentPath, forType: .string)
        }
        Button("Вставить") {
            guard let pastedPath = NSPasteboard.general.string(forType: .string), !pastedPath.isEmpty else { return }
            vm.startEditingPath(side: side)
            vm.manualPathInput = pastedPath
        }
        .disabled(NSPasteboard.general.string(forType: .string)?.isEmpty != false)
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

// MARK: - In-place Inline Renaming Text Field
public final class CustomRenameNSTextField: NSTextField {
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.command),
           KeyCommandMonitor.performTextShortcut(keyCode: Int(event.keyCode), targetResponder: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
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
        textField.stringValue = text
        textField.isBordered = true
        textField.bezelStyle = .roundedBezel
        textField.focusRingType = .exterior
        textField.font = NSFont.systemFont(ofSize: 12)
        textField.delegate = context.coordinator
        textField.isEditable = true
        textField.isSelectable = true
        textField.drawsBackground = true
        textField.backgroundColor = NSColor.white
        textField.textColor = NSColor.black
        
        DispatchQueue.main.async {
            guard let window = textField.window else { return }
            window.makeFirstResponder(textField)
            
            // Выделяем имя файла без расширения, если это обычный файл
            if let editor = textField.currentEditor() {
                let name = textField.stringValue
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
            guard !isHandled else { return }
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
        return tv === activeTv
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
        
        public static func focusAndScrollToItem(id: String, side: PaneSide) {
            DispatchQueue.main.async {
                let tv = (side == .left) ? leftTableView : rightTableView
                let items = (side == .left) ? (leftVM?.leftItems ?? []) : (rightVM?.rightItems ?? [])
                guard let index = items.firstIndex(where: { $0.id == id || $0.path == id }) else { return }
                tv?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                tv?.scrollRowToVisible(index)
                tv?.window?.makeFirstResponder(tv)
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
        
        deinit {
            longPressWorkItem?.cancel()
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
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
            tv.intercellSpacing = NSSize(width: 0, height: tv.intercellSpacing.height)
            NotificationCenter.default.removeObserver(self, name: NSTableView.selectionDidChangeNotification, object: nil)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onTableSelectionDidChange(_:)),
                name: NSTableView.selectionDidChangeNotification,
                object: tv
            )
            setupEventMonitor()
        }
        
        @objc private func onTableSelectionDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTableView, tv === hookedTableView else { return }
            let selectedRow = tv.selectedRow
            guard selectedRow >= 0 && selectedRow < items.count else { return }
            let item = items[selectedRow]
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let vm = self.vm else { return }
                if vm.activePane != self.side {
                    vm.activePane = self.side
                }
                if self.side == .left {
                    if vm.leftSelection != [item.id] {
                        vm.leftSelection = [item.id]
                    }
                } else {
                    if vm.rightSelection != [item.id] {
                        vm.rightSelection = [item.id]
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
                
                // KeyDown handling
                if event.type == .keyDown {
                    self.longPressWorkItem?.cancel()
                    self.longPressWorkItem = nil
                    
                    // Если фокус находится в любом поле ввода текста (поле фильтра, пути, модальном окне),
                    // обрабатываем Ctrl+V, Ctrl+C, Ctrl+X, Ctrl+A через KeyCommandMonitor
                    if let firstResponder = tv.window?.firstResponder {
                        if firstResponder is NSText || firstResponder is NSTextView || firstResponder is NSTextField {
                            if KeyCommandMonitor.handleEvent(event) == nil {
                                return nil
                            }
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
                            self.vm?.triggerQuickLook(preferNativeQuickLook: true)
                            return nil
                        }
                    }
                    return event
                }
                
                if event.type == .leftMouseUp {
                    self.longPressWorkItem?.cancel()
                    self.longPressWorkItem = nil
                    return event
                }
                
                if event.type == .leftMouseDragged {
                    let currLoc = event.locationInWindow
                    let dist = hypot(currLoc.x - self.mouseDownLocation.x, currLoc.y - self.mouseDownLocation.y)
                    if dist > 4 {
                        self.longPressWorkItem?.cancel()
                        self.longPressWorkItem = nil
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
        let utTypes: [UTType] = [
            UTType(DualPaneViewModel.dragUTType) ?? .data,
            .fileURL,
            .utf8PlainText,
            .plainText,
            .data,
            .item
        ]
        let providers = info.itemProviders(for: utTypes)
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
                return
            } else {
                // Наведение между файлами (или на обычный файл) -> синяя линия между файлами
                Self.springLoadTimer?.cancel()
                Self.springLoadTimer = nil
                Self.currentSpringLoadFolderId = nil
                
                let insertRow = isInsertTop ? targetRow : targetRow + 1
                vm.dragHoverSide = side
                vm.dragHoverFolderId = nil
                vm.dragInsertionIndex = insertRow
                return
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

/// Индикатор состояния подключения телефона (Серый = отключен, Мигающий оранжевый = подключение, Салатовый = подключен)
public struct PhoneConnectionIndicatorView: View {
    public let isConnected: Bool
    public let isConnecting: Bool
    
    public init(isConnected: Bool, isConnecting: Bool) {
        self.isConnected = isConnected
        self.isConnecting = isConnecting
    }
    
    public var body: some View {
        if isConnecting {
            PulsingIndicatorCircle()
        } else {
            Circle()
                .fill(isConnected ? Color(red: 0.35, green: 0.88, blue: 0.35) : Color(nsColor: .systemGray).opacity(0.5))
                .frame(width: 7, height: 7)
        }
    }
}

private struct PulsingIndicatorCircle: View {
    @State private var isDimmed: Bool = false
    
    var body: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 7, height: 7)
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
