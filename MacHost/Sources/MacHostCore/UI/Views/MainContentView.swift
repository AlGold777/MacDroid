import SwiftUI

public struct MainContentView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    @Environment(\.colorScheme) var colorScheme
    
    @State private var headerWindowWidth: CGFloat = 0

    public init() {}
    
    public var body: some View {
        GeometryReader { fullGeo in
            mainLayout(fullGeo: fullGeo)
                .onAppear { headerWindowWidth = fullGeo.size.width }
                .onChange(of: fullGeo.size.width) { _, width in headerWindowWidth = width }
        }
        .coordinateSpace(name: "MainContentSpace")
        .overlay(alignment: .topLeading) {
            tooltipAndPopoverOverlay
        }
        .overlay {
            if vm.isDuplicating {
                ZStack {
                    Color.black.opacity(vm.showDuplicationModal ? 0.22 : 0.0001)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Блокируем любые клики по окну во время дублирования
                        }
                    
                    if vm.showDuplicationModal {
                        DuplicateProgressModalView(vm: vm)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.95).combined(with: .opacity),
                                removal: .scale(scale: 0.95).combined(with: .opacity)
                            ))
                    }
                }
                .zIndex(20000)
            }
        }
        .toolbar {
            windowToolbar
        }
        .modifier(MainContentSheetsModifier(vm: vm))
        .onAppear {
            DualPaneViewModel.shared = vm
            KeyCommandMonitor.activeViewModel = vm
            KeyCommandMonitor.installGlobalMonitor()
            vm.hoveredPhoneButtonSide = nil
        }
    }
    
    @ViewBuilder
    private func mainLayout(fullGeo: GeometryProxy) -> some View {
        let minHeight: CGFloat = 160
        let maxHeight = max(minHeight, fullGeo.size.height - 120)
        let defaultHeight = max(minHeight, min(420, fullGeo.size.height * 0.45))
        let baseHeight = min(maxHeight, max(minHeight, vm.fileDiffHeight ?? defaultHeight))
        
        VStack(spacing: 0) {
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
            if vm.showCopyDoneOffer {
                HStack {
                    Label("Импорт завершён. Проверить копии и освободить место на телефоне?", systemImage: "checkmark.shield")
                        .font(.callout)
                    Spacer()
                    Button("Проверить — copy done") { vm.acceptCopyDoneOffer() }
                        .disabled(!vm.canStartCopyDone)
                    Button("Позже") { vm.showCopyDoneOffer = false }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08))
            }
                        .frame(minWidth: 145, idealWidth: sidebarWidth, maxWidth: 220)
                }
                PaneView(side: .left)
                    .frame(minWidth: TableDoubleClickHandler.TableColumnLayoutEngine.minimumPaneWidth, idealWidth: paneIdealWidth)
                PaneView(side: .right)
                    .frame(minWidth: TableDoubleClickHandler.TableColumnLayoutEngine.minimumPaneWidth, idealWidth: paneIdealWidth)
            }
            .id(vm.splitViewResetId)
            .background(
                SplitViewCenterResetHelper(
                    resetId: vm.splitViewResetId,
                    isFinderMode: vm.panelLayoutMode == .finder,
                    sidebarWidth: sidebarWidth
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
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
    
    @ViewBuilder
    private var tooltipAndPopoverOverlay: some View {
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
        // Поповер быстрого подключения к телефону теперь отображается через нативный .popover в PaneView прямо над кнопкой телефона.
    }
    
    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 6) {
                Text(headerWindowWidth < 1200 ? "MacDroid" : "MacDroid Commander")
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
        
        ToolbarItem(placement: .principal) {
            HeaderAppLauncher(windowWidth: headerWindowWidth)
        }
        
        ToolbarItem(placement: .primaryAction) {
            TopToolbarTrailingActionsView(vm: vm)
        }
    }
}

private struct MainContentSheetsModifier: ViewModifier {
    @ObservedObject var vm: DualPaneViewModel
    
