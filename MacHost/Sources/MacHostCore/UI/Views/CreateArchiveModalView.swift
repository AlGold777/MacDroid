import SwiftUI

public struct CreateArchiveModalView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    @Environment(\.dismiss) var dismiss
    
    public init() {}
    
    private var totalSize: UInt64 {
        vm.archiveTargetItems.reduce(0) { $0 + $1.size }
    }
    
    private func updateExtension(for format: ArchiveService.ArchiveFormat) {
        let current = vm.archiveName
        let url = URL(fileURLWithPath: current)
        var base = url.deletingPathExtension().lastPathComponent
        if base.hasSuffix(".tar") {
            base = String(base.dropLast(4))
        }
        vm.archiveName = "\(base).\(format.fileExtension)"
    }
    
    public var body: some View {
        VStack(spacing: 16) {
            // Заголовок
            HStack(spacing: 10) {
                Image(systemName: "archivebox.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Создание архива (Alt+F5)")
                        .font(.headline)
                    Text("Выбрано объектов: \(vm.archiveTargetItems.count) (\(ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            Divider()
            
            // Название архива
            VStack(alignment: .leading, spacing: 6) {
                Text("Имя целевого архива:")
                    .font(.caption)
                    .fontWeight(.semibold)
                
                TextField("Имя архива...", text: $vm.archiveName)
                    .textFieldStyle(.roundedBorder)
            }
            
            // Формат архива
            VStack(alignment: .leading, spacing: 6) {
                Text("Формат сжатия:")
                    .font(.caption)
                    .fontWeight(.semibold)
                
                Picker("", selection: Binding(
                    get: { vm.archiveFormat },
                    set: { newFormat in
                        vm.archiveFormat = newFormat
                        updateExtension(for: newFormat)
                    }
                )) {
                    ForEach(ArchiveService.ArchiveFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            // Папка назначения
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Папка назначения:")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Spacer()
                    Button("В противоположную панель") {
                        let oppositePath = (vm.activePane == .left) ? vm.rightPath : vm.leftPath
                        vm.archiveDestinationPath = oppositePath
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                }
                
                Text(vm.archiveDestinationPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(4)
            }
            
            if vm.isArchiving {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Сжатие файлов в архив...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
            
            Divider()
            
            // Кнопки управления
            HStack(spacing: 12) {
                Button("Отмена (Esc)") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(vm.isArchiving)
                
                Spacer()
                
                Button("Создать архив (Enter)") {
                    vm.confirmCreateArchive()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(vm.archiveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isArchiving)
            }
        }
        .padding(20)
        .frame(minWidth: 440, maxWidth: 480)
    }
}
