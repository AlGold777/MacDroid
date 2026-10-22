import SwiftUI

public struct BottomToolbarView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    
    public init() {}
    
    public var body: some View {
        ZStack {
            // Центральный блок действий
            HStack(spacing: 2) {
                ToolButton(icon: .copy, tooltip: "Копировать (F5)") { vm.triggerCopy() }
                ToolbarSeparator()
                ToolButton(icon: .move, tooltip: "Переместить (F6)") { vm.triggerMove() }
                ToolbarSeparator()
                ToolButton(icon: .newFolder, tooltip: "Новая папка (F7)") { vm.prepareNewFolder() }
                ToolbarSeparator()
                ToolButton(
                    icon: .info,
                    tooltip: "Свойства (Cmd+I) • Двойной клик: скопировать путь",
                    doubleClickAction: { vm.copySelectedPath() }
                ) {
                    vm.triggerProperties()
                }
                ToolbarSeparator()
                ToolButton(icon: .delete, tooltip: "Удалить (F8 / Delete)") { vm.triggerDelete() }
                ToolbarSeparator()
                ToolButton(icon: .rename, tooltip: "Групповое переименование (Ctrl+M)") { vm.triggerBatchRename() }
                ToolbarSeparator()
                ToolButton(icon: .comparePanes, tooltip: "Сравнить папки", isActive: vm.isComparing) { vm.comparePanes() }
                ToolbarSeparator()
                ToolButton(
                    icon: .compareFiles,
                    tooltip: vm.isFileDiffActive ? "Закрыть сравнение файлов (Esc)" : "Сравнить файлы (по содержимому)",
                    isActive: vm.isFileDiffActive
                ) {
                    vm.triggerFileDiff()
                }
            }
            
            // Правая часть
            HStack(spacing: 2) {
                Spacer()
                
                if vm.isTransferMinimized && vm.currentTransferTask != nil && !vm.isTransferCompleted {
                    Button(action: { vm.showQueueDialog = true }) {
                        HStack(spacing: 6) {
                            ProgressView(value: vm.transferProgress, total: 1.0)
                                .progressViewStyle(.circular)
                                .controlSize(.mini)
                            Text("\(Int(vm.transferProgress * 100))%")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.primary)
                            if !vm.currentTransferFileName.isEmpty {
                                Text(vm.currentTransferFileName)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 130)
                            }
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Свёрнутая операция: \(vm.currentTransferFileName) (\(Int(vm.transferProgress * 100))%). Нажмите для открытия треков очереди.")
                    
                    ToolbarSeparator()
                }
                
                ToolButton(icon: .search, tooltip: "Поиск файлов (Cmd+F)") { vm.toggleSearch(side: vm.activePane) }
                ToolbarSeparator()
                
                QueueToolbarButton(count: vm.queueManager.tasks.count) {
                    vm.showQueueDialog = true
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

public struct ToolbarSeparator: View {
    public init() {}
    
    public var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.65))
            .frame(width: 1, height: 15)
            .padding(.horizontal, 2)
    }
}

public struct QueueToolbarButton: View {
    public let count: Int
    public let action: () -> Void
    @State private var isHovered: Bool = false
    
    public init(count: Int, action: @escaping () -> Void) {
        self.count = count
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                ToolbarIconView(icon: .queue, size: 14.4, lineWidth: 1.3)
                    .foregroundColor(isHovered ? .primary : Color(nsColor: .darkGray))
                Text("Очередь (\(count))")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isHovered ? .primary : Color(nsColor: .darkGray))
            .padding(.horizontal, 8)
            .frame(height: 25)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color(nsColor: .separatorColor).opacity(0.22) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .help("Очередь операций")
    }
}

public struct ToolButton: View {
    public let icon: ToolbarIcon?
    public let systemImage: String?
    public let tooltip: String
    public let isActive: Bool
    public let isEnabled: Bool
    public let width: CGFloat
    public let height: CGFloat
    public let iconSize: CGFloat?
    public let doubleClickAction: (() -> Void)?
    public let action: () -> Void
    
    @State private var isHovered: Bool = false
    @State private var isDoubleClickedFeedback: Bool = false
    @State private var clickWorkItem: DispatchWorkItem? = nil
    