    func body(content: Content) -> some View {
        content
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
            .sheet(isPresented: $vm.showTransferConfirmationDialog) {
                if let ctx = vm.transferConfirmation {
                    TransferConfirmationModalView(
                        context: ctx,
                        onConfirm: { confirmedPath in
                            vm.confirmTransfer(targetDirPath: confirmedPath)
                        },
                        onCancel: {
                            vm.cancelTransferConfirmation()
                        }
                    )
                }
            }
            // Закрытие без выбора (Esc) отменяет передачу, которая ждёт решения
            .sheet(isPresented: $vm.showConflictDialog, onDismiss: { vm.dismissConflictIfPending() }) {
                if let conflict = vm.activeConflict {
                    ConflictResolutionModalView(
                        conflict: conflict,
                        onResolve: { result in
                            vm.resolveConflict(with: result)
                        },
                        onCancel: {
                            vm.cancelConflict()
                        }
                    )
                    .animation(.easeInOut(duration: 0.15), value: conflict.id)
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
            .sheet(isPresented: $vm.showCreateArchiveDialog) {
                CreateArchiveModalView()
                    .environmentObject(vm)
            }
            .sheet(isPresented: $vm.showPathDisplaySettings) {
                PathDisplaySettingsModalView()
                    .environmentObject(vm)
            }
            .sheet(isPresented: $vm.showPhoneTrash) {
                PhoneTrashView()
                    .environmentObject(vm)
            }
            .sheet(isPresented: $vm.showDuplicateFinder) {
                DuplicateFinderView().environmentObject(vm)
            }
            .sheet(isPresented: $vm.showArchiveBrowser, onDismiss: { vm.closeArchiveBrowser() }) {
                if let url = vm.archiveBrowserURL {
                    ArchiveBrowserView(archiveURL: url, title: vm.archiveBrowserTitle)
                        .id(url)
                } else {
                    VStack(spacing: 16) {
                        Text(vm.archiveBrowserTitle).font(.headline)
                        if let error = vm.archiveBrowserError {
                            Text(error).textSelection(.enabled)
                        } else {
                            ProgressView("Загрузка архива с телефона…")
                        }
                        Button("Закрыть") { vm.showArchiveBrowser = false }
                    }.padding(24).frame(minWidth: 480, minHeight: 200)
                }
            }
            .sheet(isPresented: $vm.showCopyDone) {
                CopyDoneView().environmentObject(vm)
            }
            .alert(vm.errorAlertTitle, isPresented: Binding(
                get: { vm.showErrorAlert && vm.fullscreenGridPaneSide == nil },
                set: { vm.showErrorAlert = $0 }
            )) {
                Button(vm.errorAlertButtonTitle, role: .cancel) {}
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
                    Text("Переместить \(count) выбранных объектов в Корзину телефона? Их можно восстановить через меню «Корзина телефона…».")
                }
            }
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
            
            TopToolbarCenterSplitResetButton(vm: vm)
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
            
            let activeFolderSortMode = (vm.activePane == .left ? vm.leftFolderSortMode : vm.rightFolderSortMode)
            TopToolbarFolderSortButton(mode: activeFolderSortMode) {
                vm.toggleFolderSortMode(for: vm.activePane)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            
            PanelLayoutModeSwitcher(mode: vm.panelLayoutMode) { newMode in
                vm.setPanelLayoutMode(newMode)
            }
            .padding(.trailing, 6)
            
            let activeMode = (vm.activePane == .left ? vm.leftViewMode : vm.rightViewMode)
            TopToolbarViewModeButton(mode: activeMode) {
                vm.toggleViewMode(for: vm.activePane)
            }
            
            ToolbarSeparator()
                .padding(.horizontal, 4)
            
            TopToolbarFilterView(vm: vm)
            TopToolbarSearchView(vm: vm)
        }
    }
}

private struct SplitViewCenterResetHelper: NSViewRepresentable {
    let resetId: UUID
    let isFinderMode: Bool
    let sidebarWidth: CGFloat
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let splitView = findSplitView(in: nsView) else { return }
            let boundsWidth = splitView.bounds.width
            guard boundsWidth > 100 else { return }
            
            if isFinderMode {
                let remainingWidth = max(200, boundsWidth - sidebarWidth)
                let divider1X = sidebarWidth + (remainingWidth / 2.0)
                if splitView.subviews.count >= 3 {
                    splitView.setPosition(sidebarWidth, ofDividerAt: 0)
                    splitView.setPosition(divider1X, ofDividerAt: 1)
                }
            } else {
                let divider0X = boundsWidth / 2.0
                if splitView.subviews.count >= 2 {
                    splitView.setPosition(divider0X, ofDividerAt: 0)
                }
            }
            splitView.adjustSubviews()
        }
    }
    
    private func findSplitView(in view: NSView) -> NSSplitView? {
        var current: NSView? = view
        while let c = current {
            if let split = c as? NSSplitView { return split }
            for sub in c.subviews {
                if let split = sub as? NSSplitView { return split }
            }
            current = c.superview
        }
        return nil
    }
}

