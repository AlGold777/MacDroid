import Foundation
import SwiftUI
import AppKit

public enum SortField: String, CaseIterable, Sendable {
    case name = "Имя"
    case size = "Размер"
    case date = "Дата"
}

public enum PaneSide: Sendable {
    case left, right
}

@MainActor
public final class DualPaneViewModel: ObservableObject {
    @Published public var activePane: PaneSide = .left
    
    // Левая панель
    @Published public var leftSource: FileSource = .localMac
    @Published public var leftPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    @Published public var leftItems: [FileItem] = []
    @Published public var leftSelection: Set<String> = []
    @Published public var leftFilter: String = ""
    @Published public var leftSortField: SortField = .name
    @Published public var leftSortAscending: Bool = true
    @Published public var leftFreeSpace: (free: UInt64, total: UInt64) = (0, 0)
    @Published public var leftIsStale: Bool = false
    
    // Правая панель
    @Published public var rightSource: FileSource = .remotePhone
    @Published public var rightPath: String = "/storage/emulated/0/DCIM"
    @Published public var rightItems: [FileItem] = []
    @Published public var rightSelection: Set<String> = []
    @Published public var rightFilter: String = ""
    @Published public var rightSortField: SortField = .name
    @Published public var rightSortAscending: Bool = true
    @Published public var rightFreeSpace: (free: UInt64, total: UInt64) = (0, 0)
    @Published public var rightIsStale: Bool = false
    
    // Диалоги и задачи
    @Published public var showNewFolderDialog: Bool = false
    @Published public var showDeleteConfirmDialog: Bool = false
    @Published public var showTransferProgress: Bool = false
    @Published public var transferProgress: Double = 0.0
    @Published public var statusMessage: String = "Готов к работе"
    @Published public var newFolderName: String = ""
    
    // Просмотр изображений и галерея
    @Published public var showImageViewer: Bool = false
    @Published public var viewerImages: [FileItem] = []
    @Published public var viewerStartIndex: Int = 0
    
    public let localDriver = LocalFSDriver()
    public let remoteDriver = RemoteSFTPDriver()
    public let discoveryService = DiscoveryService()
    
    private let transport = TransportMultiplexer()
    private lazy var orchestrator: JobOrchestrator = {
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("mac_android_ledger.db")
        let ledger = try! IntentLedger(databaseURL: dbURL)
        return JobOrchestrator(ledger: ledger, transport: transport, localFS: localDriver)
    }()
    
    public init() {
        refreshPane(side: .left)
        refreshPane(side: .right)
        discoveryService.startDiscovery()
    }
    
    public func toggleActivePane() {
        activePane = (activePane == .left) ? .right : .left
    }
    
    public func swapPanes() {
        // Полный обмен состояниями левой и правой панели
        let tempSource = leftSource
        let tempPath = leftPath
        let tempItems = leftItems
        let tempSelection = leftSelection
        let tempFilter = leftFilter
        let tempSortField = leftSortField
        let tempSortAscending = leftSortAscending
        let tempFreeSpace = leftFreeSpace
        let tempIsStale = leftIsStale
        
        leftSource = rightSource
        leftPath = rightPath
        leftItems = rightItems
        leftSelection = rightSelection
        leftFilter = rightFilter
        leftSortField = rightSortField
        leftSortAscending = rightSortAscending
        leftFreeSpace = rightFreeSpace
        leftIsStale = rightIsStale
        
        rightSource = tempSource
        rightPath = tempPath
        rightItems = tempItems
        rightSelection = tempSelection
        rightFilter = tempFilter
        rightSortField = tempSortField
        rightSortAscending = tempSortAscending
        rightFreeSpace = tempFreeSpace
        rightIsStale = tempIsStale
        
        statusMessage = "Панели поменяны местами"
    }
    