    public init(
        icon: ToolbarIcon,
        tooltip: String,
        isActive: Bool = false,
        isEnabled: Bool = true,
        width: CGFloat = 28,
        height: CGFloat = 25,
        iconSize: CGFloat? = nil,
        doubleClickAction: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.systemImage = nil
        self.tooltip = tooltip
        self.isActive = isActive
        self.isEnabled = isEnabled
        self.width = width
        self.height = height
        self.iconSize = iconSize
        self.doubleClickAction = doubleClickAction
        self.action = action
    }
    
    public init(
        systemImage: String,
        tooltip: String,
        isActive: Bool = false,
        isEnabled: Bool = true,
        width: CGFloat = 28,
        height: CGFloat = 25,
        iconSize: CGFloat? = nil,
        doubleClickAction: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = nil
        self.systemImage = systemImage
        self.tooltip = tooltip
        self.isActive = isActive
        self.isEnabled = isEnabled
        self.width = width
        self.height = height
        self.iconSize = iconSize
        self.doubleClickAction = doubleClickAction
        self.action = action
    }
    
    private func handleClick() {
        guard isEnabled else { return }
        guard let doubleClick = doubleClickAction else {
            action()
            return
        }
        
        if let pending = clickWorkItem {
            pending.cancel()
            clickWorkItem = nil
            withAnimation(.easeInOut(duration: 0.15)) {
                isDoubleClickedFeedback = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isDoubleClickedFeedback = false
                }
            }
            doubleClick()
        } else {
            let work = DispatchWorkItem {
                clickWorkItem = nil
                action()
            }
            clickWorkItem = work
            let interval = (NSEvent.doubleClickInterval > 0 && NSEvent.doubleClickInterval < 0.6)
                ? NSEvent.doubleClickInterval
                : 0.28
            DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
        }
    }
    
    public var body: some View {
        Button(action: handleClick) {
            Group {
                if isDoubleClickedFeedback {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                } else if let icon = icon {
                    ToolbarIconView(icon: icon, size: iconSize ?? 16.7, lineWidth: 1.3)
                } else if let systemImage = systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .foregroundColor(
                isDoubleClickedFeedback
                    ? .green
                    : (!isEnabled
                        ? Color.secondary.opacity(0.35)
                        : (isActive ? .accentColor : (isHovered ? .primary : Color(nsColor: .darkGray))))
            )
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isActive
                            ? Color.accentColor.opacity(0.18)
                            : ((isHovered && isEnabled) ? Color(nsColor: .separatorColor).opacity(0.22) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        isActive ? Color.accentColor.opacity(0.4) : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .help(isDoubleClickedFeedback ? "Путь скопирован в буфер обмена!" : tooltip)
    }
}

public struct TopToolbarRefreshButton: View {
    public let isRefreshing: Bool
    public let action: () -> Void
    @State private var isHovered: Bool = false
    
    public init(isRefreshing: Bool, action: @escaping () -> Void) {
        self.isRefreshing = isRefreshing
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            ToolbarIconView(icon: .refresh, size: 16.7, lineWidth: 1.3)
                .foregroundColor(isRefreshing ? .accentColor : (isHovered ? .primary : Color(nsColor: .darkGray)))
                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                .animation(isRefreshing ? Animation.linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                .frame(width: 28, height: 25)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color(nsColor: .separatorColor).opacity(0.22) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .help("Обновить обе панели (Cmd+R)")
    }
}

public struct TopToolbarCenterSplitResetButton: View {
    @ObservedObject var vm: DualPaneViewModel
    @State private var isHovered: Bool = false
    
    public init(vm: DualPaneViewModel) {
        self.vm = vm
    }
    
    public var body: some View {
        Button(action: {
            vm.resetSplitAndRefresh()
        }) {
            ToolbarIconView(icon: .centerSplitReset, size: 16.7, lineWidth: 1.25)
                .foregroundColor(
                    (vm.leftIsRefreshing || vm.rightIsRefreshing)
                        ? .accentColor
                        : (isHovered ? .primary : Color.secondary)
                )
                .opacity((vm.leftIsRefreshing || vm.rightIsRefreshing) ? 0.7 : 1.0)
                .frame(width: 28, height: 25)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color(nsColor: .separatorColor).opacity(0.18) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .help("Обновить обе панели и выровнять разделение по центру (Cmd+R)")
    }
}

public struct FolderSortIconView: View {
    public let mode: FolderSortMode
    public var size: CGFloat
    
    public init(mode: FolderSortMode, size: CGFloat = 16.7) {
        self.mode = mode
        self.size = size
    }
    
    public var body: some View {
        ToolbarIconView(icon: .list, size: size, lineWidth: 1.4)
    }
}

public struct TopToolbarFolderSortButton: View {
    public let mode: FolderSortMode
    public let action: () -> Void
    @State private var isHovered: Bool = false
    
    public init(mode: FolderSortMode, action: @escaping () -> Void) {
        self.mode = mode
        self.action = action
    }
    
    private var isSelected: Bool {
        mode == .separate
    }
    
    public var body: some View {
        Button(action: action) {
            FolderSortIconView(mode: mode, size: 16.7)
                .foregroundColor(isSelected ? .primary : (isHovered ? .primary : Color(nsColor: .darkGray)))
                .frame(width: 24.1, height: 21.7)
                .background(
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(
                            isSelected
                                ? Color(nsColor: .separatorColor).opacity(0.18)
                                : (isHovered ? Color(nsColor: .separatorColor).opacity(0.22) : Color.clear)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .stroke(
                            isSelected
                                ? Color(nsColor: .darkGray).opacity(0.65)
                                : (isHovered ? Color(nsColor: .separatorColor).opacity(0.35) : Color.clear),
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .help(mode == .separate
            ? "Режим сортировки: папки отдельно. Нажмите для сортировки вместе с файлами (как в Finder)"
            : "Режим сортировки: папки и файлы вместе (как в Finder). Нажмите для сортировки папок отдельно")
    }
}

public struct TopToolbarViewModeButton: View {
    public let mode: PaneViewMode
    public let action: () -> Void
    @State private var isHovered: Bool = false
    
    public init(mode: PaneViewMode, action: @escaping () -> Void) {
        self.mode = mode
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            ToolbarIconView(icon: mode == .table ? .viewGrid : .viewTable, size: 16.7, lineWidth: 1.3)
                .foregroundColor(mode == .grid ? .accentColor : (isHovered ? .primary : Color(nsColor: .darkGray)))
                .frame(width: 28, height: 25)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            mode == .grid
                                ? Color.accentColor.opacity(0.18)
                                : (isHovered ? Color(nsColor: .separatorColor).opacity(0.22) : Color.clear)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(mode == .grid ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .help(mode == .table ? "Включить режим сетки для активной панели (Cmd+2)" : "Включить режим списка для активной панели (Cmd+1)")
    }
}

public struct PanelLayoutModeSwitcher: View {
    public let mode: PanelLayoutMode
    public let onSelect: (PanelLayoutMode) -> Void
    @State private var hoveredMode: PanelLayoutMode? = nil
    
    public init(mode: PanelLayoutMode, onSelect: @escaping (PanelLayoutMode) -> Void) {
        self.mode = mode
        self.onSelect = onSelect
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            segmentButton(segmentMode: .dual, label: "T", tooltip: "Двухпанельный режим (T)")
            
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(width: 1, height: 14)
            
            segmentButton(segmentMode: .finder, label: "F", tooltip: "Режим Finder с боковой панелью (F)")
        }
        .frame(height: 23)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    
    @ViewBuilder
    private func segmentButton(segmentMode: PanelLayoutMode, label: String, tooltip: String) -> some View {
        let isSelected = (mode == segmentMode)
        let isHovered = (hoveredMode == segmentMode)
        
        Button(action: {
            onSelect(segmentMode)
        }) {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(white: 0.35))
                        .padding(1.5)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(nsColor: .separatorColor).opacity(0.25))
                        .padding(1.5)
                }
                
                Text(label)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(isSelected ? .white : (isHovered ? .primary : .secondary))
            }
            .frame(width: 23, height: 23)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredMode = hovering ? segmentMode : nil
        }
        .help(tooltip)
    }
}
