import Foundation

public extension DualPaneViewModel {
    var canStartCopyDone: Bool {
        remoteDriver.isConnected && !isPhoneTrashBusy && !showTransferProgress
            && !isTransferMinimized && !TransferQueueManager.shared.isProcessing
    }

    func openCopyDone(side: PaneSide, item: FileItem? = nil) {
        let source = side == .left ? leftSource : rightSource
        guard source == .remotePhone else { return }
        let items = item.map { contextMenuItems(for: $0, side: side) } ?? []
        copyDoneScopes = items.isEmpty
            ? [CopyDoneScope(path: side == .left ? leftPath : rightPath, isDirectory: true)]
            : items.map { CopyDoneScope(path: $0.path, isDirectory: $0.isDirectory) }
        showCopyDone = true
    }

    func acceptCopyDoneOffer() {
        showCopyDoneOffer = false
        guard remoteDriver.coordinator.sessionEpoch == copyDoneOfferEpoch else {
            statusMessage = "Подключение изменилось. Откройте copy done в контекстном меню телефона."
            return
        }
        copyDoneScopes = copyDoneOfferScopes
        showCopyDone = true
    }
}