    public func refreshPane(side: PaneSide) {
        let source = (side == .left) ? leftSource : rightSource
        let path = (side == .left) ? leftPath : rightPath
        let driver: FileSystemDriver = (source == .localMac) ? localDriver : remoteDriver
        
        Task {
            do {
                let items = try await driver.listDirectory(at: path)
                let space = try await driver.checkFreeSpace(at: path)
                
                if side == .left {
                    self.leftItems = items
                    self.leftFreeSpace = space
                    self.leftIsStale = false
                } else {
                    self.rightItems = items
                    self.rightFreeSpace = space
                    self.rightIsStale = false
                }
            } catch {
                if side == .left {
                    self.leftIsStale = true
                } else {
                    self.rightIsStale = true
                }
                self.statusMessage = "Ошибка обновления панели: \(error.localizedDescription)"
            }
        }
    }
    
    public func navigateInto(item: FileItem, side: PaneSide) {
        guard item.isDirectory else { return }
        if side == .left {
            leftPath = item.path
            leftSelection.removeAll()
            refreshPane(side: .left)
        } else {
            rightPath = item.path
            rightSelection.removeAll()
            refreshPane(side: .right)
        }
    }
    
    public func navigateUp() {
        let side = activePane
        let currentPath = (side == .left) ? leftPath : rightPath
        let parentURL = URL(fileURLWithPath: currentPath).deletingLastPathComponent()
        let parentPath = parentURL.path.precomposedStringWithCanonicalMapping
        
        guard parentPath != currentPath else { return }
        
        if side == .left {
            leftPath = parentPath
            leftSelection.removeAll()
            refreshPane(side: .left)
        } else {
            rightPath = parentPath
            rightSelection.removeAll()
            refreshPane(side: .right)
        }
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
            for id in selectedIds {
                try? await driver.deleteItem(at: id, moveToTrash: source == .localMac)
            }
            if side == .left {
                self.leftSelection.removeAll()
            } else {
                self.rightSelection.removeAll()
            }
            self.refreshPane(side: side)
            self.statusMessage = "Удалено объектов: \(selectedIds.count)"
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
    
    public func triggerQuickLook() {
        let side = activePane
        let selected = (side == .left) ? leftSelection : rightSelection
        guard let first = selected.first else { return }
        let url = URL(fileURLWithPath: first)
        
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "dng", "webp"].contains(ext) {
            let currentItems = (side == .left) ? leftItems : rightItems
            let photoItems = currentItems.filter {
                let e = URL(fileURLWithPath: $0.path).pathExtension.lowercased()
                return ["jpg", "jpeg", "png", "heic", "dng", "webp"].contains(e)
            }
            if let idx = photoItems.firstIndex(where: { $0.path == first }) {
                self.viewerImages = photoItems
                self.viewerStartIndex = idx
                self.showImageViewer = true
                return
            }
        }
        QuickLookBridge.shared.preview(url: url)
    }
    
    private func startTransfer(isMove: Bool) {
        let sourceSide = activePane
        let selected = (sourceSide == .left) ? leftSelection : rightSelection
        guard let firstSelected = selected.first else {
            statusMessage = "Выберите файлы для передачи"
            return
        }
        
        let targetDirPath = (sourceSide == .left) ? rightPath : leftPath
        let targetDirURL = URL(fileURLWithPath: targetDirPath)
        
        showTransferProgress = true
        transferProgress = 0.0
        
        Task {
            do {
                let jobId = UUID().uuidString
                let itemId = UUID().uuidString
                let fileName = URL(fileURLWithPath: firstSelected).lastPathComponent
                statusMessage = (isMove ? "Перемещение: " : "Копирование: ") + fileName
                
                if isMove {
                    try await orchestrator.executeMovePhoneToMac(
                        jobId: jobId,
                        itemId: itemId,
                        remotePath: firstSelected,
                        localTargetDir: targetDirURL
                    ) { progress in
                        Task { @MainActor in
                            self.transferProgress = progress
                        }
                    }
                } else {
                    try await orchestrator.executeCopyPhoneToMac(
                        jobId: jobId,
                        itemId: itemId,
                        remotePath: firstSelected,
                        localTargetDir: targetDirURL
                    ) { progress in
                        Task { @MainActor in
                            self.transferProgress = progress
                        }
                    }
                }
                
                self.showTransferProgress = false
                self.refreshPane(side: .left)
                self.refreshPane(side: .right)
                self.statusMessage = "Операция успешно завершена: \(fileName)"
            } catch {
                self.showTransferProgress = false
                self.statusMessage = "Ошибка: \(error.localizedDescription)"
            }
        }
    }
}
