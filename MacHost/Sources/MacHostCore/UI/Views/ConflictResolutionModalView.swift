import SwiftUI

public struct ConflictResolutionModalView: View {
    public let conflict: ConflictContext
    public let onSelectStrategy: (ConflictResolutionStrategy, Bool) -> Void
    @Environment(\.dismiss) var dismiss
    
    @State private var applyToAll: Bool = false
    
    public init(
        conflict: ConflictContext,
        onSelectStrategy: @escaping (ConflictResolutionStrategy, Bool) -> Void
    ) {
        self.conflict = conflict
        self.onSelectStrategy = onSelectStrategy
    }
    
    public var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 24))
                Text("Конфликт имен файлов")
                    .font(.headline)
            }
            
            Text("Файл с именем «\(conflict.sourceItem.name)» уже существует в целевом расположении.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            
            // Сравнение свойств двух файлов
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Исходный файл (копируемый):")
                        .font(.caption)
                        .fontWeight(.bold)
                    Text("Размер: \(formatBytes(conflict.sourceItem.size))")
                        .font(.caption)
                    Text("Изменен: \(formatDate(conflict.sourceItem.mtime))")
                        .font(.caption)
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("Существующий файл (в цели):")
                        .font(.caption)
                        .fontWeight(.bold)
                    Text("Размер: \(formatBytes(conflict.targetItem.size))")
                        .font(.caption)
                    Text("Изменен: \(formatDate(conflict.targetItem.mtime))")
                        .font(.caption)
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
            }
            
            Toggle("Применить это действие ко всем следующим конфликтам", isOn: $applyToAll)
                .font(.caption)
                .padding(.top, 4)
            
            Divider()
            
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Button("Заменить") {
                        onSelectStrategy(.overwrite, applyToAll)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button("Заменить, если новее") {
                        onSelectStrategy(.overwriteIfNewer, applyToAll)
                        dismiss()
                    }
                    
                    Button("Автонумерация (_1)") {
                        onSelectStrategy(.autoRename, applyToAll)
                        dismiss()
                    }
                }
                
                HStack(spacing: 10) {
                    Button("Пропустить") {
                        onSelectStrategy(.skip, applyToAll)
                        dismiss()
                    }
                    
                    Button("Пропустить идентичные") {
                        onSelectStrategy(.skipIfIdentical, applyToAll)
                        dismiss()
                    }
                    
                    Button("Отмена передачи") {
                        dismiss()
                    }
                    .foregroundColor(.secondary)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 540)
    }
    
    private func formatBytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }
    
    private func formatDate(_ timestamp: Double) -> String {
        guard timestamp > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: timestamp)
        let df = DateFormatter()
        df.dateFormat = "dd.MM.yy HH:mm"
        return df.string(from: date)
    }
}
