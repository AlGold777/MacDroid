import SwiftUI
import AppKit

// MARK: - Специализированное окно для полноэкранного просмотрщика

final class GridFullscreenViewerWindow: NSWindow {
    var onEscape: (() -> Void)?
    
    override var canBecomeKey: Bool {
        return true
    }
    
    override var canBecomeMain: Bool {
        return true
    }
    
    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Контроллер окна полноэкранного просмотрщика

@MainActor
public final class GridFullscreenViewerWindowController: NSObject {
    public static let shared = GridFullscreenViewerWindowController()
    
    private var window: GridFullscreenViewerWindow?
    private weak var currentViewModel: DualPaneViewModel?
    
    public func show(for side: PaneSide, viewModel: DualPaneViewModel) {
        self.currentViewModel = viewModel
        
        if let existing = window {
            existing.orderOut(nil)
            window = nil
        }
        
        // В CLI-тестах без графической сессии WindowServer окно не создается
        guard NSApp.activationPolicy() != .prohibited && !ProcessInfo.processInfo.processName.contains("MacHostTests") else {
            return
        }
        
        let targetScreen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = targetScreen else { return }
        
        let win = GridFullscreenViewerWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        win.onEscape = { [weak self] in
            if viewModel.showErrorAlert {
                viewModel.showErrorAlert = false
                return
            }
            if viewModel.showDeleteConfirmDialog {
                viewModel.showDeleteConfirmDialog = false
                return
            }
            self?.close()
        }
        
        let hostView = GridFullscreenHostView(side: side, screenRect: screen.visibleFrame) { [weak self] in
            self?.close()
        }
        .environmentObject(viewModel)
        
        win.contentView = NSHostingView(rootView: hostView)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        self.window = win
    }
    
    public func close() {
        guard let win = window else { return }
        currentViewModel?.fullscreenGridPaneSide = nil
        win.orderOut(nil)
        window = nil
    }
}

// MARK: - Верхняя панель полноэкранного просмотрщика

public struct GridFullscreenHeaderView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    public let side: PaneSide
    public let onClose: () -> Void
    
