import SwiftUI

public struct MainContentView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    @Environment(\.colorScheme) var colorScheme
    
    public init() {}
    
    public var body: some View {
        GeometryReader { fullGeo in
            VStack(spacing: 0) {
                let minHeight: CGFloat = 160
                let maxHeight = max(minHeight, fullGeo.size.height - 120)
                let defaultHeight = max(minHeight, min(420, fullGeo.size.height * 0.45))
                let baseHeight = min(maxHeight, max(minHeight, vm.fileDiffHeight ?? defaultHeight))
                
                // Если сравнение активно и примагничено сверху:
                if vm.isFileDiffActive && vm.fileDiffDockPosition == .top {
                    FileDiffOverlayView(
                        baseHeight: baseHeight,
                        minHeight: minHeight,
                        maxHeight: maxHeight
                    )
                    .environmentObject(vm)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    
                    Divider()
                }
                
                let sidebarWidth: CGFloat = 166
                let availableWidth = max(400, fullGeo.size.width - (vm.panelLayoutMode == .finder ? sidebarWidth : 0))
                let paneIdealWidth = availableWidth / 2
                
                HSplitView {
                    if vm.panelLayoutMode == .finder {
                        FinderSidebarView()
                            .frame(minWidth: 145, idealWidth: sidebarWidth, maxWidth: 220)
                    }
                    PaneView(side: .left)
                        .frame(minWidth: 200, idealWidth: paneIdealWidth)
                    PaneView(side: .right)
                        .frame(minWidth: 200, idealWidth: paneIdealWidth)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Если сравнение активно и примагничено снизу:
                if vm.isFileDiffActive && vm.fileDiffDockPosition == .bottom {
                    Divider()
                    
                    FileDiffOverlayView(
                        baseHeight: baseHeight,
                        minHeight: minHeight,
                        maxHeight: maxHeight
                    )
                    .environmentObject(vm)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .coordinateSpace(name: "MainContentSpace")
        .overlay(alignment: .topLeading) {
            // Глобальный непрозрачный тултип поверх всех панелей, хлебных крошек и элементов
            if vm.failedConnectionSide == nil,
               let side = vm.hoveredPhoneButtonSide,
               vm.isPhoneConnected && vm.remoteDriver.isConnected,
               let tooltipText = vm.connectedPhoneTooltip {
                let frame = side == .left ? vm.phoneButtonFrameLeft : vm.phoneButtonFrameRight
                if frame != .zero {
                    Text(tooltipText)
                        .font(.system(size: 13, weight: .medium))
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(colorScheme == .dark ? Color(red: 0.16, green: 0.16, blue: 0.16) : Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.18), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 2)
                        .fixedSize()
                        .offset(x: frame.maxX + 3, y: frame.minY - 12)
                        .allowsHitTesting(false)
                        .zIndex(10000)
                }
            }
            
            if let side = vm.failedConnectionSide {
                let frame = side == .left ? vm.phoneButtonFrameLeft : vm.phoneButtonFrameRight
                if frame != .zero {
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .frame(width: 5000, height: 5000)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                vm.failedConnectionSide = nil
                            }
                            .offset(x: -2500, y: -2500)
                        
                        CompactConnectionPopoverView()
                            .environmentObject(vm)
                            .padding(.leading, 12)
                            .padding(.trailing, 4)
                            .padding(.vertical, 4)
                            .background(
                                PopoverBubbleShape(arrowWidth: 12, arrowHeight: 18, arrowYOffset: 16)
                                    .fill(Color(nsColor: .windowBackgroundColor))
                                    .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 3)
                                    .overlay(
                                        PopoverBubbleShape(arrowWidth: 12, arrowHeight: 18, arrowYOffset: 16)
                                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                                    )
                            )
                            // Position popover perfectly next to the phone button frame
                            // frame.maxX is right edge of button. frame.midY is vertical center.
                            // We offset y by -16 to align the arrow (which is 16px down in popover)
                            .offset(x: frame.maxX + 4, y: frame.midY - 16)
                    }
                    .zIndex(9999)
                }
            }
        }
        .toolbar {
            // 1. Слева: название программы и версия
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 6) {
                    Text("MacDroid Commander")
                        .font(.system(size: 13, weight: .semibold))
                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !version.isEmpty {
                        Text(version)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    
                    ToolbarSeparator()
                        .padding(.horizontal, 2)
                    
                    HStack(spacing: 2) {
                        ToolButton(icon: .copy, tooltip: "Копировать (F5)") { vm.triggerCopy() }
                        ToolButton(icon: .move, tooltip: "Переместить (F6)") { vm.triggerMove() }
                        ToolButton(icon: .newFolder, tooltip: "Новая папка (F7)") { vm.prepareNewFolder() }
                        ToolButton(
                            icon: .info,
                            tooltip: "Свойства (Cmd+I) • Двойной клик: скопировать путь",
                            doubleClickAction: { vm.copySelectedPath() }
                        ) {
                            vm.triggerProperties()
                        }
                    }
                }
            }
            
            // 2. Ровно посередине: иконки ⇦ ⇨ для визуального отражения противоположной панели
            ToolbarItem(placement: .principal) {
                HStack(spacing: 3) {
                    MirrorToolbarButton(
                        icon: .mirrorLeft,
                        tooltip: "Отразить правую панель в левой (⇦)"
                    ) {
                        vm.mirrorPane(from: .right, to: .left)
                    }
                    
                    MirrorToolbarButton(
                        icon: .mirrorRight,
                        tooltip: "Отразить левую панель в правой (⇨)"
                    ) {
                        vm.mirrorPane(from: .left, to: .right)
                    }
                }
            }
            
            // 3. Справа: действия, поиск, обновление обеих панелей, режим плитки для активной панели
            ToolbarItem(placement: .primaryAction) {
                TopToolbarTrailingActionsView(vm: vm)
            }
        }
        .sheet(isPresented: Binding(
            get: { vm.showNewFolderDialog && vm.fullscreenGridPaneSide == nil },
            set: { vm.showNewFolderDialog = $0 }
        )) {
            NewFolderModalView()
        }
        .sheet(isPresented: Binding(
            get: { vm.showRenameDialog && vm.fullscreenGridPaneSide == nil },
            set: { vm.showRenameDialog = $0 }
        )) {
            RenameModalView()
        }
        .sheet(isPresented: Binding(
            get: { vm.showPropertiesDialog && vm.fullscreenGridPaneSide == nil },
            set: { vm.showPropertiesDialog = $0 }
        )) {
            FilePropertiesModalView()
        }
        .sheet(isPresented: $vm.showTransferProgress) {
            TransferProgressModalView()
        }
        .sheet(isPresented: $vm.showQueueDialog) {
            TransferQueueModalView()
        }
        .sheet(item: $vm.batchRenameSession) { session in
            BatchRenameModalView(items: session.items, side: session.side) { mappings in
                vm.applyBatchRename(mappings: mappings, side: session.side)
            }
            .environmentObject(vm)
        }
        .sheet(isPresented: $vm.showConflictDialog) {
            if let conflict = vm.activeConflict {
                ConflictResolutionModalView(conflict: conflict) { strategy, applyToAll in
                    if applyToAll {
                        vm.rememberedStrategy = strategy
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { vm.showImageViewer && vm.fullscreenGridPaneSide == nil },
            set: { vm.showImageViewer = $0 }
        )) {
            ImageViewerModalView(images: vm.viewerImages, startIndex: vm.viewerStartIndex)
                .environmentObject(vm)
        }
        .sheet(isPresented: $vm.showPairingDialog) {
            PairingModalView()
        }
        .sheet(isPresented: $vm.showOperationReport) {
            if let report = vm.operationReport {
                OperationReportView(report: report)
            }
        }
        .sheet(isPresented: $vm.showSearchDialog) {
            SearchResultsView()
        }
        .sheet(isPresented: $vm.showCreateArchiveDialog) {
            CreateArchiveModalView()
                .environmentObject(vm)
        }
        .sheet(isPresented: $vm.showPathDisplaySettings) {
            PathDisplaySettingsModalView()
                .environmentObject(vm)
        }
        .alert("Ошибка файловой операции", isPresented: Binding(
            get: { vm.showErrorAlert && vm.fullscreenGridPaneSide == nil },
            set: { vm.showErrorAlert = $0 }
        )) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(vm.errorMessage)
        }
        .alert("Подтверждение удаления", isPresented: Binding(
            get: { vm.showDeleteConfirmDialog && vm.fullscreenGridPaneSide == nil },
            set: { vm.showDeleteConfirmDialog = $0 }
        )) {
            Button("Удалить", role: .destructive) {
                vm.confirmDelete()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            let activeSource = (vm.activePane == .left) ? vm.leftSource : vm.rightSource
            let count = (vm.activePane == .left) ? vm.leftSelection.count : vm.rightSelection.count
            if activeSource == .localMac {
                Text("Вы действительно хотите переместить в Корзину \(count) выбранных объектов?")
            } else {
                Text("ВНИМАНИЕ: На телефоне нет общей Корзины. \(count) объектов будут УДАЛЕНЫ БЕЗВОЗВРАТНО!")
            }
        }
        .onAppear {
            DualPaneViewModel.shared = vm
            KeyCommandMonitor.activeViewModel = vm
            KeyCommandMonitor.installGlobalMonitor()
            vm.hoveredPhoneButtonSide = nil
        }
    }
}

