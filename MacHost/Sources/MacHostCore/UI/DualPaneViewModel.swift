import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DiskArbitration

/// Ошибки проверок перед переименованием/перемещением, которые нельзя обходить молча
public enum FileOperationNameError: LocalizedError, Sendable {
    case nameTaken(name: String)

    public var errorDescription: String? {
        switch self {
        case .nameTaken(let name):
            return "Объект с именем «\(name)» уже существует"
        }
    }
}

public enum SortField: String, CaseIterable, Sendable {
    case name = "Имя"
    case type = "Тип"
    case size = "Размер"
    case tags = "Теги"
    case date = "Дата"
    case status = "Статус"
}

public enum PaneSide: String, Sendable {
    case left = "left"
    case right = "right"
}

public enum PaneViewMode: String, CaseIterable, Sendable {
    case table = "table"
    case grid = "grid"
}

public enum FolderSortMode: String, CaseIterable, Sendable {
    case separate = "separate" // Папки отдельно (по умолчанию)
    case mixed = "mixed"       // Папки и файлы вместе (как в Finder)
}

public enum PanelLayoutMode: String, CaseIterable, Sendable, Codable {
    case dual = "T"      // Двухпанельный режим
    case finder = "F"    // Режим Finder (левый сайдбар + панель)
}

public enum FileDiffDockPosition: String, CaseIterable, Sendable {
    case top = "top"
    case bottom = "bottom"
}

public struct BatchRenameSession: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let side: PaneSide
    public let items: [FileItem]
    
    public init(id: UUID = UUID(), side: PaneSide, items: [FileItem]) {
        self.id = id
        self.side = side
        self.items = items
    }
    
    public static func == (lhs: BatchRenameSession, rhs: BatchRenameSession) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
public final class DualPaneViewModel: ObservableObject {
    public static weak var shared: DualPaneViewModel?
    @Published public var activePane: PaneSide = .left {
        didSet {
            UserDefaults.standard.set(activePane.rawValue, forKey: SessionKey.activePane)
            if activePane != oldValue {
                if !isFileDiffActive {
                    if activePane == .left {
                        rightSelection.removeAll()
                        TableDoubleClickHandler.HandlerView.rightTableView?.deselectAll(nil)
                    } else {
                        leftSelection.removeAll()
                        TableDoubleClickHandler.HandlerView.leftTableView?.deselectAll(nil)
                    }
                }
                TableDoubleClickHandler.HandlerView.setActiveSide(activePane)
                updateQuickLookIfVisible()
            }
        }
    }
    
    // Режимы отображения панелей (Таблица / Графическая сетка)
    @Published public var leftViewMode: PaneViewMode = .table {
        didSet { UserDefaults.standard.set(leftViewMode.rawValue, forKey: SessionKey.leftViewMode) }
    }
    @Published public var rightViewMode: PaneViewMode = .table {
        didSet { UserDefaults.standard.set(rightViewMode.rawValue, forKey: SessionKey.rightViewMode) }
    }
    @Published public var leftGridThumbnailSize: Double = 120 {
        didSet { UserDefaults.standard.set(leftGridThumbnailSize, forKey: SessionKey.leftGridThumbnailSize) }
    }
    @Published public var rightGridThumbnailSize: Double = 120 {
        didSet { UserDefaults.standard.set(rightGridThumbnailSize, forKey: SessionKey.rightGridThumbnailSize) }
    }
    @Published public var leftGridSpacing: Double = 10 {
        didSet { UserDefaults.standard.set(leftGridSpacing, forKey: SessionKey.leftGridSpacing) }
    }
    @Published public var rightGridSpacing: Double = 10 {
        didSet { UserDefaults.standard.set(rightGridSpacing, forKey: SessionKey.rightGridSpacing) }
    }
    
    // Вкладки левой панели
    @Published public var leftTabs: [PanelTab] = []
    /// Любая активация вкладки снимает режим корня: активной становится вкладка, а не кнопка источника
    @Published public var leftActiveTabId: UUID = UUID() {
        didSet { leftIsRootMode = false }
    }
    /// Панель показывает корень источника, выбранный кнопкой Mac/Phone/USB: активна кнопка, а не вкладка
    @Published public var leftIsRootMode: Bool = false
    @Published public var areTabsVisibleLeft: Bool = false
    
    // Вкладки правой панели
    @Published public var rightTabs: [PanelTab] = []
    @Published public var rightActiveTabId: UUID = UUID() {
        didSet { rightIsRootMode = false }
    }
    @Published public var rightIsRootMode: Bool = false
    @Published public var areTabsVisibleRight: Bool = false

    /// Показывает ли панель корень источника вместо вкладки (учитывается, только когда вкладки видны)
    public func isRootMode(side: PaneSide) -> Bool {
        (side == .left ? leftIsRootMode : rightIsRootMode) && !visibleTabs(for: side).isEmpty
    }
    
    // Состояние левой панели
    private var leftItemsVersion: Int = 0
    private var rightItemsVersion: Int = 0
    
    @Published public var leftSource: FileSource = .localMac
    @Published public var leftPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    @Published public var leftItems: [FileItem] = [] {
        didSet {
            leftItemsVersion &+= 1
            if !leftSelection.isEmpty {
                calculateSelectedFolderSizes(for: .left)
            }
        }
    }
    @Published public var leftSelection: Set<String> = [] {
        didSet { onSelectionChanged(for: .left) }
    }
    @Published public var failedConnectionSide: PaneSide? = nil
    @Published public var phoneButtonFrameLeft: CGRect = .zero
    @Published public var phoneButtonFrameRight: CGRect = .zero
    @Published public var hoveredPhoneButtonSide: PaneSide? = nil
    @Published public var leftFilter: String = ""
    @Published public var leftSortField: SortField = .name {
        didSet { UserDefaults.standard.set(leftSortField.rawValue, forKey: SessionKey.leftSortField) }
    }
    @Published public var leftSortAscending: Bool = true {
        didSet { UserDefaults.standard.set(leftSortAscending, forKey: SessionKey.leftSortAscending) }
    }
    @Published public var leftFreeSpace: (free: UInt64, total: UInt64) = (0, 0)
    @Published public var leftIsStale: Bool = false
    @Published public var leftShowHidden: Bool = false
    @Published public var leftHistory: [String] = []
    @Published public var leftHistoryIndex: Int = -1
    @Published public var isEditingLeftPath: Bool = false
    
    private func cleanDeviceName(_ name: String) -> String {
        var clean = name.replacingOccurrences(of: "(MacDroid)", with: "")
            .trimmingCharacters(in: .whitespaces)
        if clean.hasPrefix("Телефон ") {
            let remainder = String(clean.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            if !remainder.isEmpty && remainder != "Android" {
                clean = remainder
            }
        }
        if clean.contains("2409BRN2CY") || clean.contains("RN") || clean.lowercased().contains("redmi") {
            clean = clean.replacingOccurrences(of: "Xiaomi", with: "Redmi")
        }
        return clean.isEmpty ? "Phone" : clean
    }
    
    private func getConnectedPhoneName() -> String {
        let host = ConnectionHostAddress.normalized(SessionCoordinator.shared.host)
        if let discovered = discoveryService.discoveredDevices.first(where: { ConnectionHostAddress.normalized($0.host) == host }), !discovered.name.isEmpty {
            return discovered.name
        }
        if let devName = PhoneConnectionManager.shared.deviceNameForHost(host), devName != "Телефон Android", devName != "Android", !devName.isEmpty {
            return devName
        }
        if let trusted = DeviceRegistry.shared.device(matchingHost: host), trusted.name != "Телефон Android", trusted.name != "Android", !trusted.name.isEmpty {
            return trusted.name
        }
        if let saved = PairingModalView.loadInitialHistory().first(where: { ConnectionHostAddress.normalized($0.host) == host }), saved.name != "Телефон Android", saved.name != "Android", !saved.name.isEmpty {
            return saved.name
        }
        if !ConnectionController.shared.currentDeviceName.isEmpty && ConnectionController.shared.currentDeviceName != "Телефон Android" && ConnectionController.shared.currentDeviceName != "Android" {
            return ConnectionController.shared.currentDeviceName
        }
        return "Phone"
    }
    
    public var connectedPhoneShortName: String {
        guard isPhoneConnected && remoteDriver.isConnected else { return "Phone" }
        let devName = getConnectedPhoneName()
        let clean = cleanDeviceName(devName)
        return String(clean.prefix(7)).trimmingCharacters(in: .whitespaces)
    }
    
    public var connectedPhoneTooltip: String? {
        guard isPhoneConnected && remoteDriver.isConnected else { return nil }
        let host = SessionCoordinator.shared.host
        let devName = getConnectedPhoneName()
        let clean = cleanDeviceName(devName)
        return "\(clean)\n\(host)"
    }
    
    // Состояние правой панели
    @Published public var rightSource: FileSource = .remotePhone
    @Published public var rightPath: String = "/storage/emulated/0/DCIM"
    @Published public var rightItems: [FileItem] = [] {
        didSet {
            rightItemsVersion &+= 1
            if !rightSelection.isEmpty {
                calculateSelectedFolderSizes(for: .right)
            }
        }
    }
    @Published public var rightSelection: Set<String> = [] {
        didSet { onSelectionChanged(for: .right) }
    }
    @Published public var rightFilter: String = ""
    @Published public var rightSortField: SortField = .name {
        didSet { UserDefaults.standard.set(rightSortField.rawValue, forKey: SessionKey.rightSortField) }
    }
    @Published public var rightSortAscending: Bool = true {
        didSet { UserDefaults.standard.set(rightSortAscending, forKey: SessionKey.rightSortAscending) }
    }
    @Published public var rightFreeSpace: (free: UInt64, total: UInt64) = (0, 0)
    @Published public var rightIsStale: Bool = false
    @Published public var rightShowHidden: Bool = false
    @Published public var rightHistory: [String] = []
    @Published public var rightHistoryIndex: Int = -1
    @Published public var isEditingRightPath: Bool = false
    
    @Published public var manualPathInput: String = ""
    
    public var activeFilterText: String {
        get {
            activePane == .left ? leftFilter : rightFilter
        }
        set {
            if activePane == .left {
                leftFilter = newValue
            } else {
                rightFilter = newValue
            }
        }
    }
    
    public func openFilter() {
        filterFocusTrigger &+= 1
    }
    
    public func toggleFilter() {
        filterFocusTrigger &+= 1
    }
    
    // Сравнение каталогов
    @Published public var isComparing: Bool = false
    @Published public var comparisonResult: DirectoryComparisonResult = DirectoryComparisonResult() {
        didSet { leftDisplayCache = nil; rightDisplayCache = nil }
    }
    @Published public private(set) var isComparisonRunning = false
    @Published public var hideIdenticalInComparison: Bool = false
    private let comparator = DirectoryComparator()
    private var comparisonTask: Task<Void, Never>?
    private var comparisonGeneration = 0
    private var leftComparisonReady = true
    private var rightComparisonReady = true
    
    // Диалоги и задачи
    @Published public var showNewFolderDialog: Bool = false
    @Published public var showPhoneTrash = false
    @Published public var showDuplicateFinder = false
    @Published public var showArchiveBrowser = false
    @Published public private(set) var archiveBrowserURL: URL?
    @Published public private(set) var archiveBrowserTitle = ""
    @Published public private(set) var archiveBrowserError: String?
    private var archiveBrowserTask: Task<Void, Never>?
    private var archiveBrowserTemporaryDirectory: URL?
    private var archiveBrowserGeneration = UUID()
    @Published public private(set) var phoneTrashEntries: [PhoneTrashEntry] = []
    @Published public private(set) var isPhoneTrashBusy = false
    @Published public private(set) var phoneTrashError: String?
    @Published public private(set) var phoneTrashVolumePath = ""
    @Published public var showRenameDialog: Bool = false
    @Published public var itemToRename: FileItem? = nil
    @Published public var renameNewName: String = ""
    
    // In-place Inline Rename
    @Published public var editingItemId: String? = nil
    @Published public var editingItemSide: PaneSide? = nil
    @Published public var editingItemName: String = ""
    @Published public var showPropertiesDialog: Bool = false
    @Published public var propertiesItem: FileItem? = nil
    @Published public var showDeleteConfirmDialog: Bool = false
    @Published public var showTransferConfirmationDialog: Bool = false
    @Published public var transferConfirmation: TransferConfirmationContext? = nil
    @Published public var showTransferProgress: Bool = false
    @Published public var showQueueDialog: Bool = false
    @Published public var batchRenameSession: BatchRenameSession? = nil
    @Published public var showBatchRenameDialog: Bool = false {
        didSet {
            if !showBatchRenameDialog {
                batchRenameSession = nil
            }
        }
    }
    @Published public var batchRenameItems: [FileItem] = []
    @Published public var batchRenameSide: PaneSide = .left
    @Published public var lastBatchRenameHistory: [(oldPath: String, newPath: String)] = []
    @Published public var lastBatchRenameSide: PaneSide = .left
    @Published public var canUndoBatchRename: Bool = false
    
    // Встроенный поиск в стиле Finder (Scope Bar)
    @Published public var isLeftSearchActive: Bool = false
    @Published public var isRightSearchActive: Bool = false
    @Published public var leftSearchQuery: String = ""
    @Published public var rightSearchQuery: String = ""
    @Published public var isLeftSearching: Bool = false
    @Published public var isRightSearching: Bool = false
    @Published public var leftSearchResults: [FileItem] = []
    @Published public var rightSearchResults: [FileItem] = []
    @Published public var leftSearchScope: SearchScope = .currentFolder
    @Published public var rightSearchScope: SearchScope = .currentFolder
    @Published public var leftSearchMatchContent: Bool = true
    @Published public var rightSearchMatchContent: Bool = true
    @Published public var searchFocusTrigger: Int = 0
    @Published public var filterFocusTrigger: Int = 0
    private var leftSearchTask: Task<Void, Never>? = nil
    private var rightSearchTask: Task<Void, Never>? = nil
    
    @Published public var showSearchDialog: Bool = false {
        didSet {
            if showSearchDialog {
                openSearch(side: activePane)
                showSearchDialog = false
            }
        }
    }
    @Published public var showPairingDialog: Bool = false
    @Published public var showErrorAlert: Bool = false
    @Published public var errorAlertTitle: String = "Ошибка файловой операции"
    @Published public var errorAlertButtonTitle: String = "OK"
    @Published public var errorMessage: String = ""
    @Published public var transferProgress: Double = 0.0
    @Published public var transferSpeed: String = ""
    @Published public var transferETA: String = ""
    @Published public var statusMessage: String = "Готов к работе"
    @Published public var newFolderName: String = ""
    @Published public var newFolderSelectedItems: [FileItem] = []
    @Published public var showOperationReport: Bool = false
    
    // Folder & Large Items Duplication Modal State
    @Published public var isDuplicating: Bool = false
    @Published public var showDuplicationModal: Bool = false
    @Published public var duplicateTitle: String = ""
    @Published public var duplicateSubtitle: String = ""
    @Published public var duplicateProgress: Double = 0.0
    @Published public var duplicateTotalObjects: Int = 0
    @Published public var duplicateTransferredBytes: UInt64 = 0
    @Published public var duplicateTotalBytes: UInt64 = 0
    @Published public var duplicateIsFolder: Bool = true
    @Published public var duplicateFirstTargetPath: String? = nil
    @Published public var isDuplicateCancelled: Bool = false
    @Published public var duplicationModalDelay: TimeInterval = 3.0
    public var duplicateTask: Task<Void, Never>? = nil
    public var duplicateTimerTask: Task<Void, Never>? = nil
    public var duplicateCreatedPaths: [String] = []
    public var duplicatePendingTargets: [(targets: [FileItem], side: PaneSide)] = []
    
    // Drag & Drop Visual Feedback
    @Published public var dragHoverSide: PaneSide? = nil
    @Published public var dragHoverFolderId: String? = nil
    @Published public var dragInsertionIndex: Int? = nil
    
    public func clearDragHoverState() {
        dragHoverSide = nil
        dragHoverFolderId = nil
        dragInsertionIndex = nil
    }

    /// Есть ли среди провайдеров наш внутренний тип перетаскивания (drop из этого же приложения)
    public static func providersCarryInternalPayload(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(dragUTType) || provider.registeredTypeIdentifiers.contains(dragUTType)
        }
    }

    /// Внутренний payload действителен только для drop из того же drag-сеанса приложения.
    /// Внешний drop (Finder и др.) сбрасывает устаревший payload, иначе тот перехватывал бы чужие файлы (D11).
    /// Возвращает true, если нужно обработать drop через внутренний payload.
    public func consumeInternalDragPayload(isInternalDrop: Bool) -> Bool {
        // Тип com.macdroid.dragitem не объявлен в Info.plist, поэтому hasItemsConforming его не видит.
        // Свежий payload (drag начат в этом приложении только что) считаем внутренним drop'ом.
        let isFresh = Date().timeIntervalSince(currentDragPayloadDate) < 30
        guard currentDragPayload != nil, isInternalDrop || isFresh else {
            currentDragPayload = nil
            return false
        }
        return true
    }
    @Published public var isTransferCompleted: Bool = false
    @Published public var transferCompletionMessage: String = ""
    @Published public var operationReport: OperationReport? = nil
    @Published public var currentTransferTask: Task<Void, Never>? = nil
    @Published public var isTransferPaused: Bool = false
    @Published public var currentPreviewTask: Task<Void, Never>? = nil
    @Published public var isConnectingPhone: Bool = false
    @Published public var isTransferMinimized: Bool = false
    @Published public var currentTransferFileName: String = ""
    private var isAutoConnecting: Bool = false
    
    // Буфер обмена (Clipboard)
    @Published public var clipboardItems: [FileItem] = []
    @Published public var clipboardSource: FileSource = .localMac
    @Published public var clipboardIsCut: Bool = false
    public var canPaste: Bool {
        if !clipboardItems.isEmpty { return true }
        if let types = NSPasteboard.general.types, types.contains(.fileURL) { return true }
        return false
    }
    
    // Создание архивов
    @Published public var showCreateArchiveDialog: Bool = false
    @Published public var archiveTargetItems: [FileItem] = []
    @Published public var archiveName: String = ""
    @Published public var archiveFormat: ArchiveService.ArchiveFormat = .zip
    @Published public var archiveDestinationPath: String = ""
    @Published public var isArchiving: Bool = false
    
    // Конфликты имён
    @Published public var showConflictDialog: Bool = false
    @Published public var activeConflict: ConflictContext? = nil
    @Published public var rememberedStrategy: ConflictResolutionStrategy? = nil
    private var conflictContinuation: CheckedContinuation<ConflictResolutionResult?, Never>?
    
    @MainActor
    public func resolveConflict(with result: ConflictResolutionResult) {
        let shouldKeepOpen = (result.action == .skip) && (activeConflict?.canSkip == true)
        if !shouldKeepOpen {
            showConflictDialog = false
            activeConflict = nil
        }
        if result.applyToAll {
            rememberedStrategy = result.action
        }
        conflictContinuation?.resume(returning: result)
        conflictContinuation = nil
    }
    
    @MainActor
    public func cancelConflict() {
        showConflictDialog = false
        activeConflict = nil
        showTransferProgress = false
        currentTransferTask?.cancel()
        currentTransferTask = nil
        TransferQueueManager.shared.cancelAll()
        statusMessage = "Операция отменена"
        conflictContinuation?.resume(returning: nil)
        conflictContinuation = nil
        Task {
            await orchestrator.cleanAllActivePartFiles()
        }
    }
    
    /// Закрытие листа конфликта без выбора (Esc/жест): если передача ещё ждёт решения — отменяем её.
    @MainActor
    public func dismissConflictIfPending() {
        if conflictContinuation != nil {
            cancelConflict()
        }
    }

    @MainActor
    public func promptConflictResolution(conflict: ConflictContext) async -> ConflictResolutionResult? {
        if isRunningTests {
            return ConflictResolutionResult(action: rememberedStrategy ?? .overwrite, applyToAll: false)
        }
        let wasProgressShowing = self.showTransferProgress
        if wasProgressShowing {
            self.showTransferProgress = false
            // Allow AppKit sheet dismiss animation to finish before presenting conflict sheet
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        
        let result = await withCheckedContinuation { continuation in
            self.conflictContinuation = continuation
            self.activeConflict = conflict
            self.showConflictDialog = true
        }
        
        let shouldKeepOpen = (result?.action == .skip) && conflict.canSkip
        if !shouldKeepOpen {
            self.showConflictDialog = false
            self.activeConflict = nil
            
            // Wait for sheet dismissal animation before allowing next sheet
            try? await Task.sleep(nanoseconds: 150_000_000)
            
            if wasProgressShowing && result != nil && !self.isTransferMinimized && !self.isTransferCompleted {
                self.showTransferProgress = true
            }
        }
        
        return result
    }
    
    // Активная сессия перетаскивания (Drag & Drop) внутри приложения
    public var currentDragPayload: DragPayload? = nil
    public var currentDragPayloadDate: Date = .distantPast
    public var draggedTabInfo: (side: PaneSide, id: UUID)? = nil
    
    // Просмотр изображений и галерея
    @Published public var showImageViewer: Bool = false
    @Published public var viewerImages: [FileItem] = []
    @Published public var viewerStartIndex: Int = 0
    @Published public var isQuickViewActive: Bool = false
    @Published public var fullscreenGridPaneSide: PaneSide? = nil
    
    // Режим раскладки панелей: двухпанельный (T) или режим Finder с боковой панелью (F)
    @Published public var panelLayoutMode: PanelLayoutMode = .dual
    
    // Идентификатор сброса центрирования разделителя сплиттера
    @Published public var splitViewResetId: UUID = UUID()
    
    // Фильтр по тегам Finder (когда выбран тег в сайдбаре Finder)
    @Published public var selectedTagFilter: String? = nil
    
    // Режим группировки/сортировки папок для левой и правой панели
    @Published public var leftFolderSortMode: FolderSortMode = .separate {
        didSet {
            UserDefaults.standard.set(leftFolderSortMode.rawValue, forKey: SessionKey.leftFolderSortMode)
            leftDisplayCache = nil
        }
    }
    @Published public var rightFolderSortMode: FolderSortMode = .separate {
        didSet {
            UserDefaults.standard.set(rightFolderSortMode.rawValue, forKey: SessionKey.rightFolderSortMode)
            rightDisplayCache = nil
        }
    }
    
    // File Diff overlay state
    @Published public var isFileDiffActive: Bool = false
    @Published public var fileDiffDockPosition: FileDiffDockPosition = .top
    @Published public var fileDiffHeight: CGFloat? = nil
    @Published public var fileCompareState: CompareState = .noLeftFile(reason: "Выберите файл в левой панели")
    @Published public var leftCursorItemId: String? = nil {
        didSet { scheduleCompareStateRecompute() }
    }
    @Published public var rightCursorItemId: String? = nil {
        didSet { scheduleCompareStateRecompute() }
    }
    @Published public var activeFileDiffResult: DiffResult? = nil
    @Published public var activeDiffLeftTarget: CompareTarget? = nil
    @Published public var activeDiffRightTarget: CompareTarget? = nil
    @Published public var activeDiffLeftURL: URL? = nil
    @Published public var activeDiffRightURL: URL? = nil
    @Published public var diffOptions: DiffOptions = DiffOptions() {
        didSet {
            if isFileDiffActive {
                recomputeActiveFileDiff(isInitialOpen: false)
            }
        }
    }
    @Published public var leftFileEncoding: String.Encoding = .utf8
    @Published public var rightFileEncoding: String.Encoding = .utf8
    @Published public var leftFileEncodingName: String = "UTF-8"
    @Published public var rightFileEncodingName: String = "UTF-8"
    @Published public var leftFileEncodingPresumed: Bool = false
    @Published public var rightFileEncodingPresumed: Bool = false
    @Published public var isDiffSyncScrollEnabled: Bool = true
    @Published public var diffCurrentHunkIndex: Int = 0
    @Published public var isDiffLoading: Bool = false
    @Published public var diffErrorMessage: String? = nil
    @Published public var fileDiffChangedAlertSide: PaneSide? = nil
    @Published public var diffLeftPreviewLines: [String] = []
    @Published public var diffRightPreviewLines: [String] = []
    @Published public var diffLeftStatusMessage: String = "Выберите файл в левой панели"
    @Published public var diffRightStatusMessage: String = "Выберите файл в правой панели"
    
    private var compareStateDebounceTask: Task<Void, Never>?
    private var activeDiffComputeTask: Task<Void, Never>?
    private var fileDiffWatchTimer: Timer?
    private var lastObservedLeftMtime: Double?
    private var lastObservedRightMtime: Double?
    private var lastObservedLeftSize: UInt64?
    private var lastObservedRightSize: UInt64?
    
    // Внешние хранилища Android (SD-карты, OTG)
    @Published public var detectedVolumes: [PhoneConnectionManager.StorageVolume] = []
    
    // Внешние USB накопители (Mac /Volumes и Android OTG)
    public struct UsbDriveInfo: Identifiable, Hashable {
        public let id: String
        public let name: String
        public let path: String
        public let isMac: Bool
        
        public init(id: String, name: String, path: String, isMac: Bool) {
            self.id = id
            self.name = name
            self.path = path
            self.isMac = isMac
        }
    }
    @Published public var detectedUsbDrives: [UsbDriveInfo] = []
    @Published public var isPhoneConnected: Bool = false
    private var connectionMonitorTimer: Timer?
    /// Между willSleep и didWake проверки связи не запускаем (W16)
    private var isSystemAsleep = false
    private var wifiReachabilityMisses: Int = 0
    private var connectionProbeRunning = false
    private let wifiReachabilityMissLimit = 3
    
    // Вычисление размера папок по нажатию Space и при выделении
    @Published public var calculatedFolderSizes: [String: UInt64] = [:]
    @Published public var calculatingFolderPaths: Set<String> = []
    private var selectionCalculationTasks: [PaneSide: Task<Void, Never>] = [:]
    
    public private(set) var localDriver = LocalFSDriver()
    public private(set) var remoteDriver = RemoteSFTPDriver()
    public let discoveryService = DiscoveryService.shared
    public let queueManager = TransferQueueManager.shared
    
    public private(set) var transport = TransportMultiplexer()
    
    // Индикаторы процесса обновления панелей
    @Published public var leftIsRefreshing: Bool = false
    @Published public var rightIsRefreshing: Bool = false
    
    private var leftRefreshTask: Task<Void, Never>?
    private var rightRefreshTask: Task<Void, Never>?
    private var leftRefreshGeneration = 0
    private var rightRefreshGeneration = 0
    
    private lazy var orchestrator: JobOrchestrator = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("MacDroidCommander")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("mac_android_ledger.db")
        
        let ledger: IntentLedger
        if let primaryLedger = try? IntentLedger(databaseURL: dbURL) {
            ledger = primaryLedger
        } else {
            let fallbackURL = FileManager.default.temporaryDirectory.appendingPathComponent("mac_android_ledger_fallback.db")
            if let secondaryLedger = try? IntentLedger(databaseURL: fallbackURL) {
                ledger = secondaryLedger
            } else if let tempLedger = try? IntentLedger(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("ledger_\(UUID().uuidString).db")) {
                // Последний резерв: уникальный временный файл (без force-unwrap/try! и без краша)
                ledger = tempLedger
            } else {
                // Сюда попадаем только если ФС недоступна целиком; IntentLedger не умеет in-memory
                // (open по пути), поэтому явно сообщаем о неисправимом состоянии вместо молчаливого краша.
                fatalError("IntentLedger: не удалось открыть ни одну базу журнала (диск недоступен)")
            }
        }
        return JobOrchestrator(ledger: ledger, transport: transport, localFS: localDriver)
    }()
    
    // Настройки скрытия префиксов путей в Header
    @Published public var macHiddenPathPrefix: String = FileManager.default.homeDirectoryForCurrentUser.path
    @Published public var phoneHiddenPathPrefix: String = "/storage/emulated/0"
    @Published public var isPathPrefixHidingEnabled: Bool = true
    @Published public var showPathDisplaySettings: Bool = false
    
    public var isRunningTests: Bool {
        ProcessInfo.processInfo.processName == "MacHostTests"
    }
    
    // MARK: - Session Restore Keys
    private enum SessionKey {
        static let leftPath = "session.leftPath"
        static let rightPath = "session.rightPath"
        static let leftSource = "session.leftSource"
        static let rightSource = "session.rightSource"
        static let leftSortField = "session.leftSortField"
        static let leftSortAscending = "session.leftSortAscending"
        static let rightSortField = "session.rightSortField"
        static let rightSortAscending = "session.rightSortAscending"
        static let leftShowHidden = "session.leftShowHidden"
        static let rightShowHidden = "session.rightShowHidden"
        static let leftTabs = "session.leftTabs"
        static let rightTabs = "session.rightTabs"
        static let leftActiveTabId = "session.leftActiveTabId"
        static let rightActiveTabId = "session.rightActiveTabId"
        static let leftIsRootMode = "session.leftIsRootMode"
        static let rightIsRootMode = "session.rightIsRootMode"
        static let areTabsVisibleLeft = "session.areTabsVisibleLeft"
        static let areTabsVisibleRight = "session.areTabsVisibleRight"
        static let activePane = "session.activePane"
        static let isQuickViewActive = "session.isQuickViewActive"
        static let panelLayoutMode = "session.panelLayoutMode"
        static let leftFolderSortMode = "session.leftFolderSortMode"
        static let rightFolderSortMode = "session.rightFolderSortMode"
        static let leftViewMode = "session.leftViewMode"
        static let rightViewMode = "session.rightViewMode"
        static let leftGridThumbnailSize = "session.leftGridThumbnailSize"
        static let rightGridThumbnailSize = "session.rightGridThumbnailSize"
        static let leftGridSpacing = "session.leftGridSpacing"
        static let rightGridSpacing = "session.rightGridSpacing"
        static let macHiddenPathPrefix = "session.macHiddenPathPrefix"
        static let phoneHiddenPathPrefix = "session.phoneHiddenPathPrefix"
        static let isPathPrefixHidingEnabled = "session.isPathPrefixHidingEnabled"
    }
    
