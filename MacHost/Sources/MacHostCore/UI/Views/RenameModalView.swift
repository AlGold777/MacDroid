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
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(ConflictColors.nameText)
                .padding(.vertical, 2)
                .padding(.horizontal, 5)
                .background(ConflictColors.renameInputBg)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(ConflictColors.inputFocusBorder, lineWidth: 1)
                )
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