private struct MirrorToolbarButton: View {
    let icon: ToolbarIcon
    let tooltip: String
    let action: () -> Void
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: action) {
            ToolbarIconView(icon: icon, size: 14.4, lineWidth: 1.3)
                .foregroundColor(isHovered ? .primary : Color(nsColor: .darkGray))
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovered ? Color(nsColor: .separatorColor).opacity(0.25) : Color(nsColor: .controlColor).opacity(0.35))
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
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

private struct TopToolbarTrailingActionsView: View {
    @ObservedObject var vm: DualPaneViewModel
    
    var body: some View {
        HStack(spacing: 2) {
            ToolButton(
                icon: .navBack,
                tooltip: "Шаг назад (Cmd+[)",
                isEnabled: vm.canNavigateBack(side: vm.activePane)
            ) {
                vm.navigateBack(side: vm.activePane)
            }
            
            ToolButton(
                icon: .navForward,
                tooltip: "Шаг вперёд (Cmd+])",
                isEnabled: vm.canNavigateForward(side: vm.activePane)
            ) {
                vm.navigateForward(side: vm.activePane)
            }
            
            TopToolbarFilterView(vm: vm)
                .padding(.trailing, 2)
            
            ToolButton(icon: .rename, tooltip: "Групповое переименование (Ctrl+M)") { vm.triggerBatchRename() }
            ToolButton(icon: .comparePanes, tooltip: "Сравнить папки", isActive: vm.isComparing) { vm.comparePanes() }
            ToolButton(
                icon: .compareFiles,
                tooltip: vm.isFileDiffActive ? "Закрыть сравнение файлов (Esc)" : "Сравнить файлы (по содержимому)",
                isActive: vm.isFileDiffActive
            ) {
                vm.triggerFileDiff()
            }
            
            if vm.isTransferMinimized && vm.currentTransferTask != nil && !vm.isTransferCompleted {
                Button(action: { vm.showQueueDialog = true }) {
                    HStack(spacing: 5) {
                        ProgressView(value: vm.transferProgress, total: 1.0)
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                        Text("\(Int(vm.transferProgress * 100))%")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Свёрнутая операция: \(vm.currentTransferFileName) (\(Int(vm.transferProgress * 100))%). Нажмите для открытия очереди.")
            }
            
            ToolButton(icon: .search, tooltip: "Поиск файлов (Cmd+F)") { vm.showSearchDialog = true }
            
            ToolbarSeparator()
            
            TopToolbarRefreshButton(isRefreshing: vm.leftIsRefreshing || vm.rightIsRefreshing) {
                vm.refreshBothPanes()
            }
            
            let activeFolderSortMode = (vm.activePane == .left ? vm.leftFolderSortMode : vm.rightFolderSortMode)
            TopToolbarFolderSortButton(mode: activeFolderSortMode) {
                vm.toggleFolderSortMode(for: vm.activePane)
            }
            
            PanelLayoutModeSwitcher(mode: vm.panelLayoutMode) { newMode in
                vm.setPanelLayoutMode(newMode)
            }
            .padding(.leading, 6)
            .padding(.trailing, 6)
            
            let activeMode = (vm.activePane == .left ? vm.leftViewMode : vm.rightViewMode)
            TopToolbarViewModeButton(mode: activeMode) {
                vm.toggleViewMode(for: vm.activePane)
            }
        }
    }
}

private struct TopToolbarFilterView: View {
    @ObservedObject var vm: DualPaneViewModel
    
    var body: some View {
        HStack(spacing: 4) {
            ToolbarIconView(icon: .filter, size: 12.65, lineWidth: 1.3)
                .foregroundColor(Color(nsColor: .darkGray))
            
            TextField("Фильтр...", text: Binding(
                get: { vm.activeFilterText },
                set: { vm.activeFilterText = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .onExitCommand {
                vm.activeFilterText = ""
            }
            
            if !vm.activeFilterText.isEmpty {
                Button(action: {
                    vm.activeFilterText = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Очистить фильтр (Esc)")
            }
        }
        .padding(.horizontal, 6)
        .frame(width: 100, height: 23)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .help("Фильтр содержимого активной панели (\(vm.activePane == .left ? "левая" : "правая")) (Esc для очистки)")
    }
}

