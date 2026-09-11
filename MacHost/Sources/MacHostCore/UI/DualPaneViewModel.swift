import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

public enum SortField: String, CaseIterable, Sendable {
    case name = "Имя"
    case size = "Размер"
    case date = "Дата"
}

public enum PaneSide: String, Sendable {
    case left = "left"
    case right = "right"
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
            }
        }
    }
    
    // Вкладки левой панели
    @Published public var leftTabs: [PanelTab] = []
    @Published public var leftActiveTabId: UUID = UUID()
    
    // Вкладки правой панели
    @Published public var rightTabs: [PanelTab] = []
    @Published public var rightActiveTabId: UUID = UUID()
    
    // Состояние левой панели
    @Published public var leftSource: FileSource = .localMac
    @Published public var leftPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    @Published public var leftItems: [FileItem] = []
    @Published public var leftSelection: Set<String> = []
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
    @Published public var rightItems: [FileItem] = []
    @Published public var rightSelection: Set<String> = []
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
    @Published public var showPropertiesDialog: Bool = false
    @Published public var propertiesItem: FileItem? = nil
    @Published public var showDeleteConfirmDialog: Bool = false
    @Published public var showTransferProgress: Bool = false
    @Published public var showQueueDialog: Bool = false
    @Published public var showBatchRenameDialog: Bool = false
    @Published public var lastBatchRenameHistory: [(oldPath: String, newPath: String)] = []
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
    @Published public var showOperationReport: Bool = false
    @Published public var isTransferCompleted: Bool = false
    @Published public var transferCompletionMessage: String = ""
    @Published public var operationReport: OperationReport? = nil
    @Published public var currentTransferTask: Task<Void, Never>? = nil
    @Published public var isTransferPaused: Bool = false
    @Published public var currentPreviewTask: Task<Void, Never>? = nil
    @Published public var isConnectingPhone: Bool = false
    
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
    
    // Вычисление размера папок по нажатию Space
    @Published public var calculatedFolderSizes: [String: UInt64] = [:]
    @Published public var calculatingFolderPaths: Set<String> = []
    
    public let localDriver = LocalFSDriver()
    public let remoteDriver = RemoteSFTPDriver()
    public let discoveryService = DiscoveryService()
    public let queueManager = TransferQueueManager.shared
    
    public let transport = TransportMultiplexer()
    private lazy var orchestrator: JobOrchestrator = {
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("mac_android_ledger.db")
        let ledger = try! IntentLedger(databaseURL: dbURL)
        return JobOrchestrator(ledger: ledger, transport: transport, localFS: localDriver)
    }()
    
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
    }
    
    public init() {
        // Восстановление сохранённого адреса телефона
        let savedHost = UserDefaults.standard.string(forKey: "lastConnectedHost") ?? "192.168.1.18"
        let savedPort = UInt16(UserDefaults.standard.integer(forKey: "lastConnectedPort"))
        let port = savedPort > 0 ? savedPort : 2222
        remoteDriver.updateEndpoint(host: savedHost, port: port)
        transport.updateEndpoint(host: savedHost, port: port)
        
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
        
        refreshPane(side: .left)
        refreshPane(side: .right)
        discoveryService.startDiscovery()
        
        // Автоматическое обнаружение и подключение смартфона по USB при старте
        if leftSource == .remotePhone || rightSource == .remotePhone {
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
    }
    
    public func clearSavedSession() {
        Self.clearSavedSession()
    }
    
    /// Восстановление состояния панелей из UserDefaults
    public func restoreSession() {
        let defaults = UserDefaults.standard
        
        if let savedLeftSource = defaults.string(forKey: SessionKey.leftSource) {
            if savedLeftSource == "MacBook (Локально)" || savedLeftSource == "MacBook" {
                leftSource = .localMac
            } else if savedLeftSource == "Xiaomi 14 Ultra (Wi-Fi/SFTP)" || savedLeftSource == "Xiaomi 14" {
                leftSource = .remotePhone
            } else if let source = FileSource(rawValue: savedLeftSource) {
                leftSource = source
            }
        }
        if let savedRightSource = defaults.string(forKey: SessionKey.rightSource) {
            if savedRightSource == "MacBook (Локально)" || savedRightSource == "MacBook" {
                rightSource = .localMac
            } else if savedRightSource == "Xiaomi 14 Ultra (Wi-Fi/SFTP)" || savedRightSource == "Xiaomi 14" {
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
            refreshPane(side: .left)
            saveSession()
        } else if side == .right, let tab = rightTabs.first(where: { $0.id == id }) {
            rightActiveTabId = id
            rightPath = tab.path
            rightSource = tab.source
            refreshPane(side: .right)
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
        var rawCount: Int
        var rawFirstId: String?
        var rawLastId: String?
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
        
        let rawCount = raw.count
        let rawFirstId = raw.first?.id
        let rawLastId = raw.last?.id
        
        if side == .left, let cache = leftDisplayCache,
           cache.rawCount == rawCount,
           cache.rawFirstId == rawFirstId,
           cache.rawLastId == rawLastId,
           cache.filter == filter,
           cache.sortField == sortField,
           cache.sortAsc == sortAsc,
           cache.showHidden == showHidden,
           cache.comparing == comparing,
           cache.hideIdentical == hideIdentical {
            return cache.result
        }
        
        if side == .right, let cache = rightDisplayCache,
           cache.rawCount == rawCount,
           cache.rawFirstId == rawFirstId,
           cache.rawLastId == rawLastId,
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
            rawCount: rawCount,
            rawFirstId: rawFirstId,
            rawLastId: rawLastId,
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
        let items = (side == .left) ? leftItems : rightItems
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
        
        statusMessage = "Панели поменяны местами"
        saveSession()
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
            }
            leftSelection.removeAll()
            updateActiveTab(side: .left)
            refreshPane(side: .left)
            if newSource == .remotePhone {
                autoConnectPhoneIfAvailable()
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
            }
            rightSelection.removeAll()
            updateActiveTab(side: .right)
            refreshPane(side: .right)
            if newSource == .remotePhone {
                autoConnectPhoneIfAvailable()
            }
        }
    }
    
    /// Обновление сетевого адреса телефона для SFTP и передачи файлов
    public func updateRemoteEndpoint(host: String, port: UInt16) {
        remoteDriver.updateEndpoint(host: host, port: port)
        transport.updateEndpoint(host: host, port: port)
        if leftSource == .remotePhone {
            refreshPane(side: .left)
        }
        if rightSource == .remotePhone {
            refreshPane(side: .right)
        }
    }
    
    /// Подключение к телефону: фоновый запуск ADB/проброс портов и авто-настройка
    public func connectPhone(forceActivate: Bool = true) {
        guard !isConnectingPhone else { return }
        isConnectingPhone = true
        statusMessage = "Поиск и подключение телефона..."
        
        Task { @MainActor in
            defer { self.isConnectingPhone = false }
            let result = await PhoneConnectionManager.shared.establishConnection()
            
            switch result {
            case .usbSuccess(let deviceId, let host, let port, let log):
                print("[PhoneConnection] Success:\n\(log)")
                self.updateRemoteEndpoint(host: host, port: port)
                _ = HostKeyStore.shared.verifyOrPin(
                    host: host,
                    port: Int(port),
                    fingerprint: "SHA256:Ed25519_Xiaomi14Ultra_DaemonFingerprint"
                )
                if forceActivate && self.rightSource != .remotePhone && self.leftSource != .remotePhone {
                    self.changeSource(to: .remotePhone, side: .right)
                } else {
                    if self.leftSource == .remotePhone { self.refreshPane(side: .left) }
                    if self.rightSource == .remotePhone { self.refreshPane(side: .right) }
                }
                self.refreshDetectedVolumes()
                self.statusMessage = "✓ Телефон подключен по USB (\(deviceId))"
                
            case .wifiSuccess(let host, let port, let name):
                UserDefaults.standard.set(host, forKey: "lastConnectedHost")
                UserDefaults.standard.set(String(port), forKey: "lastConnectedPort")
                self.updateRemoteEndpoint(host: host, port: port)
                _ = HostKeyStore.shared.verifyOrPin(
                    host: host,
                    port: Int(port),
                    fingerprint: "SHA256:Ed25519_Xiaomi14Ultra_DaemonFingerprint"
                )
                if forceActivate && self.rightSource != .remotePhone && self.leftSource != .remotePhone {
                    self.changeSource(to: .remotePhone, side: .right)
                } else {
                    if self.leftSource == .remotePhone { self.refreshPane(side: .left) }
                    if self.rightSource == .remotePhone { self.refreshPane(side: .right) }
                }
                self.refreshDetectedVolumes()
                self.statusMessage = "✓ Телефон подключен по Wi-Fi (\(name))"
                
            case .unauthorized(let deviceId, let log):
                print("[PhoneConnection] Unauthorized:\n\(log)")
                self.statusMessage = "⚠️ Телефон \(deviceId) не авторизован! Подтвердите 'Отладку по USB' на экране."
                
            case .failure(let reason, let log):
                print("[PhoneConnection] Failed:\n\(log)")
                self.statusMessage = "⚠️ \(reason)"
            }
        }
    }
    
    /// Автоматическое подключение к телефону при обнаружении USB или Wi-Fi связи
    public func autoConnectPhoneIfAvailable() {
        guard !isConnectingPhone else { return }
        guard !remoteDriver.isConnected else { return }
        guard leftSource == .remotePhone || rightSource == .remotePhone else { return }
        
        Task.detached(priority: .userInitiated) {
            // 1. Проверяем наличие USB-устройства через ADB
            var hasAdb = false
            if let adb = PhoneConnectionManager.shared.findAdbBinary() {
                let (status, out) = PhoneConnectionManager.shared.runCommand(executable: adb, arguments: ["devices"])
                if status == 0 && out.contains("\tdevice") {
                    hasAdb = true
                }
            }
            
            // 2. Если по USB не обнаружен, сканируем Wi-Fi (автоопределение)
            var hasWifi = false
            if !hasAdb {
                if PhoneConnectionManager.shared.discoverPhoneIpOnLan() != nil {
                    hasWifi = true
                }
            }
            
            if hasAdb || hasWifi {
                await MainActor.run {
                    guard self.leftSource == .remotePhone || self.rightSource == .remotePhone else { return }
                    self.connectPhone(forceActivate: false)
                }
            }
        }
    }
    
    // MARK: - Android Storage Volumes (SD-карты, OTG)
    public func refreshDetectedVolumes() {
        let volumes = PhoneConnectionManager.shared.detectStorageVolumes()
        self.detectedVolumes = volumes
    }
    
    public func switchToVolume(_ volume: PhoneConnectionManager.StorageVolume, side: PaneSide) {
        if side == .left {
            if leftSource != .remotePhone {
                leftSource = .remotePhone
            }
            leftPath = volume.path
            leftSelection.removeAll()
            updateActiveTab(side: .left)
            refreshPane(side: .left)
        } else {
            if rightSource != .remotePhone {
                rightSource = .remotePhone
            }
            rightPath = volume.path
            rightSelection.removeAll()
            updateActiveTab(side: .right)
            refreshPane(side: .right)
        }
        statusMessage = "Переход к хранилищу: \(volume.name)"
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
        if side == .left {
            leftHistoryIndex -= 1
            leftPath = leftHistory[leftHistoryIndex]
            leftSelection.removeAll()
            updateActiveTab(side: .left)
            refreshPane(side: .left)
        } else {
            rightHistoryIndex -= 1
            rightPath = rightHistory[rightHistoryIndex]
            rightSelection.removeAll()
            updateActiveTab(side: .right)
            refreshPane(side: .right)
        }
    }
    
    public func navigateForward(side: PaneSide) {
        guard canNavigateForward(side: side) else { return }
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
    
    public func refreshPane(side: PaneSide) {
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
        
        Task {
            do {
                let items = try await driver.listDirectory(at: path)
                let space = try await driver.checkFreeSpace(at: path)
                
                let isRemoteOffline = (source == .remotePhone && !self.remoteDriver.isConnected)
                if source == .remotePhone && self.remoteDriver.isConnected {
                    self.transport.rootIsEmulatedZero = self.remoteDriver.rootIsEmulatedZero
                }
                
                if side == .left {
                    self.leftItems = items
                    self.leftFreeSpace = space
                    self.leftIsStale = isRemoteOffline
                } else {
                    self.rightItems = items
                    self.rightFreeSpace = space
                    self.rightIsStale = isRemoteOffline
                }
                if isRemoteOffline {
                    self.statusMessage = "Телефон не подключен (Offline)"
                } else if source == .remotePhone {
                    self.statusMessage = "Телефон: \(path)"
                } else if source == .localMac {
                    self.statusMessage = "Mac: \(path)"
                }
                if self.isComparing {
                    self.comparisonResult = self.comparator.compare(left: self.leftItems, right: self.rightItems)
                }
            } catch {
                if side == .left {
                    self.leftItems = []
                    self.leftIsStale = (source == .remotePhone)
                } else {
                    self.rightItems = []
                    self.rightIsStale = (source == .remotePhone)
                }
                if source == .remotePhone {
                    self.statusMessage = "Телефон не подключен (Offline)"
                } else {
                    self.statusMessage = "Ошибка обновления панели: \(error.localizedDescription)"
                }
            }
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
        
        if side == .left {
            leftPath = parentPath
            leftSelection.removeAll()
            updateActiveTab(side: .left)
            refreshPane(side: .left)
        } else {
            rightPath = parentPath
            rightSelection.removeAll()
            updateActiveTab(side: .right)
            refreshPane(side: .right)
        }
    }
    
    // MARK: - Single Rename
    public func triggerRename(item: FileItem? = nil, side: PaneSide? = nil) {
        let currentSide = side ?? activePane
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
        self.showRenameDialog = true
    }
    
    public func confirmRename() {
        guard let item = itemToRename else { return }
        let trimmed = renameNewName.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
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
    
    public func createFolder() {
        guard !newFolderName.isEmpty else { return }
        let currentPath = (activePane == .left) ? leftPath : rightPath
        let source = (activePane == .left) ? leftSource : rightSource
        let driver: FileSystemDriver = (source == .localMac) ? localDriver : remoteDriver
        let targetPath = URL(fileURLWithPath: currentPath).appendingPathComponent(newFolderName).path
        
        Task {
            try? await driver.createDirectory(at: targetPath)
            self.newFolderName = ""
            self.refreshPane(side: self.activePane)
            self.statusMessage = "Папка создана: \(targetPath)"
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
    
    public func triggerBatchRename() {
        let side = activePane
        let selected = (side == .left) ? leftSelection : rightSelection
        let items = (side == .left) ? leftItems : rightItems
        if selected.isEmpty && items.isEmpty {
            statusMessage = "В текущей панели нет файлов для переименования"
            return
        }
        showBatchRenameDialog = true
    }
    
    public func applyBatchRename(mappings: [(oldItem: FileItem, newName: String)]) {
        let side = activePane
        let source = (side == .left) ? leftSource : rightSource
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
                self.canUndoBatchRename = true
            }
            self.refreshPane(side: side)
            self.statusMessage = "Успешно переименовано объектов: \(renamedCount)"
        }
    }
    
    public func undoBatchRename() {
        guard !lastBatchRenameHistory.isEmpty else { return }
        let side = activePane
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
        
        if targets.count == 1 {
            let base = URL(fileURLWithPath: targets[0].path).deletingPathExtension().lastPathComponent
            self.archiveName = "\(base).zip"
        } else {
            let dirName = URL(fileURLWithPath: currentPath).lastPathComponent
            self.archiveName = "\(dirName.isEmpty ? "Archive" : dirName).zip"
        }
        
        self.showCreateArchiveDialog = true
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
    
    public func triggerQuickLook(preferNativeQuickLook: Bool = false) {
        let side = activePane
        let selected = (side == .left) ? leftSelection : rightSelection
        let source = (side == .left) ? leftSource : rightSource
        let currentItems = (side == .left) ? leftItems : rightItems
        
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
        
        // Встроенный просмотрщик для фотографий (локальных и удалённых)
        if photoExtensions.contains(ext) && !preferNativeQuickLook {
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
    
    // MARK: - Folder Size Calculation (Space Key)
    public func calculateFolderSize(for item: FileItem, side: PaneSide) {
        guard item.isDirectory else { return }
        
        let path = item.path
        let source = (side == .left) ? leftSource : rightSource
        
        calculatingFolderPaths.insert(path)
        
        Task { @MainActor in
            let size: UInt64
            if source == .localMac {
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
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }
            
            var totalSize: UInt64 = 0
            while let fileURL = enumerator.nextObject() as? URL {
                guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                      let isDirectory = resourceValues.isDirectory,
                      !isDirectory,
                      let fileSize = resourceValues.fileSize else {
                    continue
                }
                totalSize += UInt64(fileSize)
            }
            return totalSize
        }.value
    }
    
    private func calculateFolderSizeRemote(at path: String) async -> UInt64 {
        // Fast path: adb shell du -sk -- '<path>'
        let escaped = PhoneConnectionManager.shellEscape(path)
        let res = PhoneConnectionManager.shared.executeAdbShell(command: "du -sk -- \(escaped)")
        if res.status == 0, let firstLine = res.output.components(separatedBy: CharacterSet.newlines).first {
            let tokens = firstLine.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).components(separatedBy: CharacterSet.whitespaces)
            if let first = tokens.first, let sizeKb = UInt64(first) {
                return sizeKb * 1024
            }
        }
        
        // Fallback: SFTP driver listing
        do {
            let items = try await remoteDriver.listDirectory(at: path)
            var total: UInt64 = 0
            for it in items {
                if !it.isDirectory {
                    total += it.size
                }
            }
            return total
        } catch {
            return 0
        }
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
            provider.registerItem(forTypeIdentifier: UTType.fileURL.identifier) { completionHandler, _, _ in
                let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacDroidCommander/DragOut", isDirectory: true)
                try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let localTargetURL = tempDir.appendingPathComponent(item.name)
                
                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    do {
                        try await self.orchestrator.executeCopyPhoneToMac(
                            jobId: UUID().uuidString,
                            itemId: UUID().uuidString,
                            remotePath: item.path,
                            localTargetDir: tempDir,
                            strategy: .overwrite
                        ) { _ in }
                    } catch {
                        print("DragOut download error: \(error)")
                    }
                    semaphore.signal()
                }
                _ = semaphore.wait(timeout: .now() + 30.0)
                completionHandler?(localTargetURL as NSURL, nil)
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
    public func handleDroppedProviders(_ providers: [NSItemProvider], toSide: PaneSide, isMove: Bool = false) -> Bool {
        guard !providers.isEmpty else { return false }
        
        // 1. Приоритетная проверка внутреннего перетаскивания (inter-pane drag inside app)
        if let payload = self.currentDragPayload {
            self.currentDragPayload = nil
            let fromSource: FileSource = (payload.sourceKind == "localMac") ? .localMac : .remotePhone
            let currentTargetDir = (toSide == .left) ? self.leftPath : self.rightPath
            
            let sourceDirNorm = (payload.sourceDirPath as NSString).standardizingPath
            let targetDirNorm = (currentTargetDir as NSString).standardizingPath
            let isSameDir = (payload.sourceSide == (toSide == .left ? "left" : "right")) && (sourceDirNorm == targetDirNorm)
            if isSameDir {
                self.statusMessage = "Файлы уже находятся в этой папке"
                return true
            }
            
            self.executeTransfer(
                paths: payload.paths,
                fromSource: fromSource,
                toSide: toSide,
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
                        let currentTargetDir = (toSide == .left) ? self.leftPath : self.rightPath
                        
                        let sourceDirNorm = (payload.sourceDirPath as NSString).standardizingPath
                        let targetDirNorm = (currentTargetDir as NSString).standardizingPath
                        let isSameDir = (payload.sourceSide == (toSide == .left ? "left" : "right")) && (sourceDirNorm == targetDirNorm)
                        if isSameDir {
                            self.statusMessage = "Файлы уже находятся в этой папке"
                            return
                        }
                        
                        self.executeTransfer(
                            paths: payload.paths,
                            fromSource: fromSource,
                            toSide: toSide,
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
        TransferQueueManager.shared.cancelAll()
        statusMessage = "Операция отменена"
        Task {
            await orchestrator.cleanAllActivePartFiles()
        }
    }
    
    public func executeTransfer(
        paths: [String],
        fromSource: FileSource,
        toSide: PaneSide,
        isMove: Bool
    ) {
        guard !paths.isEmpty else { return }
        
        let targetSource = (toSide == .left) ? leftSource : rightSource
        let targetDirPath = (toSide == .left) ? leftPath : rightPath
        
        showTransferProgress = true
        isTransferCompleted = false
        transferCompletionMessage = ""
        transferProgress = 0.0
        transferSpeed = ""
        transferETA = ""
        isTransferPaused = false
        
        let speedTracker = TransferSpeedTracker()
        
        currentTransferTask = Task {
            // Включаем защиту от засыпания Mac во время активной очереди
            NotificationManager.shared.beginSleepPrevention()
            defer {
                NotificationManager.shared.endSleepPrevention()
            }
            
            self.statusMessage = "Анализ файлов и структуры папок..."
            let plan = await self.resolveTransferPlan(
                paths: paths,
                fromSource: fromSource,
                targetBaseDirPath: targetDirPath
            )
            
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
                let taskId = taskIds[path]
                
                let actionVerb = isMove ? "Перемещение: " : "Копирование: "
                self.statusMessage = "\(actionVerb)\(fileName)"
                
                let onProgress: @Sendable (Double) -> Void = { @Sendable pct in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        let currentFileBytes = UInt64(Double(fileSize) * pct)
                        let totalTransferredNow = completedBytesSoFar + currentFileBytes
                        speedTracker.update(bytesTransferred: totalTransferredNow)
                        
                        let currentSpeed = speedTracker.currentSpeedBytesPerSec
                        let remainingBytes = (totalQueueBytes > totalTransferredNow) ? (totalQueueBytes - totalTransferredNow) : 0
                        let eta = speedTracker.calculateETA(remainingBytes: remainingBytes)
                        
                        self.transferSpeed = TransferSpeedTracker.formatSpeed(currentSpeed)
                        self.transferETA = TransferSpeedTracker.formatETA(eta)
                        
                        if totalQueueBytes > 0 {
                            self.transferProgress = min(1.0, Double(totalTransferredNow) / Double(totalQueueBytes))
                        } else {
                            self.transferProgress = Double(completedCount) / Double(max(1, totalCount))
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
                            result = ok ? .transferred : .skipped(reason: "Не удалось переименовать на телефоне")
                        } else {
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
                        _ = try? await self.remoteDriver.deleteEmptyDirectory(at: folder)
                    }
                }
            }
            
            // Обновление медиатеки Android (MediaScanner)
            if !transferredMediaPaths.isEmpty {
                PhoneConnectionManager.shared.notifyMediaScanner(paths: transferredMediaPaths)
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
            } else {
                self.showTransferProgress = false
                self.isTransferCompleted = false
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
    
    private func resolveTransferPlan(
        paths: [String],
        fromSource: FileSource,
        targetBaseDirPath: String
    ) async -> (directoriesToCreate: [String], filesToTransfer: [TransferPlanItem], sourceFoldersToDeleteOnMove: [String]) {
        var directoriesToCreate: [String] = []
        var filesToTransfer: [TransferPlanItem] = []
        var sourceFoldersToDeleteOnMove: [String] = []
        
        for path in paths {
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            var isDir = false
            
            if fromSource == .localMac {
                var isDirectoryObjC: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectoryObjC)
                isDir = exists && isDirectoryObjC.boolValue
            } else {
                let sourceItems = (fromSource == leftSource) ? leftItems : rightItems
                if let item = sourceItems.first(where: { $0.id == path || $0.path == path }) {
                    isDir = item.isDirectory
                } else {
                    if let _ = try? await remoteDriver.listDirectory(at: path) {
                        isDir = true
                    }
                }
            }
            
            if !isDir {
                let size: UInt64
                if fromSource == .localMac {
                    size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
                } else {
                    let sourceItems = (fromSource == leftSource) ? leftItems : rightItems
                    size = sourceItems.first(where: { $0.id == path || $0.path == path })?.size ?? 0
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
                        ) else { return }
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
                    func scanRemote(remoteDir: String, currentTargetDir: String) async {
                        guard let contents = try? await remoteDriver.listDirectory(at: remoteDir) else { return }
                        for item in contents {
                            if item.name == "." || item.name == ".." { continue }
                            if item.name.hasPrefix(".") && (item.name.contains(".part.") || item.name.hasSuffix(".mcdpart")) { continue }
                            let subTarget = (currentTargetDir as NSString).appendingPathComponent(item.name)
                            if item.isDirectory {
                                sourceFoldersToDeleteOnMove.append(item.path)
                                directoriesToCreate.append(subTarget)
                                await scanRemote(remoteDir: item.path, currentTargetDir: subTarget)
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
                    await scanRemote(remoteDir: path, currentTargetDir: folderTargetBase)
                }
            }
        }
        
        // Сортируем каталоги по длине пути по убыванию (deepest first / post-order),
        // чтобы при переносе сначала удалялись самые глубокие пустые подпапки
        sourceFoldersToDeleteOnMove.sort { $0.count > $1.count }
        
        return (directoriesToCreate, filesToTransfer, sourceFoldersToDeleteOnMove)
    }
    
    private func startTransfer(isMove: Bool) {
        var sourceSide = activePane
        var selected = (sourceSide == .left) ? leftSelection : rightSelection
        
        // Если в активной панели ничего не выбрано, но в противоположной панели есть выделение
        if selected.isEmpty {
            let oppositeSide: PaneSide = (sourceSide == .left) ? .right : .left
            let oppositeSelection = (oppositeSide == .left) ? leftSelection : rightSelection
            if !oppositeSelection.isEmpty {
                sourceSide = oppositeSide
                selected = oppositeSelection
            }
        }
        
        guard !selected.isEmpty else {
            statusMessage = "Выберите файлы для передачи"
            return
        }
        
        let targetSide: PaneSide = (sourceSide == .left) ? .right : .left
        let fromSource = (sourceSide == .left) ? leftSource : rightSource
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
