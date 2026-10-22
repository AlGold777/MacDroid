import SwiftUI

public struct MainContentView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 0) {
            // Двухпанельная рабочая область
            HSplitView {
                PaneView(side: .left)
                    .frame(minWidth: 350)
                PaneView(side: .right)
                    .frame(minWidth: 350)
            }
            
            Divider()
            
            // Нижний статус-бар и функциональные клавиши
            BottomToolbarView()
        }
        .sheet(isPresented: $vm.showNewFolderDialog) {
            NewFolderModalView()
        }
        .sheet(isPresented: $vm.showRenameDialog) {
            RenameModalView()
        }
        .sheet(isPresented: $vm.showPropertiesDialog) {
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
        // Закрытие без выбора (Esc, «Отмена передачи») отменяет передачу, которая ждёт решения
        .sheet(isPresented: $vm.showConflictDialog, onDismiss: { vm.resolveConflict(nil) }) {
            if let conflict = vm.activeConflict {
                ConflictResolutionModalView(conflict: conflict) { strategy, applyToAll in
                    vm.resolveConflict((strategy, applyToAll))
                }
            }
        }
        .sheet(isPresented: $vm.showImageViewer) {
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
        .alert("Ошибка файловой операции", isPresented: $vm.showErrorAlert) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(vm.errorMessage)
        }
        .alert("Подтверждение удаления", isPresented: $vm.showDeleteConfirmDialog) {
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
    }
}
