import SwiftUI

public struct RenameModalView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    @Environment(\.dismiss) var dismiss
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 16) {
            Text("Переименование объекта")
                .font(.headline)
            
            if let item = vm.itemToRename {
                Text(item.name)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            TextField("Новое имя", text: $vm.renameNewName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            
            HStack(spacing: 12) {
                Button("Отмена") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Переименовать") {
                    vm.confirmRename()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(vm.renameNewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 350)
    }
}
