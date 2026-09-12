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
            if vm.isTransferCompleted {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.green)
                    
                    Text("Готово!")
                        .font(.headline)
                    
                    Text(vm.transferCompletionMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    ProgressView(value: 1.0, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(.green)
                        .frame(width: 340)
                }
                .frame(width: 340)
                .transition(.opacity)
            } else {
                Text(vm.statusMessage.contains("перемещ") ? "Перемещение файлов" : "Копирование файлов")
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
                
                if !vm.transferSpeed.isEmpty || !vm.transferETA.isEmpty {
                    HStack {
                        if !vm.transferSpeed.isEmpty {
                            Label(vm.transferSpeed, systemImage: "speedometer")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        Spacer()
                        if !vm.transferETA.isEmpty {
                            Label("Осталось: \(vm.transferETA)", systemImage: "clock")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(width: 340)
                }
                
                HStack(spacing: 12) {
                    if vm.isTransferPaused {
                        Button("Возобновить") {
                            vm.resumeTransfer()
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.green)
                    } else {
                        Button("Пауза") {
                            vm.pauseTransfer()
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.orange)
                    }
                    
                    Button("Отменить копирование") {
                        vm.cancelTransfer()
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                    
                    Button("Фон") {
                        vm.minimizeTransferToBackground()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: vm.isTransferCompleted)
        .padding(24)
    }
}
