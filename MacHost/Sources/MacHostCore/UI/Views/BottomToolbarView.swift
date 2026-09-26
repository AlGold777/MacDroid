import SwiftUI

public struct BottomToolbarView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    
    public init() {}
    
    public var body: some View {
        ZStack {
            HStack(spacing: 4) {
                ToolButton(systemImage: "doc.on.doc", tooltip: "Копировать (F5)") { vm.triggerCopy() }
                ToolButton(systemImage: "arrow.right.doc.on.clipboard", tooltip: "Переместить (F6)") { vm.triggerMove() }
                ToolButton(systemImage: "folder.badge.plus", tooltip: "Новая папка (F7)") { vm.prepareNewFolder() }
                ToolButton(systemImage: "trash", tooltip: "Удалить (F8)") { vm.triggerDelete() }
                ToolButton(systemImage: "textformat.abc", tooltip: "Групповое переименование (Ctrl+M)") { vm.triggerBatchRename() }
                ToolButton(systemImage: "rectangle.2.swap", tooltip: "Сравнить папки", isActive: vm.isComparing) { vm.comparePanes() }
                
                Spacer()
                
                if vm.isTransferMinimized && vm.currentTransferTask != nil && !vm.isTransferCompleted {
                    Button(action: { vm.showQueueDialog = true }) {
                        HStack(spacing: 6) {
                            ProgressView(value: vm.transferProgress, total: 1.0)
                                .progressViewStyle(.circular)
                                .controlSize(.mini)
                            Text("\(Int(vm.transferProgress * 100))%")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.primary)
                            if !vm.currentTransferFileName.isEmpty {
                                Text(vm.currentTransferFileName)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 130)
                            }
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Свёрнутая операция: \(vm.currentTransferFileName) (\(Int(vm.transferProgress * 100))%). Нажмите для открытия треков очереди.")
                }
                
                ToolButton(systemImage: "magnifyingglass", tooltip: "Поиск файлов (Cmd+F)") { vm.showSearchDialog = true }
                
                Button(action: { vm.showQueueDialog = true }) {
                    Text("Очередь (\(vm.queueManager.tasks.count))")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Очередь операций")
            }
            
            // Ровно посередине
            ToolButton(systemImage: "arrow.left.arrow.right", tooltip: "Поменять панели местами") { vm.swapPanes() }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

public struct ToolButton: View {
    public let systemImage: String
    public let tooltip: String
    public let isActive: Bool
    public let action: () -> Void
    
    @State private var isHovered: Bool = false
    
    public init(systemImage: String, tooltip: String, isActive: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.tooltip = tooltip
        self.isActive = isActive
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isActive ? .accentColor : (isHovered ? .primary : .secondary))
                .frame(width: 26, height: 24)
                .background(isHovered ? Color(nsColor: .controlColor).opacity(0.3) : Color.clear)
                .cornerRadius(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(tooltip)
    }
}
