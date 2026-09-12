import SwiftUI

public struct FilePropertiesModalView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    @Environment(\.dismiss) var dismiss
    
    public init() {}
    
    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        return df
    }()
    
    public var body: some View {
        VStack(spacing: 20) {
            if let item = vm.propertiesItem {
                HStack(spacing: 16) {
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                        .font(.system(size: 44))
                        .foregroundColor(item.isDirectory ? .yellow : .blue)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.title3)
                            .fontWeight(.bold)
                            .lineLimit(2)
                        
                        Text(item.isDirectory ? "Папка с файлами" : "Файл \(URL(fileURLWithPath: item.name).pathExtension.uppercased())")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                
                Divider()
                
                VStack(spacing: 10) {
                    propertyRow(title: "Источник:", value: item.source.rawValue)
                    propertyRow(title: "Полный путь:", value: item.path)
                    if !item.isDirectory {
                        propertyRow(title: "Размер:", value: "\(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)) (\(item.size) байт)")
                    } else if let size = vm.calculatedFolderSizes[item.path] {
                        propertyRow(title: "Размер:", value: "\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) (\(size) байт)")
                    }
                    if item.mtime > 0 {
                        propertyRow(title: "Изменён:", value: Self.dateFormatter.string(from: Date(timeIntervalSince1970: item.mtime)))
                    }
                }
                
                Divider()
                
                HStack {
                    Spacer()
                    Button("Закрыть") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("Нет выбранного объекта")
                    .foregroundColor(.secondary)
                Button("Закрыть") { dismiss() }
            }
        }
        .padding(24)
        .frame(minWidth: 420, maxWidth: 500)
    }
    
    private func propertyRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .trailing)
            
            Text(value)
                .font(.system(size: 12))
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
