import SwiftUI

public struct NewFolderModalView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    @Environment(\.dismiss) var dismiss
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 16) {
            Text("Создание новой папки")
                .font(.headline)
            
            TextField("Имя каталога", text: $vm.newFolderName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            
            HStack(spacing: 12) {
                Button("Отмена") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Создать") {
                    vm.createFolder()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}

public struct TransferProgressModalView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 16) {
            Text("Передача файлов")
                .font(.headline)
            
            ProgressView(value: vm.transferProgress, total: 1.0)
                .progressViewStyle(.linear)
                .frame(width: 340)
            
            HStack {
                Text(String(format: "%.0f %%", vm.transferProgress * 100))
                    .font(.subheadline)
                    .fontWeight(.bold)
                Spacer()
                Text(vm.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 340)
        }
        .padding(24)
    }
}
