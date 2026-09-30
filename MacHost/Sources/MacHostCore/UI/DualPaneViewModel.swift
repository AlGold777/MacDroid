import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DiskArbitration

public enum SortField: String, CaseIterable, Sendable {
    case name = "Имя"
    case size = "Размер"
    case date = "Дата"
}

public enum PaneSide: String, Sendable {
    case left = "left"
    case right = "right"
}

public enum PaneViewMode: String, CaseIterable, Sendable {
    case table = "table"
    case grid = "grid"
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
    @Published public var activePane: PaneSide = .left {
        didSet {
            UserDefaults.standard.set(activePane.rawValue, forKey: SessionKey.activePane)
            if activePane != oldValue {
                if activePane == .left {
                    rightSelection.removeAll()
                    TableDoubleClickHandler.HandlerView.rightTableView?.deselectAll(nil)
                } else {
                    leftSelection.removeAll()
                    TableDoubleClickHandler.HandlerView.leftTableView?.deselectAll(nil)
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
    @Published public var leftActiveTabId: UUID = UUID()
    
    // Вкладки правой панели
    @Published public var rightTabs: [PanelTab] = []
    @Published public var rightActiveTabId: UUID = UUID()
    
    // Состояние левой панели
    private var leftItemsVersion: Int = 0
    private var rightItemsVersion: Int = 0
    
    @Published public var leftSource: FileSource = .localMac
    @Published public var leftPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    @Published public var leftItems: [FileItem] = [] {
        didSet { leftItemsVersion &+= 1 }
    }
    @Published public var leftSelection: Set<String> = [] {
        didSet { onSelectionChanged(for: .left) }
    }
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
    
    // Состояние правой панели
    @Published public var rightSource: FileSource = .remotePhone
    @Published public var rightPath: String = "/storage/emulated/0/DCIM"
    @Published public var rightItems: [FileItem] = [] {
        didSet { rightItemsVersion &+= 1 }
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
    
    // Сравнение каталогов
    @Published public var isComparing: Bool = false
    @Published public var comparisonResult: DirectoryComparisonResult = DirectoryComparisonResult()
    @Published public var hideIdenticalInComparison: Bool = false
    private let comparator = DirectoryComparator()
    
    // Диалоги и задачи
    @Published public var showNewFolderDialog: Bool = false
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
    @Published public var showSearchDialog: Bool = false
    @Published public var showPairingDialog: Bool = false
    @Published public var showErrorAlert: Bool = false
    @Published public var errorMessage: String = ""
    @Published public var transferProgress: Double = 0.0
    @Published public var transferSpeed: String = ""
    @Published public var transferETA: String = ""
    @Published public var statusMessage: String = "Готов к работе"
    @Published public var newFolderName: String = ""
    @Published public var newFolderSelectedItems: [FileItem] = []
    @Published public var showOperationReport: Bool = false
    
    // Drag & Drop Visual Feedback
    @Published public var dragHoverSide: PaneSide? = nil
    @Published public var dragHoverFolderId: String? = nil
    @Published public var dragInsertionIndex: Int? = nil
    
    public func clearDragHoverState() {
        dragHoverSide = nil
        dragHoverFolderId = nil
        dragInsertionIndex = nil
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
    
    // Активная сессия перетаскивания (Drag & Drop) внутри приложения
    public var currentDragPayload: DragPayload? = nil
    public var draggedTabInfo: (side: PaneSide, id: UUID)? = nil
    
    // Просмотр изображений и галерея
    @Published public var showImageViewer: Bool = false
    @Published public var viewerImages: [FileItem] = []
    @Published public var viewerStartIndex: Int = 0
    @Published public var isQuickViewActive: Bool = false
    
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
    private var wifiReachabilityMisses: Int = 0
    private var connectionProbeRunning = false
    private let wifiReachabilityMissLimit = 3
    
    // Вычисление размера папок по нажатию Space
    @Published public var calculatedFolderSizes: [String: UInt64] = [:]
    @Published public var calculatingFolderPaths: Set<String> = []
    
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
            } else {
                // В худшем случае in-memory база, гарантирующая отсутствие краша
                ledger = (try? IntentLedger(databaseURL: URL(fileURLWithPath: ":memory:")))
                    ?? (try! IntentLedger(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("ledger_\(UUID().uuidString).db")))
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
        static let activePane = "session.activePane"
        static let isQuickViewActive = "session.isQuickViewActive"
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
        
        let leftTabTitle = URL(fileURLWithPath: leftPath).lastPathComponent
        if leftTabs.isEmpty {
            let defaultLeftTab = PanelTab(title: leftTabTitle.isEmpty ? "Домой" : leftTabTitle, path: leftPath, source: leftSource)
            leftTabs = [defaultLeftTab]
            leftActiveTabId = defaultLeftTab.id
        }
        
        let rightTabTitle = URL(fileURLWithPath: rightPath).lastPathComponent
        if rightTabs.isEmpty {
            let defaultRightTab = PanelTab(title: rightTabTitle.isEmpty ? "DCIM" : rightTabTitle, path: rightPath, source: rightSource)
            rightTabs = [defaultRightTab]
            rightActiveTabId = defaultRightTab.id
        }
        
        if leftSource != .remotePhone || remoteDriver.isConnected {
            refreshPane(side: .left)
        }
        if rightSource != .remotePhone || remoteDriver.isConnected {
            refreshPane(side: .right)
        }
        discoveryService.startDiscovery()
        
        QuickLookBridge.shared.onNavigateNext = { [weak self] in
            self?.selectNext()
        }
        QuickLookBridge.shared.onNavigatePrevious = { [weak self] in
            self?.selectPrevious()
        }
        
        // Автоматическое обнаружение и подключение смартфона при старте
        let isRunningTests = ProcessInfo.processInfo.processName == "MacHostTests"
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
        defaults.set(activePane.rawValue, forKey: SessionKey.activePane)
        defaults.set(isQuickViewActive, forKey: SessionKey.isQuickViewActive)
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
        defaults.removeObject(forKey: SessionKey.activePane)
        defaults.removeObject(forKey: SessionKey.isQuickViewActive)
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
        if let leftTabsData = defaults.data(forKey: SessionKey.leftTabs),
           let tabs = try? JSONDecoder().decode([PanelTab].self, from: leftTabsData),
           !tabs.isEmpty {
            leftTabs = tabs.map { tab in
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
                return PanelTab(id: tab.id, title: (title.isEmpty || validPath == "/") ? "⌂" : title, path: validPath, source: tab.source, isPinned: tab.isPinned)
            }
        }
        if let rightTabsData = defaults.data(forKey: SessionKey.rightTabs),
           let tabs = try? JSONDecoder().decode([PanelTab].self, from: rightTabsData),
           !tabs.isEmpty {
            rightTabs = tabs.map { tab in
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
                return PanelTab(id: tab.id, title: (title.isEmpty || validPath == "/") ? "⌂" : title, path: validPath, source: tab.source, isPinned: tab.isPinned)
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
        
        // Синхронизация текущего пути и источника с активными вкладками
        if let active = leftTabs.first(where: { $0.id == leftActiveTabId }) {
            leftPath = active.path
            leftSource = active.source
        }
        if let active = rightTabs.first(where: { $0.id == rightActiveTabId }) {
            rightPath = active.path
            rightSource = active.source
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
    
    /// Генерация цепочки хлебных крошек с учетом настроек скрытия базовых префиксов (Mac и Phone)
    public func breadcrumbs(for path: String, source: FileSource) -> [PathBreadcrumb] {
        let cleanPath = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        
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
                // Мы находимся в скрываемом базовом каталоге: отображаем только стрелочку корня
                return [PathBreadcrumb(title: "›", fullPath: prefix, isRoot: true)]
            } else if cleanPath.hasPrefix(prefix + "/") {
                // Путь находится внутри скрываемого базового каталога
                var result: [PathBreadcrumb] = [
                    PathBreadcrumb(title: "›", fullPath: prefix, isRoot: true)
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
            return [PathBreadcrumb(title: "›", fullPath: "/", isRoot: true)]
        }
        
        var result: [PathBreadcrumb] = []
        var accumulated = ""
        for (index, component) in parts.enumerated() {
            if index == 0 {
                let targetRoot = (source == .localMac)
                    ? (FileManager.default.fileExists(atPath: cleanPath) ? "/" : FileManager.default.homeDirectoryForCurrentUser.path)
                    : "/"
                result.append(PathBreadcrumb(title: "›", fullPath: targetRoot, isRoot: true))
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
        if newSide == .left {
            rightSelection.removeAll()
            TableDoubleClickHandler.HandlerView.rightTableView?.deselectAll(nil)
            if leftSelection.isEmpty, let first = leftItems.first {
                leftSelection = [first.id]
            }
        } else {
            leftSelection.removeAll()
            TableDoubleClickHandler.HandlerView.leftTableView?.deselectAll(nil)
            if rightSelection.isEmpty, let first = rightItems.first {
                rightSelection = [first.id]
            }
        }
        activePane = newSide
        TableDoubleClickHandler.HandlerView.setActiveSide(newSide)
        saveSession()
    }
    
    // MARK: - Tabs Management
    public func addTab(side: PaneSide) {
        if side == .left {
            let tab = PanelTab(
                title: URL(fileURLWithPath: leftPath).lastPathComponent,
                path: leftPath,
                source: leftSource
            )
            leftTabs.append(tab)
            leftActiveTabId = tab.id
        } else {
            let tab = PanelTab(
                title: URL(fileURLWithPath: rightPath).lastPathComponent,
                path: rightPath,
                source: rightSource
            )
            rightTabs.append(tab)
            rightActiveTabId = tab.id
        }
        saveSession()
    }
    
    public func closeTab(id: UUID, side: PaneSide) {
        if side == .left && leftTabs.count > 1 {
            if let tab = leftTabs.first(where: { $0.id == id }), tab.isPinned {
                return // Закрепленную вкладку нельзя закрыть
            }
            leftTabs.removeAll(where: { $0.id == id })
            if leftActiveTabId == id, let first = leftTabs.first {
                switchTab(id: first.id, side: .left)
            } else {
                saveSession()
            }
        } else if side == .right && rightTabs.count > 1 {
            if let tab = rightTabs.first(where: { $0.id == id }), tab.isPinned {
                return // Закрепленную вкладку нельзя закрыть
            }
            rightTabs.removeAll(where: { $0.id == id })
            if rightActiveTabId == id, let first = rightTabs.first {
                switchTab(id: first.id, side: .right)
            } else {
                saveSession()
            }
        }
    }
    
    public func togglePinTab(id: UUID, side: PaneSide) {
        if side == .left {
            if let index = leftTabs.firstIndex(where: { $0.id == id }) {
                leftTabs[index].isPinned.toggle()
                if leftTabs[index].isPinned {
                    let name = URL(fileURLWithPath: leftPath).lastPathComponent
                    leftTabs[index].title = (name.isEmpty || leftPath == "/") ? (leftSource == .localMac ? "Домой" : "0") : name
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
                    let name = URL(fileURLWithPath: rightPath).lastPathComponent
                    rightTabs[index].title = (name.isEmpty || rightPath == "/") ? (rightSource == .localMac ? "Домой" : "0") : name
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
                switchTab(id: newTab.id, side: .left)
                statusMessage = "Вкладка дублирована: \(newTab.title)"
                saveSession()
            }
        } else {
            if let index = rightTabs.firstIndex(where: { $0.id == id }) {
                let current = rightTabs[index]
                let newTab = PanelTab(title: current.title, path: current.path, source: current.source, isPinned: false)
                rightTabs.insert(newTab, at: index + 1)
                switchTab(id: newTab.id, side: .right)
                statusMessage = "Вкладка дублирована: \(newTab.title)"
                saveSession()
            }
        }
    }
    
    public func switchTab(id: UUID, side: PaneSide) {
        if side == .left, let tab = leftTabs.first(where: { $0.id == id }) {
            leftActiveTabId = id
            leftPath = tab.path
            leftSource = tab.source
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
    
    // MARK: - Memoized Display Items
    private struct DisplayCache {
        var version: Int
        var rawCount: Int
        var filter: String
        var sortField: SortField
        var sortAsc: Bool
        var showHidden: Bool
        var comparing: Bool
        var hideIdentical: Bool
        var result: [FileItem]
    }
    
    private var leftDisplayCache: DisplayCache?
    private var rightDisplayCache: DisplayCache?
    
    public func displayItems(for side: PaneSide) -> [FileItem] {
        let raw = (side == .left) ? leftItems : rightItems
        let filter = (side == .left) ? leftFilter : rightFilter
        let sortField = (side == .left) ? leftSortField : rightSortField
        let sortAsc = (side == .left) ? leftSortAscending : rightSortAscending
        let showHidden = (side == .left) ? leftShowHidden : rightShowHidden
        let comparing = isComparing
        let hideIdentical = hideIdenticalInComparison
        
        let version = (side == .left) ? leftItemsVersion : rightItemsVersion
        let rawCount = raw.count
        
        if side == .left, let cache = leftDisplayCache,
           cache.version == version,
           cache.rawCount == rawCount,
           cache.filter == filter,
           cache.sortField == sortField,
           cache.sortAsc == sortAsc,
           cache.showHidden == showHidden,
           cache.comparing == comparing,
           cache.hideIdentical == hideIdentical {
            return cache.result
        }
        
        if side == .right, let cache = rightDisplayCache,
           cache.version == version,
           cache.rawCount == rawCount,
           cache.filter == filter,
           cache.sortField == sortField,
           cache.sortAsc == sortAsc,
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
        
        let sorted = filtered.sorted { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory && !b.isDirectory
            }
            switch sortField {
            case .name:
                let cmp = a.name.localizedStandardCompare(b.name)
                return sortAsc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
            case .size:
                return sortAsc ? (a.size < b.size) : (a.size > b.size)
            case .date:
                return sortAsc ? (a.mtime < b.mtime) : (a.mtime > b.mtime)
            }
        }
        
        let newCache = DisplayCache(
            version: version,
            rawCount: rawCount,
            filter: filter,
            sortField: sortField,
            sortAsc: sortAsc,
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
    
    // MARK: - Directory Comparison
    public func comparePanes() {
        if isComparing {
            isComparing = false
            hideIdenticalInComparison = false
            comparisonResult = DirectoryComparisonResult()
            statusMessage = "Сравнение каталогов отключено"
        } else {
            isComparing = true
            comparisonResult = comparator.compare(left: leftItems, right: rightItems)
            statusMessage = "Сравнение: одинаковых: \(comparisonResult.identical.count), измененных: \(comparisonResult.different.count), слева: \(comparisonResult.onlyLeft.count), справа: \(comparisonResult.onlyRight.count)"
        }
    }
    
    public func selectDifferences() {
        guard isComparing else { return }
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
        guard isComparing else { return }
        
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
        let tempSource = leftSource
        let tempPath = leftPath
        let tempItems = leftItems
        let tempSelection = leftSelection
        let tempFilter = leftFilter
        let tempSortField = leftSortField
        let tempSortAscending = leftSortAscending
        let tempFreeSpace = leftFreeSpace
        let tempIsStale = leftIsStale
        let tempTabs = leftTabs
        let tempActiveTabId = leftActiveTabId
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
        rightFreeSpace = tempFreeSpace
        rightIsStale = tempIsStale
        rightTabs = tempTabs
        rightActiveTabId = tempActiveTabId
        rightViewMode = tempViewMode
        rightGridThumbnailSize = tempThumbnailSize
        rightGridSpacing = tempSpacing
        
        statusMessage = "Панели поменяны местами"
        saveSession()
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
    
    /// Обновление заголовка, пути и источника активной вкладки
    public func updateActiveTab(side: PaneSide) {
        if side == .left {
            if let idx = leftTabs.firstIndex(where: { $0.id == leftActiveTabId }) {
                guard !leftTabs[idx].isPinned else { return }
                let name = URL(fileURLWithPath: leftPath).lastPathComponent
                leftTabs[idx].title = (name.isEmpty || leftPath == "/") ? (leftSource == .localMac ? "Домой" : "0") : name
                leftTabs[idx].path = leftPath
                leftTabs[idx].source = leftSource
            }
        } else {
            if let idx = rightTabs.firstIndex(where: { $0.id == rightActiveTabId }) {
                guard !rightTabs[idx].isPinned else { return }
                let name = URL(fileURLWithPath: rightPath).lastPathComponent
                rightTabs[idx].title = (name.isEmpty || rightPath == "/") ? (rightSource == .localMac ? "Домой" : "0") : name
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
            if newSource == .localMac {
                if leftPath.hasPrefix("/storage") || !FileManager.default.fileExists(atPath: leftPath) {
                    leftPath = FileManager.default.homeDirectoryForCurrentUser.path
                }
                leftIsStale = false
            } else {
                if !leftPath.hasPrefix("/storage") {
                    leftPath = "/storage/emulated/0"
                }
                leftIsStale = false
            }
            leftSelection.removeAll()
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
            if newSource == .localMac {
                if rightPath.hasPrefix("/storage") || !FileManager.default.fileExists(atPath: rightPath) {
                    rightPath = FileManager.default.homeDirectoryForCurrentUser.path
                }
                rightIsStale = false
            } else {
                if !rightPath.hasPrefix("/storage") {
                    rightPath = "/storage/emulated/0"
                }
                rightIsStale = false
            }
            rightSelection.removeAll()
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
        isExplicit: Bool = true
    ) {
        guard !isConnectingPhone else { return }
        isConnectingPhone = true
        if leftSource == .remotePhone { leftIsStale = false }
        if rightSource == .remotePhone { rightIsStale = false }
        if isExplicit {
            statusMessage = "Поиск и подключение телефона..."
        }
        
        Task { @MainActor in
            defer { self.isConnectingPhone = false }
            let success = await ConnectionController.shared.connect(
                targetCandidate: targetPath,
                customHost: customHost,
                customPort: customPort,
                preferredDeviceId: preferredDeviceId,
                isExplicitUserAction: isExplicit,
                viewModel: self
            )
            if success {
                self.leftIsStale = false
                self.rightIsStale = false
                if forceActivate && self.rightSource != .remotePhone && self.leftSource != .remotePhone {
                    self.changeSource(to: .remotePhone, side: .right)
                } else {
                    if self.leftSource == .remotePhone { self.refreshPane(side: .left) }
                    if self.rightSource == .remotePhone { self.refreshPane(side: .right) }
                }
                self.refreshDetectedVolumes()
            } else {
                if self.leftSource == .remotePhone { self.leftIsStale = true }
                if self.rightSource == .remotePhone { self.rightIsStale = true }
                self.refreshUsbDrives()
            }
        }
    }
    
    /// Явное отключение телефона пользователем с завершением дочерних процессов
    public func disconnectPhone() {
        ConnectionController.shared.disconnect(viewModel: self)
        refreshUsbDrives()
        if leftSource == .remotePhone { refreshPane(side: .left) }
        if rightSource == .remotePhone { refreshPane(side: .right) }
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
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            // 1. Проверяем наличие USB-устройства через ADB и его политику autoConnect
            var chosenCandidate: CandidatePath? = nil
            var chosenUsbDeviceId: String? = nil
            for id in PhoneConnectionManager.shared.authorizedAdbDeviceIds() {
                if let dev = DeviceRegistry.shared.device(withId: id), dev.autoConnect {
                    chosenUsbDeviceId = id
                    break
                }
            }
            
            // 2. Если по USB не обнаружен, сканируем Wi-Fi для доверенных устройств с autoConnect == true
            if chosenUsbDeviceId == nil {
                if let foundIp = PhoneConnectionManager.shared.discoverPhoneIpOnLan() {
                    let dev = DeviceRegistry.shared.device(matchingHost: foundIp)
                    if dev?.autoConnect == true {
                        let isV6 = foundIp.contains(":")
                        chosenCandidate = .lan(host: foundIp, port: 2222, isV6: isV6)
                    }
                }
            }

            let candidateToConnect = chosenCandidate
            let usbDeviceToConnect = chosenUsbDeviceId
            await MainActor.run {
                self.isAutoConnecting = false
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
        guard !isConnectingPhone && !connectionProbeRunning else { return }
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
            if targetPath.hasPrefix("/storage") || !FileManager.default.fileExists(atPath: targetPath) {
                targetPath = FileManager.default.homeDirectoryForCurrentUser.path
            }
        } else if source == .remotePhone {
            if !targetPath.hasPrefix("/storage") {
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
        var path = (side == .left) ? leftPath : rightPath
        let source = (side == .left) ? leftSource : rightSource
        
        // Автокоррекция пути при несоответствии платформе: для Mac всегда реальный локальный путь
        if source == .localMac {
            if path.hasPrefix("/storage") || !FileManager.default.fileExists(atPath: path) {
                path = FileManager.default.homeDirectoryForCurrentUser.path
                if side == .left { leftPath = path } else { rightPath = path }
                updateActiveTab(side: side)
            }
        } else if source == .remotePhone {
            if !path.hasPrefix("/storage") {
                path = "/storage/emulated/0"
                if side == .left { leftPath = path } else { rightPath = path }
                updateActiveTab(side: side)
            }
        }
        
        let driver: FileSystemDriver = (source == .localMac) ? localDriver : remoteDriver
        
        if side == .left {
            leftIsRefreshing = true
            leftRefreshTask?.cancel()
        } else {
            rightIsRefreshing = true
            rightRefreshTask?.cancel()
        }
        
        let task = Task { @MainActor in
            if side == .left {
                self.leftIsRefreshing = true
            } else {
                self.rightIsRefreshing = true
            }
            defer {
                if side == .left {
                    self.leftIsRefreshing = false
                } else {
                    self.rightIsRefreshing = false
                }
            }
            do {
                let items = try await driver.listDirectory(at: path)
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
                if self.isComparing {
                    self.comparisonResult = self.comparator.compare(left: self.leftItems, right: self.rightItems)
                }
                
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
            unarchive(item: item, side: side)
        } else {
            openFile(item: item)
        }
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
        
        let parentPath = URL(fileURLWithPath: targetItem.path).deletingLastPathComponent().path
        let newPath = (parentPath as NSString).appendingPathComponent(trimmed).precomposedStringWithCanonicalMapping
        let driver: FileSystemDriver = (targetItem.source == .localMac) ? localDriver : remoteDriver
        
        Task {
            do {
                try await driver.renameItem(from: targetItem.path, to: newPath)
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
        
        let parentPath = URL(fileURLWithPath: item.path).deletingLastPathComponent().path
        let newPath = (parentPath as NSString).appendingPathComponent(trimmed).precomposedStringWithCanonicalMapping
        let driver: FileSystemDriver = (item.source == .localMac) ? localDriver : remoteDriver
        let side: PaneSide = (item.source == leftSource && leftItems.contains(where: { $0.id == item.id })) ? .left : .right
        
        Task {
            do {
                try await driver.renameItem(from: item.path, to: newPath)
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
        startTransfer(isMove: false)
    }
    
    public func triggerMove() {
        startTransfer(isMove: true)
    }
    
    public func triggerDelete() {
        let selectedCount = (activePane == .left) ? leftSelection.count : rightSelection.count
        guard selectedCount > 0 else {
            statusMessage = "Нет выбранных объектов для удаления"
            return
        }
        showDeleteConfirmDialog = true
    }
    
    public func confirmDelete() {
        let side = activePane
        let selectedIds = (side == .left) ? leftSelection : rightSelection
        let source = (side == .left) ? leftSource : rightSource
        let driver: FileSystemDriver = (source == .localMac) ? localDriver : remoteDriver
        
        Task {
            var failedCount = 0
            for id in selectedIds {
                do {
                    try await driver.deleteItem(at: id, moveToTrash: source == .localMac)
                } catch {
                    failedCount += 1
                }
            }
            if side == .left {
                self.leftSelection.removeAll()
            } else {
                self.rightSelection.removeAll()
            }
            self.refreshPane(side: side)
            if failedCount > 0 {
                let successCount = selectedIds.count - failedCount
                self.statusMessage = "Удалено: \(successCount), с ошибкой: \(failedCount)"
            } else {
                self.statusMessage = "Удалено объектов: \(selectedIds.count)"
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
        if let side, activePane != side { activePane = side }
        newFolderName = ""
        newFolderSelectedItems = []
        showNewFolderDialog = true
    }

    public func prepareNewFolderWithSelection(item: FileItem, side: PaneSide) {
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
        
        // Интеграция с системным буфером обмена macOS
        NSPasteboard.general.clearContents()
        if currentSource == .localMac {
            let urls = targetItems.map { URL(fileURLWithPath: $0.path) }
            NSPasteboard.general.writeObjects(urls as [NSURL])
        } else {
            let names = targetItems.map(\.name).joined(separator: "\n")
            NSPasteboard.general.setString(names, forType: .string)
        }
        
        statusMessage = "Скопировано в буфер: \(targetItems.count) объектов"
    }
    
    public func pasteFromClipboard(targetSide: PaneSide? = nil) {
        let destSide = targetSide ?? activePane
        let destPath = (destSide == .left) ? leftPath : rightPath
        let destSource = (destSide == .left) ? leftSource : rightSource
        
        // 1. Проверяем внутренний буфер приложения
        if !clipboardItems.isEmpty {
            let source = clipboardSource
            let itemsToPaste = clipboardItems
            
            if source == destSource {
                // Копирование в пределах одного хранилища
                Task {
                    var successCount = 0
                    for item in itemsToPaste {
                        let originalURL = URL(fileURLWithPath: item.path)
                        var targetName = originalURL.lastPathComponent
                        
                        // Если вставляем в ту же самую папку — генерируем имя "(копия)"
                        if originalURL.deletingLastPathComponent().path == destPath {
                            targetName = self.generateDuplicateName(baseName: item.name, in: (destSide == .left ? self.leftItems : self.rightItems))
                        }
                        
                        let targetURL = URL(fileURLWithPath: destPath).appendingPathComponent(targetName)
                        do {
                            if destSource == .localMac {
                                try FileManager.default.copyItem(at: originalURL, to: targetURL)
                            } else {
                                self.queueManager.enqueue(source: item, targetDir: destPath, isMove: false)
                            }
                            successCount += 1
                        } catch {
                            print("Paste error: \(error)")
                        }
                    }
                    self.refreshPane(side: destSide)
                    self.statusMessage = "Вставлено объектов: \(successCount)"
                }
            } else {
                // Межплатформенная вставка (Mac <-> Android)
                self.executeTransfer(
                    paths: itemsToPaste.map(\.path),
                    fromSource: source,
                    toSide: destSide,
                    isMove: false
                )
            }
            return
        }
        
        // 2. Проверяем системный буфер обмена (файлы из Finder)
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let paths = urls.map(\.path)
            if destSource == .localMac {
                Task {
                    var successCount = 0
                    for url in urls {
                        let targetURL = URL(fileURLWithPath: destPath).appendingPathComponent(url.lastPathComponent)
                        try? FileManager.default.copyItem(at: url, to: targetURL)
                        successCount += 1
                    }
                    self.refreshPane(side: destSide)
                    self.statusMessage = "Вставлено из Finder: \(successCount) объектов"
                }
            } else {
                self.executeTransfer(
                    paths: paths,
                    fromSource: .localMac,
                    toSide: destSide,
                    isMove: false
                )
            }
        }
    }
    
    public func duplicateItem(item: FileItem? = nil, side: PaneSide? = nil) {
        let currentSide = side ?? activePane
        let allItems = (currentSide == .left) ? leftItems : rightItems
        let selection = (currentSide == .left) ? leftSelection : rightSelection
        let source = (currentSide == .left) ? leftSource : rightSource
        
        let targetItem: FileItem?
        if let item = item {
            targetItem = item
        } else if let firstId = selection.first,
                  let found = allItems.first(where: { $0.id == firstId || $0.path == firstId }) {
            targetItem = found
        } else {
            targetItem = allItems.first
        }
        
        guard let target = targetItem else {
            statusMessage = "Нет выбранного объекта для дублирования"
            return
        }
        
        let newName = generateDuplicateName(baseName: target.name, in: allItems)
        let dir = URL(fileURLWithPath: target.path).deletingLastPathComponent().path
        let newPath = URL(fileURLWithPath: dir).appendingPathComponent(newName).path
        
        Task {
            do {
                if source == .localMac {
                    try FileManager.default.copyItem(atPath: target.path, toPath: newPath)
                } else {
                    let dupItem = FileItem(id: target.id, name: target.name, path: target.path, size: target.size, mtime: target.mtime, isDirectory: target.isDirectory, source: .remotePhone)
                    self.queueManager.enqueue(source: dupItem, targetDir: dir, isMove: false)
                }
                self.refreshPane(side: currentSide)
                self.statusMessage = "Создан дубликат: \(newName)"
            } catch {
                self.errorMessage = "Не удалось дублировать: \(error.localizedDescription)"
                self.showErrorAlert = true
            }
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
        
        Task {
            var renamedCount = 0
            var history: [(oldPath: String, newPath: String)] = []
            for mapping in mappings {
                guard mapping.oldItem.name != mapping.newName else { continue }
                let dir = URL(fileURLWithPath: mapping.oldItem.path).deletingLastPathComponent().path
                let canonicalNewName = mapping.newName.precomposedStringWithCanonicalMapping
                let newPath = URL(fileURLWithPath: dir).appendingPathComponent(canonicalNewName).path
                do {
                    try await driver.renameItem(from: mapping.oldItem.path, to: newPath)
                    renamedCount += 1
                    history.append((oldPath: mapping.oldItem.path, newPath: newPath))
                } catch {
                    print("Rename error for \(mapping.oldItem.name): \(error)")
                }
            }
            if !history.isEmpty {
                self.lastBatchRenameHistory = history
                self.lastBatchRenameSide = targetSide
                self.canUndoBatchRename = true
            }
            self.refreshPane(side: targetSide)
            self.statusMessage = "Успешно переименовано объектов: \(renamedCount)"
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
    
    public func confirmCreateArchive() {
        guard !archiveTargetItems.isEmpty else { return }
        let trimmedName = archiveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        let format = archiveFormat
        let targetItems = archiveTargetItems
        let destPath = archiveDestinationPath
        let destFullURL = URL(fileURLWithPath: destPath).appendingPathComponent(trimmedName)
        let activeSide = activePane
        let source = (activeSide == .left) ? leftSource : rightSource
        
        isArchiving = true
        statusMessage = "Создание архива: \(trimmedName)..."
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                if source == .localMac {
                    let sourcePaths = targetItems.map { $0.path }
                    try await ArchiveService.shared.createArchive(
                        sources: sourcePaths,
                        destinationPath: destFullURL.path,
                        format: format
                    )
                } else {
                    // Телефон (Remote SFTP): скачиваем во временный каталог, архивируем
                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("MacDroidArchive_\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    
                    var downloadedPaths: [String] = []
                    for item in targetItems {
                        let localDest = tempDir.appendingPathComponent(item.name)
                        let stat = try await self.transport.prepareRead(actionId: UUID().uuidString, path: item.path)
                        try await self.transport.downloadFileStreaming(
                            actionId: UUID().uuidString,
                            remotePath: item.path,
                            targetURL: localDest,
                            totalSize: stat.size
                        ) { _ in }
                        downloadedPaths.append(localDest.path)
                    }
                    
                    // Создаем архив локально
                    let tempArchiveURL = tempDir.appendingPathComponent(trimmedName)
                    try await ArchiveService.shared.createArchive(
                        sources: downloadedPaths,
                        destinationPath: tempArchiveURL.path,
                        format: format
                    )
                    
                    let destSource = (destPath.hasPrefix("/sdcard") || destPath.hasPrefix("/storage")) ? FileSource.remotePhone : FileSource.localMac
                    if destSource == .localMac {
                        let finalDest = URL(fileURLWithPath: destPath).appendingPathComponent(trimmedName)
                        try? FileManager.default.removeItem(at: finalDest)
                        try FileManager.default.moveItem(at: tempArchiveURL, to: finalDest)
                    } else {
                        let archiveSize = (try? FileManager.default.attributesOfItem(atPath: tempArchiveURL.path)[.size] as? UInt64) ?? 0
                        let queueItem = FileItem(
                            id: tempArchiveURL.path,
                            name: trimmedName,
                            path: tempArchiveURL.path,
                            size: archiveSize,
                            mtime: Date().timeIntervalSince1970,
                            isDirectory: false
                        )
                        self.queueManager.enqueue(source: queueItem, targetDir: destPath, isMove: true)
                    }
                    
                    try? FileManager.default.removeItem(at: tempDir)
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
                    
                    let extractedFiles = (try? FileManager.default.contentsOfDirectory(atPath: tempExtractDir.path)) ?? []
                    for name in extractedFiles {
                        let localFilePath = tempExtractDir.appendingPathComponent(name).path
                        let isDir = (try? FileManager.default.attributesOfItem(atPath: localFilePath)[.type] as? FileAttributeType) == .typeDirectory
                        let size = (try? FileManager.default.attributesOfItem(atPath: localFilePath)[.size] as? UInt64) ?? 0
                        let queueItem = FileItem(
                            id: localFilePath,
                            name: name,
                            path: localFilePath,
                            size: size,
                            mtime: Date().timeIntervalSince1970,
                            isDirectory: isDir
                        )
                        self.queueManager.enqueue(source: queueItem, targetDir: destinationPath, isMove: true)
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
                        
                        let extractedFiles = (try? FileManager.default.contentsOfDirectory(atPath: tempExtractDir.path)) ?? []
                        for name in extractedFiles {
                            let localFilePath = tempExtractDir.appendingPathComponent(name).path
                            let isDir = (try? FileManager.default.attributesOfItem(atPath: localFilePath)[.type] as? FileAttributeType) == .typeDirectory
                            let size = (try? FileManager.default.attributesOfItem(atPath: localFilePath)[.size] as? UInt64) ?? 0
                            let queueItem = FileItem(
                                id: localFilePath,
                                name: name,
                                path: localFilePath,
                                size: size,
                                mtime: Date().timeIntervalSince1970,
                                isDirectory: isDir
                            )
                            self.queueManager.enqueue(source: queueItem, targetDir: destinationPath, isMove: true)
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
    
    // MARK: - Folder Size Calculation (Space Key)
    public func calculateFolderSize(for item: FileItem, side: PaneSide) {
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
            self.statusMessage = "Папка '\(item.name)': \(self.formatBytes(size))"
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
            dragPaths = Array(currentSelection)
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
        var localPaths: [String] = []
        let group = DispatchGroup()
        
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    defer { group.leave() }
                    if let url = url {
                        localPaths.append(url.path)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    defer { group.leave() }
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        localPaths.append(url.path)
                    } else if let url = item as? URL {
                        localPaths.append(url.path)
                    } else if let nsurl = item as? NSURL, let p = nsurl.path {
                        localPaths.append(p)
                    } else if let str = item as? String {
                        if str.hasPrefix("file://"), let u = URL(string: str) {
                            localPaths.append(u.path)
                        } else {
                            localPaths.append(str)
                        }
                    }
                }
            }
        }
        
        group.notify(queue: .main) {
            if !localPaths.isEmpty {
                self.executeTransfer(
                    paths: localPaths,
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
    
    public func executeTransfer(
        paths: [String],
        fromSource: FileSource,
        toSide: PaneSide,
        targetDirPath: String? = nil,
        isMove: Bool
    ) {
        guard !paths.isEmpty else { return }
        
        let targetSource = (toSide == .left) ? leftSource : rightSource
        let targetDirPath = targetDirPath ?? ((toSide == .left) ? leftPath : rightPath)
        
        showTransferProgress = true
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
            let strategy = rememberedStrategy ?? .overwrite
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
                
                let jobId = UUID().uuidString
                let itemId = UUID().uuidString
                let path = file.sourcePath
                let fileName = file.fileName
                let fileSize = file.size
                let targetSubDir = file.targetDirPath
                let targetSubDirURL = URL(fileURLWithPath: targetSubDir)
                
                let actionVerb = isMove ? "Перемещение: " : "Копирование: "
                self.currentTransferFileName = fileName
                self.statusMessage = "\(actionVerb)\(fileName)"
                
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
                                strategy: strategy,
                                progress: onProgress
                            )
                        } else {
                            result = try await orchestrator.executeCopyMacToPhone(
                                jobId: jobId,
                                itemId: itemId,
                                localSourceURL: localURL,
                                remoteTargetDir: targetSubDir,
                                strategy: strategy,
                                progress: onProgress
                            )
                        }
                        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
                        let wasTransferred: Bool
                        switch result {
                        case .transferred, .transferredWithoutSourceDeletion:
                            wasTransferred = true
                        case .skipped:
                            wasTransferred = false
                        }
                        if mediaExtensions.contains(ext) && wasTransferred {
                            let remoteTargetFilePath = (targetSubDir as NSString).appendingPathComponent(fileName)
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
                                strategy: strategy,
                                progress: onProgress
                            )
                        } else {
                            result = try await orchestrator.executeCopyPhoneToMac(
                                jobId: jobId,
                                itemId: itemId,
                                remotePath: path,
                                localTargetDir: targetSubDirURL,
                                strategy: strategy,
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
                                strategy: strategy,
                                progress: onProgress
                            )
                        } else {
                            result = try await orchestrator.executeCopyMacToMac(
                                jobId: jobId,
                                itemId: itemId,
                                localSourceURL: localURL,
                                localTargetDir: targetSubDirURL,
                                strategy: strategy,
                                progress: onProgress
                            )
                        }
                        
                    case (.remotePhone, .remotePhone):
                        let targetPath = (targetSubDir as NSString).appendingPathComponent(fileName)
                        if isMove {
                            let ok = try await orchestrator.transport.executeRename(oldPath: path, newPath: targetPath)
                            if ok {
                                result = .transferred
                            } else if PhoneConnectionManager.shared.copyFileOnDevice(sourcePath: path, targetPath: targetPath) {
                                // Обработка EXDEV (Cross-device link): если перенос между разделами (SD-карта / память), копируем и удаляем оригинал
                                _ = try? await orchestrator.transport.executeDelete(actionId: itemId, path: path)
                                onProgress(1.0)
                                result = .transferred
                            } else {
                                result = .skipped(reason: "Не удалось переименовать или переместить на телефоне (защита Scoped Storage или разные разделы)")
                            }
                        } else {
                            // Оптимизация P1: Прямое серверное копирование файла внутри телефона без прокачки 20 ГБ трафика через Mac
                            if PhoneConnectionManager.shared.copyFileOnDevice(sourcePath: path, targetPath: targetPath) {
                                onProgress(1.0)
                                result = .transferred
                            } else {
                                // Фоллбэк: если прямое копирование на телефоне недоступно (нет ADB / беспроводной SFTP без shell)
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
                                result = try await orchestrator.executeCopyMacToPhone(
                                    jobId: jobId,
                                    itemId: itemId,
                                    localSourceURL: tempLocalURL,
                                    remoteTargetDir: targetSubDir,
                                    strategy: strategy,
                                    progress: onProgress
                                )
                                try? FileManager.default.removeItem(at: tempLocalURL)
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
            
            // Если перемещение (Move): удаляем исходные папки ТОЛЬКО если они стали ПУСТЫМИ!
            // Если внутри папки остался хотя бы один пропущенный или непереданный файл,
            // rmdir / deleteEmptyDirectory не удалит папку, сохранив её вместе с файлами.
            if isMove && !Task.isCancelled {
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
            
            if Task.isCancelled {
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
            
            if Task.isCancelled {
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
                
                // Отображаем успешное завершение в окне прогресса 1.8 секунды и автоматически закрываем
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                self.showTransferProgress = false
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
            if fromSource == .localMac {
                var isDirectoryObjC: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectoryObjC)
                isDir = exists && isDirectoryObjC.boolValue
            } else {
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
            }
            
            if !isDir {
                let size: UInt64
                if fromSource == .localMac {
                    size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
                } else {
                    size = remoteStatSize ?? 0
                }
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
                
                if fromSource == .localMac {
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
                } else {
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
        }
        
        // Сортируем каталоги по длине пути по убыванию (deepest first / post-order),
        // чтобы при переносе сначала удалялись самые глубокие пустые подпапки
        sourceFoldersToDeleteOnMove.sort { $0.count > $1.count }
        
        return (directoriesToCreate, filesToTransfer, sourceFoldersToDeleteOnMove, skippedFolders)
    }
    
    private func startTransfer(isMove: Bool) {
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
        executeTransfer(paths: Array(selected), fromSource: fromSource, toSide: targetSide, isMove: isMove)
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
