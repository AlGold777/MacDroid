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
        .sheet(isPresented: $vm.showTransferProgress) {
            TransferProgressModalView()
        }
        .sheet(isPresented: $vm.showImageViewer) {
            ImageViewerModalView(images: vm.viewerImages, startIndex: vm.viewerStartIndex)
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
                Text("Вы действительно хотите переместить в Корзину \(count) выбраных объектов?")
            } else {
                Text("ВНИМАНИЕ: На телефоне нет общей Корзины. \(count) объектов будут УДАЛЕНЫ БЕЗВОЗВРАТНО!")
            }
        }
    }
}