    public init(side: PaneSide, onClose: @escaping () -> Void) {
        self.side = side
        self.onClose = onClose
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
    
    private var sourceIcon: String {
        let source = (side == .left ? vm.leftSource : vm.rightSource)
        return source == .localMac ? "macbook" : "phone.fill"
    }
    
    private var currentPath: String {
        side == .left ? vm.leftPath : vm.rightPath
    }
    
    private var currentFolderName: String {
        let p = currentPath
        if p == "/" || p.isEmpty { return "Корень" }
        return URL(fileURLWithPath: p).lastPathComponent
    }
    
    public var body: some View {
        HStack(spacing: 8) {
            // Навигационные кнопки (Назад / Вверх)
            HStack(spacing: 2) {
                Button(action: {
                    vm.navigateBack(side: side)
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(vm.canNavigateBack(side: side) ? .primary : .secondary.opacity(0.4))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .controlColor).opacity(0.22))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .disabled(!vm.canNavigateBack(side: side))
                .help("Назад (Cmd+[)")
                
                Button(action: {
                    vm.navigateUp()
                }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .controlColor).opacity(0.22))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Перейти вверх (Cmd+↑)")
            }
            
            // Заголовок папки и источника
            HStack(spacing: 5) {
                Image(systemName: sourceIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.accentColor)
                
                Text(currentFolderName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                
                Text("(\(currentPath))")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 320, alignment: .leading)
            }
            
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)
            
            // Меню сортировки
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
                
                Divider()
                
                let currentFolderMode = (side == .left ? vm.leftFolderSortMode : vm.rightFolderSortMode)
                Button(action: {
                    if side == .left {
                        vm.leftFolderSortMode = .separate
                    } else {
                        vm.rightFolderSortMode = .separate
                    }
                }) {
                    HStack {
                        Text("Папки отдельно")
                        if currentFolderMode == .separate {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                
                Button(action: {
                    if side == .left {
                        vm.leftFolderSortMode = .mixed
                    } else {
                        vm.rightFolderSortMode = .mixed
                    }
                }) {
                    HStack {
                        Text("Папки и файлы вместе (Finder)")
                        if currentFolderMode == .mixed {
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
            
            // Счётчик количества объектов в формате «X obj»
            let itemsCount = vm.displayItems(for: side).count
            Text("\(itemsCount) obj")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            
            Spacer()
            
            // Ползунок размера эскиза
            ModernGridSliderControl(
                icon: "photo",
                value: thumbnailSizeBinding,
                range: 64...384,
                step: 8,
                defaultValue: 120,
                displayFormat: { "\(Int($0)) px" },
                helpText: "Размер эскизов: \(Int(thumbnailSizeBinding.wrappedValue)) px"
            )
            
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)
            
            // Ползунок интервала между эскизами
            ModernGridSliderControl(
                icon: "arrow.left.and.line.vertical.and.arrow.right",
                value: gridSpacingBinding,
                range: 1...32,
                step: 1,
                defaultValue: 3,
                displayFormat: { $0 <= 3 ? "\(Int($0)) px (≈1 мм)" : "\(Int($0)) px" },
                helpText: "Расстояние между эскизами: \(Int(gridSpacingBinding.wrappedValue)) px"
            )
            
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)
            
            // Сброс кэша эскизов
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
            .help("Сбросить кэш эскизов")
            
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)
            
            // Кнопка закрытия окна (крестик / Esc)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Закрыть просмотрщик (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(height: 32)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Корневой хост просмотрщика с затемнённым фоном и окном 95% площади экрана

public struct GridFullscreenHostView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    public let side: PaneSide
    public let screenRect: NSRect
    public let onClose: () -> Void
    
    public init(side: PaneSide, screenRect: NSRect, onClose: @escaping () -> Void) {
        self.side = side
        self.screenRect = screenRect
        self.onClose = onClose
    }
    
    // Площадь 95% площади экрана:
    // Ширина и высота масштабируются коэффициентом sqrt(0.95) ≈ 0.9746794
    private var windowSize: CGSize {
        let scale: CGFloat = sqrt(0.95)
        let w = round(screenRect.width * scale)
        let h = round(screenRect.height * scale)
        return CGSize(width: max(400, w), height: max(300, h))
    }
    
    public var body: some View {
        ZStack {
            // Затемнённый фон: клик мимо окна закрывает просмотрщик (или сбрасывает диалоги)
            Color.black.opacity(0.45)
                .edgesIgnoringSafeArea(.all)
                .contentShape(Rectangle())
                .onTapGesture {
                    if vm.showDeleteConfirmDialog {
                        vm.showDeleteConfirmDialog = false
                    } else if vm.showErrorAlert {
                        vm.showErrorAlert = false
                    } else {
                        onClose()
                    }
                }
            
            // Окно просмотрщика содержимого панели площадью 95% площади экрана
            VStack(spacing: 0) {
                GridFullscreenHeaderView(side: side, onClose: onClose)
                
                Divider()
                
                FileGridPaneView(side: side)
            }
            .frame(width: windowSize.width, height: windowSize.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 24, x: 0, y: 10)
            
            // Модальное окно подтверждения удаления (выше всех окон и элементов)
            if vm.showDeleteConfirmDialog {
                deleteConfirmationOverlay
            }
            
            // Модальное окно ошибки (выше всех окон)
            if vm.showErrorAlert {
                errorAlertOverlay
            }
        }
        .sheet(isPresented: Binding(
            get: { vm.showImageViewer && vm.fullscreenGridPaneSide != nil },
            set: { vm.showImageViewer = $0 }
        )) {
            ImageViewerModalView(images: vm.viewerImages, startIndex: vm.viewerStartIndex)
                .environmentObject(vm)
        }
        .sheet(isPresented: Binding(
            get: { vm.showRenameDialog && vm.fullscreenGridPaneSide != nil },
            set: { vm.showRenameDialog = $0 }
        )) {
            RenameModalView()
                .environmentObject(vm)
        }
        .sheet(isPresented: Binding(
            get: { vm.showNewFolderDialog && vm.fullscreenGridPaneSide != nil },
            set: { vm.showNewFolderDialog = $0 }
        )) {
            NewFolderModalView()
                .environmentObject(vm)
        }
        .sheet(isPresented: Binding(
            get: { vm.showPropertiesDialog && vm.fullscreenGridPaneSide != nil },
            set: { vm.showPropertiesDialog = $0 }
        )) {
            FilePropertiesModalView()
                .environmentObject(vm)
        }
    }
    
    // MARK: - Модальное окно подтверждения удаления (поверх сетки и всех окон)
    
    private var deleteConfirmationOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .edgesIgnoringSafeArea(.all)
                .contentShape(Rectangle())
                .onTapGesture {
                    vm.showDeleteConfirmDialog = false
                }
            
            DeleteConfirmationModalView(
                isPresented: $vm.showDeleteConfirmDialog,
                vm: vm,
                targetSide: side
            )
            .shadow(color: Color.black.opacity(0.4), radius: 24, x: 0, y: 10)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
    
    // MARK: - Модальное окно ошибки файловой операции
    
    private var errorAlertOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .edgesIgnoringSafeArea(.all)
                .contentShape(Rectangle())
                .onTapGesture {
                    vm.showErrorAlert = false
                }
            
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.yellow)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text(vm.errorAlertTitle)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.primary)
                        
                        Text(vm.errorMessage)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                HStack {
                    Spacer()
                    Button(vm.errorAlertButtonTitle) {
                        vm.showErrorAlert = false
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }
            .padding(22)
            .frame(width: 420)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.4), radius: 24, x: 0, y: 10)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}
