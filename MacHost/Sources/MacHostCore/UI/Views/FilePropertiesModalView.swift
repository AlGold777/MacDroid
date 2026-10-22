import SwiftUI

public struct FilePropertiesModalView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    @Environment(\.dismiss) var dismiss
    
    @State private var isPathCopied: Bool = false
    
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
                    FileItemIconView(isDirectory: item.isDirectory, fileName: item.name, size: 44)
                    
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
                    pathPropertyRow(title: "Полный путь:", path: item.path)
                    
                    if let cdate = resolvedCreationDate(for: item) {
                        propertyRow(title: "Создан:", value: Self.dateFormatter.string(from: cdate))
                    } else {
                        propertyRow(title: "Создан:", value: "—")
                    }
                    
                    if item.mtime > 0 {
                        propertyRow(title: "Изменён:", value: Self.dateFormatter.string(from: Date(timeIntervalSince1970: item.mtime)))
                    } else {
                        propertyRow(title: "Изменён:", value: "—")
                    }
                    
                    if !item.isDirectory {
                        propertyRow(title: "Размер:", value: "\(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)) (\(item.size) байт)")
                    } else if let size = vm.calculatedFolderSizes[item.path] {
                        propertyRow(title: "Размер:", value: "\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) (\(size) байт)")
                    } else if vm.calculatingFolderPaths.contains(item.path) {
                        propertyRow(title: "Размер:", value: "Вычисление...")
                    } else {
                        propertyRow(title: "Размер:", value: "—")
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
        .onAppear {
            if let item = vm.propertiesItem, item.isDirectory, vm.calculatedFolderSizes[item.path] == nil {
                vm.calculateFolderSize(for: item, side: vm.activePane)
            }
        }
    }
    
    private func resolvedCreationDate(for item: FileItem) -> Date? {
        if let creationDate = item.creationDate, creationDate > 0 {
            return Date(timeIntervalSince1970: creationDate)
        }
        if item.source == .localMac {
            let url = URL(fileURLWithPath: item.path)
            if let vals = try? url.resourceValues(forKeys: [.creationDateKey]),
               let cdate = vals.creationDate {
                return cdate
            }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: item.path),
               let cdate = attrs[.creationDate] as? Date {
                return cdate
            }
        }
        return nil
    }
    
    private func pathPropertyRow(title: String, path: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 95, alignment: .trailing)
            
            Text(path)
                .font(.system(size: 12))
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
                withAnimation(.easeInOut(duration: 0.15)) {
                    isPathCopied = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isPathCopied = false
                    }
                }
            }) {
                Image(systemName: isPathCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isPathCopied ? .green : .secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isPathCopied ? "Путь скопирован в буфер обмена" : "Скопировать путь")
        }
    }
    
    private func propertyRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 95, alignment: .trailing)
            
            Text(value)
                .font(.system(size: 12))
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