    public init() {
        // Восстановление сохранённого адреса телефона
        let savedHost = UserDefaults.standard.string(forKey: "lastConnectedHost") ?? ""
        let savedPort = UInt16(UserDefaults.standard.integer(forKey: "lastConnectedPort"))
        let savedDeviceId = savedHost == "127.0.0.1"
            ? UserDefaults.standard.string(forKey: "lastConnectedDeviceId")
            : nil
        let port = savedPort > 0 ? savedPort : 2222
        if !savedHost.isEmpty {
            remoteDriver.updateEndpoint(host: savedHost, port: port, deviceId: savedDeviceId)
            transport.updateEndpoint(host: savedHost, port: port, deviceId: savedDeviceId)
        }
        
        // Восстановление состояния из предыдущей сессии
        restoreSession()
        
        // Инициализация истории навигации
        leftHistory = [leftPath]
        leftHistoryIndex = 0
        rightHistory = [rightPath]
        rightHistoryIndex = 0
        
        if leftTabs.isEmpty {
            let defaultLeftTab = PanelTab(title: defaultTabTitle(for: leftPath, source: leftSource), path: leftPath, source: leftSource)
            leftTabs = [defaultLeftTab]
            leftActiveTabId = defaultLeftTab.id
        }
        
        if rightTabs.isEmpty {
            let defaultRightTab = PanelTab(title: defaultTabTitle(for: rightPath, source: rightSource), path: rightPath, source: rightSource)
            rightTabs = [defaultRightTab]
            rightActiveTabId = defaultRightTab.id
        }
        // Автоматическое обновление и обнаружение при старте (отключено во время юнит-тестов)
        let isRunningTests = ProcessInfo.processInfo.processName == "MacHostTests"
        if !isRunningTests {
            if leftSource != .remotePhone || remoteDriver.isConnected {
                refreshPane(side: .left)
            }
            if rightSource != .remotePhone || remoteDriver.isConnected {
                refreshPane(side: .right)
            }
            discoveryService.startDiscovery()
        }
        
        QuickLookBridge.shared.onNavigateNext = { [weak self] in
            self?.selectNext()
        }
        QuickLookBridge.shared.onNavigatePrevious = { [weak self] in
            self?.selectPrevious()
        }
        
        // Автоматическое обнаружение и подключение смартфона при старте
        if !isRunningTests && (leftSource == .remotePhone || rightSource == .remotePhone) {
            leftIsStale = false
            rightIsStale = false
            connectPhone(preferredDeviceId: savedDeviceId, forceActivate: false, isExplicit: false)
        } else if UserDefaults.standard.bool(forKey: "autoConnectEnabled") {
            autoConnectPhoneIfAvailable()
        }
        
        // Фоновая очистка зависших временных файлов (.part старше 1 часа) при старте приложения
        let startupOrchestrator = self.orchestrator
        Task.detached(priority: .utility) {
            if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                await startupOrchestrator.reconcileInterruptedJobs(in: downloads)
            }
            if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
                await startupOrchestrator.reconcileInterruptedJobs(in: desktop)
            }
        }
        
        // Подписка на завершение приложения для сохранения сессии
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.saveSession()
            }
        }
        
        // Инициализация и наблюдение за подключением внешних USB накопителей
        refreshUsbDrives()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshUsbDrives()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshUsbDrives()
            }
        }
        
        // Сон/пробуждение (W16): во сне сокеты не отвечают, поэтому проверки связи приостанавливаем,
        // а после пробуждения сразу выполняем health check (сеть успевает подняться за 2 с)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSystemAsleep = true
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSystemAsleep = false
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.checkPhoneConnectionState()
            }
        }

        Self.shared = self
        KeyCommandMonitor.activeViewModel = self
        
        // Глобальный перехватчик Ctrl+V, Ctrl+C, Ctrl+X, Ctrl+A в текстовых полях
        KeyCommandMonitor.installGlobalMonitor()
        
        // Фоновый мониторинг связи со смартфоном
        startConnectionMonitor()
    }
    
    /// Сохранение текущего состояния панелей в UserDefaults
    public func saveSession() {
        let defaults = UserDefaults.standard
        defaults.set(leftPath, forKey: SessionKey.leftPath)
        defaults.set(rightPath, forKey: SessionKey.rightPath)
        defaults.set(leftSource.rawValue, forKey: SessionKey.leftSource)
        defaults.set(rightSource.rawValue, forKey: SessionKey.rightSource)
        defaults.set(leftSortField.rawValue, forKey: SessionKey.leftSortField)
        defaults.set(leftSortAscending, forKey: SessionKey.leftSortAscending)
        defaults.set(rightSortField.rawValue, forKey: SessionKey.rightSortField)
        defaults.set(rightSortAscending, forKey: SessionKey.rightSortAscending)
        defaults.set(leftShowHidden, forKey: SessionKey.leftShowHidden)
        defaults.set(rightShowHidden, forKey: SessionKey.rightShowHidden)
        defaults.set(leftActiveTabId.uuidString, forKey: SessionKey.leftActiveTabId)
        defaults.set(rightActiveTabId.uuidString, forKey: SessionKey.rightActiveTabId)
        defaults.set(leftIsRootMode, forKey: SessionKey.leftIsRootMode)
        defaults.set(rightIsRootMode, forKey: SessionKey.rightIsRootMode)
        defaults.set(activePane.rawValue, forKey: SessionKey.activePane)
        defaults.set(isQuickViewActive, forKey: SessionKey.isQuickViewActive)
        defaults.set(panelLayoutMode.rawValue, forKey: SessionKey.panelLayoutMode)
        defaults.set(leftFolderSortMode.rawValue, forKey: SessionKey.leftFolderSortMode)
        defaults.set(rightFolderSortMode.rawValue, forKey: SessionKey.rightFolderSortMode)
        defaults.set(leftViewMode.rawValue, forKey: SessionKey.leftViewMode)
        defaults.set(rightViewMode.rawValue, forKey: SessionKey.rightViewMode)
        defaults.set(leftGridThumbnailSize, forKey: SessionKey.leftGridThumbnailSize)
        defaults.set(rightGridThumbnailSize, forKey: SessionKey.rightGridThumbnailSize)
        defaults.set(leftGridSpacing, forKey: SessionKey.leftGridSpacing)
        defaults.set(rightGridSpacing, forKey: SessionKey.rightGridSpacing)
        defaults.set(macHiddenPathPrefix, forKey: SessionKey.macHiddenPathPrefix)
        defaults.set(phoneHiddenPathPrefix, forKey: SessionKey.phoneHiddenPathPrefix)
        defaults.set(isPathPrefixHidingEnabled, forKey: SessionKey.isPathPrefixHidingEnabled)
        
        // Сериализация вкладок в JSON (включая флаги закрепления isPinned)
        if let leftTabsData = try? JSONEncoder().encode(leftTabs) {
            defaults.set(leftTabsData, forKey: SessionKey.leftTabs)
        }
        if let rightTabsData = try? JSONEncoder().encode(rightTabs) {
            defaults.set(rightTabsData, forKey: SessionKey.rightTabs)
        }
        defaults.set(areTabsVisibleLeft, forKey: SessionKey.areTabsVisibleLeft)
        defaults.set(areTabsVisibleRight, forKey: SessionKey.areTabsVisibleRight)
    }
    
    /// Очистка сохранённой сессии (для тестов или сброса)
    public static func clearSavedSession() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: SessionKey.leftPath)
        defaults.removeObject(forKey: SessionKey.rightPath)
        defaults.removeObject(forKey: SessionKey.leftSource)
        defaults.removeObject(forKey: SessionKey.rightSource)
        defaults.removeObject(forKey: SessionKey.leftSortField)
        defaults.removeObject(forKey: SessionKey.leftSortAscending)
        defaults.removeObject(forKey: SessionKey.rightSortField)
        defaults.removeObject(forKey: SessionKey.rightSortAscending)
        defaults.removeObject(forKey: SessionKey.leftShowHidden)
        defaults.removeObject(forKey: SessionKey.rightShowHidden)
        defaults.removeObject(forKey: SessionKey.leftTabs)
        defaults.removeObject(forKey: SessionKey.rightTabs)
        defaults.removeObject(forKey: SessionKey.leftActiveTabId)
        defaults.removeObject(forKey: SessionKey.rightActiveTabId)
        defaults.removeObject(forKey: SessionKey.leftIsRootMode)
        defaults.removeObject(forKey: SessionKey.rightIsRootMode)
        defaults.removeObject(forKey: SessionKey.areTabsVisibleLeft)
        defaults.removeObject(forKey: SessionKey.areTabsVisibleRight)
        defaults.removeObject(forKey: SessionKey.activePane)
        defaults.removeObject(forKey: SessionKey.isQuickViewActive)
        defaults.removeObject(forKey: SessionKey.panelLayoutMode)
        defaults.removeObject(forKey: SessionKey.leftFolderSortMode)
        defaults.removeObject(forKey: SessionKey.rightFolderSortMode)
        defaults.removeObject(forKey: SessionKey.leftViewMode)
        defaults.removeObject(forKey: SessionKey.rightViewMode)
        defaults.removeObject(forKey: SessionKey.leftGridThumbnailSize)
        defaults.removeObject(forKey: SessionKey.rightGridThumbnailSize)
        defaults.removeObject(forKey: SessionKey.leftGridSpacing)
        defaults.removeObject(forKey: SessionKey.rightGridSpacing)
        defaults.removeObject(forKey: SessionKey.macHiddenPathPrefix)
        defaults.removeObject(forKey: SessionKey.phoneHiddenPathPrefix)
        defaults.removeObject(forKey: SessionKey.isPathPrefixHidingEnabled)
    }
    
    public func clearSavedSession() {
        Self.clearSavedSession()
    }
    
    /// Восстановление состояния панелей из UserDefaults
    public func restoreSession() {
        let defaults = UserDefaults.standard
        
        if let savedLeftSource = defaults.string(forKey: SessionKey.leftSource) {
            if savedLeftSource == "MacBook (Локально)" || savedLeftSource == "MacBook" || savedLeftSource == "Mac" {
                leftSource = .localMac
            } else if savedLeftSource == "Xiaomi 14 Ultra (Wi-Fi/SFTP)" || savedLeftSource == "Xiaomi 14" || savedLeftSource == "Phone" {
                leftSource = .remotePhone
            } else if let source = FileSource(rawValue: savedLeftSource) {
                leftSource = source
            }
        }
        if let savedRightSource = defaults.string(forKey: SessionKey.rightSource) {
            if savedRightSource == "MacBook (Локально)" || savedRightSource == "MacBook" || savedRightSource == "Mac" {
                rightSource = .localMac
            } else if savedRightSource == "Xiaomi 14 Ultra (Wi-Fi/SFTP)" || savedRightSource == "Xiaomi 14" || savedRightSource == "Phone" {
                rightSource = .remotePhone
            } else if let source = FileSource(rawValue: savedRightSource) {
                rightSource = source
            }
        }
        
        if let savedLeftPath = defaults.string(forKey: SessionKey.leftPath), !savedLeftPath.isEmpty {
            leftPath = savedLeftPath
        }
        if let savedRightPath = defaults.string(forKey: SessionKey.rightPath), !savedRightPath.isEmpty {
            rightPath = savedRightPath
        }
        
        if defaults.object(forKey: SessionKey.leftShowHidden) != nil {
            leftShowHidden = defaults.bool(forKey: SessionKey.leftShowHidden)
        }
        if defaults.object(forKey: SessionKey.rightShowHidden) != nil {
            rightShowHidden = defaults.bool(forKey: SessionKey.rightShowHidden)
        }
        
        if let savedActivePane = defaults.string(forKey: SessionKey.activePane),
           let pane = PaneSide(rawValue: savedActivePane) {
            activePane = pane
        }
        if defaults.object(forKey: SessionKey.isQuickViewActive) != nil {
            isQuickViewActive = defaults.bool(forKey: SessionKey.isQuickViewActive)
        }
        if let savedLayoutMode = defaults.string(forKey: SessionKey.panelLayoutMode),
           let layoutMode = PanelLayoutMode(rawValue: savedLayoutMode) {
            panelLayoutMode = layoutMode
        }
        if let savedLeftFolderSort = defaults.string(forKey: SessionKey.leftFolderSortMode),
           let folderSort = FolderSortMode(rawValue: savedLeftFolderSort) {
            leftFolderSortMode = folderSort
        }
        if let savedRightFolderSort = defaults.string(forKey: SessionKey.rightFolderSortMode),
           let folderSort = FolderSortMode(rawValue: savedRightFolderSort) {
            rightFolderSortMode = folderSort
        }
        if let savedLeftMode = defaults.string(forKey: SessionKey.leftViewMode),
           let mode = PaneViewMode(rawValue: savedLeftMode) {
            leftViewMode = mode
        }
        if let savedRightMode = defaults.string(forKey: SessionKey.rightViewMode),
           let mode = PaneViewMode(rawValue: savedRightMode) {
            rightViewMode = mode
        }
        if defaults.object(forKey: SessionKey.leftGridThumbnailSize) != nil {
            let size = defaults.double(forKey: SessionKey.leftGridThumbnailSize)
            if size >= 60 && size <= 300 { leftGridThumbnailSize = size }
        }
        if defaults.object(forKey: SessionKey.rightGridThumbnailSize) != nil {
            let size = defaults.double(forKey: SessionKey.rightGridThumbnailSize)
            if size >= 60 && size <= 300 { rightGridThumbnailSize = size }
        }
        if defaults.object(forKey: SessionKey.leftGridSpacing) != nil {
            let spacing = defaults.double(forKey: SessionKey.leftGridSpacing)
            if spacing >= 2 && spacing <= 40 { leftGridSpacing = spacing }
        }
        if defaults.object(forKey: SessionKey.rightGridSpacing) != nil {
            let spacing = defaults.double(forKey: SessionKey.rightGridSpacing)
            if spacing >= 2 && spacing <= 40 { rightGridSpacing = spacing }
        }
        
        // Валидация путей относительно источника (защита от устаревших несовместимых сессий)
        if leftSource == .localMac {
            if leftPath.hasPrefix("/storage") || !FileManager.default.fileExists(atPath: leftPath) {
                leftPath = FileManager.default.homeDirectoryForCurrentUser.path
            }
        } else {
            if !leftPath.hasPrefix("/storage") {
                leftPath = "/storage/emulated/0"
            }
        }
        
        if rightSource == .localMac {
            if rightPath.hasPrefix("/storage") || !FileManager.default.fileExists(atPath: rightPath) {
                rightPath = FileManager.default.homeDirectoryForCurrentUser.path
            }
        } else {
            if !rightPath.hasPrefix("/storage") {
                rightPath = "/storage/emulated/0/DCIM"
            }
        }
        
        if let savedLeftSort = defaults.string(forKey: SessionKey.leftSortField),
           let sortField = SortField(rawValue: savedLeftSort) {
            leftSortField = sortField
        }
        if defaults.object(forKey: SessionKey.leftSortAscending) != nil {
            leftSortAscending = defaults.bool(forKey: SessionKey.leftSortAscending)
        }
        if let savedRightSort = defaults.string(forKey: SessionKey.rightSortField),
           let sortField = SortField(rawValue: savedRightSort) {
            rightSortField = sortField
        }
        if defaults.object(forKey: SessionKey.rightSortAscending) != nil {
            rightSortAscending = defaults.bool(forKey: SessionKey.rightSortAscending)
        }
        
        // Восстановление вкладок с валидацией путей и сохранением закрепления (isPinned)
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let homeName = URL(fileURLWithPath: homePath).lastPathComponent
        if let leftTabsData = defaults.data(forKey: SessionKey.leftTabs),
           let tabs = try? JSONDecoder().decode([PanelTab].self, from: leftTabsData),
           !tabs.isEmpty {
            leftTabs = tabs.map { original in
                var tab = original
                if let fix = repairedPinnedLocation(for: original, homePath: homePath) {
                    tab.path = fix.path
                    tab.source = fix.source
                }
                var validPath = tab.path
                if tab.source == .localMac {
                    if validPath.hasPrefix("/storage") || !FileManager.default.fileExists(atPath: validPath) {
                        validPath = homePath
                    }
                } else {
                    if !validPath.hasPrefix("/storage") {
                        validPath = "/storage/emulated/0"
                    }
                }
                let defaultTitle = defaultTabTitle(for: validPath, source: tab.source)
                let isLegacyRootTitle = (tab.source == .localMac && (tab.title == "restart" || tab.title == homeName) && (validPath == homePath || validPath == "/")) ||
                    (tab.source == .remotePhone && tab.title == "0" && (validPath == "/storage/emulated/0" || validPath == "/sdcard"))
                let title = (tab.title.isEmpty || isLegacyRootTitle) ? defaultTitle : tab.title
                return PanelTab(id: tab.id, title: (title.isEmpty || validPath == "/") ? defaultTitle : title, path: validPath, source: tab.source, isPinned: tab.isPinned)
            }
        }
        if let rightTabsData = defaults.data(forKey: SessionKey.rightTabs),
           let tabs = try? JSONDecoder().decode([PanelTab].self, from: rightTabsData),
           !tabs.isEmpty {
            rightTabs = tabs.map { original in
                var tab = original
                if let fix = repairedPinnedLocation(for: original, homePath: homePath) {
                    tab.path = fix.path
                    tab.source = fix.source
                }
                var validPath = tab.path
                if tab.source == .localMac {
                    if validPath.hasPrefix("/storage") || !FileManager.default.fileExists(atPath: validPath) {
                        validPath = homePath
                    }
                } else {
                    if !validPath.hasPrefix("/storage") {
                        validPath = "/storage/emulated/0"
                    }
                }
                let defaultTitle = defaultTabTitle(for: validPath, source: tab.source)
                let isLegacyRootTitle = (tab.source == .localMac && (tab.title == "restart" || tab.title == homeName) && (validPath == homePath || validPath == "/")) ||
                    (tab.source == .remotePhone && tab.title == "0" && (validPath == "/storage/emulated/0" || validPath == "/sdcard"))
                let title = (tab.title.isEmpty || isLegacyRootTitle) ? defaultTitle : tab.title
                return PanelTab(id: tab.id, title: (title.isEmpty || validPath == "/") ? defaultTitle : title, path: validPath, source: tab.source, isPinned: tab.isPinned)
            }
        }
        
        // Восстановление активных вкладок
        if let savedLeftTabIdStr = defaults.string(forKey: SessionKey.leftActiveTabId),
           let savedUUID = UUID(uuidString: savedLeftTabIdStr),
           leftTabs.contains(where: { $0.id == savedUUID }) {
            leftActiveTabId = savedUUID
        } else if let first = leftTabs.first {
            leftActiveTabId = first.id
        }
        
        if let savedRightTabIdStr = defaults.string(forKey: SessionKey.rightActiveTabId),
           let savedUUID = UUID(uuidString: savedRightTabIdStr),
           rightTabs.contains(where: { $0.id == savedUUID }) {
            rightActiveTabId = savedUUID
        } else if let first = rightTabs.first {
            rightActiveTabId = first.id
        }
        
        // Режим корня (панель показывала корень источника, а не вкладку) — после установки активных вкладок,
        // иначе didSet активной вкладки его сбросит
        leftIsRootMode = defaults.bool(forKey: SessionKey.leftIsRootMode)
        rightIsRootMode = defaults.bool(forKey: SessionKey.rightIsRootMode)

        // Синхронизация текущего пути и источника с активными вкладками (в режиме корня остаются сохранённые путь и источник)
        if !leftIsRootMode, let active = leftTabs.first(where: { $0.id == leftActiveTabId }) {
            leftPath = active.path
            leftSource = active.source
        }
        if !rightIsRootMode, let active = rightTabs.first(where: { $0.id == rightActiveTabId }) {
            rightPath = active.path
            rightSource = active.source
        }
        
        // Восстановление флагов видимости одиночных вкладок
        if defaults.object(forKey: SessionKey.areTabsVisibleLeft) != nil {
            areTabsVisibleLeft = defaults.bool(forKey: SessionKey.areTabsVisibleLeft)
        }
        if defaults.object(forKey: SessionKey.areTabsVisibleRight) != nil {
            areTabsVisibleRight = defaults.bool(forKey: SessionKey.areTabsVisibleRight)
        }
        
        // Восстановление настроек скрытия префиксов путей
        if let savedMacPrefix = defaults.string(forKey: SessionKey.macHiddenPathPrefix), !savedMacPrefix.isEmpty {
            macHiddenPathPrefix = savedMacPrefix
        }
        if let savedPhonePrefix = defaults.string(forKey: SessionKey.phoneHiddenPathPrefix), !savedPhonePrefix.isEmpty {
            phoneHiddenPathPrefix = savedPhonePrefix
        }
        if defaults.object(forKey: SessionKey.isPathPrefixHidingEnabled) != nil {
            isPathPrefixHidingEnabled = defaults.bool(forKey: SessionKey.isPathPrefixHidingEnabled)
        }
    }
    
    // MARK: - Path Display Settings
    public func resetPathDisplaySettings() {
        macHiddenPathPrefix = FileManager.default.homeDirectoryForCurrentUser.path
        phoneHiddenPathPrefix = "/storage/emulated/0"
        isPathPrefixHidingEnabled = true
        savePathDisplaySettings()
    }
    
    public func savePathDisplaySettings() {
        let defaults = UserDefaults.standard
        defaults.set(macHiddenPathPrefix, forKey: SessionKey.macHiddenPathPrefix)
        defaults.set(phoneHiddenPathPrefix, forKey: SessionKey.phoneHiddenPathPrefix)
        defaults.set(isPathPrefixHidingEnabled, forKey: SessionKey.isPathPrefixHidingEnabled)
    }
    
    public struct PathBreadcrumb: Identifiable, Equatable {
        public let id: String
        public let title: String
        public let fullPath: String
        public let isRoot: Bool
        
        public init(title: String, fullPath: String, isRoot: Bool = false) {
            self.id = fullPath + (isRoot ? "#root" : "")
            self.title = title
            self.fullPath = fullPath
            self.isRoot = isRoot
        }
    }
    
    /// Название корневого источника для отображения в начале строки пути
    public func rootSourceTitle(for path: String, source: FileSource) -> String {
        let activeUsb = detectedUsbDrives.first(where: { path.hasPrefix($0.path) })
        if let usb = activeUsb {
            return usb.name
        }
        if source == .localMac {
            return "Mac"
        } else {
            return connectedPhoneShortName
        }
    }
    
    /// Вычисление заголовка вкладки для заданного пути и источника.
    /// Для домашней папки Mac (или корня "/") отображается "Mac" (а не имя учетной записи, например "restart").
    /// Для корня накопителя телефона (/storage/emulated/0 или /sdcard) отображается имя телефона (например, Xiaomi), а не "0".
    public func defaultTabTitle(for path: String, source: FileSource) -> String {
        let cleanPath = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        
        if source == .localMac {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let cleanHome = (home.hasSuffix("/") && home.count > 1) ? String(home.dropLast()) : home
            if cleanPath == cleanHome || cleanPath == "/" || cleanPath.isEmpty {
                return rootSourceTitle(for: cleanPath, source: source)
            }
        } else {
            if cleanPath == "/storage/emulated/0" || cleanPath == "/sdcard" || cleanPath == "/" || cleanPath.isEmpty {
                return rootSourceTitle(for: cleanPath, source: source)
            }
        }
        
        if let usb = detectedUsbDrives.first(where: { cleanPath == $0.path || cleanPath == $0.path + "/" }) {
            return usb.name
        }
        
        let name = URL(fileURLWithPath: cleanPath).lastPathComponent
        if name.isEmpty || name == "/" {
            return rootSourceTitle(for: cleanPath, source: source)
        }
        if source == .localMac {
            let homeName = URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path).lastPathComponent
            if name == homeName && cleanPath == FileManager.default.homeDirectoryForCurrentUser.path {
                return rootSourceTitle(for: cleanPath, source: source)
            }
        } else if source == .remotePhone {
            if name == "0" && (cleanPath == "/storage/emulated/0" || cleanPath.hasSuffix("/0")) {
                return rootSourceTitle(for: cleanPath, source: source)
            }
        }
        return name
    }
    
    /// Генерация цепочки хлебных крошек с учетом настроек скрытия базовых префиксов (Mac и Phone)
    public func breadcrumbs(for path: String, source: FileSource) -> [PathBreadcrumb] {
        let cleanPath = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        let rootTitle = rootSourceTitle(for: cleanPath, source: source)
        
        let prefixToHide: String? = {
            guard isPathPrefixHidingEnabled else { return nil }
            if source == .localMac {
                let trimmed = macHiddenPathPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
                let clean = (trimmed.hasSuffix("/") && trimmed.count > 1) ? String(trimmed.dropLast()) : trimmed
                return clean.isEmpty ? nil : clean
            } else {
                let trimmed = phoneHiddenPathPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
                let clean = (trimmed.hasSuffix("/") && trimmed.count > 1) ? String(trimmed.dropLast()) : trimmed
                return clean.isEmpty ? nil : clean
            }
        }()
        
        if let prefix = prefixToHide, !prefix.isEmpty {
            if cleanPath == prefix {
                // Мы находимся в скрываемом базовом каталоге: отображаем имя источника
                return [PathBreadcrumb(title: rootTitle, fullPath: prefix, isRoot: true)]
            } else if cleanPath.hasPrefix(prefix + "/") {
                // Путь находится внутри скрываемого базового каталога
                var result: [PathBreadcrumb] = [
                    PathBreadcrumb(title: rootTitle, fullPath: prefix, isRoot: true)
                ]
                let relative = cleanPath.dropFirst(prefix.count + 1)
                let parts = relative.split(separator: "/").map(String.init)
                var accumulated = prefix
                for part in parts {
                    accumulated += "/" + part
                    result.append(PathBreadcrumb(title: part, fullPath: accumulated, isRoot: false))
                }
                return result
            }
        }
        
        // Обычный путь (не подпадает под скрываемый префикс, либо скрытие отключено)
        let parts = URL(fileURLWithPath: cleanPath).pathComponents
        guard !parts.isEmpty else {
            return [PathBreadcrumb(title: rootTitle, fullPath: "/", isRoot: true)]
        }
        
        var result: [PathBreadcrumb] = []
        var accumulated = ""
        for (index, component) in parts.enumerated() {
            if index == 0 {
                let targetRoot = (source == .localMac)
                    ? (FileManager.default.fileExists(atPath: cleanPath) ? "/" : FileManager.default.homeDirectoryForCurrentUser.path)
                    : "/"
                result.append(PathBreadcrumb(title: rootTitle, fullPath: targetRoot, isRoot: true))
                accumulated = ""
            } else {
                accumulated += "/" + component
                result.append(PathBreadcrumb(title: component, fullPath: accumulated, isRoot: false))
            }
        }
        return result
    }
    
    public func toggleActivePane() {
        let newSide: PaneSide = (activePane == .left) ? .right : .left
        TableDoubleClickHandler.HandlerView.ensureTableViewsDiscovered()
        if !isFileDiffActive {
            if newSide == .left {
                rightSelection.removeAll()
                TableDoubleClickHandler.HandlerView.rightTableView?.deselectAll(nil)
                let items = displayItems(for: .left)
                if leftSelection.isEmpty, let first = items.first {
                    leftSelection = [first.id]
                }
            } else {
                leftSelection.removeAll()
                TableDoubleClickHandler.HandlerView.leftTableView?.deselectAll(nil)
                let items = displayItems(for: .right)
                if rightSelection.isEmpty, let first = items.first {
                    rightSelection = [first.id]
                }
            }
        }
        activePane = newSide
        TableDoubleClickHandler.HandlerView.setActiveSide(newSide)
        
        let targetTv = (newSide == .left) ? TableDoubleClickHandler.HandlerView.leftTableView : TableDoubleClickHandler.HandlerView.rightTableView
        let targetSelection = (newSide == .left) ? leftSelection : rightSelection
        let targetItems = displayItems(for: newSide)
        
        if let targetId = targetSelection.first ?? targetItems.first?.id,
           let index = targetItems.firstIndex(where: { $0.id == targetId || $0.path == targetId }) {
            targetTv?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            targetTv?.scrollRowToVisible(index)
        }
        
        let win = targetTv?.window ?? NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
        if let tv = targetTv {
            win?.makeFirstResponder(tv)
        }
        
        if let targetId = targetSelection.first ?? targetItems.first?.id {
            TableDoubleClickHandler.HandlerView.focusAndScrollToItem(id: targetId, side: newSide)
        }
        saveSession()
    }
    
    // MARK: - Tabs Management
    /// Обновление содержимого панели / активной вкладки (Ctrl+R / Cmd+R):
    /// 1. При наличии видимых вкладок — обновляет панель до содержимого активной вкладки (activeTab).
    /// 2. Если активных закладок и вообще закладок нет — сбрасывает и обновляет содержимое до корневой папки Mac или телефона.
    public func refreshPaneToActiveTab(side: PaneSide) {
        if activePane != side {
            activePane = side
            TableDoubleClickHandler.HandlerView.setActiveSide(side)
        }
        
        let visible = visibleTabs(for: side)
        let currentSource = (side == .left) ? leftSource : rightSource
        let currentPath = (side == .left) ? leftPath : rightPath
        
        if !visible.isEmpty {
            // Случай 1: Есть активные видимые вкладки -> обновляем до содержимого активной вкладки
            let tabs = (side == .left) ? leftTabs : rightTabs
            let activeId = (side == .left) ? leftActiveTabId : rightActiveTabId
            let activeTab = tabs.first(where: { $0.id == activeId }) ?? visible.first
            
            if let tab = activeTab {
                let targetPath: String
                let targetSource: FileSource
                
                // Проверяем соответствие платформе: если вкладка совпадает с текущим источником, используем её путь
                if tab.source == currentSource {
                    targetSource = currentSource
                    targetPath = tab.path
                } else if currentSource == .remotePhone {
                    // Источник панели - телефон, а вкладка была Mac: сохраняем телефонный источник и текущий путь (или /storage/emulated/0)
                    targetSource = .remotePhone
                    targetPath = currentPath.hasPrefix("/storage") ? currentPath : "/storage/emulated/0"
                } else {
                    // Источник панели - Mac, а вкладка была телефон: сохраняем Mac и текущий путь (или Home)
                    targetSource = .localMac
                    targetPath = !currentPath.hasPrefix("/storage") && FileManager.default.fileExists(atPath: currentPath)
                        ? currentPath
                        : FileManager.default.homeDirectoryForCurrentUser.path
                }
                
                if side == .left {
                    leftPath = targetPath
                    leftSource = targetSource
                    leftSelection.removeAll()
                } else {
                    rightPath = targetPath
                    rightSource = targetSource
                    rightSelection.removeAll()
                }
                
                if targetSource == .remotePhone {
                    DirectoryCache.shared.invalidate(path: targetPath)
                    if !remoteDriver.isConnected {
                        if side == .left { leftIsStale = false } else { rightIsStale = false }
                        if !isRunningTests {
                            connectPhone(forceActivate: false, isExplicit: true)
                        }
                        statusMessage = "Обновление вкладки: «\(tab.title)»..."
                        return
                    }
                }
                
                statusMessage = "Обновлено содержимое вкладки «\(tab.title)»"
                refreshPane(side: side)
            } else {
                refreshPane(side: side)
            }
        } else {
            // Случай 2: Вкладок нет (или скрыты) -> сброс и обновление до содержимого Mac или телефона
            let defaultPath: String
            if currentSource == .remotePhone {
                defaultPath = "/storage/emulated/0"
            } else if currentSource == .localMac {
                defaultPath = FileManager.default.homeDirectoryForCurrentUser.path
            } else {
                defaultPath = currentPath
            }
            
            if side == .left {
                leftPath = defaultPath
                leftSelection.removeAll()
                if !leftTabs.isEmpty {
                    leftTabs[0].path = defaultPath
                    leftTabs[0].source = currentSource
                    leftTabs[0].title = defaultTabTitle(for: defaultPath, source: currentSource)
                }
            } else {
                rightPath = defaultPath
                rightSelection.removeAll()
                if !rightTabs.isEmpty {
                    rightTabs[0].path = defaultPath
                    rightTabs[0].source = currentSource
                    rightTabs[0].title = defaultTabTitle(for: defaultPath, source: currentSource)
                }
            }
            
            if currentSource == .remotePhone {
                DirectoryCache.shared.invalidate(path: defaultPath)
                if !remoteDriver.isConnected {
                    if side == .left { leftIsStale = false } else { rightIsStale = false }
                    if !isRunningTests {
                        connectPhone(forceActivate: false, isExplicit: true)
                    }
                    statusMessage = "Телефон (/storage/emulated/0)..."
                    return
                }
                statusMessage = "Обновлено содержимое: Телефон (/storage/emulated/0)"
            } else {
                statusMessage = "Обновлено содержимое: Mac (\(defaultPath))"
            }
            
            refreshPane(side: side)
        }
    }
    public func addTab(side: PaneSide) {
        let currentPath = (side == .left) ? leftPath : rightPath
        let currentSource = (side == .left) ? leftSource : rightSource
        let tabs = (side == .left) ? leftTabs : rightTabs
        let isCurrentlyVisible = !visibleTabs(for: side).isEmpty
        
        // 1. Если вкладки были скрыты (состояние 0 видимых вкладок):
        // При нажатии '+' пользователь создает первую видимую вкладку для текущей директории.
        // Не создаем дубликат — делаем первую вкладку видимой и синхронизируем с текущим путем!
        if !isCurrentlyVisible {
            if side == .left {
                areTabsVisibleLeft = true
                if !leftTabs.isEmpty {
                    leftTabs[0].path = currentPath
                    leftTabs[0].source = currentSource
                    leftTabs[0].title = defaultTabTitle(for: currentPath, source: currentSource)
                    leftActiveTabId = leftTabs[0].id
                } else {
                    let newTab = PanelTab(
                        title: defaultTabTitle(for: currentPath, source: currentSource),
                        path: currentPath,
                        source: currentSource
                    )
                    leftTabs = [newTab]
                    leftActiveTabId = newTab.id
                }
            } else {
                areTabsVisibleRight = true
                if !rightTabs.isEmpty {
                    rightTabs[0].path = currentPath
                    rightTabs[0].source = currentSource
                    rightTabs[0].title = defaultTabTitle(for: currentPath, source: currentSource)
                    rightActiveTabId = rightTabs[0].id
                } else {
                    let newTab = PanelTab(
                        title: defaultTabTitle(for: currentPath, source: currentSource),
                        path: currentPath,
                        source: currentSource
                    )
                    rightTabs = [newTab]
                    rightActiveTabId = newTab.id
                }
            }
            let title = defaultTabTitle(for: currentPath, source: currentSource)
            statusMessage = "Вкладка «\(title)» создана"
            saveSession()
            return
        }
        
        // 2. Если в таблице/сетке выделена ровно одна папка, открываем её в новой вкладке
        let selection = (side == .left) ? leftSelection : rightSelection
        let items = (side == .left) ? leftItems : rightItems
        if selection.count == 1,
           let selectedId = selection.first,
           let selectedItem = items.first(where: { $0.id == selectedId }),
           selectedItem.isDirectory {
            openFolderInNewTab(path: selectedItem.path, source: selectedItem.source, side: side)
            return
        }
        
        // 3. Открываем текущую папку (с проверкой на уникальность)
        openFolderInNewTab(path: currentPath, source: currentSource, side: side)
    }
    
    /// Открытие указанной папки в новой вкладке с гарантией уникальности (без дубликатов для одной и той же директории)
    public func openFolderInNewTab(path: String, source: FileSource, side: PaneSide) {
        let tabs = (side == .left) ? leftTabs : rightTabs
        
        // Правило: Запрет создания дубликатов для одной и той же директории
        if let existing = tabs.first(where: { $0.path == path && $0.source == source }) {
            switchTab(id: existing.id, side: side)
            statusMessage = "Вкладка для этой папки уже открыта: «\(existing.title)»"
            return
        }
        
        let newTab = PanelTab(
            title: defaultTabTitle(for: path, source: source),
            path: path,
            source: source
        )
        
        if side == .left {
            areTabsVisibleLeft = true
            leftTabs.append(newTab)
            leftActiveTabId = newTab.id
        } else {
            areTabsVisibleRight = true
            rightTabs.append(newTab)
            rightActiveTabId = newTab.id
        }
        
        statusMessage = "Создана вкладка: «\(newTab.title)»"
        saveSession()
    }
    
    /// Список вкладок, которые должны отображаться в интерфейсе.
    /// Если в панели вкладки не были явно созданы/активированы пользователем и нет нескольких или закрепленных вкладок,
    /// они остаются невидимыми, чтобы не дублировать активную кнопку источника (Mac / Phone / USB).
    public func visibleTabs(for side: PaneSide) -> [PanelTab] {
        let tabs = (side == .left) ? leftTabs : rightTabs
        let isExplicit = (side == .left) ? areTabsVisibleLeft : areTabsVisibleRight
        if tabs.count > 1 || tabs.contains(where: { $0.isPinned }) || isExplicit {
            return tabs
        }
        return []
    }
    
    public func closeTab(id: UUID, side: PaneSide) {
        if side == .left {
            if let tab = leftTabs.first(where: { $0.id == id }), tab.isPinned {
                return // Закрепленную вкладку нельзя закрыть
            }
            if leftTabs.count > 1 {
                leftTabs.removeAll(where: { $0.id == id })
                if leftActiveTabId == id, let first = leftTabs.first {
                    switchTab(id: first.id, side: .left)
                } else {
                    saveSession()
                }
            } else {
                // Закрытие последней вкладки: скрываем вкладку из интерфейса
                areTabsVisibleLeft = false
                saveSession()
            }
        } else if side == .right {
            if let tab = rightTabs.first(where: { $0.id == id }), tab.isPinned {
                return // Закрепленную вкладку нельзя закрыть
            }
            if rightTabs.count > 1 {
                rightTabs.removeAll(where: { $0.id == id })
                if rightActiveTabId == id, let first = rightTabs.first {
                    switchTab(id: first.id, side: .right)
                } else {
                    saveSession()
                }
            } else {
                // Закрытие последней вкладки: скрываем вкладку из интерфейса
                areTabsVisibleRight = false
                saveSession()
            }
        }
    }
    
    public func togglePinTab(id: UUID, side: PaneSide) {
        if side == .left {
            if let index = leftTabs.firstIndex(where: { $0.id == id }) {
                leftTabs[index].isPinned.toggle()
                if leftTabs[index].isPinned {
                    leftTabs[index].title = defaultTabTitle(for: leftPath, source: leftSource)
                    leftTabs[index].path = leftPath
                    leftTabs[index].source = leftSource
                } else {
                    updateActiveTab(side: .left)
                }
                statusMessage = leftTabs[index].isPinned ? "Вкладка '\(leftTabs[index].title)' закреплена" : "Вкладка '\(leftTabs[index].title)' откреплена"
                saveSession()
            }
        } else {
            if let index = rightTabs.firstIndex(where: { $0.id == id }) {
                rightTabs[index].isPinned.toggle()
                if rightTabs[index].isPinned {
                    rightTabs[index].title = defaultTabTitle(for: rightPath, source: rightSource)
                    rightTabs[index].path = rightPath
                    rightTabs[index].source = rightSource
                } else {
                    updateActiveTab(side: .right)
                }
                statusMessage = rightTabs[index].isPinned ? "Вкладка '\(rightTabs[index].title)' закреплена" : "Вкладка '\(rightTabs[index].title)' откреплена"
                saveSession()
            }
        }
    }
    
    public func duplicateTab(id: UUID, side: PaneSide) {
        if side == .left {
            if let index = leftTabs.firstIndex(where: { $0.id == id }) {
                let current = leftTabs[index]
                let newTab = PanelTab(title: current.title, path: current.path, source: current.source, isPinned: false)
                leftTabs.insert(newTab, at: index + 1)
                areTabsVisibleLeft = true
                switchTab(id: newTab.id, side: .left)
                statusMessage = "Вкладка дублирована: \(newTab.title)"
                saveSession()
            }
        } else {
            if let index = rightTabs.firstIndex(where: { $0.id == id }) {
                let current = rightTabs[index]
                let newTab = PanelTab(title: current.title, path: current.path, source: current.source, isPinned: false)
                rightTabs.insert(newTab, at: index + 1)
                areTabsVisibleRight = true
                switchTab(id: newTab.id, side: .right)
                statusMessage = "Вкладка дублирована: \(newTab.title)"
                saveSession()
            }
        }
    }
    
    public func switchTab(id: UUID, side: PaneSide) {
        if activePane != side {
            activePane = side
        }
        closeSearch(side: side)
        if side == .left, let tab = leftTabs.first(where: { $0.id == id }) {
            leftActiveTabId = id
            leftPath = tab.path
            leftSource = tab.source
            showTabContentImmediately(side: .left, path: tab.path, source: tab.source)
            if tab.source == .remotePhone && !remoteDriver.isConnected {
                leftIsStale = false
                if !isRunningTests {
                    connectPhone(forceActivate: false, isExplicit: true)
                }
            } else {
                refreshPane(side: .left)
            }
            saveSession()
        } else if side == .right, let tab = rightTabs.first(where: { $0.id == id }) {
            rightActiveTabId = id
            rightPath = tab.path
            rightSource = tab.source
            showTabContentImmediately(side: .right, path: tab.path, source: tab.source)
            if tab.source == .remotePhone && !remoteDriver.isConnected {
                rightIsStale = false
                if !isRunningTests {
                    connectPhone(forceActivate: false, isExplicit: true)
                }
            } else {
                refreshPane(side: .right)
            }
            saveSession()
        }
    }

    /// Сразу подменяет список файлов панели содержимым новой вкладки, не дожидаясь `refreshPane`.
    /// Иначе до ответа драйвера (а для неподключённого телефона — бесконечно) на экране остаются файлы предыдущей вкладки.
    /// Берём свежий кеш телефона, если он есть; иначе список пуст до загрузки.
    private func showTabContentImmediately(side: PaneSide, path: String, source: FileSource) {
        let items = (source == .remotePhone) ? (DirectoryCache.shared.get(path: path) ?? []) : []
        if side == .left {
            leftItems = items
        } else {
            rightItems = items
        }
    }

    /// Чинит закреплённую вкладку, чьё название — папка домашнего каталога Mac (например, «Downloads»), а путь «уехал»
    /// в корень (домашнюю папку Mac или корень телефона). Так портились вкладки, когда путь закреплённой вкладки
    /// перезаписывался при смене источника панели, а название оставалось прежним.
    public func repairedPinnedLocation(for tab: PanelTab, homePath: String) -> (path: String, source: FileSource)? {
        guard tab.isPinned, !tab.title.isEmpty, !tab.title.contains("/") else { return nil }
        let isRootPath = (tab.source == .localMac && tab.path == homePath) ||
            (tab.source == .remotePhone && (tab.path == "/storage/emulated/0" || tab.path == "/sdcard"))
        guard isRootPath else { return nil }
        let candidate = (homePath as NSString).appendingPathComponent(tab.title)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return (candidate, .localMac)
    }
    
    public func renameTab(id: UUID, newTitle: String, side: PaneSide) {
        let cleanTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        if side == .left {
            if let index = leftTabs.firstIndex(where: { $0.id == id }) {
                leftTabs[index].title = cleanTitle
                statusMessage = "Вкладка переименована: \(cleanTitle)"
                saveSession()
            }
        } else {
            if let index = rightTabs.firstIndex(where: { $0.id == id }) {
                rightTabs[index].title = cleanTitle
                statusMessage = "Вкладка переименована: \(cleanTitle)"
                saveSession()
            }
        }
    }
    
    public func moveTab(fromIndex: Int, toIndex: Int, side: PaneSide) {
        if side == .left {
            guard fromIndex >= 0 && fromIndex < leftTabs.count,
                  toIndex >= 0 && toIndex < leftTabs.count,
                  fromIndex != toIndex else { return }
            let item = leftTabs.remove(at: fromIndex)
            leftTabs.insert(item, at: toIndex)
            saveSession()
        } else {
            guard fromIndex >= 0 && fromIndex < rightTabs.count,
                  toIndex >= 0 && toIndex < rightTabs.count,
                  fromIndex != toIndex else { return }
            let item = rightTabs.remove(at: fromIndex)
            rightTabs.insert(item, at: toIndex)
            saveSession()
        }
    }
    
    // MARK: - Tabs Export & Import (JSON)
    
    /// Экспорт всех открытых вкладок обеих панелей со статусом закрепления в JSON-файл
    public func exportTabsToFile(url: URL) throws {
        updateActiveTab(side: .left)
        updateActiveTab(side: .right)
        
        let exportData = TabsExportData(
            leftTabs: leftTabs,
            rightTabs: rightTabs,
            leftActiveTabId: leftActiveTabId,
            rightActiveTabId: rightActiveTabId
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(exportData)
        try data.write(to: url, options: .atomic)
        statusMessage = "Вкладки сохранены: \(url.lastPathComponent)"
    }
    
    /// Валидация пути и названия вкладки для безопасного импорта
    private func sanitizeImportedTab(_ tab: PanelTab) -> PanelTab {
        var validPath = tab.path
        if tab.source == .localMac {
            if validPath.hasPrefix("/storage") || !FileManager.default.fileExists(atPath: validPath) {
                validPath = FileManager.default.homeDirectoryForCurrentUser.path
            }
        } else {
            if !validPath.hasPrefix("/storage") {
                validPath = "/storage/emulated/0"
            }
        }
        let title = tab.title.isEmpty ? (URL(fileURLWithPath: validPath).lastPathComponent) : tab.title
        return PanelTab(
            id: tab.id,
            title: (title.isEmpty || validPath == "/") ? "⌂" : title,
            path: validPath,
            source: tab.source,
            isPinned: tab.isPinned
        )
    }
    
    /// Импорт вкладок из JSON-файла:
    /// - .replace: полностью замещает существующие вкладки в обеих панелях
    /// - .append: добавляет импортированные вкладки к существующим (с уникальными новыми id)
    public func importTabsFromFile(url: URL, mode: TabImportMode) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let imported = try decoder.decode(TabsExportData.self, from: data)
        
        switch mode {
        case .replace:
            let sanitizedLeft = imported.leftTabs.map { sanitizeImportedTab($0) }
            let sanitizedRight = imported.rightTabs.map { sanitizeImportedTab($0) }
            
            if !sanitizedLeft.isEmpty {
                leftTabs = sanitizedLeft
                if let activeId = imported.leftActiveTabId, leftTabs.contains(where: { $0.id == activeId }) {
                    leftActiveTabId = activeId
                } else if let first = leftTabs.first {
                    leftActiveTabId = first.id
                }
            }
            
            if !sanitizedRight.isEmpty {
                rightTabs = sanitizedRight
                if let activeId = imported.rightActiveTabId, rightTabs.contains(where: { $0.id == activeId }) {
                    rightActiveTabId = activeId
                } else if let first = rightTabs.first {
                    rightActiveTabId = first.id
                }
            }
            
            refreshPaneToActiveTab(side: .left)
            refreshPaneToActiveTab(side: .right)
            saveSession()
            let totalCount = leftTabs.count + rightTabs.count
            statusMessage = "Вкладки импортированы (\(totalCount) шт.)"
            
        case .append:
            var addedCount = 0
            for importedTab in imported.leftTabs {
                let sanitized = sanitizeImportedTab(importedTab)
                // Создаем новый уникальный UUID для добавляемой вкладки
                let newTab = PanelTab(
                    id: UUID(),
                    title: sanitized.title,
                    path: sanitized.path,
                    source: sanitized.source,
                    isPinned: sanitized.isPinned
                )
                leftTabs.append(newTab)
                addedCount += 1
            }
            
            for importedTab in imported.rightTabs {
                let sanitized = sanitizeImportedTab(importedTab)
                let newTab = PanelTab(
                    id: UUID(),
                    title: sanitized.title,
                    path: sanitized.path,
                    source: sanitized.source,
                    isPinned: sanitized.isPinned
                )
                rightTabs.append(newTab)
                addedCount += 1
            }
            
            saveSession()
            statusMessage = "Вкладки добавлены (\(addedCount) шт.)"
        }
    }
    
    /// Вызов диалогового окна сохранения вкладок (Save tabs)
    public func saveTabsWithSavePanel() {
        let panel = NSSavePanel()
        panel.title = "Сохранить вкладки в JSON"
        panel.nameFieldStringValue = "MacDroidCommander_tabs.json"
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.json]
        } else {
            panel.allowedFileTypes = ["json"]
        }
        panel.canCreateDirectories = true
        
        if panel.runModal() == .OK, let targetURL = panel.url {
            do {
                try exportTabsToFile(url: targetURL)
            } catch {
                errorMessage = "Ошибка при сохранении вкладок: \(error.localizedDescription)"
                showErrorAlert = true
            }
        }
    }
    
    /// Вызов диалогового окна выбора файла для импорта вкладок (Import tabs / Add tabs)
    public func importTabsWithOpenPanel(mode: TabImportMode) {
        let panel = NSOpenPanel()
        panel.title = (mode == .replace) ? "Импортировать вкладки (с замещением)" : "Добавить вкладки из файла"
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.json]
        } else {
            panel.allowedFileTypes = ["json"]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        if panel.runModal() == .OK, let fileURL = panel.url {
            do {
                try importTabsFromFile(url: fileURL, mode: mode)
            } catch {
                errorMessage = "Ошибка при чтении файла вкладок: \(error.localizedDescription)"
                showErrorAlert = true
            }
        }
    }
    
    // MARK: - Memoized Display Items
    private struct DisplayCache {
        var version: Int
        var rawCount: Int
        var filter: String
        var tagFilter: String?
        var sortField: SortField
        var sortAsc: Bool
        var folderSortMode: FolderSortMode
        var showHidden: Bool
        var comparing: Bool
        var hideIdentical: Bool
        var result: [FileItem]
    }
    
    private var leftDisplayCache: DisplayCache?
    private var rightDisplayCache: DisplayCache?
    
    private func statusScore(for item: FileItem, side: PaneSide) -> Int {
        if side == .left {
            if comparisonResult.onlyLeft.contains(item.name) { return 0 }
            if comparisonResult.different.contains(item.name) { return 1 }
        } else {
            if comparisonResult.onlyRight.contains(item.name) { return 0 }
            if comparisonResult.different.contains(item.name) { return 1 }
        }
        return 2
    }
    
    public func displayItems(for side: PaneSide) -> [FileItem] {
        let query = (side == .left ? leftSearchQuery : rightSearchQuery).trimmingCharacters(in: .whitespaces)
        if isSearchActive(for: side) && !query.isEmpty {
            let searchItems = (side == .left) ? leftSearchResults : rightSearchResults
            let filter = (side == .left) ? leftFilter : rightFilter
            let sortField = (side == .left) ? leftSortField : rightSortField
            let sortAsc = (side == .left) ? leftSortAscending : rightSortAscending
            let folderSortMode = (side == .left) ? leftFolderSortMode : rightFolderSortMode
            let showHidden = (side == .left) ? leftShowHidden : rightShowHidden
            
            var filtered = searchItems
            if !showHidden {
                filtered = filtered.filter { !$0.name.hasPrefix(".") }
            }
            if !filter.isEmpty {
                filtered = filtered.filter { $0.name.localizedCaseInsensitiveContains(filter) }
            }
            if let tagFilter = selectedTagFilter, !tagFilter.isEmpty {
                filtered = filtered.filter { item in
                    Self.itemMatchesTag(item, tag: tagFilter)
                }
            }
            return sortFiles(filtered, sortField: sortField, sortAsc: sortAsc, folderSortMode: folderSortMode, comparing: false, side: side)
        }
        
        let raw = (side == .left) ? leftItems : rightItems
        let filter = (side == .left) ? leftFilter : rightFilter
        let sortField = (side == .left) ? leftSortField : rightSortField
        let sortAsc = (side == .left) ? leftSortAscending : rightSortAscending
        let folderSortMode = (side == .left) ? leftFolderSortMode : rightFolderSortMode
        let showHidden = (side == .left) ? leftShowHidden : rightShowHidden
        let comparing = isComparing
        let hideIdentical = hideIdenticalInComparison
        
        let version = (side == .left) ? leftItemsVersion : rightItemsVersion
        let rawCount = raw.count
        
        if side == .left, let cache = leftDisplayCache,
           cache.version == version,
           cache.rawCount == rawCount,
           cache.filter == filter,
           cache.tagFilter == selectedTagFilter,
           cache.sortField == sortField,
           cache.sortAsc == sortAsc,
           cache.folderSortMode == folderSortMode,
           cache.showHidden == showHidden,
           cache.comparing == comparing,
           cache.hideIdentical == hideIdentical {
            return cache.result
        }
        
        if side == .right, let cache = rightDisplayCache,
           cache.version == version,
           cache.rawCount == rawCount,
           cache.filter == filter,
           cache.tagFilter == selectedTagFilter,
           cache.sortField == sortField,
           cache.sortAsc == sortAsc,
           cache.folderSortMode == folderSortMode,
           cache.showHidden == showHidden,
           cache.comparing == comparing,
           cache.hideIdentical == hideIdentical {
            return cache.result
        }
        
        var filtered = raw
        if !showHidden {
            filtered = filtered.filter { !$0.name.hasPrefix(".") }
        }
        if comparing && hideIdentical {
            filtered = filtered.filter { !comparisonResult.identical.contains($0.name) }
        }
        if !filter.isEmpty {
            filtered = filtered.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        }
        
        // Фильтрация по тегам Finder
        if let tagFilter = selectedTagFilter, !tagFilter.isEmpty {
            filtered = filtered.filter { item in
                Self.itemMatchesTag(item, tag: tagFilter)
            }
        }
        
        let sorted = sortFiles(filtered, sortField: sortField, sortAsc: sortAsc, folderSortMode: folderSortMode, comparing: comparing, side: side)
        
        let newCache = DisplayCache(
            version: version,
            rawCount: rawCount,
            filter: filter,
            tagFilter: selectedTagFilter,
            sortField: sortField,
            sortAsc: sortAsc,
            folderSortMode: folderSortMode,
            showHidden: showHidden,
            comparing: comparing,
            hideIdentical: hideIdentical,
            result: sorted
        )
        if side == .left {
            leftDisplayCache = newCache
        } else {
            rightDisplayCache = newCache
        }
        
        return sorted
    }
    
    // MARK: - Сортировка файлов для панели и поиска
    public func sortFiles(
        _ items: [FileItem],
        sortField: SortField,
        sortAsc: Bool,
        folderSortMode: FolderSortMode,
        comparing: Bool,
        side: PaneSide
    ) -> [FileItem] {
        return items.sorted { a, b in
            if comparing && sortField == .name {
                let isRedA = (side == .left ? comparisonResult.onlyLeft : comparisonResult.onlyRight).contains(a.name)
                let isRedB = (side == .left ? comparisonResult.onlyLeft : comparisonResult.onlyRight).contains(b.name)
                if isRedA != isRedB {
                    return sortAsc ? isRedA : !isRedA
                }
            }
            if folderSortMode == .separate {
                if a.isDirectory != b.isDirectory {
                    return a.isDirectory && !b.isDirectory
                }
            }
            switch sortField {
            case .name:
                let cmp = a.name.localizedStandardCompare(b.name)
                if cmp != .orderedSame {
                    return sortAsc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
                } else {
                    if a.isDirectory != b.isDirectory {
                        return a.isDirectory
                    }
                    return false
                }
            case .type:
                if folderSortMode == .separate {
                    let typeCmp = a.fileType.localizedStandardCompare(b.fileType)
                    if typeCmp != .orderedSame {
                        return sortAsc ? (typeCmp == .orderedAscending) : (typeCmp == .orderedDescending)
                    } else {
                        let cmp = a.name.localizedStandardCompare(b.name)
                        return sortAsc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
                    }
                } else {
                    let typeA = a.isDirectory ? "" : a.fileType
                    let typeB = b.isDirectory ? "" : b.fileType
                    let typeCmp = typeA.localizedStandardCompare(typeB)
                    if typeCmp != .orderedSame {
                        return sortAsc ? (typeCmp == .orderedAscending) : (typeCmp == .orderedDescending)
                    } else {
                        let cmp = a.name.localizedStandardCompare(b.name)
                        if cmp != .orderedSame {
                            return sortAsc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
                        } else {
                            if a.isDirectory != b.isDirectory {
                                return a.isDirectory
                            }
                            return false
                        }
                    }
                }
            case .size:
                if folderSortMode == .separate {
                    if a.isDirectory && b.isDirectory {
                        let sizeA = calculatedFolderSizes[a.path]
                        let sizeB = calculatedFolderSizes[b.path]
                        switch (sizeA, sizeB) {
                        case let (.some(sA), .some(sB)):
                            if sA != sB {
                                return sortAsc ? (sA < sB) : (sA > sB)
                            } else {
                                let cmp = a.name.localizedStandardCompare(b.name)
                                return sortAsc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
                            }
                        case (.some, .none):
                            return true
                        case (.none, .some):
                            return false
                        case (.none, .none):
                            let cmp = a.name.localizedStandardCompare(b.name)
                            return sortAsc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
                        }
                    } else {
                        if a.size != b.size {
                            return sortAsc ? (a.size < b.size) : (a.size > b.size)
                        } else {
                            let cmp = a.name.localizedStandardCompare(b.name)
                            return sortAsc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
                        }
                    }
                } else {
                    let sizeA: Int64? = a.isDirectory ? calculatedFolderSizes[a.path].map { Int64($0) } : Int64(a.size)
                    let sizeB: Int64? = b.isDirectory ? calculatedFolderSizes[b.path].map { Int64($0) } : Int64(b.size)
                    switch (sizeA, sizeB) {
                    case let (.some(sA), .some(sB)):
                        if sA != sB {
                            return sortAsc ? (sA < sB) : (sA > sB)
                        } else {
                            let cmp = a.name.localizedStandardCompare(b.name)
                            return sortAsc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
                        }
                    case (.some, .none):
                        return true
                    case (.none, .some):
                        return false
                    case (.none, .none):
                        let cmp = a.name.localizedStandardCompare(b.name)
                        return sortAsc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
                    }
                }
            case .tags:
                let tagA = a.tags.first
                let tagB = b.tags.first
                let hasTagA = (tagA != nil && !tagA!.isEmpty)
                let hasTagB = (tagB != nil && !tagB!.isEmpty)
                
                if hasTagA && !hasTagB {
                    return true
                } else if !hasTagA && hasTagB {
                    return false
                } else if hasTagA && hasTagB {
                    let cmp = tagA!.localizedStandardCompare(tagB!)
                    if cmp != .orderedSame {
                        return sortAsc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
                    } else {
                        let nameCmp = a.name.localizedStandardCompare(b.name)
                        return sortAsc ? (nameCmp == .orderedAscending) : (nameCmp == .orderedDescending)
                    }
                } else {
                    let nameCmp = a.name.localizedStandardCompare(b.name)
                    return sortAsc ? (nameCmp == .orderedAscending) : (nameCmp == .orderedDescending)
                }
            case .date:
                if a.mtime != b.mtime {
                    return sortAsc ? (a.mtime < b.mtime) : (a.mtime > b.mtime)
                } else {
                    let cmp = a.name.localizedStandardCompare(b.name)
                    return sortAsc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
                }
            case .status:
                if comparing {
                    let aStatus = statusScore(for: a, side: side)
                    let bStatus = statusScore(for: b, side: side)
                    if aStatus != bStatus {
                        return sortAsc ? (aStatus < bStatus) : (aStatus > bStatus)
                    }
                }
                let cmp = a.name.localizedStandardCompare(b.name)
                return sortAsc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
            }
        }
    }
    
    // MARK: - Встроенный поиск в стиле Finder
    
    public func isSearchActive(for side: PaneSide) -> Bool {
        side == .left ? isLeftSearchActive : isRightSearchActive
    }
    
    public func openSearch(side: PaneSide) {
        if side == .left {
            isLeftSearchActive = true
        } else {
            isRightSearchActive = true
        }
        activePane = side
        searchFocusTrigger &+= 1
    }
    
    public func setSearchMatchContent(_ matchContent: Bool, side: PaneSide) {
        if side == .left {
            leftSearchMatchContent = matchContent
        } else {
            rightSearchMatchContent = matchContent
        }
        startSearch(side: side)
    }
    
    public func setSearchScope(_ scope: SearchScope, side: PaneSide) {
        if side == .left {
            leftSearchScope = scope
        } else {
            rightSearchScope = scope
        }
        startSearch(side: side)
    }
    
    public func closeSearch(side: PaneSide) {
        if side == .left {
            leftSearchTask?.cancel()
            leftSearchTask = nil
            isLeftSearching = false
            isLeftSearchActive = false
            leftSearchQuery = ""
            leftSearchResults.removeAll()
            leftItemsVersion &+= 1
        } else {
            rightSearchTask?.cancel()
            rightSearchTask = nil
            isRightSearching = false
            isRightSearchActive = false
            rightSearchQuery = ""
            rightSearchResults.removeAll()
            rightItemsVersion &+= 1
        }
    }
    
    public func toggleSearch(side: PaneSide) {
        if isSearchActive(for: side) {
            closeSearch(side: side)
        } else {
            openSearch(side: side)
        }
    }
    
    public func stopSearch(side: PaneSide) {
        if side == .left {
            leftSearchTask?.cancel()
            leftSearchTask = nil
            isLeftSearching = false
        } else {
            rightSearchTask?.cancel()
            rightSearchTask = nil
            isRightSearching = false
        }
    }
    
    public func startSearch(side: PaneSide) {
        let query = (side == .left ? leftSearchQuery : rightSearchQuery).trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            if side == .left {
                leftSearchTask?.cancel()
                leftSearchTask = nil
                isLeftSearching = false
                leftSearchResults.removeAll()
                leftItemsVersion &+= 1
            } else {
                rightSearchTask?.cancel()
                rightSearchTask = nil
                isRightSearching = false
                rightSearchResults.removeAll()
                rightItemsVersion &+= 1
            }
            return
        }
        
        let scope = (side == .left ? leftSearchScope : rightSearchScope)
        let searchContent = (side == .left ? leftSearchMatchContent : rightSearchMatchContent)
        let src = (side == .left ? leftSource : rightSource)
        let currentP = (side == .left ? leftPath : rightPath)
        
        // Определение каталога для поиска
        let targetDir: String
        if scope == .everywhere {
            targetDir = (src == .localMac) ? "/" : "/"
        } else {
            targetDir = currentP
        }
        
        stopSearch(side: side)
        
        if side == .left {
            isLeftSearching = true
            leftSearchResults.removeAll()
            leftItemsVersion &+= 1
        } else {
            isRightSearching = true
            rightSearchResults.removeAll()
            rightItemsVersion &+= 1
        }
        
        let task = Task {
            do {
                _ = try await SearchService.shared.search(
                    query: query,
                    in: targetDir,
                    source: src,
                    localDriver: self.localDriver,
                    remoteDriver: self.remoteDriver,
                    searchContent: searchContent
                ) { [weak self] foundItem in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        if side == .left {
                            self.leftSearchResults.append(foundItem)
                            self.leftItemsVersion &+= 1
                        } else {
                            self.rightSearchResults.append(foundItem)
                            self.rightItemsVersion &+= 1
                        }
                    }
                }
            } catch {
                // Ignore cancellation
            }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if side == .left {
                    self.isLeftSearching = false
                } else {
                    self.isRightSearching = false
                }
            }
        }
        
        if side == .left {
            leftSearchTask = task
        } else {
            rightSearchTask = task
        }
    }
    
    public func revealInFolder(item: FileItem, side: PaneSide) {
        closeSearch(side: side)
        let parentDir = item.isDirectory ? item.path : URL(fileURLWithPath: item.path).deletingLastPathComponent().path
        if side == .left {
            leftPath = parentDir
            leftSelection = [item.path]
            refreshPane(side: .left)
        } else {
            rightPath = parentDir
            rightSelection = [item.path]
            refreshPane(side: .right)
        }
    }
    
    /// Проверка соответствия файла выбранному тегу (Finder Tags или имя файла)
    public static func itemMatchesTag(_ item: FileItem, tag: String) -> Bool {
        let tagLower = tag.lowercased()
        if !item.tags.isEmpty {
            if item.tags.contains(where: { t in
                let tLower = t.lowercased()
                if tLower == tagLower { return true }
                if isTagEquivalent(tLower, tagLower) { return true }
                return false
            }) {
                return true
            }
        }
        if item.source == .localMac {
            let url = URL(fileURLWithPath: item.path)
            if let tags = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames, !tags.isEmpty {
                return tags.contains { t in
                    let tLower = t.lowercased()
                    if tLower == tagLower { return true }
                    if isTagEquivalent(tLower, tagLower) { return true }
                    return false
                }
            }
        }
        let nameLower = item.name.lowercased()
        if nameLower.contains(tagLower) { return true }
        if let synonyms = synonymsForTag(tagLower) {
            return synonyms.contains { nameLower.contains($0) }
        }
        return false
    }
    
    private static func isTagEquivalent(_ a: String, _ b: String) -> Bool {
        if let synonyms = synonymsForTag(a) {
            return synonyms.contains(b)
        }
        return false
    }
    
    private static func synonymsForTag(_ tag: String) -> [String]? {
        let redSynonyms = ["red", "красный", "червоний"]
        let orangeSynonyms = ["orange", "оранжевый", "оранжевий", "помаранчевий"]
        let yellowSynonyms = ["yellow", "желтый", "жовтий"]
        let greenSynonyms = ["green", "greem", "зеленый", "зелений"]
        let blueSynonyms = ["blue", "синий", "синій", "голубой", "блакитний"]
        let greySynonyms = ["grey", "gray", "серый", "сірий"]
        let purpleSynonyms = ["purple", "фиолетовый", "бузковий"]
        
        let groups = [redSynonyms, orangeSynonyms, yellowSynonyms, greenSynonyms, blueSynonyms, greySynonyms, purpleSynonyms]
        for g in groups {
            if g.contains(tag) { return g }
        }
        return nil
    }
    
    /// Переключение тега для списка объектов (файлов или папок)
    public func toggleTag(_ tag: String, for items: [FileItem], side: PaneSide) {
        let targetItems: [FileItem]
        if !items.isEmpty {
            targetItems = items
        } else {
            let selection = (side == .left) ? leftSelection : rightSelection
            let currentItems = (side == .left) ? leftItems : rightItems
            targetItems = currentItems.filter { selection.contains($0.id) }
        }
        guard !targetItems.isEmpty else { return }
        
        let updatedMap = TagsManager.shared.applyTagToggle(tag, to: targetItems)
        
        let updateList = { (itemList: inout [FileItem]) in
            for i in itemList.indices {
                if let newTags = updatedMap[itemList[i].id] {
                    itemList[i].tags = newTags
                }
            }
        }
        
        updateList(&leftItems)
        updateList(&rightItems)
        leftDisplayCache = nil
        rightDisplayCache = nil
        objectWillChange.send()
    }
    
    // MARK: - Directory Comparison
    public func comparePanes() {
        if isComparing {
            cancelDirectoryComparison()
            isComparing = false
            hideIdenticalInComparison = false
            comparisonResult = DirectoryComparisonResult()
            statusMessage = "Сравнение каталогов отключено"
        } else {
            isComparing = true
            startDirectoryComparison()
        }
    }

    private func cancelDirectoryComparison() {
        comparisonGeneration &+= 1
        comparisonTask?.cancel()
        comparisonTask = nil
        isComparisonRunning = false
        comparisonResult = DirectoryComparisonResult()
    }

    private func startDirectoryComparison() {
        cancelDirectoryComparison()
        guard isComparing else { return }
        // Не сравниваем прежний список одной панели с новым списком другой.
        guard leftComparisonReady, rightComparisonReady, !leftIsStale, !rightIsStale,
              !(isConnectingPhone && (leftSource == .remotePhone || rightSource == .remotePhone)) else {
            statusMessage = "Сравнение не завершено: содержимое панели недоступно. Обновите панели."
            return
        }
        let left = leftItems, right = rightItems
        let generation = comparisonGeneration
        let local = localDriver, remote = remoteDriver, comparator = comparator
        let content = FileContentService(transport: transport)
        isComparisonRunning = true
        statusMessage = "Сравнение содержимого файлов и вложенных папок (SHA-256)…"
        comparisonTask = Task { [weak self] in
            do {
                let result = try await comparator.compare(left: left, right: right, listDirectory: { item in
                    if item.source == .localMac {
                        return try await local.listDirectory(at: item.path)
                    }
                    return try await remote.listDirectory(at: item.path, forceRefresh: true)
                }, contentDigest: { item in try await content.digest(item) })
                guard let self, self.isComparing, self.comparisonGeneration == generation else { return }
                self.isComparisonRunning = false
                self.comparisonResult = result
                self.showDirectoryComparisonSummary()
            } catch {
                guard let self, self.isComparing, self.comparisonGeneration == generation else { return }
                self.isComparisonRunning = false
                self.statusMessage = "Сравнение не завершено: \(error.localizedDescription)"
            }
        }
    }

    private func showDirectoryComparisonSummary() {
        statusMessage = "Сравнение: одинаковых: \(comparisonResult.identical.count), измененных: \(comparisonResult.different.count), слева: \(comparisonResult.onlyLeft.count), справа: \(comparisonResult.onlyRight.count)"
    }
    
    public func selectDifferences() {
        guard isComparing, !isComparisonRunning else { return }
        let diffLeft = comparisonResult.onlyLeft.union(comparisonResult.different)
        let diffRight = comparisonResult.onlyRight.union(comparisonResult.different)
        
        leftSelection = Set(leftItems.filter { diffLeft.contains($0.name) }.map(\.id))
        rightSelection = Set(rightItems.filter { diffRight.contains($0.name) }.map(\.id))
        statusMessage = "Выделены различия: \(leftSelection.count) слева, \(rightSelection.count) справа"
    }
    
    public enum SyncDirection {
        case leftToRight
        case rightToLeft
    }
    
    public func syncDifferences(direction: SyncDirection) {
        guard isComparing, !isComparisonRunning else { return }
        
        switch direction {
        case .leftToRight:
            let diffLeft = comparisonResult.onlyLeft.union(comparisonResult.different)
            let itemsToSync = leftItems.filter { diffLeft.contains($0.name) }
            guard !itemsToSync.isEmpty else {
                statusMessage = "Нет файлов для синхронизации слева направо"
                return
            }
            let paths = itemsToSync.map(\.path)
            executeTransfer(paths: paths, fromSource: leftSource, toSide: .right, isMove: false)
            statusMessage = "Запущена синхронизация: \(paths.count) элементов →"
            
        case .rightToLeft:
            let diffRight = comparisonResult.onlyRight.union(comparisonResult.different)
            let itemsToSync = rightItems.filter { diffRight.contains($0.name) }
            guard !itemsToSync.isEmpty else {
                statusMessage = "Нет файлов для синхронизации справа налево"
                return
            }
            let paths = itemsToSync.map(\.path)
            executeTransfer(paths: paths, fromSource: rightSource, toSide: .left, isMove: false)
            statusMessage = "Запущена синхронизация: ← \(paths.count) элементов"
        }
    }
    
    // MARK: - Quick View Image Mode
    public func toggleQuickView() {
        isQuickViewActive.toggle()
        if isQuickViewActive {
            statusMessage = "Режим быстрого просмотра (Quick View) включён"
        } else {
            statusMessage = "Режим быстрого просмотра (Quick View) выключен"
        }
        saveSession()
    }
    
    // MARK: - Fullscreen Grid Viewer Mode
    public func openFullscreenGrid(side: PaneSide) {
        fullscreenGridPaneSide = side
        activePane = side
        GridFullscreenViewerWindowController.shared.show(for: side, viewModel: self)
    }
    
    public func closeFullscreenGrid() {
        fullscreenGridPaneSide = nil
        GridFullscreenViewerWindowController.shared.close()
    }
    
    public var quickViewItem: FileItem? {
        let side = activePane
        let selected = (side == .left) ? leftSelection : rightSelection
        let items = displayItems(for: side)
        if let firstSelected = selected.first,
           let item = items.first(where: { $0.id == firstSelected || $0.path == firstSelected || $0.name == firstSelected }) {
            return item
        }
        return items.first
    }
    
    public func downloadRemoteFile(remotePath: String, targetURL: URL, totalSize: UInt64) async throws {
        let stat = try await transport.prepareRead(actionId: UUID().uuidString, path: remotePath)
        try await transport.downloadFileStreaming(
            actionId: UUID().uuidString,
            remotePath: remotePath,
            targetURL: targetURL,
            totalSize: totalSize > 0 ? totalSize : stat.size
        ) { _ in }
    }
    
    public func downloadRemoteFile(item: FileItem) async -> URL? {
        do {
            return try await QuickLookCacheManager.shared.fetchFile(item: item, transport: transport)
        } catch {
            print("ERROR: Failed to download remote file \(item.path): \(error)")
            return nil
        }
    }
    
    public func swapPanes() {
        // Идущие обновления относятся к старым источникам панелей: отменяем их, иначе результат
        // попадёт в чужую панель. После обмена обе панели перечитываются заново (U3).
        leftRefreshTask?.cancel()
        rightRefreshTask?.cancel()
        leftIsRefreshing = false
        rightIsRefreshing = false

        let tempSource = leftSource
        let tempPath = leftPath
        let tempItems = leftItems
        let tempSelection = leftSelection
        let tempFilter = leftFilter
        let tempSortField = leftSortField
        let tempSortAscending = leftSortAscending
        let tempFolderSortMode = leftFolderSortMode
        let tempFreeSpace = leftFreeSpace
        let tempIsStale = leftIsStale
        let tempTabs = leftTabs
        let tempActiveTabId = leftActiveTabId
        let tempIsRootMode = leftIsRootMode
        let rightIsRootModeBeforeSwap = rightIsRootMode
        let tempViewMode = leftViewMode
        let tempThumbnailSize = leftGridThumbnailSize
        let tempSpacing = leftGridSpacing
        
        leftSource = rightSource
        leftPath = rightPath
        leftItems = rightItems
        leftSelection = rightSelection
        leftFilter = rightFilter
        leftSortField = rightSortField
        leftSortAscending = rightSortAscending
        leftFolderSortMode = rightFolderSortMode
        leftFreeSpace = rightFreeSpace
        leftIsStale = rightIsStale
        leftTabs = rightTabs
        leftActiveTabId = rightActiveTabId
        leftViewMode = rightViewMode
        leftGridThumbnailSize = rightGridThumbnailSize
        leftGridSpacing = rightGridSpacing
        
        rightSource = tempSource
        rightPath = tempPath
        rightItems = tempItems
        rightSelection = tempSelection
        rightFilter = tempFilter
        rightSortField = tempSortField
        rightSortAscending = tempSortAscending
        rightFolderSortMode = tempFolderSortMode
        rightFreeSpace = tempFreeSpace
        rightIsStale = tempIsStale
        rightTabs = tempTabs
        rightActiveTabId = tempActiveTabId
        // didSet активной вкладки сбросил режимы корня: возвращаем их вместе с панелями
        leftIsRootMode = rightIsRootModeBeforeSwap
        rightIsRootMode = tempIsRootMode
        rightViewMode = tempViewMode
        rightGridThumbnailSize = tempThumbnailSize
        rightGridSpacing = tempSpacing
        
        statusMessage = "Панели поменяны местами"
        saveSession()
        refreshPane(side: .left)
        refreshPane(side: .right)
    }
    
    /// Переключение между режимом таблицы и графической сетки
    public func toggleViewMode(for side: PaneSide? = nil) {
        let targetSide = side ?? activePane
        if targetSide == .left {
            leftViewMode = (leftViewMode == .table) ? .grid : .table
        } else {
            rightViewMode = (rightViewMode == .table) ? .grid : .table
        }
        statusMessage = (targetSide == .left ? leftViewMode : rightViewMode) == .grid
            ? "Режим сетки (галерея)"
            : "Режим списка (таблица)"
    }
    
    /// Переключение между режимами сортировки: папки отдельно vs папки и файлы вместе (Finder)
    public func toggleFolderSortMode(for side: PaneSide? = nil) {
        let targetSide = side ?? activePane
        if targetSide == .left {
            leftFolderSortMode = (leftFolderSortMode == .separate) ? .mixed : .separate
        } else {
            rightFolderSortMode = (rightFolderSortMode == .separate) ? .mixed : .separate
        }
        let currentMode = (targetSide == .left ? leftFolderSortMode : rightFolderSortMode)
        statusMessage = currentMode == .mixed
            ? "Сортировка: папки и файлы вместе (как в Finder)"
            : "Сортировка: папки отдельно, файлы отдельно"
    }
    
    /// Обновление заголовка, пути и источника активной вкладки
    public func updateActiveTab(side: PaneSide) {
        // Пока панель показывает корень источника, ни одна вкладка не активна и не перезаписывается
        if isRootMode(side: side) {
            saveSession()
            return
        }
        if side == .left {
            if let idx = leftTabs.firstIndex(where: { $0.id == leftActiveTabId }) {
                guard !leftTabs[idx].isPinned else {
                    // Закреплённая вкладка хранит своё место: путь и источник панели ей не присваиваются
                    saveSession()
                    return
                }
                leftTabs[idx].title = defaultTabTitle(for: leftPath, source: leftSource)
                leftTabs[idx].path = leftPath
                leftTabs[idx].source = leftSource
            }
        } else {
            if let idx = rightTabs.firstIndex(where: { $0.id == rightActiveTabId }) {
                guard !rightTabs[idx].isPinned else {
                    // Закреплённая вкладка хранит своё место: путь и источник панели ей не присваиваются
                    saveSession()
                    return
                }
                rightTabs[idx].title = defaultTabTitle(for: rightPath, source: rightSource)
                rightTabs[idx].path = rightPath
                rightTabs[idx].source = rightSource
            }
        }
        saveSession()
    }
    
    /// Безопасная смена источника панели с автоматической коррекцией пути под платформу
    public func changeSource(to newSource: FileSource, side: PaneSide) {
        if activePane != side { activePane = side }
        if side == .left {
            leftSource = newSource
            // Кнопки Mac/Phone ведут себя как вкладки без пути: всегда показывают корень источника
            leftPath = (newSource == .localMac) ? FileManager.default.homeDirectoryForCurrentUser.path : "/storage/emulated/0"
            leftIsStale = false
            leftSelection.removeAll()
            if leftTabs.count <= 1 && !(leftTabs.first?.isPinned ?? false) {
                areTabsVisibleLeft = false
            }
            if visibleTabs(for: .left).isEmpty {
                // Вкладок на экране нет: единственная скрытая вкладка следует за панелью
                leftIsRootMode = false
                if let idx = leftTabs.firstIndex(where: { $0.id == leftActiveTabId }) {
                    leftTabs[idx].source = newSource
                    leftTabs[idx].path = leftPath
                    if !leftTabs[idx].isPinned {
                        leftTabs[idx].title = defaultTabTitle(for: leftPath, source: newSource)
                    }
                }
            } else {
                // Вкладки видны: панель показывает корень, ни одна вкладка не активна и не перезаписывается
                leftIsRootMode = true
            }
            updateActiveTab(side: .left)
            if newSource == .remotePhone {
                if !remoteDriver.isConnected {
                    leftIsStale = false
                    if !isRunningTests {
                        connectPhone(forceActivate: false, isExplicit: true)
                    }
                } else {
                    refreshPane(side: .left)
                }
            } else {
                refreshPane(side: .left)
            }
        } else {
            rightSource = newSource
            // Кнопки Mac/Phone ведут себя как вкладки без пути: всегда показывают корень источника
            rightPath = (newSource == .localMac) ? FileManager.default.homeDirectoryForCurrentUser.path : "/storage/emulated/0"
            rightIsStale = false
            rightSelection.removeAll()
            if rightTabs.count <= 1 && !(rightTabs.first?.isPinned ?? false) {
                areTabsVisibleRight = false
            }
            if visibleTabs(for: .right).isEmpty {
                // Вкладок на экране нет: единственная скрытая вкладка следует за панелью
                rightIsRootMode = false
                if let idx = rightTabs.firstIndex(where: { $0.id == rightActiveTabId }) {
                    rightTabs[idx].source = newSource
                    rightTabs[idx].path = rightPath
                    if !rightTabs[idx].isPinned {
                        rightTabs[idx].title = defaultTabTitle(for: rightPath, source: newSource)
                    }
                }
            } else {
                // Вкладки видны: панель показывает корень, ни одна вкладка не активна и не перезаписывается
                rightIsRootMode = true
            }
            updateActiveTab(side: .right)
            if newSource == .remotePhone {
                if !remoteDriver.isConnected {
                    rightIsStale = false
                    if !isRunningTests {
                        connectPhone(forceActivate: false, isExplicit: true)
                    }
                } else {
                    refreshPane(side: .right)
                }
            } else {
                refreshPane(side: .right)
            }
        }
    }
    
    /// Обновление сетевого адреса телефона для SFTP и передачи файлов
    public func updateRemoteEndpoint(host: String, port: UInt16, deviceId: String? = nil) {
        remoteDriver.updateEndpoint(host: host, port: port, deviceId: deviceId)
        transport.updateEndpoint(host: host, port: port, deviceId: deviceId)
    }
    
    /// Подключение к телефону: единое управление через ConnectionController (Слой 3)
    public func connectPhone(
        targetPath: CandidatePath? = nil,
        customHost: String? = nil,
        customPort: UInt16? = nil,
        preferredDeviceId: String? = nil,
        forceActivate: Bool = true,
        isExplicit: Bool = true,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !isConnectingPhone else {
            completion?(false)
            return
        }
        isConnectingPhone = true
        if leftSource == .remotePhone || rightSource == .remotePhone {
            if isComparing { cancelDirectoryComparison() }
            if leftSource == .remotePhone { leftComparisonReady = false }
            if rightSource == .remotePhone { rightComparisonReady = false }
        }
        if leftSource == .remotePhone { leftIsStale = false }
        if rightSource == .remotePhone { rightIsStale = false }
        if isExplicit {
            statusMessage = "Поиск и подключение телефона..."
        }
        
        Task { @MainActor in
            let success = await ConnectionController.shared.connect(
                targetCandidate: targetPath,
                customHost: customHost,
                customPort: customPort,
                preferredDeviceId: preferredDeviceId,
                isExplicitUserAction: isExplicit,
                viewModel: self
            )
            // W7: учёт backoff автоподключения. Ручное действие снимает паузы и подавление.
            let autoKey = self.autoConnectKey(targetPath: targetPath, preferredDeviceId: preferredDeviceId)
            if isExplicit {
                self.autoConnectBackoff[DualPaneViewModel.lanScanBackoffKey] = nil
                if let key = autoKey { self.autoConnectBackoff[key] = nil }
                if let customHost {
                    self.autoConnectBackoff["lan:\(ConnectionHostAddress.normalized(customHost))"] = nil
                }
            } else if let key = autoKey {
                if success {
                    self.autoConnectBackoff[key] = nil
                } else if case .authFailed = ConnectionController.shared.phase {
                    // Неверный ключ/отладка не подтверждена: повторять автоматически нельзя до ручного подключения
                    self.suppressAutoConnect(key: key)
                } else {
                    self.recordAutoConnectFailure(key: key)
                }
            }
            if success {
                self.failedConnectionSide = nil
                // При автоматическом подборе адреса входной targetPath отсутствует.
                // Ручной успех снимает подавление именно с фактического endpoint.
                if isExplicit,
                   let currentPath = ConnectionController.shared.currentPath,
                   case .lan(let host, _, _) = currentPath {
                    self.autoConnectBackoff["lan:\(host)"] = nil
                    self.autoConnectBackoff["lan:\(ConnectionHostAddress.normalized(host))"] = nil
                }
                self.leftIsStale = false
                self.rightIsStale = false
                if forceActivate && self.rightSource != .remotePhone && self.leftSource != .remotePhone {
                    self.changeSource(to: .remotePhone, side: .right)
                } else {
                    if self.leftSource == .remotePhone {
                        self.updateActiveTab(side: .left)
                        self.refreshPane(side: .left)
                    }
                    if self.rightSource == .remotePhone {
                        self.updateActiveTab(side: .right)
                        self.refreshPane(side: .right)
                    }
                }
                self.refreshDetectedVolumes()
            } else {
                if self.leftSource == .remotePhone { self.leftIsStale = true }
                if self.rightSource == .remotePhone { self.rightIsStale = true }
                self.refreshUsbDrives()
            }
            self.isConnectingPhone = false
            completion?(success)
        }
    }
    
    /// Явное отключение телефона пользователем с завершением дочерних процессов
    public func disconnectPhone() {
        ConnectionController.shared.disconnect(viewModel: self)
        refreshUsbDrives()
        if leftSource == .remotePhone {
            updateActiveTab(side: .left)
            refreshPane(side: .left)
        }
        if rightSource == .remotePhone {
            updateActiveTab(side: .right)
            refreshPane(side: .right)
        }
    }
    
    // MARK: - Backoff автоподключения (W7)
    
    /// Состояние повторных попыток автоподключения по endpoint (USB-серийник, IP, или общий поиск в LAN)
    private struct AutoConnectBackoff: Sendable {
        var failures: Int = 0
        var nextAttemptAt: Date = .distantPast
        /// После authFailed автоподключение по endpoint не повторяется до ручного действия пользователя
        var suppressed: Bool = false
    }
    
    private static let lanScanBackoffKey = "lan-scan"
    private var autoConnectBackoff: [String: AutoConnectBackoff] = [:]
    
    private nonisolated static func autoConnectAllowed(_ key: String, state: [String: AutoConnectBackoff], now: Date = Date()) -> Bool {
        guard let entry = state[key] else { return true }
        return !entry.suppressed && now >= entry.nextAttemptAt
    }
    
    /// Экспоненциальная пауза после неудачи: 5, 10, 20 … 300 секунд
    private func recordAutoConnectFailure(key: String) {
        var entry = autoConnectBackoff[key] ?? AutoConnectBackoff()
        entry.failures += 1
        let delay = min(2.5 * pow(2.0, Double(min(entry.failures, 8))), 300)
        entry.nextAttemptAt = Date().addingTimeInterval(delay)
        autoConnectBackoff[key] = entry
    }
    
    private func suppressAutoConnect(key: String) {
        var entry = autoConnectBackoff[key] ?? AutoConnectBackoff()
        entry.suppressed = true
        autoConnectBackoff[key] = entry
    }
    
    private func autoConnectKey(targetPath: CandidatePath?, preferredDeviceId: String?) -> String? {
        if let path = targetPath {
            switch path {
            case .lan(let host, _, _): return "lan:\(ConnectionHostAddress.normalized(host))"
            case .usb(let deviceId, _): return "usb:\(deviceId)"
            }
        }
        if let id = preferredDeviceId { return "usb:\(id)" }
        return nil
    }
    
    /// Автоматическое подключение к телефону при обнаружении USB или Wi-Fi связи
    public func autoConnectPhoneIfAvailable() {
        guard !isConnectingPhone && !isAutoConnecting && !remoteDriver.isConnected else {
            if remoteDriver.isConnected && !isPhoneConnected {
                isPhoneConnected = true
            }
            return
        }
        guard !ConnectionController.shared.isManualDisconnectSuppressed else {
            return
        }
        isAutoConnecting = true
        
        // Снимок состояния backoff передаём в фоновую задачу: проверки делаются до дорогих операций (adb, nc-пробы)
        let backoffState = autoConnectBackoff
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            // 1. Проверяем наличие USB-устройства через ADB и его политику autoConnect
            var chosenUsbDeviceId: String? = nil
            for id in PhoneConnectionManager.shared.authorizedAdbDeviceIds() {
                if let dev = DeviceRegistry.shared.device(withId: id), dev.autoConnect,
                   DualPaneViewModel.autoConnectAllowed("usb:\(id)", state: backoffState) {
                    chosenUsbDeviceId = id
                    break
                }
            }
            
            // 2. Если по USB не обнаружен, сканируем Wi-Fi для доверенных устройств с autoConnect == true
            var chosenCandidate: CandidatePath? = nil
            var scanAttempted = false
            if chosenUsbDeviceId == nil && DualPaneViewModel.autoConnectAllowed(DualPaneViewModel.lanScanBackoffKey, state: backoffState) {
                scanAttempted = true
                // Политика и backoff применяются до выбора первого доверенного телефона:
                // отключённое устройство не должно скрывать следующий доступный endpoint.
                let excludedHosts = Set(backoffState.keys.compactMap { key -> String? in
                    guard key.hasPrefix("lan:"),
                          !DualPaneViewModel.autoConnectAllowed(key, state: backoffState) else { return nil }
                    return ConnectionHostAddress.normalized(String(key.dropFirst(4)))
                })
                if case .paired(let foundIp, let foundPort, _, _) = await PhoneConnectionManager.shared.findPairedPhoneOnLan(
                    deep: false,
                    autoConnectOnly: true,
                    excludedHosts: excludedHosts
                ) {
                    chosenCandidate = .lan(host: foundIp, port: foundPort, isV6: foundIp.contains(":"))
                }
            }

            let candidateToConnect = chosenCandidate
            let usbDeviceToConnect = chosenUsbDeviceId
            let scanProducedCandidate = chosenCandidate != nil
            await MainActor.run {
                self.isAutoConnecting = false
                if scanAttempted {
                    if scanProducedCandidate {
                        self.autoConnectBackoff[DualPaneViewModel.lanScanBackoffKey] = nil
                    } else {
                        self.recordAutoConnectFailure(key: DualPaneViewModel.lanScanBackoffKey)
                    }
                }
                // Важно: повторная проверка подавления прямо перед коннектом
                guard !ConnectionController.shared.isManualDisconnectSuppressed else { return }
                if (candidateToConnect != nil || usbDeviceToConnect != nil), !self.isConnectingPhone && !self.remoteDriver.isConnected {
                    self.connectPhone(
                        targetPath: candidateToConnect,
                        preferredDeviceId: usbDeviceToConnect,
                        forceActivate: false,
                        isExplicit: false
                    )
                }
            }
        }
    }
    
    // MARK: - Android Storage Volumes & External USB Drives (SD-карты, OTG, USB флешки)
    public func refreshDetectedVolumes() {
        let volumes = PhoneConnectionManager.shared.detectStorageVolumes()
        self.detectedVolumes = volumes
        self.refreshUsbDrives()
    }
    
    /// Проверка, является ли том реальным физическим внешним USB накопителем (исключая DMG и виртуальные диски)
    public static func isActualUsbDrive(url: URL) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return false }
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else { return false }
        guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return false }
        if let proto = desc[kDADiskDescriptionDeviceProtocolKey as String] as? String {
            return proto.caseInsensitiveCompare("USB") == .orderedSame
        }
        return false
    }
    
    /// Обнаружение подключенных внешних USB накопителей (на Mac в /Volumes и на Android OTG)
    public func refreshUsbDrives() {
        var list: [UsbDriveInfo] = []
        
        // 1. Проверяем внешние съемные накопители Mac (в /Volumes, исключая корень "/")
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeNameKey]
        if let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) {
            for url in urls {
                guard url.path != "/" && !url.path.isEmpty else { continue }
                guard let vals = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                let isRemovable = vals.volumeIsRemovable ?? false
                let isEjectable = vals.volumeIsEjectable ?? false
                guard isRemovable || isEjectable else { continue }
                
                // Проверяем через DiskArbitration, что шина устройства именно USB, а не виртуальный DMG/RAM-образ
                if Self.isActualUsbDrive(url: url) {
                    let name = vals.volumeName ?? url.lastPathComponent
                    list.append(UsbDriveInfo(id: "mac:\(url.path)", name: name, path: url.path, isMac: true))
                }
            }
        }
        
        // 2. Проверяем внешние тома Android (OTG, внешняя SD-карта) только при активном подключении телефона
        if isPhoneConnected {
            for vol in detectedVolumes where !vol.isPrimary {
                list.append(UsbDriveInfo(id: "phone:\(vol.path)", name: vol.name, path: vol.path, isMac: false))
            }
        }
        
        self.detectedUsbDrives = list
    }
    
    /// Фоновый мониторинг связи со смартфоном (каждые 2.5 сек)
    public func startConnectionMonitor() {
        connectionMonitorTimer?.invalidate()
        connectionMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPhoneConnectionState()
            }
        }
    }
    
    /// Проверка актуального состояния подключения телефона
    public func checkPhoneConnectionState() {
        guard !isConnectingPhone && !connectionProbeRunning && !isSystemAsleep else { return }
        if !remoteDriver.isConnected {
            wifiReachabilityMisses = 0
            if isPhoneConnected {
                isPhoneConnected = false
                refreshUsbDrives()
            }
            autoConnectPhoneIfAvailable()
            return
        }
        connectionProbeRunning = true
        let probeEpoch = remoteDriver.coordinator.sessionEpoch
        let monitoredPath = ConnectionController.shared.currentPath
        let activeSSHChannel = remoteDriver.coordinator.interactiveChannel
        
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            let adbDeviceIds = PhoneConnectionManager.shared.authorizedAdbDeviceIds()
            let monitoredUsbDeviceId: String? = {
                guard let path = monitoredPath, case .usb(let deviceId, _) = path else { return nil }
                return deviceId
            }()
            let isAdbConnected = monitoredUsbDeviceId.map(adbDeviceIds.contains) ?? false
            
            let adbDetected = isAdbConnected
            let sshProcessAlive = activeSSHChannel?.isRunning == true
            
            await MainActor.run {
                self.connectionProbeRunning = false
                guard !self.isConnectingPhone,
                      self.remoteDriver.coordinator.sessionEpoch == probeEpoch,
                      ConnectionController.shared.currentPath == monitoredPath else { return }
                if self.remoteDriver.isConnected {
                    // Check the authenticated SSH process itself. An ADB forward or
                    // an unrelated listener on port 2222 does not prove SFTP is alive.
                    let sessionTransportAlive = sshProcessAlive && (monitoredUsbDeviceId == nil || adbDetected)
                    if !sessionTransportAlive {
                        self.wifiReachabilityMisses = 0
                        self.isPhoneConnected = false
                        self.remoteDriver.disconnect()
                        self.refreshUsbDrives()
                        if self.leftSource == .remotePhone { self.refreshPane(side: .left) }
                        if self.rightSource == .remotePhone { self.refreshPane(side: .right) }
                        self.statusMessage = "Телефон отключен (связь потеряна)"
                    } else if !self.isPhoneConnected {
                        self.wifiReachabilityMisses = 0
                        self.isPhoneConnected = true
                        self.refreshUsbDrives()
                    } else {
                        self.wifiReachabilityMisses = 0
                    }
                } else {
                    self.wifiReachabilityMisses = 0
                    // Если SFTP драйвер не подключен, индикатор ОБЯЗАН быть серым (не подключен)
                    if self.isPhoneConnected {
                        self.isPhoneConnected = false
                        self.refreshUsbDrives()
                    }
                    
                    // Приоритетное автоподключение:
                    // Если обнаружено физическое устройство по USB или доступен телефон по Wi-Fi:
                    if (adbDetected || monitoredPath != nil) && !self.isConnectingPhone && !self.isAutoConnecting {
                        self.autoConnectPhoneIfAvailable()
                    }
                }
            }
        }
    }
    
    public func switchToVolume(_ volume: PhoneConnectionManager.StorageVolume, side: PaneSide) {
        if activePane != side { activePane = side }
        if side == .left {
            if leftSource != .remotePhone {
                leftSource = .remotePhone
            }
            leftPath = volume.path
            leftSelection.removeAll()
            updateActiveTab(side: .left)
            if !remoteDriver.isConnected {
                leftIsStale = false
                if !isRunningTests {
                    connectPhone(forceActivate: false, isExplicit: true)
                }
            } else {
                refreshPane(side: .left)
            }
        } else {
            if rightSource != .remotePhone {
                rightSource = .remotePhone
            }
            rightPath = volume.path
            rightSelection.removeAll()
            updateActiveTab(side: .right)
            if !remoteDriver.isConnected {
                rightIsStale = false
                if !isRunningTests {
                    connectPhone(forceActivate: false, isExplicit: true)
                }
            } else {
                refreshPane(side: .right)
            }
        }
        statusMessage = "Переход к хранилищу: \(volume.name)"
    }
    
    /// Переключение на внешний USB накопитель
    public func switchToUsbDrive(_ drive: UsbDriveInfo, side: PaneSide) {
        if activePane != side { activePane = side }
        // Кнопка USB, как Mac/Phone, показывает корень накопителя и не трогает вкладки
        if side == .left { leftIsRootMode = true } else { rightIsRootMode = true }
        if drive.isMac {
            if (side == .left ? leftSource : rightSource) != .localMac {
                changeSource(to: .localMac, side: side)
            }
            navigateTo(path: drive.path, side: side)
        } else {
            if let vol = detectedVolumes.first(where: { $0.path == drive.path }) {
                switchToVolume(vol, side: side)
            } else {
                if (side == .left ? leftSource : rightSource) != .remotePhone {
                    changeSource(to: .remotePhone, side: side)
                }
                navigateTo(path: drive.path, side: side)
            }
        }
        statusMessage = "Переход к USB накопителю: \(drive.name)"
    }
    
    // MARK: - Quick Bookmarks & Navigation
    public func quickBookmarks(for side: PaneSide) -> [BookmarksManager.Bookmark] {
        let source = (side == .left) ? leftSource : rightSource
        return BookmarksManager.shared.bookmarks(for: source)
    }
    
    public func navigateToHome(side: PaneSide? = nil) {
        let targetSide = side ?? activePane
        let source = (targetSide == .left) ? leftSource : rightSource
        if source == .localMac {
            navigateTo(path: FileManager.default.homeDirectoryForCurrentUser.path, side: targetSide)
        } else {
            navigateTo(path: "/storage/emulated/0", side: targetSide)
        }
    }
    
    public func navigateToDesktop(side: PaneSide? = nil) {
        let targetSide = side ?? activePane
        let source = (targetSide == .left) ? leftSource : rightSource
        if source == .localMac {
            let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path
            navigateTo(path: desktop, side: targetSide)
        } else {
            navigateTo(path: "/storage/emulated/0/DCIM", side: targetSide)
        }
    }
    
    public func navigateToDownloads(side: PaneSide? = nil) {
        let targetSide = side ?? activePane
        let source = (targetSide == .left) ? leftSource : rightSource
        if source == .localMac {
            let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
            navigateTo(path: downloads, side: targetSide)
        } else {
            navigateTo(path: "/storage/emulated/0/Download", side: targetSide)
        }
    }
    
    public func navigateToDocuments(side: PaneSide? = nil) {
        let targetSide = side ?? activePane
        let source = (targetSide == .left) ? leftSource : rightSource
        if source == .localMac {
            let docs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents").path
            navigateTo(path: docs, side: targetSide)
        } else {
            navigateTo(path: "/storage/emulated/0/Documents", side: targetSide)
        }
    }
    
    public func navigateToApplications(side: PaneSide? = nil) {
        let targetSide = side ?? activePane
        let source = (targetSide == .left) ? leftSource : rightSource
        if source == .localMac {
            navigateTo(path: "/Applications", side: targetSide)
        } else {
            navigateTo(path: "/storage/emulated/0", side: targetSide)
        }
    }
    
    public func navigateToRecents(side: PaneSide? = nil) {
        let targetSide = side ?? activePane
        if let recent = BookmarksManager.shared.recentPaths.first {
            if (targetSide == .left ? leftSource : rightSource) != recent.source {
                changeSource(to: recent.source, side: targetSide)
            }
            navigateTo(path: recent.path, side: targetSide)
        } else {
            navigateToHome(side: targetSide)
        }
    }
    
    public func setPanelLayoutMode(_ mode: PanelLayoutMode) {
        guard panelLayoutMode != mode else { return }
        panelLayoutMode = mode
        if mode == .finder && activePane == .right {
            activePane = .left
        }
        saveSession()
        statusMessage = (mode == .finder) ? "Режим Finder с боковой панелью" : "Двухпанельный режим"
    }
    
    public func togglePanelLayoutMode() {
        setPanelLayoutMode(panelLayoutMode == .dual ? .finder : .dual)
    }
    
    public func connectOrNavigateToDevice(named name: String, side: PaneSide? = nil) {
        let targetSide = side ?? (panelLayoutMode == .finder ? .left : activePane)
        if isPhoneConnected && remoteDriver.isConnected {
            if (targetSide == .left ? leftSource : rightSource) != .remotePhone {
                changeSource(to: .remotePhone, side: targetSide)
            }
            navigateTo(path: "/storage/emulated/0", side: targetSide)
            return
        }
        
        let allDevs = DeviceRegistry.shared.allDevices()
        if let matching = allDevs.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
            connectPhone(
                customHost: matching.lastKnownHost,
                customPort: matching.lastKnownPort,
                preferredDeviceId: matching.id,
                forceActivate: true,
                isExplicit: true
            )
        } else if let discovered = discoveryService.discoveredDevices.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
            connectPhone(
                customHost: discovered.host,
                customPort: UInt16(discovered.port),
                forceActivate: true,
                isExplicit: true
            )
        } else {
            connectPhone(forceActivate: true, isExplicit: true)
        }
    }
    
    public func recordHistory(path: String, side: PaneSide) {
        if side == .left {
            if leftHistoryIndex >= 0 && leftHistoryIndex < leftHistory.count && leftHistory[leftHistoryIndex] == path { return }
            leftHistory = Array(leftHistory.prefix(leftHistoryIndex + 1))
            leftHistory.append(path)
            leftHistoryIndex = leftHistory.count - 1
        } else {
            if rightHistoryIndex >= 0 && rightHistoryIndex < rightHistory.count && rightHistory[rightHistoryIndex] == path { return }
            rightHistory = Array(rightHistory.prefix(rightHistoryIndex + 1))
            rightHistory.append(path)
            rightHistoryIndex = rightHistory.count - 1
        }
    }
    
    public func canNavigateBack(side: PaneSide) -> Bool {
        (side == .left) ? (leftHistoryIndex > 0) : (rightHistoryIndex > 0)
    }
    
    public func canNavigateForward(side: PaneSide) -> Bool {
        if side == .left {
            return leftHistoryIndex >= 0 && leftHistoryIndex < leftHistory.count - 1
        } else {
            return rightHistoryIndex >= 0 && rightHistoryIndex < rightHistory.count - 1
        }
    }
    
    public func navigateBack(side: PaneSide) {
        guard canNavigateBack(side: side) else { return }
        if activePane != side { activePane = side }
        let previousPath = (side == .left) ? leftPath : rightPath
        if side == .left {
            leftHistoryIndex -= 1
            leftPath = leftHistory[leftHistoryIndex]
            leftSelection.removeAll()
            updateActiveTab(side: .left)
            refreshPane(side: .left, selectPath: Self.immediateChildPath(of: leftPath, toward: previousPath))
        } else {
            rightHistoryIndex -= 1
            rightPath = rightHistory[rightHistoryIndex]
            rightSelection.removeAll()
            updateActiveTab(side: .right)
            refreshPane(side: .right, selectPath: Self.immediateChildPath(of: rightPath, toward: previousPath))
        }
    }
    
    public func navigateForward(side: PaneSide) {
        guard canNavigateForward(side: side) else { return }
        if activePane != side { activePane = side }
        if side == .left {
            leftHistoryIndex += 1
            leftPath = leftHistory[leftHistoryIndex]
            leftSelection.removeAll()
            updateActiveTab(side: .left)
            refreshPane(side: .left)
        } else {
            rightHistoryIndex += 1
            rightPath = rightHistory[rightHistoryIndex]
            rightSelection.removeAll()
            updateActiveTab(side: .right)
            refreshPane(side: .right)
        }
    }
    
    public func toggleShowHidden(side: PaneSide? = nil) {
        let targetSide = side ?? activePane
        if targetSide == .left {
            leftShowHidden.toggle()
            statusMessage = leftShowHidden ? "Скрытые файлы отображаются (слева)" : "Скрытые файлы скрыты (слева)"
        } else {
            rightShowHidden.toggle()
            statusMessage = rightShowHidden ? "Скрытые файлы отображаются (справа)" : "Скрытые файлы скрыты (справа)"
        }
        saveSession()
    }
    
    public func startEditingPath(side: PaneSide) {
        manualPathInput = (side == .left) ? leftPath : rightPath
        if side == .left {
            isEditingLeftPath = true
        } else {
            isEditingRightPath = true
        }
    }
    
    public func commitManualPath(side: PaneSide) {
        let trimmed = manualPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if side == .left {
            isEditingLeftPath = false
            if !trimmed.isEmpty && trimmed != leftPath {
                navigateTo(path: trimmed, side: .left)
            }
        } else {
            isEditingRightPath = false
            if !trimmed.isEmpty && trimmed != rightPath {
                navigateTo(path: trimmed, side: .right)
            }
        }
    }
    
    public func addCurrentPathToBookmarks(side: PaneSide) {
        let path = (side == .left) ? leftPath : rightPath
        let source = (side == .left) ? leftSource : rightSource
        let name = URL(fileURLWithPath: path).lastPathComponent.isEmpty ? path : URL(fileURLWithPath: path).lastPathComponent
        BookmarksManager.shared.addBookmark(name: name, path: path, source: source)
        statusMessage = "Добавлено в Избранное: \(name)"
    }
    
    /// Прямая навигация по пути с валидацией платформы
    public func navigateTo(path: String, side: PaneSide) {
        let source = (side == .left) ? leftSource : rightSource
        var targetPath = path
        if source == .localMac {
            if targetPath.hasPrefix("/storage") || targetPath.hasPrefix("/sdcard") || !FileManager.default.fileExists(atPath: targetPath) {
                targetPath = FileManager.default.homeDirectoryForCurrentUser.path
            }
        } else if source == .remotePhone {
            if targetPath.hasPrefix("/sdcard") {
                targetPath = "/storage/emulated/0" + targetPath.dropFirst("/sdcard".count)
            } else if targetPath.hasPrefix("/Users/") || targetPath.hasPrefix("/System/") || targetPath.hasPrefix("/Applications/") || targetPath.hasPrefix("/Library/") || targetPath.hasPrefix("/private/") || targetPath.isEmpty {
                targetPath = "/storage/emulated/0"
            }
        }
        recordHistory(path: targetPath, side: side)
        if activePane != side {
            activePane = side
        }
        if side == .left {
            leftPath = targetPath
            leftSelection.removeAll()
            updateActiveTab(side: .left)
            refreshPane(side: .left)
        } else {
            rightPath = targetPath
            rightSelection.removeAll()
            updateActiveTab(side: .right)
            refreshPane(side: .right)
        }
    }
    
    public func refreshPane(side: PaneSide, selectPath: String? = nil) {
        if isComparing { cancelDirectoryComparison() }
        if side == .left { leftComparisonReady = false } else { rightComparisonReady = false }
        var path = (side == .left) ? leftPath : rightPath
        let source = (side == .left) ? leftSource : rightSource
        
        // Автокоррекция пути при несоответствии платформе: для Mac всегда реальный локальный путь
        if source == .localMac {
            if path.hasPrefix("/storage") || path.hasPrefix("/sdcard") || !FileManager.default.fileExists(atPath: path) {
                path = FileManager.default.homeDirectoryForCurrentUser.path
                if side == .left { leftPath = path } else { rightPath = path }
                updateActiveTab(side: side)
            }
        } else if source == .remotePhone {
            if path.hasPrefix("/sdcard") {
                path = "/storage/emulated/0" + path.dropFirst("/sdcard".count)
                if side == .left { leftPath = path } else { rightPath = path }
                updateActiveTab(side: side)
            } else if path.hasPrefix("/Users/") || path.hasPrefix("/System/") || path.hasPrefix("/Applications/") || path.hasPrefix("/Library/") || path.hasPrefix("/private/") || path.isEmpty {
                path = "/storage/emulated/0"
                if side == .left { leftPath = path } else { rightPath = path }
                updateActiveTab(side: side)
            }
            if !remoteDriver.isConnected && !isConnectingPhone && !isRunningTests {
                connectPhone(forceActivate: false, isExplicit: true)
                return
            }
        }
        
        if source == .remotePhone {
            DirectoryCache.shared.invalidate(path: path)
        }
        
        let driver: FileSystemDriver = (source == .localMac) ? localDriver : remoteDriver

        // Номер поколения загрузки: спиннер гаснет только по последней запущенной загрузке панели (U3)
        let generation: Int
        if side == .left {
            leftRefreshGeneration &+= 1
            generation = leftRefreshGeneration
            leftIsRefreshing = true
            leftRefreshTask?.cancel()
        } else {
            rightRefreshGeneration &+= 1
            generation = rightRefreshGeneration
            rightIsRefreshing = true
            rightRefreshTask?.cancel()
        }

        let task = Task { @MainActor in
            defer {
                if side == .left {
                    if generation == self.leftRefreshGeneration { self.leftIsRefreshing = false }
                } else if generation == self.rightRefreshGeneration {
                    self.rightIsRefreshing = false
                }
            }
            do {
                let items: [FileItem]
                if source == .remotePhone {
                    DirectoryCache.shared.invalidate(path: path)
                    items = try await self.remoteDriver.listDirectory(at: path, forceRefresh: true)
                } else {
                    items = try await driver.listDirectory(at: path)
                }
                guard !Task.isCancelled else { return }
                await self.waitForScrollToSettle(side: side)
                guard !Task.isCancelled else { return }
                
                // Оптимизация P2: Сразу публикуем полученные файлы в интерфейс,
                // не дожидаясь вторичного сетевого запроса свободного места checkFreeSpace
                let isRemoteOffline = (source == .remotePhone && !self.remoteDriver.isConnected)
                if source == .remotePhone && self.remoteDriver.isConnected {
                    self.isPhoneConnected = true
                    self.transport.rootIsEmulatedZero = self.remoteDriver.rootIsEmulatedZero
                }
                
                if side == .left {
                    self.leftItems = items
                    self.leftIsStale = isRemoteOffline && !self.isConnectingPhone
                    if let selectPath = selectPath {
                        let normSelectPath = selectPath.precomposedStringWithCanonicalMapping
                        let selectName = URL(fileURLWithPath: selectPath).lastPathComponent.precomposedStringWithCanonicalMapping
                        if let target = items.first(where: { $0.path == normSelectPath || $0.name == selectName }) {
                            self.activePane = .left
                            self.leftSelection = [target.id]
                            TableDoubleClickHandler.HandlerView.focusAndScrollToItem(id: target.id, side: .left)
                        }
                    }
                } else {
                    self.rightItems = items
                    self.rightIsStale = isRemoteOffline && !self.isConnectingPhone
                    if let selectPath = selectPath {
                        let normSelectPath = selectPath.precomposedStringWithCanonicalMapping
                        let selectName = URL(fileURLWithPath: selectPath).lastPathComponent.precomposedStringWithCanonicalMapping
                        if let target = items.first(where: { $0.path == normSelectPath || $0.name == selectName }) {
                            self.activePane = .right
                            self.rightSelection = [target.id]
                            TableDoubleClickHandler.HandlerView.focusAndScrollToItem(id: target.id, side: .right)
                        }
                    }
                }
                if isRemoteOffline {
                    if !self.isConnectingPhone {
                        self.statusMessage = "Телефон не подключен (Offline)"
                    }
                } else if source == .remotePhone {
                    self.statusMessage = "Телефон: \(path)"
                } else if source == .localMac {
                    self.statusMessage = "Mac: \(path)"
                }
                if side == .left {
                    self.leftComparisonReady = !isRemoteOffline
                } else {
                    self.rightComparisonReady = !isRemoteOffline
                }
                if self.isComparing { self.startDirectoryComparison() }
                
                // Проверка свободного места выполняется вторым шагом без задержки показа файлов
                if let space = try? await driver.checkFreeSpace(at: path), !Task.isCancelled {
                    if side == .left {
                        self.leftFreeSpace = space
                    } else {
                        self.rightFreeSpace = space
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                if side == .left {
                    self.leftItems = []
                    self.leftIsStale = (source == .remotePhone) && !self.isConnectingPhone
                } else {
                    self.rightItems = []
                    self.rightIsStale = (source == .remotePhone) && !self.isConnectingPhone
                }
                if source == .remotePhone {
                    if !self.isConnectingPhone {
                        self.statusMessage = "Телефон не подключен (Offline)"
                    }
                    self.isPhoneConnected = false
                    self.refreshUsbDrives()
                } else {
                    self.statusMessage = "Ошибка обновления панели: \(error.localizedDescription)"
                }
            }
        }
        
        if side == .left {
            leftRefreshTask = task
        } else {
            rightRefreshTask = task
        }
    }
    
    // MARK: - Синхронизация публикации файлов с анимацией прокрутки

    private var bouncingSides: Set<PaneSide> = []
    private var scrollSettleWaiters: [PaneSide: [CheckedContinuation<Void, Never>]] = [:]

    /// Пока список панели возвращается после оттяжки (pull-to-refresh), новые файлы не публикуются:
    /// подмена данных посреди анимации «резинки» заставляет таблицу дёргаться.
    public func setScrollBouncing(_ bouncing: Bool, side: PaneSide) {
        if bouncing {
            bouncingSides.insert(side)
        } else {
            bouncingSides.remove(side)
            scrollSettleWaiters.removeValue(forKey: side)?.forEach { $0.resume() }
        }
    }

    private func waitForScrollToSettle(side: PaneSide) async {
        guard bouncingSides.contains(side) else { return }
        await withCheckedContinuation { scrollSettleWaiters[side, default: []].append($0) }
    }

    /// Одновременное обновление содержимого обеих панелей
    public func refreshBothPanes() {
        refreshPane(side: .left)
        refreshPane(side: .right)
    }
    
    /// Обновление обеих панелей с центрированием разделителя панелей строго посередине и сбросом колонок
    public func resetSplitAndRefresh() {
        refreshPaneToActiveTab(side: .left)
        refreshPaneToActiveTab(side: .right)
        splitViewResetId = UUID()
    }
    
    /// Зеркальное копирование визуального состояния (источник и путь) между панелями без копирования файлов
    public func mirrorPane(from sourceSide: PaneSide, to targetSide: PaneSide) {
        let srcSource = (sourceSide == .left) ? leftSource : rightSource
        let srcPath = (sourceSide == .left) ? leftPath : rightPath
        
        if targetSide == .left {
            leftSource = srcSource
            leftPath = srcPath
            leftIsStale = false
            leftSelection.removeAll()
            updateActiveTab(side: .left)
            refreshPane(side: .left)
        } else {
            rightSource = srcSource
            rightPath = srcPath
            rightIsStale = false
            rightSelection.removeAll()
            updateActiveTab(side: .right)
            refreshPane(side: .right)
        }
    }
    
    private var lastOpenedPath: String = ""
    private var lastOpenedTime: TimeInterval = 0
    
    public func openItem(item: FileItem, side: PaneSide) {
        let now = Date().timeIntervalSince1970
        if item.path == lastOpenedPath && (now - lastOpenedTime) < 0.15 {
            return
        }
        lastOpenedPath = item.path
        lastOpenedTime = now
        
        print("DUAL_PANE: openItem '\(item.name)', isDirectory: \(item.isDirectory)")
        if item.isDirectory {
            navigateInto(item: item, side: side)
        } else if isArchive(item: item) {
            if ["zip", "apk"].contains(URL(fileURLWithPath: item.name).pathExtension.lowercased()) {
                openArchiveBrowser(item: item)
            } else {
                unarchive(item: item, side: side)
            }
        } else {
            openFile(item: item)
        }
    }
    
    public func openArchiveBrowser(item: FileItem) {
        closeArchiveBrowser()
        archiveBrowserTitle = item.name
        archiveBrowserError = nil
        showArchiveBrowser = true
        if item.source == .localMac {
            archiveBrowserURL = URL(fileURLWithPath: item.path)
            return
        }
        let generation = archiveBrowserGeneration
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacDroidArchive-\(UUID().uuidString)")
        archiveBrowserTemporaryDirectory = directory
        let stagingName = URL(fileURLWithPath: item.name).pathExtension.lowercased() == "apk" ? "archive.apk" : "archive.zip"
        let destination = directory.appendingPathComponent(stagingName)
        archiveBrowserTask = Task { [weak self] in
            var published = false
            defer {
                if !published { try? FileManager.default.removeItem(at: directory) }
            }
            do {
                try Task.checkCancellation()
                guard let self, self.archiveBrowserGeneration == generation else { return }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try await self.downloadRemoteFile(remotePath: item.path, targetURL: destination, totalSize: item.size)
                try Task.checkCancellation()
                guard self.archiveBrowserGeneration == generation else { return }
                self.archiveBrowserURL = destination
                published = true
            } catch {
                guard let self, self.archiveBrowserGeneration == generation else { return }
                self.archiveBrowserError = error.localizedDescription
            }
        }
    }

    public func closeArchiveBrowser() {
        archiveBrowserGeneration = UUID()
        archiveBrowserTask?.cancel()
        archiveBrowserTask = nil
        archiveBrowserURL = nil
        if let directory = archiveBrowserTemporaryDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        archiveBrowserTemporaryDirectory = nil
    }

    public func openFile(item: FileItem) {
        print("DUAL_PANE: openFile '\(item.name)', source: \(item.source)")
        if item.source == .localMac {
            let url = URL(fileURLWithPath: item.path)
            let success = NSWorkspace.shared.open(url)
            if success {
                statusMessage = "Открыт файл: \(item.name)"
            } else {
                let revealed = NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                if revealed {
                    statusMessage = "Файл показан в Finder: \(item.name)"
                } else {
                    statusMessage = "Не удалось открыть файл: \(item.name)"
                }
            }
        } else {
            // Файл на телефоне: скачивание во временный каталог и открытие
            let fileName = item.name
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacDroidOpenedFiles")
            let tempURL = tempDir.appendingPathComponent(fileName)
            
            statusMessage = "Скачивание для открытия: \(fileName)..."
            
            Task {
                do {
                    try FileManager.default.createDirectory(
                        at: tempDir,
                        withIntermediateDirectories: true
                    )
                    
                    let stat = try await transport.prepareRead(actionId: UUID().uuidString, path: item.path)
                    try await transport.downloadFileStreaming(
                        actionId: UUID().uuidString,
                        remotePath: item.path,
                        targetURL: tempURL,
                        totalSize: stat.size
                    ) { _ in }
                    
                    self.statusMessage = "Открыт файл: \(fileName)"
                    NSWorkspace.shared.open(tempURL)
                } catch {
                    self.statusMessage = "Ошибка скачивания для открытия: \(error.localizedDescription)"
                    self.errorMessage = "Не удалось открыть файл с телефона: \(error.localizedDescription)"
                    self.showErrorAlert = true
                }
            }
        }
    }
    
    public func openSelected() {
        let side = activePane
        let selectedPaths = (side == .left) ? leftSelection : rightSelection
        let items = (side == .left) ? leftItems : rightItems
        guard let firstSelected = selectedPaths.first,
              let item = items.first(where: { $0.id == firstSelected || $0.path == firstSelected }) else {
            return
        }
        openItem(item: item, side: side)
    }
    
    public func navigateInto(item: FileItem, side: PaneSide) {
        guard item.isDirectory else {
            openFile(item: item)
            return
        }
        // Отслеживание недавних папок
        BookmarksManager.shared.addRecentPath(path: item.path, source: item.source)
        recordHistory(path: item.path, side: side)
        if isSearchActive(for: side) {
            closeSearch(side: side)
        }
        if activePane != side {
            activePane = side
        }
        if side == .left {
            leftPath = item.path
            leftSelection.removeAll()
            updateActiveTab(side: .left)
            refreshPane(side: .left)
        } else {
            rightPath = item.path
            rightSelection.removeAll()
            updateActiveTab(side: .right)
            refreshPane(side: .right)
        }
    }
    
    public func navigateUp(side targetSide: PaneSide? = nil) {
        let side = targetSide ?? activePane
        if activePane != side { activePane = side }
        let currentSource = (side == .left) ? leftSource : rightSource
        let currentPath = (side == .left) ? leftPath : rightPath
        
        // Предотвращение выхода за пределы хранилища Android (основного или SD/OTG)
        if currentSource == .remotePhone {
            let isPrimaryRoot = (currentPath == "/storage/emulated/0" || currentPath == "/storage/emulated/0/" || currentPath == "/storage/emulated" || currentPath == "/storage")
            let isVolumeRoot = detectedVolumes.contains(where: { currentPath == $0.path || currentPath == $0.path + "/" })
            if isPrimaryRoot || isVolumeRoot {
                statusMessage = "Корневой каталог хранилища Android достигнут"
                return
            }
        }
        
        let parentURL = URL(fileURLWithPath: currentPath).deletingLastPathComponent()
        let parentPath = parentURL.path.precomposedStringWithCanonicalMapping
        
        guard parentPath != currentPath else { return }
        recordHistory(path: parentPath, side: side)
        
        // Курсор возвращается на папку, из которой вышли (как в Total Commander / Finder)
        if side == .left {
            leftPath = parentPath
            leftSelection.removeAll()
            updateActiveTab(side: .left)
            refreshPane(side: .left, selectPath: currentPath)
        } else {
            rightPath = parentPath
            rightSelection.removeAll()
            updateActiveTab(side: .right)
            refreshPane(side: .right, selectPath: currentPath)
        }
    }
    
    /// Путь непосредственного потомка `ancestor` на пути к `descendant`
    /// (`/a`, `/a/b/c` → `/a/b`). Nil, если `descendant` не лежит внутри `ancestor`.
    public static func immediateChildPath(of ancestor: String, toward descendant: String) -> String? {
        let base = ancestor.hasSuffix("/") ? String(ancestor.dropLast()) : ancestor
        guard descendant.count > base.count + 1, descendant.hasPrefix(base + "/") else { return nil }
        let rest = descendant.dropFirst(base.count + 1)
        guard let component = rest.split(separator: "/").first, !component.isEmpty else { return nil }
        return base + "/" + component
    }
    
    // MARK: - Single Rename & In-place Inline Rename
    public func triggerRename(item: FileItem? = nil, side: PaneSide? = nil) {
        startInlineRename(item: item, side: side)
    }
    
    public func startInlineRename(item: FileItem? = nil, side: PaneSide? = nil) {
        let currentSide = side ?? activePane
        if activePane != currentSide {
            activePane = currentSide
        }
        let items = (currentSide == .left) ? leftItems : rightItems
        let selection = (currentSide == .left) ? leftSelection : rightSelection
        
        let targetItem: FileItem?
        if let item = item {
            targetItem = item
        } else if let firstSelected = selection.first,
                  let found = items.first(where: { $0.id == firstSelected || $0.path == firstSelected || $0.name == firstSelected }) {
            targetItem = found
        } else {
            targetItem = items.first
        }
        
        guard let target = targetItem else {
            statusMessage = "Нет выбранного файла для переименования"
            return
        }
        
        self.itemToRename = target
        self.renameNewName = target.name
        self.editingItemId = target.id
        self.editingItemSide = currentSide
        self.editingItemName = target.name
        self.showRenameDialog = false
    }
    
    public func commitInlineRename(item: FileItem? = nil, side: PaneSide? = nil) {
        guard let targetItem = item ?? itemToRename ?? (editingItemId != nil ? (editingItemSide == .left ? leftItems : rightItems).first(where: { $0.id == editingItemId }) : nil) else {
            cancelInlineRename()
            return
        }
        let targetSide = side ?? editingItemSide ?? activePane
        let trimmed = editingItemName.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        
        cancelInlineRename()
        
        guard !trimmed.isEmpty else {
            errorMessage = "Имя файла не может быть пустым"
            showErrorAlert = true
            return
        }
        guard !trimmed.contains("/") else {
            errorMessage = "Имя файла не может содержать символ '/'"
            showErrorAlert = true
            return
        }
        guard trimmed != targetItem.name else { return }
        
        Task {
            do {
                try await self.renameChecked(from: targetItem.path, toName: trimmed, source: targetItem.source)
                await MainActor.run {
                    self.statusMessage = "Переименовано: '\(targetItem.name)' → '\(trimmed)'"
                    self.refreshPane(side: targetSide)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Ошибка переименования: \(error.localizedDescription)"
                    self.showErrorAlert = true
                }
            }
        }
    }
    
    /// Занято ли имя в папке. Для Mac — проверка по ФС (совпадение inode с самим объектом не считается конфликтом),
    /// для телефона — свежий листинг без кэша. Ошибка листинга пробрасывается: не считаем имя свободным вслепую.
    private func isNameTaken(inDirectory dir: String, name: String, originalPath: String, source: FileSource) async throws -> Bool {
        let target = (dir as NSString).appendingPathComponent(name)
        if source == .localMac {
            guard FileManager.default.fileExists(atPath: target) else { return false }
            let targetInode = (try? FileManager.default.attributesOfItem(atPath: target))?[.systemFileNumber] as? NSNumber
            let originalInode = (try? FileManager.default.attributesOfItem(atPath: originalPath))?[.systemFileNumber] as? NSNumber
            if let targetInode = targetInode, let originalInode = originalInode, targetInode == originalInode {
                return false
            }
            return true
        }
        let originalName = (originalPath as NSString).lastPathComponent
        let items = try await remoteDriver.listDirectory(at: dir, forceRefresh: true)
        return items.contains { $0.name.lowercased() == name.lowercased() && $0.name != originalName }
    }

    /// Переименование с проверкой занятого имени: rename поверх существующего объекта уничтожил бы его (D7)
    private func renameChecked(from oldPath: String, toName newName: String, source: FileSource) async throws {
        let dir = (oldPath as NSString).deletingLastPathComponent
        if try await isNameTaken(inDirectory: dir, name: newName, originalPath: oldPath, source: source) {
            throw FileOperationNameError.nameTaken(name: newName)
        }
        let newPath = (dir as NSString).appendingPathComponent(newName).precomposedStringWithCanonicalMapping
        let driver: FileSystemDriver = (source == .localMac) ? localDriver : remoteDriver
        try await driver.renameItem(from: oldPath, to: newPath)
    }

    public func cancelInlineRename() {
        editingItemId = nil
        editingItemSide = nil
        editingItemName = ""
    }
    
    public func confirmRename() {
        if !editingItemName.isEmpty {
            renameNewName = editingItemName
        }
        guard let item = itemToRename else { return }
        let trimmed = renameNewName.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        editingItemId = nil
        editingItemSide = nil
        editingItemName = ""
        
        guard !trimmed.isEmpty else {
            errorMessage = "Имя файла не может быть пустым"
            showErrorAlert = true
            return
        }
        guard !trimmed.contains("/") else {
            errorMessage = "Имя файла не может содержать символ '/'"
            showErrorAlert = true
            return
        }
        guard trimmed != item.name else { return }
        
        let side: PaneSide = (item.source == leftSource && leftItems.contains(where: { $0.id == item.id })) ? .left : .right

        Task {
            do {
                try await self.renameChecked(from: item.path, toName: trimmed, source: item.source)
                await MainActor.run {
                    self.statusMessage = "Переименовано: '\(item.name)' → '\(trimmed)'"
                    self.refreshPane(side: side)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Ошибка переименования: \(error.localizedDescription)"
                    self.showErrorAlert = true
                }
            }
        }
    }
    
    // MARK: - Properties (Get Info)
    public func triggerProperties(item: FileItem? = nil, side: PaneSide? = nil) {
        let currentSide = side ?? activePane
        let items = (currentSide == .left) ? leftItems : rightItems
        let selection = (currentSide == .left) ? leftSelection : rightSelection
        
        if let item = item {
            propertiesItem = item
        } else if let firstSelected = selection.first,
                  let found = items.first(where: { $0.id == firstSelected || $0.path == firstSelected || $0.name == firstSelected }) {
            propertiesItem = found
        } else {
            propertiesItem = items.first
        }
        showPropertiesDialog = true
    }
    
    // MARK: - File Diff Overlay Controls
    public func triggerFileDiff() {
        if isFileDiffActive {
            closeFileDiff()
            return
        }
        
        withAnimation(.easeInOut(duration: 0.18)) {
            isFileDiffActive = true
        }
        recomputeActiveFileDiff(isInitialOpen: true)
    }
    
    public func closeFileDiff() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isFileDiffActive = false
        }
        activeFileDiffResult = nil
        activeDiffLeftTarget = nil
        activeDiffRightTarget = nil
        activeDiffLeftURL = nil
        activeDiffRightURL = nil
        diffLeftPreviewLines = []
        diffRightPreviewLines = []
        diffLeftStatusMessage = "Выберите файл в левой панели"
        diffRightStatusMessage = "Выберите файл в правой панели"
        fileDiffChangedAlertSide = nil
        diffErrorMessage = nil
        stopWatchingFileDiffChanges()
        FileCompareManager.shared.closeSession()
        
        if activePane == .left {
            if !rightSelection.isEmpty {
                rightSelection.removeAll()
                TableDoubleClickHandler.HandlerView.rightTableView?.deselectAll(nil)
            }
        } else {
            if !leftSelection.isEmpty {
                leftSelection.removeAll()
                TableDoubleClickHandler.HandlerView.leftTableView?.deselectAll(nil)
            }
        }
    }
    
    public func scheduleCompareStateRecompute() {
        compareStateDebounceTask?.cancel()
        compareStateDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, let self = self else { return }
            let state = FileCompareManager.computeFastCompareState(
                leftItems: self.displayItems(for: .left),
                leftSelection: self.leftSelection,
                leftCursorId: self.leftCursorItemId,
                rightItems: self.displayItems(for: .right),
                rightSelection: self.rightSelection,
                rightCursorId: self.rightCursorItemId
            )
            self.fileCompareState = state
            if self.isFileDiffActive {
                self.recomputeActiveFileDiff(isInitialOpen: false)
            }
        }
    }
    
    public func recomputeActiveFileDiff(isInitialOpen: Bool = false) {
        activeDiffComputeTask?.cancel()
        
        let leftDisp = displayItems(for: .left)
        let rightDisp = displayItems(for: .right)
        
        let leftRes = FileCompareManager.resolveCompareTarget(
            side: .left,
            items: leftDisp,
            selection: leftSelection,
            cursorItemId: leftCursorItemId
        )
        let rightRes = FileCompareManager.resolveCompareTarget(
            side: .right,
            items: rightDisp,
            selection: rightSelection,
            cursorItemId: rightCursorItemId
        )
        
        var effectiveLeftRes = leftRes
        if case .failure = effectiveLeftRes,
           let existing = self.activeDiffLeftTarget,
           leftSelection.isEmpty,
           leftDisp.contains(where: { $0.id == existing.fileItem.id || $0.path == existing.fileItem.path }) {
            effectiveLeftRes = .success(existing)
            self.leftSelection = [existing.fileItem.id]
        }
        
        var effectiveRightRes = rightRes
        if case .failure = effectiveRightRes,
           let existing = self.activeDiffRightTarget,
           rightSelection.isEmpty,
           rightDisp.contains(where: { $0.id == existing.fileItem.id || $0.path == existing.fileItem.path }) {
            effectiveRightRes = .success(existing)
            self.rightSelection = [existing.fileItem.id]
        }
        
        switch effectiveLeftRes {
        case .success(let target):
            self.activeDiffLeftTarget = target
            self.diffLeftStatusMessage = ""
        case .failure(let err):
            self.activeDiffLeftTarget = nil
            self.diffLeftStatusMessage = err.message
            self.diffLeftPreviewLines = []
        }
        
        switch effectiveRightRes {
        case .success(let target):
            self.activeDiffRightTarget = target
            self.diffRightStatusMessage = ""
        case .failure(let err):
            self.activeDiffRightTarget = nil
            self.diffRightStatusMessage = err.message
            self.diffRightPreviewLines = []
        }
        
        let state: CompareState
        if case .success(let lTarget) = effectiveLeftRes, case .success(let rTarget) = effectiveRightRes {
            if lTarget.canonicalPath == rTarget.canonicalPath && lTarget.isRemote == rTarget.isRemote {
                state = .sameFile
            } else {
                state = .ready(left: lTarget, right: rTarget)
            }
        } else if case .failure(let err) = effectiveLeftRes {
            state = .noLeftFile(reason: err.message)
        } else if case .failure(let err) = effectiveRightRes {
            state = .noRightFile(reason: err.message)
        } else {
            state = .noLeftFile(reason: "Выберите файл")
        }
        self.fileCompareState = state
        
        guard case .ready(let leftTarget, let rightTarget) = state else {
            self.activeFileDiffResult = nil
            self.diffErrorMessage = state.tooltip
            self.isDiffLoading = false
            if let leftTarget = self.activeDiffLeftTarget {
                loadDiffPreview(target: leftTarget, side: .left)
            }
            if let rightTarget = self.activeDiffRightTarget {
                loadDiffPreview(target: rightTarget, side: .right)
            }
            return
        }
        
        self.activeDiffLeftTarget = leftTarget
        self.activeDiffRightTarget = rightTarget
        self.isDiffLoading = true
        self.diffErrorMessage = nil
        
        activeDiffComputeTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let leftURL = try await FileCompareManager.shared.prepareTargetForComparison(
                    target: leftTarget,
                    side: .left
                ) { [weak self] remotePath, targetURL in
                    guard let self = self else { return }
                    let stat = try await self.transport.prepareRead(actionId: UUID().uuidString, path: remotePath)
                    try await self.transport.downloadFileStreaming(
                        actionId: UUID().uuidString,
                        remotePath: remotePath,
                        targetURL: targetURL,
                        totalSize: stat.size
                    ) { _ in }
                }
                
                let rightURL = try await FileCompareManager.shared.prepareTargetForComparison(
                    target: rightTarget,
                    side: .right
                ) { [weak self] remotePath, targetURL in
                    guard let self = self else { return }
                    let stat = try await self.transport.prepareRead(actionId: UUID().uuidString, path: remotePath)
                    try await self.transport.downloadFileStreaming(
                        actionId: UUID().uuidString,
                        remotePath: remotePath,
                        targetURL: targetURL,
                        totalSize: stat.size
                    ) { _ in }
                }
                
                guard !Task.isCancelled else { return }
                
                self.activeDiffLeftURL = leftURL
                self.activeDiffRightURL = rightURL
                
                // Валидация и декодирование левого файла
                let leftVal = FileEncodingDetector.validateTextFile(fileURL: leftURL)
                let leftText: String
                switch leftVal {
                case .validText(let text, let enc, let name, let presumed):
                    leftText = text
                    self.leftFileEncoding = enc
                    self.leftFileEncodingName = name
                    self.leftFileEncodingPresumed = presumed
                case .binary(let reason), .readError(let reason):
                    self.diffErrorMessage = "Левый файл: \(reason)"
                    self.isDiffLoading = false
                    return
                case .tooLarge(let sz, let lim):
                    self.diffErrorMessage = "Левый файл больше лимита (\(sz / (1024 * 1024)) МБ > \(lim / (1024 * 1024)) МБ)"
                    self.isDiffLoading = false
                    return
                case .tooManyLines(let count, let lim):
                    self.diffErrorMessage = "Левый файл содержит слишком много строк (\(count) > \(lim))"
                    self.isDiffLoading = false
                    return
                }
                
                // Валидация и декодирование правого файла
                let rightVal = FileEncodingDetector.validateTextFile(fileURL: rightURL)
                let rightText: String
                switch rightVal {
                case .validText(let text, let enc, let name, let presumed):
                    rightText = text
                    self.rightFileEncoding = enc
                    self.rightFileEncodingName = name
                    self.rightFileEncodingPresumed = presumed
                case .binary(let reason), .readError(let reason):
                    self.diffErrorMessage = "Правый файл: \(reason)"
                    self.isDiffLoading = false
                    return
                case .tooLarge(let sz, let lim):
                    self.diffErrorMessage = "Правый файл больше лимита (\(sz / (1024 * 1024)) МБ > \(lim / (1024 * 1024)) МБ)"
                    self.isDiffLoading = false
                    return
                case .tooManyLines(let count, let lim):
                    self.diffErrorMessage = "Правый файл содержит слишком много строк (\(count) > \(lim))"
                    self.isDiffLoading = false
                    return
                }
                
                guard !Task.isCancelled else { return }
                
                let options = self.diffOptions
                let result = await Task.detached(priority: .userInitiated) {
                    return TextDiffEngine.diff(textA: leftText, textB: rightText, options: options)
                }.value
                
                guard !Task.isCancelled else { return }
                
                if result.isIdentical && isInitialOpen {
                    self.statusMessage = "Файлы совпадают"
                    self.closeFileDiff()
                    return
                }
                
                self.activeFileDiffResult = result
                self.diffCurrentHunkIndex = 0
                self.isDiffLoading = false
                
                if let attrs = try? FileManager.default.attributesOfItem(atPath: leftURL.path) {
                    self.lastObservedLeftMtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
                    self.lastObservedLeftSize = attrs[.size] as? UInt64
                }
                if let attrs = try? FileManager.default.attributesOfItem(atPath: rightURL.path) {
                    self.lastObservedRightMtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
                    self.lastObservedRightSize = attrs[.size] as? UInt64
                }
                self.startWatchingFileDiffChanges()
                
            } catch is CancellationError {
                // Отменено
            } catch {
                if !Task.isCancelled {
                    self.diffErrorMessage = "Ошибка сравнения: \(error.localizedDescription)"
                    self.isDiffLoading = false
                }
            }
        }
    }
    
    private func loadDiffPreview(target: CompareTarget, side: PaneSide) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let url = try await FileCompareManager.shared.prepareTargetForComparison(
                    target: target,
                    side: side
                ) { [weak self] remotePath, targetURL in
                    guard let self = self else { return }
                    let stat = try await self.transport.prepareRead(actionId: UUID().uuidString, path: remotePath)
                    try await self.transport.downloadFileStreaming(
                        actionId: UUID().uuidString,
                        remotePath: remotePath,
                        targetURL: targetURL,
                        totalSize: stat.size
                    ) { _ in }
                }
                guard !Task.isCancelled else { return }
                let val = FileEncodingDetector.validateTextFile(fileURL: url)
                if case .validText(let text, let enc, let name, let presumed) = val {
                    let lines = text.components(separatedBy: .newlines)
                    if side == .left {
                        self.leftFileEncoding = enc
                        self.leftFileEncodingName = name
                        self.leftFileEncodingPresumed = presumed
                        self.diffLeftPreviewLines = lines
                    } else {
                        self.rightFileEncoding = enc
                        self.rightFileEncodingName = name
                        self.rightFileEncodingPresumed = presumed
                        self.diffRightPreviewLines = lines
                    }
                }
            } catch {
                // Игнорируем ошибки при загрузке превью
            }
        }
    }
    
    public func changeFileEncoding(side: PaneSide, encoding: String.Encoding, name: String) {
        if side == .left {
            leftFileEncoding = encoding
            leftFileEncodingName = name
            leftFileEncodingPresumed = false
        } else {
            rightFileEncoding = encoding
            rightFileEncodingName = name
            rightFileEncodingPresumed = false
        }
        recomputeActiveFileDiff(isInitialOpen: false)
    }
    
    public func nextDiffDifference() {
        guard let res = activeFileDiffResult, !res.hunks.isEmpty else { return }
        if diffCurrentHunkIndex < res.hunks.count - 1 {
            diffCurrentHunkIndex += 1
        }
    }
    
    public func prevDiffDifference() {
        guard let res = activeFileDiffResult, !res.hunks.isEmpty else { return }
        if diffCurrentHunkIndex > 0 {
            diffCurrentHunkIndex -= 1
        }
    }
    
    public func reloadModifiedDiffFile(side: PaneSide) {
        fileDiffChangedAlertSide = nil
        recomputeActiveFileDiff(isInitialOpen: false)
    }
    
    private func startWatchingFileDiffChanges() {
        stopWatchingFileDiffChanges()
        fileDiffWatchTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkIfOpenDiffFilesChanged()
            }
        }
    }
    
    private func stopWatchingFileDiffChanges() {
        fileDiffWatchTimer?.invalidate()
        fileDiffWatchTimer = nil
    }
    
    private func checkIfOpenDiffFilesChanged() {
        guard isFileDiffActive else { return }
        
        if let leftURL = activeDiffLeftURL, let leftTarget = activeDiffLeftTarget, !leftTarget.isRemote {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: leftURL.path) {
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let size = (attrs[.size] as? UInt64) ?? 0
                if let lastM = lastObservedLeftMtime, let lastS = lastObservedLeftSize {
                    if mtime != lastM || size != lastS {
                        fileDiffChangedAlertSide = .left
                        return
                    }
                }
            }
        }
        
        if let rightURL = activeDiffRightURL, let rightTarget = activeDiffRightTarget, !rightTarget.isRemote {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: rightURL.path) {
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let size = (attrs[.size] as? UInt64) ?? 0
                if let lastM = lastObservedRightMtime, let lastS = lastObservedRightSize {
                    if mtime != lastM || size != lastS {
                        fileDiffChangedAlertSide = .right
                        return
                    }
                }
            }
        }
    }
    
    // MARK: - Copy Path of Selected Item
    @discardableResult
    public func copySelectedPath(side: PaneSide? = nil) -> String? {
        let currentSide = side ?? activePane
        let items = (currentSide == .left) ? leftItems : rightItems
        let selection = (currentSide == .left) ? leftSelection : rightSelection
        
        let selectedItems = items.filter { item in
            selection.contains(item.id) || selection.contains(item.path) || selection.contains(item.name)
        }
        
        let pathToCopy: String?
        if selectedItems.count > 1 {
            let combined = selectedItems.map(\.path).joined(separator: "\n")
            pathToCopy = combined
            statusMessage = "Скопированы пути \(selectedItems.count) объектов"
        } else if let single = selectedItems.first ?? items.first {
            pathToCopy = single.path
            statusMessage = "Скопирован путь: \(single.path)"
        } else {
            let folderPath = (currentSide == .left) ? leftPath : rightPath
            if !folderPath.isEmpty {
                pathToCopy = folderPath
                statusMessage = "Скопирован путь к папке: \(folderPath)"
            } else {
                pathToCopy = nil
            }
        }
        
        if let path = pathToCopy {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
            return path
        }
        return nil
    }
    
    // MARK: - Selection Helpers
    public func invertSelection(side: PaneSide? = nil) {
        let currentSide = side ?? activePane
        let items = (currentSide == .left) ? leftItems : rightItems
        let currentSelection = (currentSide == .left) ? leftSelection : rightSelection
        
        let allIds = Set(items.map(\.id))
        let inverted = allIds.subtracting(currentSelection)
        if currentSide == .left {
            leftSelection = inverted
        } else {
            rightSelection = inverted
        }
        statusMessage = "Выделено объектов: \(inverted.count) из \(items.count)"
    }
    
    public func selectAll(side: PaneSide? = nil) {
        let currentSide = side ?? activePane
        let items = (currentSide == .left) ? leftItems : rightItems
        let allIds = Set(items.map(\.id))
        if currentSide == .left {
            leftSelection = allIds
        } else {
            rightSelection = allIds
        }
        statusMessage = "Выделены все объекты (\(allIds.count))"
    }
    
    public func triggerCopy() {
        guard !isDuplicating else { return }
        startTransfer(isMove: false)
    }
    
    public func triggerMove() {
        guard !isDuplicating else { return }
        startTransfer(isMove: true)
    }
    
    public func triggerDelete() {
        guard !isDuplicating else { return }
        let side = activePane
        let selectedCount = (side == .left) ? leftSelection.count : rightSelection.count
        guard selectedCount > 0 else {
            statusMessage = "Нет выбранных объектов для удаления"
            return
        }
        
        let selectedIds = (side == .left) ? leftSelection : rightSelection
        let source = (side == .left) ? leftSource : rightSource
        let items = (side == .left) ? leftItems : rightItems
        
        let selectedItems = items.filter { selectedIds.contains($0.id) || selectedIds.contains($0.path) }
        let targetItems: [FileItem]
        if !selectedItems.isEmpty {
            targetItems = selectedItems
        } else {
            targetItems = selectedIds.map { id in
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: id, isDirectory: &isDir)
                return FileItem(
                    id: id,
                    name: URL(fileURLWithPath: id).lastPathComponent,
                    path: id,
                    size: 0,
                    mtime: 0,
                    isDirectory: exists ? isDir.boolValue : false,
                    source: source
                )
            }
        }
        
        var blockedItems: [(item: FileItem, reason: String)] = []
        for item in targetItems {
            let (isTagged, reason) = TagsManager.shared.isItemOrContentsTagged(item: item)
            if isTagged {
                blockedItems.append((item, reason ?? "Имеет теги"))
            }
        }
        
        if !blockedItems.isEmpty {
            errorAlertTitle = "Удаление невозможно"
            errorAlertButtonTitle = "OK"
            errorMessage = "Чтобы удалить файл, вам необходимо снять тег."
            showErrorAlert = true
            statusMessage = "Удаление отменено: необходимо снять тег"
            return
        }
        
        showDeleteConfirmDialog = true
    }
    
    public func confirmDelete() {
        let side = activePane
        let selectedIds = (side == .left) ? leftSelection : rightSelection
        let source = (side == .left) ? leftSource : rightSource
        let driver: FileSystemDriver = (source == .localMac) ? localDriver : remoteDriver
        let items = (side == .left) ? leftItems : rightItems
        
        Task {
            var failedCount = 0
            var firstFailure: String?
            var skippedTaggedCount = 0
            var successfullyDeletedIds: Set<String> = []
            
            for id in selectedIds {
                let matchedItem = items.first(where: { $0.id == id || $0.path == id })
                let itemToCheck: FileItem
                if let matchedItem = matchedItem {
                    itemToCheck = matchedItem
                } else {
                    var isDir: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: id, isDirectory: &isDir)
                    itemToCheck = FileItem(
                        id: id,
                        name: URL(fileURLWithPath: id).lastPathComponent,
                        path: id,
                        size: 0,
                        mtime: 0,
                        isDirectory: exists ? isDir.boolValue : false,
                        source: source
                    )
                }
                
                let (isTagged, _) = TagsManager.shared.isItemOrContentsTagged(item: itemToCheck)
                if isTagged {
                    skippedTaggedCount += 1
                    continue
                }
                
                do {
                    try await driver.deleteItem(at: itemToCheck.path, moveToTrash: true)
                    successfullyDeletedIds.insert(id)
                } catch {
                    failedCount += 1
                    if firstFailure == nil { firstFailure = error.localizedDescription }
                }
            }
            
            if side == .left {
                self.leftSelection.subtract(successfullyDeletedIds)
            } else {
                self.rightSelection.subtract(successfullyDeletedIds)
            }
            self.refreshPane(side: side)
            
            if skippedTaggedCount > 0 || failedCount > 0 {
                self.statusMessage = "В корзине: \(successfullyDeletedIds.count), пропущено из-за тегов: \(skippedTaggedCount), с ошибкой: \(failedCount)"
                self.errorAlertTitle = "Не все объекты перемещены в корзину"
                self.errorAlertButtonTitle = "OK"
                var messages: [String] = []
                if skippedTaggedCount > 0 {
                    messages.append("Чтобы удалить объекты с тегами, необходимо снять тег.")
                }
                if let firstFailure { messages.append(firstFailure) }
                self.errorMessage = messages.joined(separator: "\n")
                self.showErrorAlert = true
            } else {
                self.statusMessage = "Перемещено в корзину объектов: \(selectedIds.count)"
            }
        }
    }

    public func openPhoneTrash() {
        guard !isPhoneTrashBusy else {
            showPhoneTrash = true
            return
        }
        let path: String
        if activePane == .left && leftSource == .remotePhone {
            path = leftPath
        } else if rightSource == .remotePhone {
            path = rightPath
        } else if leftSource == .remotePhone {
            path = leftPath
        } else {
            path = "/storage/emulated/0"
        }
        phoneTrashEntries = []
        phoneTrashError = nil
        showPhoneTrash = true
        do {
            phoneTrashVolumePath = try PhoneTrashService.volumeRoot(for: path)
            reloadPhoneTrash()
        } catch {
            phoneTrashVolumePath = ""
            phoneTrashError = error.localizedDescription
        }
    }

    public func reloadPhoneTrash() {
        performPhoneTrashOperation { _ in }
    }

    public func restorePhoneTrashEntry(_ entry: PhoneTrashEntry) {
        performPhoneTrashOperation(success: "Восстановлено: \(entry.name)") { service in
            try await service.restore(entry)
        }
    }

    /// Вызывается только после отдельного подтверждения в окне корзины.
    public func emptyPhoneTrash() {
        let entries = phoneTrashEntries
        guard !entries.isEmpty else { return }
        performPhoneTrashOperation(success: "Корзина телефона очищена") { service in
            for entry in entries {
                try await service.permanentlyDelete(entry)
            }
        }
    }

    private func performPhoneTrashOperation(
        success: String? = nil,
        operation: @escaping @Sendable (PhoneTrashService) async throws -> Void
    ) {
        guard !isPhoneTrashBusy else { return }
        guard !phoneTrashVolumePath.isEmpty else { return }
        guard remoteDriver.isConnected else {
            phoneTrashError = "Подключите телефон, затем нажмите «Обновить»."
            return
        }
        isPhoneTrashBusy = true
        phoneTrashError = nil
        let volume = phoneTrashVolumePath
        let service = remoteDriver.phoneTrash
        Task { [weak self] in
            do {
                try await operation(service)
                let entries = try await service.entries(volumePath: volume)
                guard let self else { return }
                self.phoneTrashEntries = entries
                if let success {
                    self.statusMessage = success
                    if self.leftSource == .remotePhone { self.refreshPane(side: .left) }
                    if self.rightSource == .remotePhone { self.refreshPane(side: .right) }
                }
                self.isPhoneTrashBusy = false
            } catch {
                let updated = try? await service.entries(volumePath: volume)
                guard let self else { return }
                if let updated { self.phoneTrashEntries = updated }
                self.phoneTrashError = error.localizedDescription
                self.isPhoneTrashBusy = false
            }
        }
    }
    
    public func contextMenuItems(for item: FileItem, side: PaneSide) -> [FileItem] {
        let items = side == .left ? leftItems : rightItems
        let selection = side == .left ? leftSelection : rightSelection
        let itemIsSelected = selection.contains(item.id) || selection.contains(item.path)
        guard itemIsSelected else { return [item] }

        let selectedItems = items.filter { selection.contains($0.id) || selection.contains($0.path) }
        return selectedItems.isEmpty ? [item] : selectedItems
    }

    public func prepareNewFolder(side: PaneSide? = nil) {
        guard !isDuplicating else { return }
        if let side, activePane != side { activePane = side }
        newFolderName = ""
        newFolderSelectedItems = []
        showNewFolderDialog = true
    }

    public func prepareNewFolderWithSelection(item: FileItem, side: PaneSide) {
        guard !isDuplicating else { return }
        let selectedItems = contextMenuItems(for: item, side: side)
        if activePane != side { activePane = side }
        newFolderName = ""
        newFolderSelectedItems = selectedItems
        showNewFolderDialog = true
    }

    public func selectContextMenuItems(for item: FileItem, side: PaneSide) {
        let selectedItems = contextMenuItems(for: item, side: side)
        if activePane != side { activePane = side }
        let selectedIDs = Set(selectedItems.map(\.id))
        if side == .left {
            leftSelection = selectedIDs
        } else {
            rightSelection = selectedIDs
        }
    }

    public func cancelNewFolderCreation() {
        newFolderName = ""
        newFolderSelectedItems = []
    }

    public func createFolder() {
        let folderName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !folderName.isEmpty, folderName != ".", folderName != "..", !folderName.contains("/") else {
            errorMessage = "Введите корректное имя папки без символа '/'."
            showErrorAlert = true
            return
        }

        let side = activePane
        let currentPath = side == .left ? leftPath : rightPath
        let source = side == .left ? leftSource : rightSource
        let driver: FileSystemDriver = source == .localMac ? localDriver : remoteDriver
        let targetPath = URL(fileURLWithPath: currentPath).appendingPathComponent(folderName).path
        let selectedItems = newFolderSelectedItems

        Task {
            var movedItems: [(source: String, destination: String)] = []
            var folderCreated = false

            do {
                let siblings = try await driver.listDirectory(at: currentPath)
                guard !siblings.contains(where: { $0.name == folderName }) else {
                    throw NSError(domain: "DualPaneViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Папка «\(folderName)» уже существует."])
                }

                try await driver.createDirectory(at: targetPath)
                folderCreated = true

                for item in selectedItems {
                    let destination = URL(fileURLWithPath: targetPath).appendingPathComponent(item.name).path
                    try await driver.renameItem(from: item.path, to: destination)
                    movedItems.append((source: item.path, destination: destination))
                }

                self.newFolderName = ""
                self.newFolderSelectedItems = []
                if !selectedItems.isEmpty {
                    if side == .left { self.leftSelection.removeAll() } else { self.rightSelection.removeAll() }
                }
                self.refreshPane(side: side)
                self.statusMessage = selectedItems.isEmpty
                    ? "Папка создана: \(targetPath)"
                    : "Создана папка «\(folderName)», перемещено объектов: \(selectedItems.count)"
            } catch {
                var rollbackSucceeded = true
                for movedItem in movedItems.reversed() {
                    do {
                        try await driver.renameItem(from: movedItem.destination, to: movedItem.source)
                    } catch {
                        rollbackSucceeded = false
                    }
                }
                if folderCreated && rollbackSucceeded {
                    try? await driver.deleteItem(at: targetPath, moveToTrash: false)
                }

                self.newFolderSelectedItems = []
                self.errorMessage = rollbackSucceeded
                    ? error.localizedDescription
                    : "\(error.localizedDescription) Не все объекты удалось вернуть на исходные места; папка «\(folderName)» сохранена."
                self.showErrorAlert = true
                self.refreshPane(side: side)
            }
        }
    }
    
    // MARK: - Clipboard & Duplicate Operations
    
    public func copyToClipboard(items: [FileItem]? = nil, side: PaneSide? = nil) {
        let currentSide = side ?? activePane
        let allItems = (currentSide == .left) ? leftItems : rightItems
        let selection = (currentSide == .left) ? leftSelection : rightSelection
        let currentSource = (currentSide == .left) ? leftSource : rightSource
        
        let targetItems: [FileItem]
        if let items = items, !items.isEmpty {
            targetItems = items
        } else if !selection.isEmpty {
            targetItems = allItems.filter { selection.contains($0.id) || selection.contains($0.path) }
        } else if let first = allItems.first {
            targetItems = [first]
        } else {
            return
        }
        
        self.clipboardItems = targetItems
        self.clipboardSource = currentSource
        self.clipboardIsCut = false
        
        // Интеграция с системным буфером обмена macOS
        NSPasteboard.general.clearContents()
        if currentSource == .localMac {
            let urls = targetItems.map { URL(fileURLWithPath: $0.path) }
            NSPasteboard.general.writeObjects(urls as [NSURL])
        } else {
            let names = targetItems.map(\.name).joined(separator: "\n")
            NSPasteboard.general.setString(names, forType: .string)
        }
        
        if targetItems.count == 1 {
            statusMessage = "Скопировано в буфер: \(targetItems[0].name)"
        } else {
            statusMessage = "Скопировано в буфер: \(targetItems.count) объектов"
        }
    }
    
    public func cutToClipboard(items: [FileItem]? = nil, side: PaneSide? = nil) {
        copyToClipboard(items: items, side: side)
        self.clipboardIsCut = true
        let count = clipboardItems.count
        if count == 1, let first = clipboardItems.first {
            statusMessage = "Вырезано в буфер: \(first.name)"
        } else {
            statusMessage = "Вырезано в буфер: \(count) объектов"
        }
    }
    
    public func copySelectedNamesToClipboard(side: PaneSide? = nil) {
        let currentSide = side ?? activePane
        let allItems = (currentSide == .left) ? leftItems : rightItems
        let selection = (currentSide == .left) ? leftSelection : rightSelection
        
        let targetItems: [FileItem]
        if !selection.isEmpty {
            targetItems = allItems.filter { selection.contains($0.id) || selection.contains($0.path) }
        } else if let first = allItems.first {
            targetItems = [first]
        } else {
            return
        }
        
        guard !targetItems.isEmpty else { return }
        let names = targetItems.map(\.name).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names, forType: .string)
        
        if targetItems.count == 1 {
            statusMessage = "Скопировано имя: \(targetItems[0].name)"
        } else {
            statusMessage = "Скопировано имён: \(targetItems.count)"
        }
    }
    
    /// Копирование локальных объектов вне MainActor. Возвращает число успешных копий и тексты ошибок.
    private func copyLocalItemsOffMain(_ pairs: [(src: URL, dst: URL)]) async -> (copied: Int, errors: [String]) {
        await Task.detached(priority: .userInitiated) {
            var copied = 0
            var errors: [String] = []
            for pair in pairs {
                do {
                    try FileManager.default.copyItem(at: pair.src, to: pair.dst)
                    copied += 1
                } catch {
                    errors.append("\(pair.src.lastPathComponent): \(error.localizedDescription)")
                }
            }
            return (copied, errors)
        }.value
    }
    
    public func pasteFromClipboard(targetSide: PaneSide? = nil) {
        let destSide = targetSide ?? activePane
        let destPath = (destSide == .left) ? leftPath : rightPath
        let destSource = (destSide == .left) ? leftSource : rightSource
        let isCut = clipboardIsCut
        
        // 1. Проверяем внутренний буфер приложения
        if !clipboardItems.isEmpty {
            let source = clipboardSource
            let itemsToPaste = clipboardItems
            
            if source == destSource && destSource == .localMac && !isCut {
                // Копирование в пределах Mac (вырезание идёт через оркестратор: защита от перезаписи, конфликты, перенос): имена для вставки в ту же папку считаем на MainActor, копируем вне его
                let sideItems = (destSide == .left) ? leftItems : rightItems
                let pairs: [(src: URL, dst: URL)] = itemsToPaste.map { item in
                    let originalURL = URL(fileURLWithPath: item.path)
                    var targetName = originalURL.lastPathComponent
                    // Если вставляем в ту же самую папку — генерируем имя "(копия)"
                    if originalURL.deletingLastPathComponent().path == destPath {
                        targetName = self.generateDuplicateName(baseName: item.name, in: sideItems)
                    }
                    return (src: originalURL, dst: URL(fileURLWithPath: destPath).appendingPathComponent(targetName))
                }
                Task {
                    let result = await self.copyLocalItemsOffMain(pairs)
                    // Копия в той же папке не должна унаследовать теги оригинала
                    for pair in pairs where pair.src.deletingLastPathComponent().path == destPath {
                        TagsManager.shared.clearTags(at: pair.dst.path, source: .localMac)
                    }
                    self.refreshPane(side: destSide)
                    self.statusMessage = "Вставлено объектов: \(result.copied)"
                    if !result.errors.isEmpty {
                        self.errorMessage = "Не вставлено объектов: \(result.errors.count)\n" + result.errors.prefix(10).joined(separator: "\n")
                        self.showErrorAlert = true
                    }
                }
            } else {
                // Телефон → телефон и межплатформенная вставка идут через оркестратор (конфликты, проверки, отчёт)
                self.executeTransfer(
                    paths: itemsToPaste.map(\.path),
                    fromSource: source,
                    toSide: destSide,
                    targetDirPath: destPath,
                    isMove: isCut
                )
                if isCut {
                    self.clipboardItems = []
                    self.clipboardIsCut = false
                }
            }
            return
        }
        
        // 2. Проверяем системный буфер обмена (файлы из Finder)
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let paths = urls.map(\.path)
            if destSource == .localMac {
                let pairs: [(src: URL, dst: URL)] = urls.map { url in
                    (src: url, dst: URL(fileURLWithPath: destPath).appendingPathComponent(url.lastPathComponent))
                }
                Task {
                    // Успех считаем только если все операции прошли; ошибки показываем пользователю
                    let result = await self.copyLocalItemsOffMain(pairs)
                    self.refreshPane(side: destSide)
                    if result.errors.isEmpty {
                        self.statusMessage = "Вставлено из Finder: \(result.copied) объектов"
                    } else {
                        self.statusMessage = "Вставлено из Finder: \(result.copied), ошибок: \(result.errors.count)"
                        self.errorMessage = "Не вставлено объектов: \(result.errors.count)\n" + result.errors.prefix(10).joined(separator: "\n")
                        self.showErrorAlert = true
                    }
                }
            } else {
                self.executeTransfer(
                    paths: paths,
                    fromSource: .localMac,
                    toSide: destSide,
                    targetDirPath: destPath,
                    isMove: false
                )
            }
        }
    }
    
    // MARK: - Folder & Item Duplication
    public func cancelDuplicate() {
        guard isDuplicating else { return }
        isDuplicateCancelled = true
        duplicateTask?.cancel()
        duplicateTimerTask?.cancel()
        duplicatePendingTargets.removeAll()
        
        for path in duplicateCreatedPaths {
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        duplicateCreatedPaths.removeAll()
        
        withAnimation(.easeOut(duration: 0.2)) {
            showDuplicationModal = false
        }
        isDuplicating = false
        statusMessage = "Дублирование отменено"
        refreshPane(side: activePane)
    }
    
    nonisolated public static func formatDuplicateSizeAndETA(transferred: UInt64, total: UInt64, eta: TimeInterval?) -> String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useAll]
        bcf.countStyle = .file
        
        let transferredStr = bcf.string(fromByteCount: Int64(transferred))
        let totalStr = bcf.string(fromByteCount: Int64(total))
        
        let etaStr: String
        if let eta = eta, eta > 0, eta.isFinite {
            if eta < 60 {
                etaStr = "меньше минуты"
            } else if eta < 3600 {
                let mins = Int(ceil(eta / 60))
                if mins == 1 {
                    etaStr = "около 1 минуты"
                } else {
                    etaStr = "около \(mins) мин."
                }
            } else {
                let hrs = Int(ceil(eta / 3600))
                etaStr = "около \(hrs) ч."
            }
        } else if transferred == 0 && total > 0 {
            etaStr = "вычисление..."
        } else if transferred >= total && total > 0 {
            etaStr = "завершение..."
        } else {
            etaStr = "меньше минуты"
        }
        
        return "\(transferredStr) из \(totalStr) — \(etaStr)"
    }
    
    public func duplicateItem(item: FileItem? = nil, side: PaneSide? = nil) {
        let currentSide = side ?? activePane
        let allItems = (currentSide == .left) ? leftItems : rightItems
        let selection = (currentSide == .left) ? leftSelection : rightSelection
        let source = (currentSide == .left) ? leftSource : rightSource
        
        let targetsToDuplicate: [FileItem]
        if let item = item {
            targetsToDuplicate = [item]
        } else if !selection.isEmpty {
            targetsToDuplicate = allItems.filter { selection.contains($0.id) || selection.contains($0.path) }
        } else if let first = allItems.first {
            targetsToDuplicate = [first]
        } else {
            targetsToDuplicate = []
        }
        
        guard !targetsToDuplicate.isEmpty else {
            statusMessage = "Нет выбранного объекта для дублирования"
            return
        }
        
        if isDuplicating {
            duplicatePendingTargets.append((targets: targetsToDuplicate, side: currentSide))
            return
        }
        
        isDuplicating = true
        isDuplicateCancelled = false
        showDuplicationModal = false
        duplicateProgress = 0.0
        duplicateTransferredBytes = 0
        duplicateCreatedPaths.removeAll()
        duplicateIsFolder = targetsToDuplicate.contains { $0.isDirectory } || targetsToDuplicate.count > 1
        duplicateFirstTargetPath = targetsToDuplicate.first?.path
        
        let parentDir = URL(fileURLWithPath: targetsToDuplicate[0].path).deletingLastPathComponent().path
        let parentDirName = URL(fileURLWithPath: parentDir).lastPathComponent
        
        duplicateTask?.cancel()
        duplicateTimerTask?.cancel()
        
        let delayNs = UInt64(max(0.01, self.duplicationModalDelay) * 1_000_000_000)
        duplicateTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard let self = self, !Task.isCancelled else { return }
            if self.isDuplicating && !self.isDuplicateCancelled {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.showDuplicationModal = true
                }
            }
        }
        
        duplicateTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.runDuplicationBatch(targets: targetsToDuplicate, side: currentSide, parentDirName: parentDirName)
            
            while !self.duplicatePendingTargets.isEmpty && !self.isDuplicateCancelled {
                let next = self.duplicatePendingTargets.removeFirst()
                let pDir = URL(fileURLWithPath: next.targets[0].path).deletingLastPathComponent().path
                let pName = URL(fileURLWithPath: pDir).lastPathComponent
                await self.runDuplicationBatch(targets: next.targets, side: next.side, parentDirName: pName)
            }
            
            self.duplicateTimerTask?.cancel()
            withAnimation(.easeOut(duration: 0.2)) {
                self.showDuplicationModal = false
            }
            self.isDuplicating = false
            self.duplicateCreatedPaths.removeAll()
        }
    }
    
    private func runDuplicationBatch(targets: [FileItem], side: PaneSide, parentDirName: String) async {
        let allItems = (side == .left) ? leftItems : rightItems
        let source = (side == .left) ? leftSource : rightSource
        let speedTracker = TransferSpeedTracker()
        
        var totalObjectsCount = 0
        var totalBytesCount: UInt64 = 0
        
        for target in targets {
            if target.isDirectory && source == .localMac {
                totalObjectsCount += 1
                if let enumerator = FileManager.default.enumerator(
                    at: URL(fileURLWithPath: target.path),
                    includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                    options: []
                ) {
                    for case let fileURL as URL in enumerator {
                        totalObjectsCount += 1
                        let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                        if vals?.isDirectory != true {
                            totalBytesCount += UInt64(vals?.fileSize ?? 0)
                        }
                    }
                }
            } else {
                totalObjectsCount += 1
                totalBytesCount += target.size
            }
        }
        
        self.duplicateTotalObjects = totalObjectsCount
        self.duplicateTotalBytes = totalBytesCount
        self.duplicateIsFolder = targets.contains { $0.isDirectory } || totalObjectsCount > 1
        self.duplicateFirstTargetPath = targets.first?.path
        
        if totalObjectsCount > 1 {
            self.duplicateTitle = "Дублирование объектов (\(totalObjectsCount)) в «\(parentDirName.isEmpty ? "/" : parentDirName)»"
        } else {
            self.duplicateTitle = "Дублирование «\(targets.first?.name ?? "")»"
        }
        self.duplicateSubtitle = Self.formatDuplicateSizeAndETA(transferred: 0, total: totalBytesCount, eta: nil)
        
        // Для больших файлов или папок (>= 20 МБ или >= 25 объектов) открываем модальное окно со спиннером оперативно
        if (totalBytesCount >= 20 * 1024 * 1024 || totalObjectsCount >= 25) && !self.showDuplicationModal && !self.isDuplicateCancelled {
            withAnimation(.easeInOut(duration: 0.2)) {
                self.showDuplicationModal = true
            }
        }
        
        var currentItems = allItems
        var createdNames: [String] = []
        var transferredBytesTotal: UInt64 = 0
        var lastProgressUpdate: CFAbsoluteTime = 0
        
        do {
            for target in targets {
                if self.isDuplicateCancelled || Task.isCancelled {
                    throw CancellationError()
                }
                
                let newName = self.generateDuplicateName(baseName: target.name, in: currentItems)
                let dir = URL(fileURLWithPath: target.path).deletingLastPathComponent().path
                let newPath = URL(fileURLWithPath: dir).appendingPathComponent(newName).path
                if source == .localMac {
                    self.duplicateCreatedPaths.append(newPath)
                }
                
                if source == .localMac {
                    if target.isDirectory {
                        try FileManager.default.createDirectory(atPath: newPath, withIntermediateDirectories: true)
                        
                        let sourceURL = URL(fileURLWithPath: target.path)
                        guard let enumerator = FileManager.default.enumerator(
                            at: sourceURL,
                            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                            options: []
                        ) else {
                            try FileManager.default.copyItem(atPath: target.path, toPath: newPath)
                            continue
                        }
                        
                        let targetResolvedPath = URL(fileURLWithPath: target.path).resolvingSymlinksInPath().path
                        let targetResolvedPrefix = targetResolvedPath.hasSuffix("/") ? targetResolvedPath : (targetResolvedPath + "/")
                        let targetPrefix = target.path.hasSuffix("/") ? target.path : (target.path + "/")
                        
                        for case let fileURL as URL in enumerator {
                            if self.isDuplicateCancelled || Task.isCancelled {
                                throw CancellationError()
                            }
                            
                            let fileResolvedPath = fileURL.resolvingSymlinksInPath().path
                            let relPath: String
                            if fileResolvedPath.hasPrefix(targetResolvedPrefix) {
                                relPath = String(fileResolvedPath.dropFirst(targetResolvedPrefix.count))
                            } else if fileURL.path.hasPrefix(targetPrefix) {
                                relPath = String(fileURL.path.dropFirst(targetPrefix.count))
                            } else {
                                relPath = fileURL.lastPathComponent
                            }
                            
                            let destURL = URL(fileURLWithPath: newPath).appendingPathComponent(relPath)
                            let destPath = destURL.path
                            let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                            let isDir = vals?.isDirectory ?? false
                            
                            if isDir {
                                try FileManager.default.createDirectory(atPath: destPath, withIntermediateDirectories: true)
                            } else {
                                let parentDir = destURL.deletingLastPathComponent().path
                                if !FileManager.default.fileExists(atPath: parentDir) {
                                    try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
                                }
                                let fSize = UInt64(vals?.fileSize ?? 0)
                                if fSize > 2 * 1024 * 1024,
                                   let readHandle = try? FileHandle(forReadingFrom: fileURL) {
                                    FileManager.default.createFile(atPath: destPath, contents: nil)
                                    if let writeHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: destPath)) {
                                        let chunkSize = 1024 * 1024
                                        while !self.isDuplicateCancelled && !Task.isCancelled {
                                            let data = readHandle.readData(ofLength: chunkSize)
                                            if data.isEmpty { break }
                                            writeHandle.write(data)
                                            transferredBytesTotal += UInt64(data.count)
                                            speedTracker.update(bytesTransferred: transferredBytesTotal)
                                            
                                            let now = CFAbsoluteTimeGetCurrent()
                                            if now - lastProgressUpdate >= 0.067 {
                                                lastProgressUpdate = now
                                                let rem = totalBytesCount > transferredBytesTotal ? (totalBytesCount - transferredBytesTotal) : 0
                                                let eta = speedTracker.calculateETA(remainingBytes: rem)
                                                self.duplicateTransferredBytes = transferredBytesTotal
                                                self.duplicateProgress = totalBytesCount > 0 ? min(1.0, Double(transferredBytesTotal) / Double(totalBytesCount)) : 0.0
                                                self.duplicateSubtitle = Self.formatDuplicateSizeAndETA(transferred: transferredBytesTotal, total: totalBytesCount, eta: eta)
                                            }
                                            await Task.yield()
                                        }
                                        try? writeHandle.close()
                                        try? readHandle.close()
                                        if self.isDuplicateCancelled || Task.isCancelled {
                                            throw CancellationError()
                                        }
                                    } else {
                                        try? readHandle.close()
                                        try FileManager.default.copyItem(atPath: fileURL.path, toPath: destPath)
                                        transferredBytesTotal += fSize
                                    }
                                } else {
                                    try FileManager.default.copyItem(atPath: fileURL.path, toPath: destPath)
                                    transferredBytesTotal += fSize
                                    speedTracker.update(bytesTransferred: transferredBytesTotal)
                                    
                                    let now = CFAbsoluteTimeGetCurrent()
                                    if now - lastProgressUpdate >= 0.067 {
                                        lastProgressUpdate = now
                                        let rem = totalBytesCount > transferredBytesTotal ? (totalBytesCount - transferredBytesTotal) : 0
                                        let eta = speedTracker.calculateETA(remainingBytes: rem)
                                        self.duplicateTransferredBytes = transferredBytesTotal
                                        self.duplicateProgress = totalBytesCount > 0 ? min(1.0, Double(transferredBytesTotal) / Double(totalBytesCount)) : 0.0
                                        self.duplicateSubtitle = Self.formatDuplicateSizeAndETA(transferred: transferredBytesTotal, total: totalBytesCount, eta: eta)
                                    }
                                }
                            }
                            TagsManager.shared.clearTags(at: destPath, source: .localMac)
                            await Task.yield()
                        }
                        
                        TagsManager.shared.clearTags(at: newPath, source: .localMac)
                    } else {
                        // Одиночный файл
                        let fSize = target.size
                        if fSize > 2 * 1024 * 1024,
                           let readHandle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: target.path)) {
                            FileManager.default.createFile(atPath: newPath, contents: nil)
                            if let writeHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: newPath)) {
                                let chunkSize = 1024 * 1024
                                while !self.isDuplicateCancelled && !Task.isCancelled {
                                    let data = readHandle.readData(ofLength: chunkSize)
                                    if data.isEmpty { break }
                                    writeHandle.write(data)
                                    transferredBytesTotal += UInt64(data.count)
                                    speedTracker.update(bytesTransferred: transferredBytesTotal)
                                    
                                    let now = CFAbsoluteTimeGetCurrent()
                                    if now - lastProgressUpdate >= 0.067 {
                                        lastProgressUpdate = now
                                        let rem = totalBytesCount > transferredBytesTotal ? (totalBytesCount - transferredBytesTotal) : 0
                                        let eta = speedTracker.calculateETA(remainingBytes: rem)
                                        self.duplicateTransferredBytes = transferredBytesTotal
                                        self.duplicateProgress = totalBytesCount > 0 ? min(1.0, Double(transferredBytesTotal) / Double(totalBytesCount)) : 0.0
                                        self.duplicateSubtitle = Self.formatDuplicateSizeAndETA(transferred: transferredBytesTotal, total: totalBytesCount, eta: eta)
                                    }
                                    await Task.yield()
                                }
                                try? writeHandle.close()
                                try? readHandle.close()
                                if self.isDuplicateCancelled || Task.isCancelled {
                                    throw CancellationError()
                                }
                            } else {
                                try? readHandle.close()
                                try FileManager.default.copyItem(atPath: target.path, toPath: newPath)
                                transferredBytesTotal += fSize
                            }
                        } else {
                            try FileManager.default.copyItem(atPath: target.path, toPath: newPath)
                            transferredBytesTotal += fSize
                            speedTracker.update(bytesTransferred: transferredBytesTotal)
                        }
                        TagsManager.shared.clearTags(at: newPath, source: .localMac)
                    }
                } else {
                    // Телефон: прямое копирование внутри устройства (раньше задача лишь ставилась в очередь и не выполнялась).
                    guard !target.isDirectory else {
                        throw NSError(domain: "Duplicate", code: 1, userInfo: [NSLocalizedDescriptionKey: "Дублирование папок на телефоне пока не поддерживается"])
                    }
                    // Свежий листинг: имя должно быть свободно (cp на телефоне перезаписывает цель)
                    let siblings = try? await self.remoteDriver.listDirectory(at: dir, forceRefresh: true)
                    guard let existing = siblings, !existing.contains(where: { $0.name == newName }) else {
                        throw NSError(domain: "Duplicate", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось дублировать: объект с именем «\(newName)» уже существует или папка недоступна"])
                    }
                    let copied = await Task.detached(priority: .userInitiated) {
                        PhoneConnectionManager.shared.copyFileOnDevice(sourcePath: target.path, targetPath: newPath)
                    }.value
                    guard copied else {
                        throw NSError(domain: "Duplicate", code: 3, userInfo: [NSLocalizedDescriptionKey: "Не удалось дублировать на телефоне: \(target.name)"])
                    }
                    transferredBytesTotal += target.size
                    TagsManager.shared.clearTags(at: newPath, source: .remotePhone)
                }
                
                createdNames.append(newName)
                currentItems.append(FileItem(
                    id: newPath,
                    name: newName,
                    path: newPath,
                    size: target.size,
                    mtime: Date().timeIntervalSince1970,
                    isDirectory: target.isDirectory,
                    source: source
                ))
            }
            
            self.refreshPane(side: side)
            if createdNames.count == 1, let first = createdNames.first {
                self.statusMessage = "Создан дубликат: \(first)"
            } else {
                self.statusMessage = "Создано дубликатов: \(createdNames.count)"
            }
        } catch is CancellationError {
            for path in self.duplicateCreatedPaths {
                try? FileManager.default.removeItem(atPath: path)
            }
            self.duplicateCreatedPaths.removeAll()
            self.statusMessage = "Дублирование отменено"
            self.refreshPane(side: side)
        } catch {
            for path in self.duplicateCreatedPaths {
                try? FileManager.default.removeItem(atPath: path)
            }
            self.duplicateCreatedPaths.removeAll()
            self.errorMessage = "Не удалось дублировать: \(error.localizedDescription)"
            self.showErrorAlert = true
        }
    }
    
    private func generateDuplicateName(baseName: String, in items: [FileItem]) -> String {
        let url = URL(fileURLWithPath: baseName)
        let ext = url.pathExtension
        let nameWithoutExt = url.deletingPathExtension().lastPathComponent
        
        let existingNames = Set(items.map(\.name))
        
        // 1. Проверяем "имя (копия).ext"
        let firstCandidate = ext.isEmpty ? "\(nameWithoutExt) (копия)" : "\(nameWithoutExt) (копия).\(ext)"
        if !existingNames.contains(firstCandidate) {
            return firstCandidate
        }
        
        // 2. Инкремент: "имя (копия 2).ext" ...
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(nameWithoutExt) (копия \(index))" : "\(nameWithoutExt) (копия \(index)).\(ext)"
            if !existingNames.contains(candidate) {
                return candidate
            }
            index += 1
        }
    }
    
    // MARK: - Open with...
    private var appsForExtensionCache: [String: [URL]] = [:]
    
    public func getApplicationsForFile(item: FileItem) -> [URL] {
        let ext = URL(fileURLWithPath: item.name).pathExtension.lowercased()
        if !ext.isEmpty, let cached = appsForExtensionCache[ext] {
            return cached
        }
        
        let apps: [URL]
        if item.source == .localMac && FileManager.default.fileExists(atPath: item.path) {
            let fileURL = URL(fileURLWithPath: item.path)
            apps = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
        } else {
            guard !ext.isEmpty else { return [] }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("probe.\(ext)")
            if !FileManager.default.fileExists(atPath: tempURL.path) {
                try? Data().write(to: tempURL)
            }
            apps = NSWorkspace.shared.urlsForApplications(toOpen: tempURL)
        }
        if !ext.isEmpty {
            appsForExtensionCache[ext] = apps
        }
        return apps
    }
    
    public func openFile(item: FileItem, withApplicationURL appURL: URL) {
        if item.source == .localMac {
            let fileURL = URL(fileURLWithPath: item.path)
            NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            statusMessage = "Открыто в \(appURL.deletingPathExtension().lastPathComponent): \(item.name)"
        } else {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MacDroidOpenWith")
            let tempURL = tempDir.appendingPathComponent(item.name)
            statusMessage = "Скачивание для открытия: \(item.name)..."
            
            Task {
                do {
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let stat = try await self.transport.prepareRead(actionId: UUID().uuidString, path: item.path)
                    try await self.transport.downloadFileStreaming(
                        actionId: UUID().uuidString,
                        remotePath: item.path,
                        targetURL: tempURL,
                        totalSize: stat.size
                    ) { _ in }
                    
                    self.statusMessage = "Открыто в \(appURL.deletingPathExtension().lastPathComponent): \(item.name)"
                    NSWorkspace.shared.open([tempURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                } catch {
                    self.errorMessage = "Ошибка скачивания для открытия: \(error.localizedDescription)"
                    self.showErrorAlert = true
                }
            }
        }
    }
    
    public func chooseCustomApplicationAndOpen(item: FileItem) {
        let openPanel = NSOpenPanel()
        openPanel.directoryURL = URL(fileURLWithPath: "/Applications")
        openPanel.allowedContentTypes = [.application, .bundle]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.title = "Выберите программу для открытия «\(item.name)»"
        
        if openPanel.runModal() == .OK, let selectedAppURL = openPanel.url {
            openFile(item: item, withApplicationURL: selectedAppURL)
        }
    }
    
    // MARK: - Sharing Services (Telegram, WhatsApp, Gmail)
    
    public func share(
        items: [FileItem],
        side: PaneSide,
        target: ShareTarget,
        sourceView: NSView? = nil,
        rect: NSRect = .zero
    ) {
        guard !items.isEmpty else { return }
        let hasRemote = items.contains { $0.source != .localMac }
        
        if !hasRemote {
            let urls = items.map { URL(fileURLWithPath: $0.path) }
            executeShare(urls: urls, target: target, sourceView: sourceView, rect: rect)
        } else {
            let itemNames = items.map(\.name).joined(separator: ", ")
            statusMessage = "Подготовка файлов для отправки: \(itemNames)..."
            
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacDroidShare")
                .appendingPathComponent(UUID().uuidString)
            
            Task { @MainActor in
                do {
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    var downloadedURLs: [URL] = []
                    
                    for item in items {
                        if item.source == .localMac {
                            downloadedURLs.append(URL(fileURLWithPath: item.path))
                        } else {
                            let targetURL = tempDir.appendingPathComponent(item.name)
                            let stat = try await self.transport.prepareRead(actionId: UUID().uuidString, path: item.path)
                            try await self.transport.downloadFileStreaming(
                                actionId: UUID().uuidString,
                                remotePath: item.path,
                                targetURL: targetURL,
                                totalSize: stat.size
                            ) { _ in }
                            downloadedURLs.append(targetURL)
                        }
                    }
                    
                    self.statusMessage = "Готово к отправке: \(itemNames)"
                    self.executeShare(urls: downloadedURLs, target: target, sourceView: sourceView, rect: rect)
                } catch {
                    self.errorMessage = "Ошибка подготовки файлов для отправки: \(error.localizedDescription)"
                    self.showErrorAlert = true
                    self.statusMessage = "Ошибка отправки"
                }
            }
        }
    }
    
    private func executeShare(
        urls: [URL],
        target: ShareTarget,
        sourceView: NSView?,
        rect: NSRect
    ) {
        guard !urls.isEmpty else { return }
        let anchorView = sourceView ?? NSApp.keyWindow?.contentView
        let anchorRect = rect.isEmpty ? (anchorView?.bounds ?? .zero) : rect
        
        switch target {
        case .telegram:
            let services = NSSharingService.sharingServices(forItems: urls)
            if let service = services.first(where: {
                $0.title.localizedCaseInsensitiveContains("telegram") ||
                $0.description.localizedCaseInsensitiveContains("telegram")
            }) {
                service.perform(withItems: urls)
                statusMessage = "Отправка через Telegram..."
                return
            }
            
            if let tgURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tdesktop.Telegram") ??
                           NSWorkspace.shared.urlForApplication(withBundleIdentifier: "ru.keepcoder.Telegram") {
                NSWorkspace.shared.open(urls, withApplicationAt: tgURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    DispatchQueue.main.async {
                        if let error = error {
                            self.statusMessage = "Не удалось открыть Telegram: \(error.localizedDescription)"
                        } else {
                            self.statusMessage = "Файлы переданы в Telegram"
                        }
                    }
                }
                return
            }
            
            statusMessage = "Telegram не найден. Открытие меню «Поделиться»..."
            showSharingPicker(urls: urls, sourceView: anchorView, rect: anchorRect)
            
        case .whatsapp:
            let services = NSSharingService.sharingServices(forItems: urls)
            if let service = services.first(where: {
                $0.title.localizedCaseInsensitiveContains("whatsapp") ||
                $0.description.localizedCaseInsensitiveContains("whatsapp")
            }) {
                service.perform(withItems: urls)
                statusMessage = "Отправка через WhatsApp..."
                return
            }
            
            if let waURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp") ??
                           NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp.desktop") {
                NSWorkspace.shared.open(urls, withApplicationAt: waURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    DispatchQueue.main.async {
                        if let error = error {
                            self.statusMessage = "Не удалось открыть WhatsApp: \(error.localizedDescription)"
                        } else {
                            self.statusMessage = "Файлы переданы в WhatsApp"
                        }
                    }
                }
                return
            }
            
            statusMessage = "WhatsApp не найден. Открытие меню «Поделиться»..."
            showSharingPicker(urls: urls, sourceView: anchorView, rect: anchorRect)
            
        case .gmail:
            if let emailService = NSSharingService(named: .composeEmail), emailService.canPerform(withItems: urls) {
                emailService.perform(withItems: urls)
                statusMessage = "Создание почтового сообщения..."
                return
            }
            
            let services = NSSharingService.sharingServices(forItems: urls)
            if let service = services.first(where: {
                $0.title.localizedCaseInsensitiveContains("mail") ||
                $0.title.localizedCaseInsensitiveContains("gmail")
            }) {
                service.perform(withItems: urls)
                statusMessage = "Создание письма..."
                return
            }
            
            showSharingPicker(urls: urls, sourceView: anchorView, rect: anchorRect)
        }
    }
    
    public func showSharingPicker(urls: [URL], sourceView: NSView?, rect: NSRect) {
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        if let view = sourceView ?? NSApp.keyWindow?.contentView {
            let r = rect.isEmpty ? NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1) : rect
            picker.show(relativeTo: r, of: view, preferredEdge: .minY)
        }
    }
    
    public func triggerBatchRename(item: FileItem? = nil, side: PaneSide? = nil) {
        let targetSide: PaneSide
        if let explicitSide = side {
            targetSide = explicitSide
        } else {
            // 1. Проверяем, какой NSTableView сейчас в фокусе (firstResponder)
            let leftTv = TableDoubleClickHandler.HandlerView.leftTableView
            let rightTv = TableDoubleClickHandler.HandlerView.rightTableView
            
            let isLeftFocused: Bool
            let isRightFocused: Bool
            if let window = leftTv?.window ?? rightTv?.window, let firstResponder = window.firstResponder {
                isLeftFocused = (leftTv != nil && (firstResponder === leftTv || (firstResponder as? NSView)?.isDescendant(of: leftTv!) == true))
                isRightFocused = (rightTv != nil && (firstResponder === rightTv || (firstResponder as? NSView)?.isDescendant(of: rightTv!) == true))
            } else {
                isLeftFocused = false
                isRightFocused = false
            }
            
            if isRightFocused && !isLeftFocused {
                targetSide = .right
            } else if isLeftFocused && !isRightFocused {
                targetSide = .left
            } else {
                // Если шорткат вызван глобально или нажата кнопка тулбара,
                // целевой стороной ВСЕГДА является текущая активная панель (activePane)
                targetSide = activePane
            }
        }
        
        if activePane != targetSide {
            activePane = targetSide
        }
        
        let allItems = (targetSide == .left) ? leftItems : rightItems
        let displayList = displayItems(for: targetSide)
        let sourceList = (displayList.isEmpty ? allItems : displayList).filter { $0.name != ".." }
        let selection = (targetSide == .left) ? leftSelection : rightSelection
        let targetTv = (targetSide == .left) ? TableDoubleClickHandler.HandlerView.leftTableView : TableDoubleClickHandler.HandlerView.rightTableView
        
        var targets: [FileItem] = []
        if let item = item {
            if selection.contains(item.id) || selection.contains(item.path) {
                targets = sourceList.filter { selection.contains($0.id) || selection.contains($0.path) }
            } else {
                targets = [item]
            }
        } else if !selection.isEmpty {
            targets = sourceList.filter { selection.contains($0.id) || selection.contains($0.path) }
        } else if let tv = targetTv, tv.selectedRowIndexes.count > 0 {
            let rowIndexes = tv.selectedRowIndexes
            targets = rowIndexes.compactMap { idx in
                (idx >= 0 && idx < sourceList.count) ? sourceList[idx] : nil
            }
        } else {
            // В стиле Total Commander: если ничего не выделено, переименовываются ВСЕ файлы активной панели
            targets = sourceList
        }
        
        self.batchRenameSide = targetSide
        
        guard !targets.isEmpty else {
            statusMessage = "В выбранной панели нет файлов для переименования"
            return
        }
        
        let session = BatchRenameSession(side: targetSide, items: targets)
        self.batchRenameItems = targets
        self.batchRenameSession = session
        self.showBatchRenameDialog = true
    }
    
    public func applyBatchRename(mappings: [(oldItem: FileItem, newName: String)], side: PaneSide? = nil) {
        let targetSide = side ?? batchRenameSide
        let source = (targetSide == .left) ? leftSource : rightSource
        let driver: FileSystemDriver = (source == .localMac) ? localDriver : remoteDriver
        
        // Меняются только реально изменённые имена
        let changes = mappings.filter { $0.oldItem.name != $0.newName }
        guard !changes.isEmpty else { return }
        
        Task {
            // 1. Актуальный листинг каталогов: модальное окно могло быть открыто на устаревшем списке (D8)
            var namesByDir: [String: Set<String>] = [:]
            do {
                for change in changes {
                    let dir = (change.oldItem.path as NSString).deletingLastPathComponent
                    if namesByDir[dir] == nil {
                        let listing: [FileItem]
                        if source == .localMac {
                            listing = try await self.localDriver.listDirectory(at: dir)
                        } else {
                            listing = try await self.remoteDriver.listDirectory(at: dir, forceRefresh: true)
                        }
                        namesByDir[dir] = Set(listing.map { $0.name })
                    }
                }
            } catch {
                self.errorMessage = "Переименование отменено: не удалось прочитать папку (\(error.localizedDescription))"
                self.showErrorAlert = true
                return
            }
            
            // 2. Конфликты: цель занята объектом, который не переименовывается в этой же операции, либо две цели совпадают
            let vacatedPaths = Set(changes.map { $0.oldItem.path })
            var seenTargets = Set<String>()
            var conflictNames: [String] = []
            for change in changes {
                let dir = (change.oldItem.path as NSString).deletingLastPathComponent
                let targetPath = (dir as NSString).appendingPathComponent(change.newName).precomposedStringWithCanonicalMapping
                let occupied = (namesByDir[dir] ?? []).contains(change.newName) && !vacatedPaths.contains(targetPath)
                if occupied || !seenTargets.insert(targetPath).inserted {
                    conflictNames.append(change.newName)
                }
            }
            guard conflictNames.isEmpty else {
                self.errorMessage = "Переименование отменено: конфликт имён (\(conflictNames.prefix(5).joined(separator: ", ")))"
                self.showErrorAlert = true
                return
            }
            
            // 3. Двухфазное переименование: сначала во временные имена, затем в целевые.
            // Так цепочки (A→B, B→C) и циклы (A→B, B→A) выполняются без затирания друг друга.
            let token = UUID().uuidString.prefix(8)
            let steps: [(oldPath: String, tempPath: String, finalPath: String)] = changes.enumerated().map { index, change in
                let dir = (change.oldItem.path as NSString).deletingLastPathComponent
                let tempPath = (dir as NSString).appendingPathComponent(".mcd_rename_\(token)_\(index).tmp")
                let finalPath = (dir as NSString).appendingPathComponent(change.newName).precomposedStringWithCanonicalMapping
                return (change.oldItem.path, tempPath, finalPath)
            }
            
            // История хранит ВСЕ фактически выполненные переименования по порядку: отмена идёт в обратном порядке.
            var history: [(oldPath: String, newPath: String)] = []
            
            // Фаза 1: старое имя → временное
            var phase1Done: [(oldPath: String, tempPath: String)] = []
            do {
                for step in steps {
                    try await driver.renameItem(from: step.oldPath, to: step.tempPath)
                    phase1Done.append((step.oldPath, step.tempPath))
                    history.append((step.oldPath, step.tempPath))
                }
            } catch {
                // Откат уже выполненной части фазы 1: операция не должна оставить скрытые временные файлы
                for pair in phase1Done.reversed() {
                    try? await driver.renameItem(from: pair.tempPath, to: pair.oldPath)
                }
                self.errorMessage = "Переименование отменено: \(error.localizedDescription)"
                self.showErrorAlert = true
                self.refreshPane(side: targetSide)
                return
            }
            
            // Фаза 2: временное имя → целевое имя
            var renamedCount = 0
            var failures: [String] = []
            for step in steps {
                do {
                    try await driver.renameItem(from: step.tempPath, to: step.finalPath)
                    history.append((step.tempPath, step.finalPath))
                    renamedCount += 1
                } catch {
                    failures.append("\(URL(fileURLWithPath: step.oldPath).lastPathComponent): \(error.localizedDescription)")
                    // Возвращаем объект под исходное имя, чтобы не оставлять скрытый временный файл
                    if (try? await driver.renameItem(from: step.tempPath, to: step.oldPath)) != nil {
                        history.removeAll { $0.oldPath == step.oldPath && $0.newPath == step.tempPath }
                    }
                }
            }
            
            if !history.isEmpty {
                self.lastBatchRenameHistory = history
                self.lastBatchRenameSide = targetSide
                self.canUndoBatchRename = true
            }
            self.refreshPane(side: targetSide)
            if failures.isEmpty {
                self.statusMessage = "Успешно переименовано объектов: \(renamedCount)"
            } else {
                self.statusMessage = "Переименовано: \(renamedCount), ошибок: \(failures.count)"
                self.errorMessage = "Не переименовано:\n" + failures.prefix(10).joined(separator: "\n")
                self.showErrorAlert = true
            }
        }
    }
    
    public func undoBatchRename() {
        guard !lastBatchRenameHistory.isEmpty else { return }
        let side = lastBatchRenameSide
        let source = (side == .left) ? leftSource : rightSource
        let driver: FileSystemDriver = (source == .localMac) ? localDriver : remoteDriver
        
        let history = lastBatchRenameHistory
        Task {
            var restoredCount = 0
            for pair in history.reversed() {
                do {
                    try await driver.renameItem(from: pair.newPath, to: pair.oldPath)
                    restoredCount += 1
                } catch {
                    print("Undo rename error: \(error)")
                }
            }
            self.lastBatchRenameHistory.removeAll()
            self.canUndoBatchRename = false
            self.refreshPane(side: side)
            self.statusMessage = "Откат переименования завершен: восстановлено \(restoredCount) файлов"
        }
    }
    
    // MARK: - Создание архивов (ZIP, TAR, TAR.GZ)
    
    public func triggerCreateArchive(item: FileItem? = nil, side: PaneSide? = nil) {
        let currentSide = side ?? activePane
        let items = (currentSide == .left) ? leftItems : rightItems
        let selection = (currentSide == .left) ? leftSelection : rightSelection
        let currentPath = (currentSide == .left) ? leftPath : rightPath
        
        var targets: [FileItem] = []
        if let item = item {
            if selection.contains(item.id) || selection.contains(item.path) {
                targets = items.filter { selection.contains($0.id) || selection.contains($0.path) }
            } else {
                targets = [item]
            }
        } else if !selection.isEmpty {
            targets = items.filter { selection.contains($0.id) || selection.contains($0.path) }
        } else if let first = items.first {
            targets = [first]
        }
        
        guard !targets.isEmpty else {
            statusMessage = "Нет выбранных файлов для архивирования"
            return
        }
        
        self.archiveTargetItems = targets
        self.archiveFormat = .zip
        self.archiveDestinationPath = currentPath
        
        let base: String
        if targets.count == 1 {
            base = URL(fileURLWithPath: targets[0].path).deletingPathExtension().lastPathComponent
        } else {
            let dirName = URL(fileURLWithPath: currentPath).lastPathComponent
            base = dirName.isEmpty ? "Archive" : dirName
        }
        
        self.archiveName = generateUniqueArchiveName(baseName: base, extension: "zip", destinationPath: currentPath)
        
        self.showCreateArchiveDialog = true
    }
    
    /// Генерирует уникальное имя для архива, добавляя счетчик (1), (2)... при наличии файла с таким же именем
    public func generateUniqueArchiveName(baseName: String, extension ext: String, destinationPath: String) -> String {
        let cleanExt = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        let side = (destinationPath == leftPath) ? PaneSide.left : (destinationPath == rightPath ? PaneSide.right : activePane)
        let items = (side == .left) ? leftItems : rightItems
        
        // Очищаем базовое имя от предыдущего счетчика " (1)", если он был добавлен ранее
        var cleanBase = baseName
        if let regex = try? NSRegularExpression(pattern: #"^(.*?)\s*\(\d+\)$"#, options: []),
           let match = regex.firstMatch(in: baseName, range: NSRange(baseName.startIndex..., in: baseName)),
           let baseRange = Range(match.range(at: 1), in: baseName) {
            cleanBase = String(baseName[baseRange])
        }
        
        let fileExists: (String) -> Bool = { filename in
            if items.contains(where: { $0.name.lowercased() == filename.lowercased() }) {
                return true
            }
            let fullPath = URL(fileURLWithPath: destinationPath).appendingPathComponent(filename).path
            return FileManager.default.fileExists(atPath: fullPath)
        }
        
        let initial = "\(cleanBase).\(cleanExt)"
        guard fileExists(initial) else {
            return initial
        }
        
        var counter = 1
        while true {
            let candidate = "\(cleanBase) (\(counter)).\(cleanExt)"
            if !fileExists(candidate) {
                return candidate
            }
            counter += 1
        }
    }
    
    /// Назначение архива на телефоне (по пути), иначе Mac
    private var archiveDestinationIsPhone: Bool {
        archiveDestinationPath.hasPrefix("/sdcard") || archiveDestinationPath.hasPrefix("/storage")
    }
    
    /// Причина, по которой архив нельзя создать с текущим именем (nil — можно). Используется диалогом.
    public func archiveDestinationProblem() -> String? {
        let trimmedName = archiveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !archiveDestinationIsPhone else { return nil }
        let destFull = URL(fileURLWithPath: archiveDestinationPath).appendingPathComponent(trimmedName).path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: destFull, isDirectory: &isDir), isDir.boolValue {
            return "По этому имени уже есть папка"
        }
        if archiveTargetItems.contains(where: { ($0.path as NSString).standardizingPath == destFull }) {
            return "Архив не может совпадать с архивируемым объектом"
        }
        return nil
    }
    
    public func confirmCreateArchive() {
        guard !archiveTargetItems.isEmpty else { return }
        let trimmedName = archiveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        // D10: отказ, если цель — папка или совпадает с архивируемым объектом (до запуска работы)
        if let problem = archiveDestinationProblem() {
            errorMessage = "Архив не создан: \(problem)"
            showErrorAlert = true
            return
        }
        
        let format = archiveFormat
        let targetItems = archiveTargetItems
        let destPath = archiveDestinationPath
        let destIsPhone = archiveDestinationIsPhone
        let destFullURL = URL(fileURLWithPath: destPath).appendingPathComponent(trimmedName)
        let activeSide = activePane
        let source = (activeSide == .left) ? leftSource : rightSource
        
        isArchiving = true
        statusMessage = "Создание архива: \(trimmedName)..."
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Архив всегда собирается во временной папке; в место назначения попадает только готовый результат
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacDroidArchive_\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: workDir) }
                let tempArchiveURL = workDir.appendingPathComponent(trimmedName)
                
                if source == .localMac {
                    try await ArchiveService.shared.createArchive(
                        sources: targetItems.map { $0.path },
                        destinationPath: tempArchiveURL.path,
                        format: format
                    )
                } else {
                    // Телефон (Remote SFTP): скачиваем во временный каталог, архивируем
                    let downloadDir = workDir.appendingPathComponent("src", isDirectory: true)
                    try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
                    var downloadedPaths: [String] = []
                    for item in targetItems {
                        let localDest = downloadDir.appendingPathComponent(item.name)
                        let stat = try await self.transport.prepareRead(actionId: UUID().uuidString, path: item.path)
                        try await self.transport.downloadFileStreaming(
                            actionId: UUID().uuidString,
                            remotePath: item.path,
                            targetURL: localDest,
                            totalSize: stat.size
                        ) { _ in }
                        downloadedPaths.append(localDest.path)
                    }
                    try await ArchiveService.shared.createArchive(
                        sources: downloadedPaths,
                        destinationPath: tempArchiveURL.path,
                        format: format
                    )
                }
                
                if destIsPhone {
                    // Загрузка на телефон через оркестратор (очередь без исполнителя больше не используется, D12).
                    // Существующий файл не перезаписываем.
                    let result = try await self.orchestrator.executeCopyMacToPhone(
                        jobId: UUID().uuidString,
                        itemId: UUID().uuidString,
                        localSourceURL: tempArchiveURL,
                        remoteTargetDir: destPath,
                        strategy: .skip,
                        progress: { _ in }
                    )
                    if case .skipped(let reason) = result {
                        throw FileOperationNameError.nameTaken(name: "\(trimmedName) (\(reason))")
                    }
                } else {
                    // Существующий файл заменяем атомарно, и только после успешного создания архива
                    if FileManager.default.fileExists(atPath: destFullURL.path) {
                        _ = try FileManager.default.replaceItemAt(destFullURL, withItemAt: tempArchiveURL)
                    } else {
                        try FileManager.default.moveItem(at: tempArchiveURL, to: destFullURL)
                    }
                }
                
                self.isArchiving = false
                self.refreshPane(side: .left)
                self.refreshPane(side: .right)
                self.statusMessage = "Архив успешно создан: \(trimmedName)"
            } catch {
                self.isArchiving = false
                self.statusMessage = "Ошибка создания архива: \(error.localizedDescription)"
                self.errorMessage = error.localizedDescription
                self.showErrorAlert = true
            }
        }
    }
    
    // MARK: - Разархивирование (Unarchive / Extract)
    
    public func isArchive(item: FileItem) -> Bool {
        return ArchiveService.isArchive(fileName: item.name)
    }
    
    /// Загрузка распакованного дерева на телефон через оркестратор. Существующие файлы не перезаписываются
    /// (считаются пропущенными), сетевые и прочие ошибки пробрасываются.
    private func uploadExtractedTreeToPhone(localDir: URL, remoteDir: String) async throws -> (uploaded: Int, skipped: Int) {
        // Папка может уже существовать: ошибку создания не считаем фатальной, загрузка сама покажет проблему
        _ = try? await remoteDriver.createDirectory(at: remoteDir)
        var uploaded = 0
        var skipped = 0
        let entries = (try? FileManager.default.contentsOfDirectory(at: localDir, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let sub = try await uploadExtractedTreeToPhone(
                    localDir: entry,
                    remoteDir: (remoteDir as NSString).appendingPathComponent(entry.lastPathComponent)
                )
                uploaded += sub.uploaded
                skipped += sub.skipped
            } else {
                let result = try await orchestrator.executeCopyMacToPhone(
                    jobId: UUID().uuidString,
                    itemId: UUID().uuidString,
                    localSourceURL: entry,
                    remoteTargetDir: remoteDir,
                    strategy: .skip,
                    progress: { _ in }
                )
                switch result {
                case .skipped:
                    skipped += 1
                case .transferred, .transferredWithoutSourceDeletion:
                    uploaded += 1
                }
            }
        }
        return (uploaded, skipped)
    }
    
    public func unarchive(item: FileItem? = nil, side: PaneSide? = nil, to destinationDir: String? = nil) {
        let currentSide = side ?? activePane
        let items = (currentSide == .left) ? leftItems : rightItems
        let selection = (currentSide == .left) ? leftSelection : rightSelection
        let currentPath = (currentSide == .left) ? leftPath : rightPath
        let source = (currentSide == .left) ? leftSource : rightSource
        
        let targetItem: FileItem?
        if let item = item {
            targetItem = item
        } else if let first = selection.first, let found = items.first(where: { $0.id == first || $0.path == first }) {
            targetItem = found
        } else {
            targetItem = items.first(where: { ArchiveService.isArchive(fileName: $0.name) })
        }
        
        guard let archiveItem = targetItem else {
            statusMessage = "Нет выбранного архива для распаковки"
            return
        }
        
        let targetDir = destinationDir ?? currentPath
        let isDestRemote = (targetDir.hasPrefix("/sdcard") || targetDir.hasPrefix("/storage"))
        
        var archiveBaseName = URL(fileURLWithPath: archiveItem.name).deletingPathExtension().lastPathComponent
        if archiveBaseName.hasSuffix(".tar") {
            archiveBaseName = String(archiveBaseName.dropLast(4))
        }
        let extractFolder = archiveBaseName.isEmpty ? "Extracted" : archiveBaseName
        let destinationPath = URL(fileURLWithPath: targetDir).appendingPathComponent(extractFolder).path
        
        isArchiving = true
        statusMessage = "Разархивирование: \(archiveItem.name)..."
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                if source == .localMac && !isDestRemote {
                    // Полностью локальная распаковка на Mac
                    try await ArchiveService.shared.extractArchive(
                        archivePath: archiveItem.path,
                        destinationPath: destinationPath
                    )
                } else if source == .localMac && isDestRemote {
                    // Локальный архив на Mac -> распаковка во временную папку -> заливка на телефон
                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("MacDroidExtract_\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    
                    let tempExtractDir = tempDir.appendingPathComponent(extractFolder)
                    try await ArchiveService.shared.extractArchive(
                        archivePath: archiveItem.path,
                        destinationPath: tempExtractDir.path
                    )
                    
                    // D12: распакованное дерево загружается на телефон через оркестратор до удаления временной папки
                    let upload = try await self.uploadExtractedTreeToPhone(localDir: tempExtractDir, remoteDir: destinationPath)
                    if upload.skipped > 0 {
                        self.errorMessage = "На телефоне уже есть файлы с такими именами, пропущено: \(upload.skipped)"
                        self.showErrorAlert = true
                    }
                    try? FileManager.default.removeItem(at: tempDir)
                } else {
                    // Удаленный архив на телефоне
                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("MacDroidExtract_\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    
                    let localArchiveURL = tempDir.appendingPathComponent(archiveItem.name)
                    let stat = try await self.transport.prepareRead(actionId: UUID().uuidString, path: archiveItem.path)
                    try await self.transport.downloadFileStreaming(
                        actionId: UUID().uuidString,
                        remotePath: archiveItem.path,
                        targetURL: localArchiveURL,
                        totalSize: stat.size
                    ) { _ in }
                    
                    if !isDestRemote {
                        // Распаковываем на Mac в destinationPath
                        try await ArchiveService.shared.extractArchive(
                            archivePath: localArchiveURL.path,
                            destinationPath: destinationPath
                        )
                    } else {
                        // Распаковываем локально и заливаем на телефон
                        let tempExtractDir = tempDir.appendingPathComponent(extractFolder)
                        try await ArchiveService.shared.extractArchive(
                            archivePath: localArchiveURL.path,
                            destinationPath: tempExtractDir.path
                        )
                        
                        // D12: распакованное дерево загружается на телефон через оркестратор до удаления временной папки
                        let upload = try await self.uploadExtractedTreeToPhone(localDir: tempExtractDir, remoteDir: destinationPath)
                        if upload.skipped > 0 {
                            self.errorMessage = "На телефоне уже есть файлы с такими именами, пропущено: \(upload.skipped)"
                            self.showErrorAlert = true
                        }
                    }
                    
                    try? FileManager.default.removeItem(at: tempDir)
                }
                
                self.isArchiving = false
                let destSide: PaneSide
                if let dest = destinationDir {
                    destSide = (dest == self.leftPath) ? .left : ((dest == self.rightPath) ? .right : currentSide)
                } else {
                    destSide = currentSide
                }
                let otherSide: PaneSide = (destSide == .left) ? .right : .left
                self.refreshPane(side: otherSide)
                self.refreshPane(side: destSide, selectPath: destinationPath)
                self.statusMessage = "Архив успешно разархивирован: \(archiveItem.name)"
            } catch {
                self.isArchiving = false
                self.statusMessage = "Ошибка разархивирования: \(error.localizedDescription)"
                self.errorMessage = error.localizedDescription
                self.showErrorAlert = true
            }
        }
    }
    
    // MARK: - Быстрый просмотр (Quick Look)
    
    public func triggerQuickLook(preferNativeQuickLook: Bool = false) {
        // Если окно Quick Look уже открыто — закрываем его (toggle по Пробелу, как в Finder)
        if QuickLookBridge.shared.isVisible {
            QuickLookBridge.shared.close()
            return
        }
        
        let side = activePane
        let selected = (side == .left) ? leftSelection : rightSelection
        let source = (side == .left) ? leftSource : rightSource
        let currentItems = (side == .left) ? leftItems : rightItems
        
        let selectedItems = currentItems.filter { selected.contains($0.id) || selected.contains($0.path) }
        let selectedFolders = selectedItems.filter { $0.isDirectory }
        
        if !selectedFolders.isEmpty {
            for folder in selectedFolders {
                calculateFolderSize(for: folder, side: side)
            }
            if selectedFolders.count == 1, let firstFolder = selectedFolders.first {
                statusMessage = "Папка: \(firstFolder.name)"
            } else {
                statusMessage = "Подсчет размера для \(selectedFolders.count) папок..."
            }
            return
        }
        
        guard let first = selected.first,
              let item = currentItems.first(where: { $0.id == first || $0.path == first }) ?? currentItems.first(where: { selected.contains($0.id) || selected.contains($0.path) }) else {
            return
        }
        
        if item.isDirectory {
            statusMessage = "Папка: \(item.name)"
            calculateFolderSize(for: item, side: side)
            return
        }
        
        let photoExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "dng", "webp", "gif", "bmp", "tiff"]
        let ext = URL(fileURLWithPath: item.name).pathExtension.lowercased()
        
        // Встроенный просмотрщик для фотографий (только для удалённых файлов телефона, если явно не запрошен нативный Quick Look и панель Quick Look ещё не открыта)
        if photoExtensions.contains(ext) && !preferNativeQuickLook && source == .remotePhone && !QuickLookBridge.shared.isVisible {
            let photoItems = currentItems.filter {
                let e = URL(fileURLWithPath: $0.name).pathExtension.lowercased()
                return photoExtensions.contains(e)
            }
            if let idx = photoItems.firstIndex(where: { $0.id == item.id || $0.path == item.path }) {
                self.viewerImages = photoItems
                self.viewerStartIndex = idx
                self.showImageViewer = true
                self.statusMessage = "Просмотр фото: \(item.name)"
                return
            }
        }
        
        // Системный Quick Look для Mac
        if source == .localMac {
            let localURL = URL(fileURLWithPath: item.path)
            self.statusMessage = "Просмотр: \(item.name)"
            QuickLookBridge.shared.preview(url: localURL)
            return
        }
        
        // Системный Quick Look для удалённого Android
        if let cachedURL = QuickLookCacheManager.shared.isCached(for: item) {
            self.statusMessage = "Просмотр: \(item.name)"
            QuickLookBridge.shared.preview(url: cachedURL)
            return
        }
        
        currentPreviewTask?.cancel()
        statusMessage = "Загрузка для просмотра: \(item.name) (0%)..."
        
        currentPreviewTask = Task { @MainActor in
            do {
                let targetURL = try await QuickLookCacheManager.shared.fetchFile(item: item, transport: self.transport) { [weak self] (progress: Double) in
                    Task { @MainActor in
                        guard let self = self else { return }
                        let percent = Int(progress * 100)
                        self.statusMessage = "Загрузка для просмотра: \(item.name) (\(percent)%)..."
                    }
                }
                guard !Task.isCancelled else { return }
                self.statusMessage = "Просмотр: \(item.name)"
                QuickLookBridge.shared.preview(url: targetURL)
            } catch is CancellationError {
                self.statusMessage = "Загрузка отменена"
            } catch {
                self.statusMessage = "Ошибка загрузки: \(error.localizedDescription)"
            }
        }
    }
    
    // MARK: - Quick Look Dynamic Selection Synchronization (Finder-like)
    
    private func onSelectionChanged(for side: PaneSide) {
        if side == activePane {
            updateQuickLookIfVisible()
        }
        calculateSelectedFolderSizes(for: side)
        if isFileDiffActive {
            scheduleCompareStateRecompute()
        }
    }
    
    public func updateQuickLookIfVisible() {
        guard QuickLookBridge.shared.isVisible else { return }
        
        let side = activePane
        let selected = (side == .left) ? leftSelection : rightSelection
        let source = (side == .left) ? leftSource : rightSource
        let currentItems = (side == .left) ? leftItems : rightItems
        
        guard let first = selected.first,
              let item = currentItems.first(where: { $0.id == first || $0.path == first }) ?? currentItems.first(where: { selected.contains($0.id) || selected.contains($0.path) }) else {
            return
        }
        
        if item.isDirectory {
            if source == .localMac {
                let localURL = URL(fileURLWithPath: item.path)
                self.statusMessage = "Просмотр папки: \(item.name)"
                QuickLookBridge.shared.updatePreview(url: localURL)
            } else {
                self.statusMessage = "Папка: \(item.name)"
            }
            return
        }
        
        if source == .localMac {
            let localURL = URL(fileURLWithPath: item.path)
            self.statusMessage = "Просмотр: \(item.name)"
            QuickLookBridge.shared.updatePreview(url: localURL)
            return
        }
        
        // Удаленный файл (Android)
        if let cachedURL = QuickLookCacheManager.shared.isCached(for: item) {
            self.statusMessage = "Просмотр: \(item.name)"
            QuickLookBridge.shared.updatePreview(url: cachedURL)
            return
        }
        
        currentPreviewTask?.cancel()
        statusMessage = "Загрузка для просмотра: \(item.name) (0%)..."
        
        currentPreviewTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let targetURL = try await QuickLookCacheManager.shared.fetchFile(item: item, transport: self.transport) { [weak self] (progress: Double) in
                    Task { @MainActor in
                        guard let self = self else { return }
                        let percent = Int(progress * 100)
                        self.statusMessage = "Загрузка для просмотра: \(item.name) (\(percent)%)..."
                    }
                }
                guard !Task.isCancelled else { return }
                guard QuickLookBridge.shared.isVisible else { return }
                let currentSide = self.activePane
                let currSel = (currentSide == .left) ? self.leftSelection : self.rightSelection
                guard currSel.contains(item.id) || currSel.contains(item.path) else { return }
                
                self.statusMessage = "Просмотр: \(item.name)"
                QuickLookBridge.shared.updatePreview(url: targetURL)
            } catch is CancellationError {
                // Ignore fast navigation
            } catch {
                self.statusMessage = "Ошибка загрузки: \(error.localizedDescription)"
            }
        }
    }
    
    public func selectNext() {
        moveSelection(by: 1)
    }
    
    public func selectPrevious() {
        moveSelection(by: -1)
    }
    
    /// Перемещение курсора в порядке отображения (сортировка/фильтр), как видит пользователь.
    /// Используется стрелками в окне Quick Look: таблица прокручивается к новому элементу.
    private func moveSelection(by offset: Int) {
        let side = activePane
        let items = displayItems(for: side)
        guard !items.isEmpty else { return }
        let selected = (side == .left) ? leftSelection : rightSelection
        
        let targetIndex: Int
        if let first = selected.first, let idx = items.firstIndex(where: { $0.id == first || $0.path == first }) {
            targetIndex = max(0, min(items.count - 1, idx + offset))
        } else {
            targetIndex = offset >= 0 ? 0 : items.count - 1
        }
        
        let target = items[targetIndex]
        if side == .left {
            leftSelection = [target.id]
        } else {
            rightSelection = [target.id]
        }
        TableDoubleClickHandler.HandlerView.scrollToItem(id: target.id, side: side)
    }
    
    // MARK: - Folder Size Calculation (Space Key & Selection)
    public func selectedBytes(for side: PaneSide) -> UInt64 {
        let selection = (side == .left) ? leftSelection : rightSelection
        guard !selection.isEmpty else { return 0 }
        let items = (side == .left) ? leftItems : rightItems
        let selectedItems = items.filter { selection.contains($0.id) || selection.contains($0.path) }
        return selectedItems.reduce(0) { sum, item in
            if item.isDirectory {
                return sum + (calculatedFolderSizes[item.path] ?? 0)
            } else {
                return sum + item.size
            }
        }
    }
    
    public func isCalculatingSelectedFolderSizes(for side: PaneSide) -> Bool {
        let selection = (side == .left) ? leftSelection : rightSelection
        guard !selection.isEmpty else { return false }
        let items = (side == .left) ? leftItems : rightItems
        let selectedItems = items.filter { selection.contains($0.id) || selection.contains($0.path) }
        return selectedItems.contains { item in
            item.isDirectory && (calculatingFolderPaths.contains(item.path) || calculatedFolderSizes[item.path] == nil)
        }
    }
    
    public func calculateSelectedFolderSizes(for side: PaneSide) {
        selectionCalculationTasks[side]?.cancel()
        selectionCalculationTasks[side] = nil
        
        let selection = (side == .left) ? leftSelection : rightSelection
        guard !selection.isEmpty else { return }
        
        let items = (side == .left) ? leftItems : rightItems
        let source = (side == .left) ? leftSource : rightSource
        
        let selectedFolders = items.filter { item in
            item.isDirectory && (selection.contains(item.id) || selection.contains(item.path))
        }
        
        let uncalculated = selectedFolders.filter {
            calculatedFolderSizes[$0.path] == nil && !calculatingFolderPaths.contains($0.path)
        }
        
        guard !uncalculated.isEmpty else { return }
        
        selectionCalculationTasks[side] = Task { @MainActor in
            for folder in uncalculated {
                guard !Task.isCancelled else { break }
                let curSel = (side == .left) ? self.leftSelection : self.rightSelection
                guard curSel.contains(folder.id) || curSel.contains(folder.path) else { continue }
                
                let path = folder.path
                self.calculatingFolderPaths.insert(path)
                
                let size: UInt64
                if source == .localMac || folder.source == .localMac {
                    size = await self.calculateFolderSizeLocal(at: path)
                } else {
                    size = await self.calculateFolderSizeRemote(at: path)
                }
                
                self.calculatingFolderPaths.remove(path)
                if !Task.isCancelled {
                    self.calculatedFolderSizes[path] = size
                }
            }
            if Task.isCancelled {
                for folder in uncalculated {
                    self.calculatingFolderPaths.remove(folder.path)
                }
            }
        }
    }

    public func calculateFolderSize(for item: FileItem, side: PaneSide, updateStatusMessage: Bool = true) {
        guard item.isDirectory else { return }
        
        let path = item.path
        let source = (side == .left) ? leftSource : rightSource
        
        guard !calculatingFolderPaths.contains(path) else { return }
        calculatingFolderPaths.insert(path)
        
        Task { @MainActor in
            let size: UInt64
            if source == .localMac || item.source == .localMac {
                size = await calculateFolderSizeLocal(at: path)
            } else {
                size = await calculateFolderSizeRemote(at: path)
            }
            
            self.calculatingFolderPaths.remove(path)
            self.calculatedFolderSizes[path] = size
            if updateStatusMessage {
                self.statusMessage = "Папка '\(item.name)': \(self.formatBytes(size))"
            }
        }
    }
    
    private func calculateFolderSizeLocal(at path: String) async -> UInt64 {
        await Task.detached {
            let fileManager = FileManager.default
            let url = URL(fileURLWithPath: path)
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey, .totalFileSizeKey],
                options: [] // Включаем все скрытые файлы и все уровни вложенных поддиректорий
            ) else { return 0 }
            
            var totalSize: UInt64 = 0
            while let fileURL = enumerator.nextObject() as? URL {
                guard !Task.isCancelled else { return totalSize }
                guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey, .totalFileSizeKey]) else {
                    if let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
                       let type = attrs[.type] as? FileAttributeType,
                       type == .typeRegular,
                       let size = attrs[.size] as? UInt64 {
                        totalSize += size
                    }
                    continue
                }
                
                // Пропускаем сами каталоги (их содержимое рекурсивно обходится enumerator на любую глубину)
                if let isDirectory = resourceValues.isDirectory, isDirectory {
                    continue
                }
                
                // Символические ссылки на каталоги пропускаем во избежание бесконечных циклов
                if let isSym = resourceValues.isSymbolicLink, isSym {
                    var isDir: ObjCBool = false
                    if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
                        continue
                    }
                }
                
                if let fileSize = resourceValues.fileSize ?? resourceValues.totalFileSize {
                    totalSize += UInt64(fileSize)
                } else if let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
                          let size = attrs[.size] as? UInt64 {
                    totalSize += size
                }
            }
            return totalSize
        }.value
    }
    
    private func calculateFolderSizeRemote(at path: String) async -> UInt64 {
        // Рекурсивный обход директории и всех подпапок любого уровня вложенности (работает через SFTP и ADB fallback)
        var totalSize: UInt64 = 0
        var queue: [String] = [path]
        var visited = Set<String>()
        visited.insert(path.precomposedStringWithCanonicalMapping)
        
        while !queue.isEmpty {
            guard !Task.isCancelled else { return totalSize }
            let currentDir = queue.removeFirst()
            
            do {
                let items = try await remoteDriver.listDirectory(at: currentDir)
                for item in items {
                    if item.isDirectory {
                        let normalizedChild = item.path.precomposedStringWithCanonicalMapping
                        if !visited.contains(normalizedChild) {
                            visited.insert(normalizedChild)
                            queue.append(item.path)
                        }
                    } else {
                        totalSize += item.size
                    }
                }
            } catch {
                continue
            }
        }
        
        return totalSize
    }
    
    public func formatBytes(_ b: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(b))
    }
    
    public static let dragUTType = "com.macdroid.dragitem"
    
    public struct DragPayload: Codable, Sendable {
        public let sourceSide: String
        public let sourceKind: String
        public let sourceDirPath: String
        public let paths: [String]
        
        public init(sourceSide: String, sourceKind: String, sourceDirPath: String, paths: [String]) {
            self.sourceSide = sourceSide
            self.sourceKind = sourceKind
            self.sourceDirPath = sourceDirPath
            self.paths = paths
        }
    }
    
    public func createDragItemProvider(for item: FileItem, side: PaneSide) -> NSItemProvider {
        let currentSelection = (side == .left) ? leftSelection : rightSelection
        let currentSource = (side == .left) ? leftSource : rightSource
        let currentDir = (side == .left) ? leftPath : rightPath
        
        let dragPaths: [String]
        if currentSelection.contains(item.id) || currentSelection.contains(item.path) {
            let items = (side == .left ? leftItems : rightItems)
            let selectedItems = items.filter { currentSelection.contains($0.id) || currentSelection.contains($0.path) }
            dragPaths = selectedItems.isEmpty ? Array(currentSelection) : selectedItems.map(\.path)
        } else {
            dragPaths = [item.path]
        }
        
        let payload = DragPayload(
            sourceSide: side == .left ? "left" : "right",
            sourceKind: currentSource == .localMac ? "localMac" : "remotePhone",
            sourceDirPath: currentDir,
            paths: dragPaths
        )
        self.currentDragPayload = payload
        self.currentDragPayloadDate = Date()
        SSHTransportLog.write("DND_CREATE_PROVIDER side=\(side) source=\(currentSource) paths=\(dragPaths)")
        
        let provider = NSItemProvider()
        
        // 1. Внутренний тип приложения для точного межпанельного Drag & Drop
        if let data = try? JSONEncoder().encode(payload) {
            provider.registerDataRepresentation(forTypeIdentifier: DualPaneViewModel.dragUTType, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        
        // 2. Внешний тип (для Finder, Telegram, Browser, Mail и т.д.)
        if currentSource == .localMac {
            let fileURL = URL(fileURLWithPath: item.path)
            provider.registerItem(forTypeIdentifier: UTType.fileURL.identifier) { completionHandler, _, _ in
                completionHandler?(fileURL as NSURL, nil)
            }
            
            // Регистрируем стандартный системный список файлов (NSFilenamesPboardType),
            // чтобы внешние приложения (Finder, Desktop, Telegram, архиваторы и т.д.)
            // получали ВСЕ выделенные файлы, а не только один.
            if let plistData = try? PropertyListSerialization.data(fromPropertyList: dragPaths, format: .xml, options: 0) {
                provider.registerDataRepresentation(forTypeIdentifier: "NSFilenamesPboardType", visibility: .all) { completion in
                    completion(plistData, nil)
                    return nil
                }
            }
            
            // Также наполняем системный NSPasteboard drag несколькими файловыми URL для мгновенной совместимости
            DispatchQueue.main.async { [weak self] in
                self?.populateDragPasteboard(paths: dragPaths, payload: payload)
            }
        } else {
            // Для удаленного файла на Android: предзагружаем в локальный кэш DragOut (только для внешних приложений)
            provider.registerItem(forTypeIdentifier: UTType.fileURL.identifier) { [weak self, orchestrator = self.orchestrator] completionHandler, _, _ in
                let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacDroidCommander/DragOut", isDirectory: true)
                try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let localTargetURL = tempDir.appendingPathComponent(item.name)
                
                Task.detached(priority: .userInitiated) {
                    do {
                        if item.isDirectory {
                            // Рекурсивная выгрузка директории со всем содержимым для внешнего приложения (Finder, Desktop)
                            try FileManager.default.createDirectory(at: localTargetURL, withIntermediateDirectories: true)
                            let plan = await self?.resolveTransferPlan(
                                paths: [item.path],
                                fromSource: .remotePhone,
                                targetBaseDirPath: tempDir.path
                            )
                            if let plan = plan {
                                for dir in plan.directoriesToCreate {
                                    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                                }
                                for file in plan.filesToTransfer {
                                    let subDirURL = URL(fileURLWithPath: file.targetDirPath)
                                    _ = try? await orchestrator.executeCopyPhoneToMac(
                                        jobId: UUID().uuidString,
                                        itemId: UUID().uuidString,
                                        remotePath: file.sourcePath,
                                        localTargetDir: subDirURL,
                                        strategy: .overwrite
                                    ) { _ in }
                                }
                            }
                        } else {
                            try await orchestrator.executeCopyPhoneToMac(
                                jobId: UUID().uuidString,
                                itemId: UUID().uuidString,
                                remotePath: item.path,
                                localTargetDir: tempDir,
                                strategy: .overwrite
                            ) { _ in }
                        }
                        completionHandler?(localTargetURL as NSURL, nil)
                    } catch {
                        print("DragOut download error: \(error)")
                        completionHandler?(nil, error)
                    }
                }
            }
        }
        
        // 3. Регистрация текста для перетаскивания в текстовые поля / терминал
        provider.registerItem(forTypeIdentifier: UTType.utf8PlainText.identifier) { completionHandler, _, _ in
            let text = dragPaths.joined(separator: "\n")
            completionHandler?(text as NSString, nil)
        }
        
        return provider
    }
    
    /// Заполняет drag pasteboard системными URL всех перетаскиваемых файлов, сохраняя внутренний payload
    public func populateDragPasteboard(paths: [String], payload: DragPayload? = nil) {
        guard !paths.isEmpty else { return }
        let dragPB = NSPasteboard(name: .drag)
        let urls = paths.map { NSURL(fileURLWithPath: $0) }
        dragPB.clearContents()
        dragPB.writeObjects(urls)
        
        if let payload = payload ?? self.currentDragPayload,
           let data = try? JSONEncoder().encode(payload) {
            let customType = NSPasteboard.PasteboardType(DualPaneViewModel.dragUTType)
            dragPB.addTypes([customType], owner: nil)
            dragPB.setData(data, forType: customType)
        }
    }
    
    @discardableResult
    public func handleDroppedProviders(
        _ providers: [NSItemProvider],
        toSide: PaneSide,
        targetDirPath: String? = nil,
        isMove: Bool = false
    ) -> Bool {
        SSHTransportLog.write("DND_HANDLE_DROPPED_PROVIDERS toSide=\(toSide) targetDirPath=\(targetDirPath ?? "nil") providersCount=\(providers.count) hasPayload=\(self.currentDragPayload != nil)")
        guard !providers.isEmpty || self.currentDragPayload != nil else { return false }
        
        let destinationDir = targetDirPath ?? ((toSide == .left) ? self.leftPath : self.rightPath)
        
        // 1. Приоритетная проверка внутреннего перетаскивания (inter-pane drag inside app)
        if let payload = self.currentDragPayload {
            self.currentDragPayload = nil
            let fromSource: FileSource = (payload.sourceKind == "localMac") ? .localMac : .remotePhone
            SSHTransportLog.write("DND_EXECUTE_INTERNAL_PAYLOAD paths=\(payload.paths) from=\(fromSource) to=\(toSide) dest=\(destinationDir)")
            
            let sourceDirNorm = (payload.sourceDirPath as NSString).standardizingPath
            let targetDirNorm = (destinationDir as NSString).standardizingPath
            let isSameDir = (payload.sourceSide == (toSide == .left ? "left" : "right")) && (sourceDirNorm == targetDirNorm)
            if isSameDir {
                self.statusMessage = "Файлы уже находятся в этой папке"
                return true
            }
            
            self.executeTransfer(
                paths: payload.paths,
                fromSource: fromSource,
                toSide: toSide,
                targetDirPath: destinationDir,
                isMove: isMove
            )
            return true
        }
        
        // 2. Проверяем наличие внутреннего драга приложения через NSItemProvider
        for provider in providers {
            let hasInternal = provider.hasItemConformingToTypeIdentifier(DualPaneViewModel.dragUTType) || provider.registeredTypeIdentifiers.contains(DualPaneViewModel.dragUTType)
            if hasInternal {
                provider.loadDataRepresentation(forTypeIdentifier: DualPaneViewModel.dragUTType) { data, error in
                    guard let data = data,
                          let payload = try? JSONDecoder().decode(DragPayload.self, from: data) else {
                        return
                    }
                    DispatchQueue.main.async {
                        let fromSource: FileSource = (payload.sourceKind == "localMac") ? .localMac : .remotePhone
                        SSHTransportLog.write("DND_EXECUTE_PAYLOAD_FROM_ITEM_PROVIDER paths=\(payload.paths) from=\(fromSource) to=\(toSide) dest=\(destinationDir)")
                        
                        let sourceDirNorm = (payload.sourceDirPath as NSString).standardizingPath
                        let targetDirNorm = (destinationDir as NSString).standardizingPath
                        let isSameDir = (payload.sourceSide == (toSide == .left ? "left" : "right")) && (sourceDirNorm == targetDirNorm)
                        if isSameDir {
                            self.statusMessage = "Файлы уже находятся в этой папке"
                            return
                        }
                        
                        self.executeTransfer(
                            paths: payload.paths,
                            fromSource: fromSource,
                            toSide: toSide,
                            targetDirPath: destinationDir,
                            isMove: isMove
                        )
                    }
                }
                return true
            }
        }
        
        // 3. Внешний драг (из Finder, Desktop и других сторонних приложений)
        // Callback'и loadObject/loadItem приходят из разных потоков: запись в массив защищаем замком (U2)
        let localPathsLock = NSLock()
        var localPaths: [String] = []
        let appendLocalPath: (String) -> Void = { path in
            localPathsLock.lock()
            localPaths.append(path)
            localPathsLock.unlock()
        }
        let group = DispatchGroup()
        
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    defer { group.leave() }
                    if let url = url {
                        appendLocalPath(url.path)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    defer { group.leave() }
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        appendLocalPath(url.path)
                    } else if let url = item as? URL {
                        appendLocalPath(url.path)
                    } else if let nsurl = item as? NSURL, let p = nsurl.path {
                        appendLocalPath(p)
                    } else if let str = item as? String {
                        if str.hasPrefix("file://"), let u = URL(string: str) {
                            appendLocalPath(u.path)
                        } else {
                            appendLocalPath(str)
                        }
                    }
                }
            }
        }
        
        group.notify(queue: .main) {
            localPathsLock.lock()
            let collectedPaths = localPaths
            localPathsLock.unlock()
            if !collectedPaths.isEmpty {
                self.executeTransfer(
                    paths: collectedPaths,
                    fromSource: .localMac,
                    toSide: toSide,
                    targetDirPath: destinationDir,
                    isMove: isMove
                )
            }
        }
        
        return true
    }
    
    public func handleDroppedPaths(_ paths: [String], toSide: PaneSide, isMove: Bool = false) {
        let fromSource: FileSource = paths.first?.hasPrefix("/storage") == true ? .remotePhone : .localMac
        executeTransfer(paths: paths, fromSource: fromSource, toSide: toSide, isMove: isMove)
    }
    
    public func pauseTransfer() {
        isTransferPaused = true
        TransferQueueManager.shared.pauseAll()
        statusMessage = "Передача приостановлена"
    }
    
    public func resumeTransfer() {
        isTransferPaused = false
        TransferQueueManager.shared.resumeAll()
        statusMessage = "Передача возобновлена"
    }
    
    public func cancelTransfer() {
        currentTransferTask?.cancel()
        currentTransferTask = nil
        isTransferPaused = false
        showTransferProgress = false
        isTransferCompleted = false
        isTransferMinimized = false
        currentTransferFileName = ""
        // Если передача ждёт решения в диалоге конфликта, освобождаем ожидание
        if let cont = conflictContinuation {
            conflictContinuation = nil
            cont.resume(returning: nil)
        }
        showConflictDialog = false
        activeConflict = nil
        TransferQueueManager.shared.cancelAll()
        statusMessage = "Операция отменена"
        Task {
            await orchestrator.cleanAllActivePartFiles()
        }
    }
    
    public func minimizeTransferToBackground() {
        isTransferMinimized = true
        showTransferProgress = false
    }
    
    /// Источник лежит прямо в папке назначения, совпадает с ней или является её предком (Mac→Mac).
    /// Такие перенос/копирование недопустимы: move удалил бы единственную копию, copy дал бы конфликт с самим собой.
    static func isSameOrInsideTarget(sourcePath: String, targetDir: String) -> Bool {
        let src = (sourcePath as NSString).standardizingPath
        let parent = (src as NSString).deletingLastPathComponent
        return parent == targetDir || src == targetDir || targetDir.hasPrefix(src + "/")
    }

    /// Метаданные локального файла для сравнения при конфликте
    private static func localFileItem(atPath path: String) -> FileItem {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        return FileItem(
            id: path,
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            size: size,
            mtime: mtime,
            isDirectory: isDir,
            source: .localMac
        )
    }

    /// Ищет объект с тем же именем в папке назначения. Листинг телефона берётся без кэша (forceRefresh),
    /// ошибка листинга пробрасывается: нельзя молча считать папку пустой.
    private func detectTransferConflict(
        file: TransferPlanItem,
        fromSource: FileSource,
        targetSource: FileSource,
        totalFilesCount: Int,
        listingCache: inout [String: [String: FileItem]]
    ) async throws -> ConflictContext? {
        let targetPath = (file.targetDirPath as NSString).appendingPathComponent(file.fileName)
        let targetItem: FileItem
        if targetSource == .localMac {
            guard FileManager.default.fileExists(atPath: targetPath) else { return nil }
            targetItem = Self.localFileItem(atPath: targetPath)
        } else {
            if listingCache[file.targetDirPath] == nil {
                let items = try await remoteDriver.listDirectory(at: file.targetDirPath, forceRefresh: true)
                listingCache[file.targetDirPath] = Dictionary(items.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            }
            guard let found = listingCache[file.targetDirPath]?[file.fileName] else { return nil }
            targetItem = found
        }

        let sourceItem: FileItem
        if fromSource == .localMac {
            sourceItem = Self.localFileItem(atPath: file.sourcePath)
        } else {
            // mtime источника на телефоне в плане не хранится: сравнение по дате для него недоступно
            sourceItem = FileItem(
                id: file.sourcePath,
                name: file.fileName,
                path: file.sourcePath,
                size: file.size,
                mtime: 0,
                isDirectory: false,
                source: fromSource
            )
        }
        return ConflictContext(sourceItem: sourceItem, targetItem: targetItem, totalFilesCount: totalFilesCount)
    }

    private enum PhonePlacement {
        case place(targetPath: String)
        case skip(reason: String)
    }

    /// Решение по конфликту для phone→phone: cp/rename на телефоне перезаписывают цель,
    /// поэтому выбор стратегии выполняем здесь, до вызова низкоуровневых команд.
    private func resolvePhonePlacement(
        fileName: String,
        targetDir: String,
        conflict: ConflictContext?,
        strategy: ConflictResolutionStrategy,
        listingCache: [String: [String: FileItem]]
    ) -> PhonePlacement {
        let defaultTarget = (targetDir as NSString).appendingPathComponent(fileName)
        guard let conflict = conflict else { return .place(targetPath: defaultTarget) }
        switch strategy {
        case .overwrite, .customRename:
            return .place(targetPath: defaultTarget)
        case .skip:
            return .skip(reason: "Файл уже существует")
        case .skipIfIdentical:
            // Дата источника на телефоне в плане не хранится: без неё «идентичность» не доказать,
            // поэтому не перезаписываем (безопасный выбор)
            if conflict.sourceItem.mtime == 0 {
                return .skip(reason: "Не удалось сравнить с существующим файлом (дата источника недоступна)")
            }
            return conflict.isIdentical ? .skip(reason: "Идентичный файл уже существует") : .place(targetPath: defaultTarget)
        case .overwriteIfNewer:
            return conflict.isSourceNewer ? .place(targetPath: defaultTarget) : .skip(reason: "Существующий файл новее или такой же (дата источника недоступна)")
        case .autoRename:
            let existing = Set(listingCache[targetDir]?.keys.map { $0 } ?? [])
            let ext = (fileName as NSString).pathExtension
            let base = (fileName as NSString).deletingPathExtension
            var counter = 1
            var candidate = fileName
            while existing.contains(candidate) {
                candidate = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
                counter += 1
            }
            return .place(targetPath: (targetDir as NSString).appendingPathComponent(candidate))
        }
    }

    public func executeTransfer(
        paths requestedPaths: [String],
        fromSource: FileSource,
        toSide: PaneSide,
        targetDirPath: String? = nil,
        isMove: Bool
    ) {
        guard !requestedPaths.isEmpty else { return }

        let targetSource = (toSide == .left) ? leftSource : rightSource
        let targetDirPath = targetDirPath ?? ((toSide == .left) ? leftPath : rightPath)

        // D5: защита от переноса/копирования в ту же папку (включая drop из Finder)
        var allowedPaths = requestedPaths
        if fromSource == .localMac && targetSource == .localMac {
            let targetNorm = (targetDirPath as NSString).standardizingPath
            let blocked = requestedPaths.filter { Self.isSameOrInsideTarget(sourcePath: $0, targetDir: targetNorm) }
            if !blocked.isEmpty {
                allowedPaths = requestedPaths.filter { !blocked.contains($0) }
                statusMessage = "Пропущено объектов, уже находящихся в папке назначения: \(blocked.count)"
                SSHTransportLog.write("UI_TRANSFER_SAME_FOLDER_BLOCKED count=\(blocked.count) target=\(targetNorm)")
            }
        }
        let paths = allowedPaths
        guard !paths.isEmpty else { return }

        // D6: выбор «применить ко всем» действует только в пределах одной операции
        rememberedStrategy = nil

        // Окно прогресса показывается после разрешения конфликтов (иначе оно мигает перед диалогом)
        showTransferProgress = isRunningTests
        isTransferMinimized = false
        currentTransferFileName = ""
        isTransferCompleted = false
        transferCompletionMessage = ""
        transferProgress = 0.0
        transferSpeed = ""
        transferETA = ""
        isTransferPaused = false
        
        let speedTracker = TransferSpeedTracker()
        
        currentTransferTask = Task {
            SSHTransportLog.write("UI_TRANSFER_TASK_START paths=\(paths) fromSource=\(fromSource) targetDir=\(targetDirPath)")
            // Включаем защиту от засыпания Mac во время активной очереди
            NotificationManager.shared.beginSleepPrevention()
            ThumbnailCacheManager.shared.isThrottledDueToTransfer = true
            defer {
                NotificationManager.shared.endSleepPrevention()
                ThumbnailCacheManager.shared.isThrottledDueToTransfer = false
                if self.showConflictDialog {
                    self.showConflictDialog = false
                    self.activeConflict = nil
                }
            }
            
            self.statusMessage = "Анализ файлов и структуры папок..."
            SSHTransportLog.write("UI_RESOLVE_PLAN_START")
            let plan = await self.resolveTransferPlan(
                paths: paths,
                fromSource: fromSource,
                targetBaseDirPath: targetDirPath
            )
            SSHTransportLog.write("UI_RESOLVE_PLAN_DONE files=\(plan.filesToTransfer.count) dirs=\(plan.directoriesToCreate.count)")
            if !plan.skippedFolders.isEmpty {
                self.statusMessage = "Внимание: пропущено защищенных папок (\(plan.skippedFolders.count))"
            }
            
            // 1. Предварительное создание всех подпапок (включая пустые)
            for dir in plan.directoriesToCreate {
                if targetSource == .localMac {
                    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
                } else {
                    try? await self.remoteDriver.createDirectory(at: dir)
                }
            }
            
            // 2. Расчёт общего объёма и регистрация файлов в очереди
            var totalQueueBytes: UInt64 = 0
            var taskIds: [String: UUID] = [:]
            for file in plan.filesToTransfer {
                totalQueueBytes += file.size
                let fileItem = FileItem(
                    id: file.sourcePath,
                    name: file.fileName,
                    path: file.sourcePath,
                    size: file.size,
                    mtime: 0,
                    isDirectory: false,
                    source: fromSource
                )
                let tid = TransferQueueManager.shared.enqueue(source: fileItem, targetDir: file.targetDirPath, isMove: isMove)
                taskIds[file.sourcePath] = tid
            }
            
            var succeeded: [String] = []
            var failed: [(path: String, error: String)] = []
            var skipped: [String] = []
            var completedBytesSoFar: UInt64 = 0
            let totalCount = plan.filesToTransfer.count
            var completedCount = 0
            let startTime = Date()
            // Стратегия конфликта выбирается для каждого файла: по диалогу либо по «применить ко всем»
            var targetListingCache: [String: [String: FileItem]] = [:]
            var stoppedByUser = false
            var transferredMediaPaths: [String] = []
            let mediaExtensions = Set(["jpg", "jpeg", "png", "heic", "dng", "webp", "mp4", "mov", "mkv", "avi", "3gp", "mp3", "flac", "wav", "aac", "m4a"])
            
            for file in plan.filesToTransfer {
                if Task.isCancelled { break }
                
                let taskId = taskIds[file.sourcePath]
                if let tid = taskId, TransferQueueManager.shared.isTaskCancelled(id: tid) {
                    skipped.append(file.sourcePath)
                    continue
                }
                
                // Проверка паузы
                while self.isTransferPaused && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if Task.isCancelled { break }

                // D6: детект конфликта имён в цели и диалог выбора. D4/D13: «нет файла» отличается от ошибки сети —
                // при ошибке проверки файл НЕ передаётся (раньше любая ошибка считалась «файла нет» и вела к перезаписи).
                let conflict: ConflictContext?
                do {
                    conflict = try await self.detectTransferConflict(
                        file: file,
                        fromSource: fromSource,
                        targetSource: targetSource,
                        totalFilesCount: totalCount,
                        listingCache: &targetListingCache
                    )
                } catch {
                    failed.append((path: file.sourcePath, error: "Не удалось проверить папку назначения: \(error.localizedDescription)"))
                    completedCount += 1
                    if let tid = taskId {
                        TransferQueueManager.shared.markFailed(id: tid, error: error.localizedDescription)
                    }
                    continue
                }

                let jobId = UUID().uuidString
                let itemId = UUID().uuidString
                let path = file.sourcePath
                let fileName = file.fileName
                let fileSize = file.size
                let targetSubDir = file.targetDirPath
                let targetSubDirURL = URL(fileURLWithPath: targetSubDir)

                var fileStrategy: ConflictResolutionStrategy? = nil
                var destinationFileName: String? = nil

                if let conflict = conflict {
                    if let remembered = self.rememberedStrategy {
                        fileStrategy = remembered
                    } else {
                        self.statusMessage = "Конфликт имени: \(fileName)"
                        guard let resolution = await self.promptConflictResolution(conflict: conflict) else {
                            // Диалог закрыт без выбора: прекращаем всю передачу
                            SSHTransportLog.write("UI_TRANSFER cancelled by user at conflict dialog")
                            TransferQueueManager.shared.cancelAll()
                            stoppedByUser = true
                            break
                        }
                        fileStrategy = resolution.action
                        if let custom = resolution.customName, !custom.isEmpty {
                            destinationFileName = custom
                        }
                    }
                }
                if Task.isCancelled { break }

                // Без конфликта стратегия — «пропустить»: если цель успеет появиться, оркестратор её не затрёт
                let effectiveStrategy = fileStrategy ?? .skip

                // Обработка стратегии
                switch effectiveStrategy {
                case .skip:
                    if conflict != nil {
                        skipped.append(file.sourcePath)
                        if let tid = taskId {
                            TransferQueueManager.shared.cancelTask(id: tid)
                        }
                        continue
                    }

                case .customRename:
                    // Новое имя тоже не должно затирать существующий объект
                    let customName = destinationFileName ?? fileName
                    let customExists: Bool
                    if targetSource == .localMac {
                        customExists = FileManager.default.fileExists(atPath: (targetSubDir as NSString).appendingPathComponent(customName))
                    } else {
                        customExists = targetListingCache[targetSubDir]?[customName] != nil
                    }
                    if customExists {
                        skipped.append(file.sourcePath)
                        failed.append((path: file.sourcePath, error: "Объект с именем «\(customName)» уже существует"))
                        completedCount += 1
                        if let tid = taskId {
                            TransferQueueManager.shared.markFailed(id: tid, error: "Объект с именем «\(customName)» уже существует")
                        }
                        continue
                    }

                case .skipIfIdentical, .overwriteIfNewer, .autoRename, .overwrite:
                    // Решение принимает оркестратор (Mac/телефон) либо resolvePhonePlacement (телефон → телефон)
                    break
                }

                let effectiveDisplayName = destinationFileName ?? fileName
                let actionVerb = isMove ? "Перемещение: " : "Копирование: "
                self.currentTransferFileName = effectiveDisplayName
                self.statusMessage = "\(actionVerb)\(effectiveDisplayName)"
                if self.showConflictDialog {
                    self.showConflictDialog = false
                    self.activeConflict = nil
                }
                if !self.isTransferMinimized && !self.showTransferProgress {
                    self.showTransferProgress = true
                }
                
                var lastUIProgressUpdate: CFAbsoluteTime = 0
                let onProgress: @Sendable (Double) -> Void = { @Sendable pct in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        let currentFileBytes = UInt64(Double(fileSize) * pct)
                        let totalTransferredNow = completedBytesSoFar + currentFileBytes
                        speedTracker.update(bytesTransferred: totalTransferredNow)
                        
                        let currentSpeed = speedTracker.currentSpeedBytesPerSec
                        let remainingBytes = (totalQueueBytes > totalTransferredNow) ? (totalQueueBytes - totalTransferredNow) : 0
                        let eta = speedTracker.calculateETA(remainingBytes: remainingBytes)
                        
                        // Троттлинг: обновляем @Published свойства UI не чаще 15 раз/сек (~67мс),
                        // предотвращая лаги SwiftUI при передаче со скоростью 100+ МБ/с
                        let now = CFAbsoluteTimeGetCurrent()
                        let isComplete = pct >= 1.0
                        if isComplete || (now - lastUIProgressUpdate >= 0.067) {
                            lastUIProgressUpdate = now
                            self.transferSpeed = TransferSpeedTracker.formatSpeed(currentSpeed)
                            self.transferETA = TransferSpeedTracker.formatETA(eta)
                            
                            if totalQueueBytes > 0 {
                                self.transferProgress = min(1.0, Double(totalTransferredNow) / Double(totalQueueBytes))
                            } else {
                                self.transferProgress = Double(completedCount) / Double(max(1, totalCount))
                            }
                        }
                        
                        if let tid = taskId {
                            TransferQueueManager.shared.updateProgress(
                                id: tid,
                                progress: pct,
                                bytesTransferred: currentFileBytes,
                                speed: currentSpeed,
                                eta: eta
                            )
                        }
                    }
                }
                
                do {
                    let result: TransferExecutionResult
                    switch (fromSource, targetSource) {
                    case (.localMac, .remotePhone):
                        let localURL = URL(fileURLWithPath: path)
                        if isMove {
                            result = try await orchestrator.executeMoveMacToPhone(
                                jobId: jobId,
                                itemId: itemId,
                                localSourceURL: localURL,
                                remoteTargetDir: targetSubDir,
                                destinationFileName: destinationFileName,
                                strategy: effectiveStrategy,
                                progress: onProgress
                            )
                        } else {
                            result = try await orchestrator.executeCopyMacToPhone(
                                jobId: jobId,
                                itemId: itemId,
                                localSourceURL: localURL,
                                remoteTargetDir: targetSubDir,
                                destinationFileName: destinationFileName,
                                strategy: effectiveStrategy,
                                progress: onProgress
                            )
                        }
                        let ext = URL(fileURLWithPath: effectiveDisplayName).pathExtension.lowercased()
                        let wasTransferred: Bool
                        switch result {
                        case .transferred, .transferredWithoutSourceDeletion:
                            wasTransferred = true
                        case .skipped:
                            wasTransferred = false
                        }
                        if mediaExtensions.contains(ext) && wasTransferred {
                            let remoteTargetFilePath = (targetSubDir as NSString).appendingPathComponent(effectiveDisplayName)
                            transferredMediaPaths.append(remoteTargetFilePath)
                        }
                        
                    case (.remotePhone, .localMac):
                        SSHTransportLog.write("UI_CALL_ORCH_COPY_PHONE_TO_MAC path=\(path) target=\(targetSubDirURL.path) isMove=\(isMove)")
                        if isMove {
                            result = try await orchestrator.executeMovePhoneToMac(
                                jobId: jobId,
                                itemId: itemId,
                                remotePath: path,
                                localTargetDir: targetSubDirURL,
                                destinationFileName: destinationFileName,
                                strategy: effectiveStrategy,
                                progress: onProgress
                            )
                        } else {
                            result = try await orchestrator.executeCopyPhoneToMac(
                                jobId: jobId,
                                itemId: itemId,
                                remotePath: path,
                                localTargetDir: targetSubDirURL,
                                destinationFileName: destinationFileName,
                                strategy: effectiveStrategy,
                                progress: onProgress
                            )
                        }
                        SSHTransportLog.write("UI_COPY_PHONE_TO_MAC_RESULT path=\(path) result=\(result)")
                        
                    case (.localMac, .localMac):
                        let localURL = URL(fileURLWithPath: path)
                        if isMove {
                            result = try await orchestrator.executeMoveMacToMac(
                                jobId: jobId,
                                itemId: itemId,
                                localSourceURL: localURL,
                                localTargetDir: targetSubDirURL,
                                destinationFileName: destinationFileName,
                                strategy: effectiveStrategy,
                                progress: onProgress
                            )
                        } else {
                            result = try await orchestrator.executeCopyMacToMac(
                                jobId: jobId,
                                itemId: itemId,
                                localSourceURL: localURL,
                                localTargetDir: targetSubDirURL,
                                destinationFileName: destinationFileName,
                                strategy: effectiveStrategy,
                                progress: onProgress
                            )
                        }
                        
                    case (.remotePhone, .remotePhone):
                        // D9: стратегия конфликта применяется здесь, т.к. cp/rename на телефоне перезаписывают цель
                        let placement = self.resolvePhonePlacement(
                            fileName: effectiveDisplayName,
                            targetDir: targetSubDir,
                            conflict: conflict,
                            strategy: effectiveStrategy,
                            listingCache: targetListingCache
                        )
                        switch placement {
                        case .skip(let reason):
                            result = .skipped(reason: reason)
                        case .place(let targetPath):
                            if isMove {
                                let ok = try await orchestrator.transport.executeRename(oldPath: path, newPath: targetPath)
                                if ok {
                                    result = .transferred
                                } else if PhoneConnectionManager.shared.copyFileOnDevice(sourcePath: path, targetPath: targetPath) {
                                    // Обработка EXDEV (Cross-device link): если перенос между разделами (SD-карта / память), копируем и удаляем оригинал.
                                    // Результат удаления проверяем: иначе копия есть, а исходник тихо остался.
                                    let deleted = (try? await orchestrator.transport.executeDelete(actionId: itemId, path: path)) ?? false
                                    onProgress(1.0)
                                    result = deleted
                                        ? .transferred
                                        : .transferredWithoutSourceDeletion(reason: "Копия создана, но исходный файл на телефоне не удалён")
                                } else {
                                    result = .skipped(reason: "Не удалось переименовать или переместить на телефоне (защита Scoped Storage или разные разделы)")
                                }
                            } else {
                                // Оптимизация P1: Прямое серверное копирование файла внутри телефона без прокачки 20 ГБ трафика через Mac
                                if PhoneConnectionManager.shared.copyFileOnDevice(sourcePath: path, targetPath: targetPath) {
                                    onProgress(1.0)
                                    result = .transferred
                                } else {
                                    // Фоллбэк: если прямое копирование на телефоне недоступно (нет ADB / беспроводной SFTP без shell).
                                    // Решение по конфликту уже принято выше, поэтому второй шаг не перепроверяет его заново.
                                    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacDroidCommander/PhoneCopy", isDirectory: true)
                                    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                                    try await orchestrator.executeCopyPhoneToMac(
                                        jobId: jobId,
                                        itemId: itemId,
                                        remotePath: path,
                                        localTargetDir: tempDir,
                                        strategy: .overwrite,
                                        progress: onProgress
                                    )
                                    let tempLocalURL = tempDir.appendingPathComponent(fileName)
                                    defer { try? FileManager.default.removeItem(at: tempLocalURL) }
                                    let fallbackStrategy: ConflictResolutionStrategy = (effectiveStrategy == .autoRename) ? .autoRename : .overwrite
                                    result = try await orchestrator.executeCopyMacToPhone(
                                        jobId: jobId,
                                        itemId: itemId,
                                        localSourceURL: tempLocalURL,
                                        remoteTargetDir: targetSubDir,
                                        destinationFileName: destinationFileName,
                                        strategy: fallbackStrategy,
                                        progress: onProgress
                                    )
                                }
                            }
                        }
                    }
                    
                    switch result {
                    case .skipped:
                        skipped.append(path)
                        completedCount += 1
                        self.transferProgress = (totalQueueBytes > 0) ? min(1.0, Double(completedBytesSoFar) / Double(totalQueueBytes)) : (Double(completedCount) / Double(max(1, totalCount)))
                        if let tid = taskId {
                            TransferQueueManager.shared.updateProgress(
                                id: tid,
                                progress: 1.0,
                                bytesTransferred: fileSize,
                                speed: 0,
                                eta: nil
                            )
                        }
                    case .transferred:
                        succeeded.append(path)
                        completedBytesSoFar += fileSize
                        completedCount += 1
                        self.transferProgress = (totalQueueBytes > 0) ? min(1.0, Double(completedBytesSoFar) / Double(totalQueueBytes)) : (Double(completedCount) / Double(max(1, totalCount)))
                        
                        if let tid = taskId {
                            TransferQueueManager.shared.updateProgress(
                                id: tid,
                                progress: 1.0,
                                bytesTransferred: fileSize,
                                speed: 0,
                                eta: nil
                            )
                        }
                    case .transferredWithoutSourceDeletion(let reason):
                        succeeded.append(path)
                        failed.append((path: path, error: reason))
                        completedBytesSoFar += fileSize
                        completedCount += 1
                        self.transferProgress = (totalQueueBytes > 0) ? min(1.0, Double(completedBytesSoFar) / Double(totalQueueBytes)) : (Double(completedCount) / Double(max(1, totalCount)))
                        if let tid = taskId {
                            TransferQueueManager.shared.markFailed(id: tid, error: reason)
                        }
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        if let tid = taskId {
                            TransferQueueManager.shared.cancelTask(id: tid)
                        }
                        break
                    }
                    failed.append((path: path, error: error.localizedDescription))
                    if let tid = taskId {
                        TransferQueueManager.shared.markFailed(id: tid, error: error.localizedDescription)
                    }
                }
            }
            
            let transferAborted = Task.isCancelled || stoppedByUser
            // Если перемещение (Move): удаляем исходные папки ТОЛЬКО если они стали ПУСТЫМИ!
            // Если внутри папки остался хотя бы один пропущенный или непереданный файл,
            // rmdir / deleteEmptyDirectory не удалит папку, сохранив её вместе с файлами.
            if isMove && !transferAborted {
                for folder in plan.sourceFoldersToDeleteOnMove {
                    if fromSource == .localMac {
                        if let contents = try? FileManager.default.contentsOfDirectory(atPath: folder) {
                            let meaningful = contents.filter { $0 != "." && $0 != ".." && !$0.hasPrefix(".DS_Store") }
                            if meaningful.isEmpty {
                                let dsStore = (folder as NSString).appendingPathComponent(".DS_Store")
                                try? FileManager.default.removeItem(atPath: dsStore)
                                _ = rmdir(folder)
                            }
                        }
                    } else {
                        var deleted = (try? await self.remoteDriver.deleteEmptyDirectory(at: folder)) ?? false
                        if !deleted {
                            // Безопасная очистка: удаляем ТОЛЬКО временные артефакты передачи (.DS_Store, .mcdpart),
                            // НИ В КОЕМ СЛУЧАЕ не удаляя произвольные скрытые пользовательские файлы (.*)
                            deleted = (try? await self.remoteDriver.deleteEmptyDirectory(at: folder)) ?? false
                        }
                    }
                }
            }
            
            // Обновление медиатеки Android (MediaScanner)
            if !transferredMediaPaths.isEmpty {
                PhoneConnectionManager.shared.notifyMediaScanner(paths: transferredMediaPaths, deviceId: self.remoteDriver.coordinator.deviceId)
            }
            
            if transferAborted {
                await self.orchestrator.cleanAllActivePartFiles()
                TransferQueueManager.shared.cancelAll()
            }
            
            let duration = Date().timeIntervalSince(startTime)
            let avgSpeed = speedTracker.averageSpeedBytesPerSec
            self.operationReport = OperationReport(
                succeeded: succeeded,
                failed: failed,
                skipped: skipped,
                totalBytes: completedBytesSoFar,
                duration: duration,
                averageSpeedBytesPerSec: avgSpeed
            )
            
            // Системное уведомление macOS для длительных операций
            NotificationManager.shared.notifyOperationCompleted(
                succeeded: succeeded.count,
                failed: failed.count,
                totalBytes: completedBytesSoFar,
                duration: duration
            )
            NSSound(named: "Glass")?.play()
            
            if transferAborted {
                self.showTransferProgress = false
                self.isTransferCompleted = false
                self.isTransferMinimized = false
                self.currentTransferFileName = ""
                self.statusMessage = "Операция отменена"
            } else if failed.isEmpty {
                let verb = isMove ? "перемещено" : "скопировано"
                var successMsg = "Успешно \(verb) объектов: \(succeeded.count)"
                if !skipped.isEmpty {
                    successMsg += " (пропущено: \(skipped.count))"
                }
                self.statusMessage = successMsg
                self.transferCompletionMessage = successMsg
                self.transferProgress = 1.0
                self.isTransferCompleted = true
                self.showOperationReport = false
                
                if self.showTransferProgress {
                    // Отображаем успешное завершение в окне прогресса 0.9 секунды (сокращено в 2 раза) и автоматически закрываем
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    self.showTransferProgress = false
                }
                self.isTransferCompleted = false
                self.isTransferMinimized = false
                self.currentTransferFileName = ""
            } else {
                self.showTransferProgress = false
                self.isTransferCompleted = false
                self.isTransferMinimized = false
                self.currentTransferFileName = ""
                self.statusMessage = "Завершено с ошибками. Успешно: \(succeeded.count), Ошибок: \(failed.count)"
                self.showOperationReport = true
            }
            
            self.refreshPane(side: .left)
            self.refreshPane(side: .right)
        }
    }
    
    public struct TransferPlanItem: Sendable {
        public let sourcePath: String
        public let targetDirPath: String
        public let fileName: String
        public let size: UInt64
        
        public init(sourcePath: String, targetDirPath: String, fileName: String, size: UInt64) {
            self.sourcePath = sourcePath
            self.targetDirPath = targetDirPath
            self.fileName = fileName
            self.size = size
        }
    }
    
    public func resolveTransferPlan(
        paths: [String],
        fromSource: FileSource,
        targetBaseDirPath: String
    ) async -> (directoriesToCreate: [String], filesToTransfer: [TransferPlanItem], sourceFoldersToDeleteOnMove: [String], skippedFolders: [(path: String, reason: String)]) {
        if fromSource == .localMac {
            // Обход локальных папок выполняем вне MainActor: на больших деревьях он подвешивал UI
            return await Task.detached(priority: .userInitiated) {
                DualPaneViewModel.scanLocalTransferPlan(paths: paths, targetBaseDirPath: targetBaseDirPath)
            }.value
        }
        
        var directoriesToCreate: [String] = []
        var filesToTransfer: [TransferPlanItem] = []
        var sourceFoldersToDeleteOnMove: [String] = []
        var skippedFolders: [(path: String, reason: String)] = []
        
        for path in paths {
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            var isDir = false
            let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let normPath = path.precomposedStringWithCanonicalMapping
            
            var remoteStatSize: UInt64? = nil
            let allSourceItems = leftItems + rightItems
            if let item = allSourceItems.first(where: {
                $0.id == path || $0.path == path ||
                $0.path.precomposedStringWithCanonicalMapping == normPath ||
                $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == cleanPath
            }) {
                isDir = item.isDirectory
                remoteStatSize = item.size
            } else if let stat = try? await self.transport.prepareRead(actionId: UUID().uuidString, path: path) {
                isDir = stat.isDirectory
                remoteStatSize = stat.size
            } else if let _ = try? await self.remoteDriver.listDirectory(at: path) {
                isDir = true
            }
            
            if !isDir {
                filesToTransfer.append(TransferPlanItem(
                    sourcePath: path,
                    targetDirPath: targetBaseDirPath,
                    fileName: fileName,
                    size: remoteStatSize ?? 0
                ))
            } else {
                sourceFoldersToDeleteOnMove.append(path)
                let folderTargetBase = (targetBaseDirPath as NSString).appendingPathComponent(fileName)
                directoriesToCreate.append(folderTargetBase)
                
                var visitedRemoteDirs = Set<String>()
                func scanRemote(remoteDir: String, currentTargetDir: String, depth: Int = 0) async {
                    guard depth < 30 else { return }
                    guard visitedRemoteDirs.insert(remoteDir).inserted else { return }
                    let contents = try? await remoteDriver.listDirectory(at: remoteDir)
                    guard let validContents = contents else {
                        if remoteDir != path {
                            print("scanRemote: failed to list directory at \(remoteDir)")
                            skippedFolders.append((path: remoteDir, reason: "Папка недоступна или защищена политикой доступа Android"))
                        }
                        return
                    }
                    for item in validContents {
                        if item.name == "." || item.name == ".." { continue }
                        if item.name.hasPrefix(".") && (item.name.contains(".part.") || item.name.hasSuffix(".mcdpart")) { continue }
                        let subTarget = (currentTargetDir as NSString).appendingPathComponent(item.name)
                        if item.isDirectory {
                            sourceFoldersToDeleteOnMove.append(item.path)
                            directoriesToCreate.append(subTarget)
                            await scanRemote(remoteDir: item.path, currentTargetDir: subTarget, depth: depth + 1)
                        } else {
                            filesToTransfer.append(TransferPlanItem(
                                sourcePath: item.path,
                                targetDirPath: currentTargetDir,
                                fileName: item.name,
                                size: item.size
                            ))
                        }
                    }
                }
                await scanRemote(remoteDir: path, currentTargetDir: folderTargetBase, depth: 0)
            }
        }
        
        // Сортируем каталоги по длине пути по убыванию (deepest first / post-order),
        // чтобы при переносе сначала удалялись самые глубокие пустые подпапки
        sourceFoldersToDeleteOnMove.sort { $0.count > $1.count }
        
        return (directoriesToCreate, filesToTransfer, sourceFoldersToDeleteOnMove, skippedFolders)
    }
    
    /// План передачи для локальных источников (Mac). Чистая функция без обращения к состоянию VM,
    /// поэтому вызывается вне MainActor.
    nonisolated static func scanLocalTransferPlan(
        paths: [String],
        targetBaseDirPath: String
    ) -> (directoriesToCreate: [String], filesToTransfer: [TransferPlanItem], sourceFoldersToDeleteOnMove: [String], skippedFolders: [(path: String, reason: String)]) {
        var directoriesToCreate: [String] = []
        var filesToTransfer: [TransferPlanItem] = []
        var sourceFoldersToDeleteOnMove: [String] = []
        var skippedFolders: [(path: String, reason: String)] = []
        
        for path in paths {
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            var isDirObjC: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirObjC)
            let isDir = exists && isDirObjC.boolValue
            
            if !isDir {
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
                filesToTransfer.append(TransferPlanItem(
                    sourcePath: path,
                    targetDirPath: targetBaseDirPath,
                    fileName: fileName,
                    size: size
                ))
            } else {
                sourceFoldersToDeleteOnMove.append(path)
                let folderTargetBase = (targetBaseDirPath as NSString).appendingPathComponent(fileName)
                directoriesToCreate.append(folderTargetBase)
                
                func scanLocal(dirURL: URL, currentTargetDir: String) {
                    guard let contents = try? FileManager.default.contentsOfDirectory(
                        at: dirURL,
                        includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                        options: []
                    ) else {
                        if dirURL.path != path {
                            skippedFolders.append((path: dirURL.path, reason: "Не удалось прочитать локальную папку"))
                        }
                        return
                    }
                    for item in contents {
                        let name = item.lastPathComponent
                        if name.hasPrefix(".") && (name.contains(".part.") || name.hasSuffix(".mcdpart")) { continue }
                        let isSubDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                        let subTarget = (currentTargetDir as NSString).appendingPathComponent(name)
                        if isSubDir {
                            sourceFoldersToDeleteOnMove.append(item.path)
                            directoriesToCreate.append(subTarget)
                            scanLocal(dirURL: item, currentTargetDir: subTarget)
                        } else {
                            let fSize = UInt64((try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                            filesToTransfer.append(TransferPlanItem(
                                sourcePath: item.path,
                                targetDirPath: currentTargetDir,
                                fileName: name,
                                size: fSize
                            ))
                        }
                    }
                }
                scanLocal(dirURL: URL(fileURLWithPath: path), currentTargetDir: folderTargetBase)
            }
        }
        
        sourceFoldersToDeleteOnMove.sort { $0.count > $1.count }
        
        return (directoriesToCreate, filesToTransfer, sourceFoldersToDeleteOnMove, skippedFolders)
    }
    
    private func startTransfer(isMove: Bool) {
        guard !isDuplicating else { return }
        var sourceSide = activePane
        var selected = (sourceSide == .left) ? leftSelection : rightSelection
        SSHTransportLog.write("UI_START_TRANSFER activePane=\(activePane) leftSel=\(leftSelection.count) rightSel=\(rightSelection.count) isMove=\(isMove)")
        
        // Если в активной панели ничего не выбрано, но в противоположной панели есть выделение
        if selected.isEmpty {
            let oppositeSide: PaneSide = (sourceSide == .left) ? .right : .left
            let oppositeSelection = (oppositeSide == .left) ? leftSelection : rightSelection
            if !oppositeSelection.isEmpty {
                sourceSide = oppositeSide
                selected = oppositeSelection
                SSHTransportLog.write("UI_START_TRANSFER fallback to oppositeSide=\(oppositeSide) selected=\(selected.count)")
            }
        }
        
        guard !selected.isEmpty else {
            statusMessage = "Выберите файлы для передачи"
            SSHTransportLog.write("UI_START_TRANSFER empty selection")
            return
        }
        
        let targetSide: PaneSide = (sourceSide == .left) ? .right : .left
        let fromSource = (sourceSide == .left) ? leftSource : rightSource
        SSHTransportLog.write("UI_START_TRANSFER proceed paths=\(Array(selected)) fromSource=\(fromSource) targetSide=\(targetSide)")
        
        if isRunningTests {
            executeTransfer(paths: Array(selected), fromSource: fromSource, toSide: targetSide, isMove: isMove)
            return
        }
        
        let sourceItems = (sourceSide == .left) ? leftItems : rightItems
        let selectedItems = sourceItems.filter { selected.contains($0.id) || selected.contains($0.path) }
        let targetDirPath = (targetSide == .left) ? leftPath : rightPath
        let totalSize = selectedItems.reduce(0) { $0 + $1.size }
        
        let context = TransferConfirmationContext(
            items: selectedItems,
            paths: Array(selected),
            isMove: isMove,
            fromSource: fromSource,
            toSide: targetSide,
            targetDirPath: targetDirPath,
            totalSize: totalSize
        )
        
        self.transferConfirmation = context
        self.showTransferConfirmationDialog = true
    }
    
    public func confirmTransfer(targetDirPath: String? = nil) {
        guard let ctx = self.transferConfirmation else { return }
        self.showTransferConfirmationDialog = false
        self.transferConfirmation = nil
        let dir = targetDirPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTargetDir = (dir != nil && !dir!.isEmpty) ? dir! : ctx.targetDirPath
        executeTransfer(paths: ctx.paths, fromSource: ctx.fromSource, toSide: ctx.toSide, targetDirPath: finalTargetDir, isMove: ctx.isMove)
    }
    
    public func cancelTransferConfirmation() {
        self.showTransferConfirmationDialog = false
        self.transferConfirmation = nil
    }
    
    public struct OperationReport: Sendable {
        public let succeeded: [String]
        public let failed: [(path: String, error: String)]
        public let skipped: [String]
        public let totalBytes: UInt64
        public let duration: TimeInterval
        public let averageSpeedBytesPerSec: Double
        
        public init(
            succeeded: [String],
            failed: [(path: String, error: String)],
            skipped: [String] = [],
            totalBytes: UInt64 = 0,
            duration: TimeInterval = 0,
            averageSpeedBytesPerSec: Double = 0
        ) {
            self.succeeded = succeeded
            self.failed = failed
            self.skipped = skipped
            self.totalBytes = totalBytes
            self.duration = duration
            self.averageSpeedBytesPerSec = averageSpeedBytesPerSec
        }
    }
}
