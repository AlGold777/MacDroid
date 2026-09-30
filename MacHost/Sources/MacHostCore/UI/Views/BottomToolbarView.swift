import SwiftUI

public struct BottomToolbarView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    
    public init() {}
    
    public var body: some View {
        ZStack {
            // Центральный блок действий
            HStack(spacing: 2) {
                ToolButton(systemImage: "doc.on.doc", tooltip: "Копировать (F5)") { vm.triggerCopy() }
                ToolbarSeparator()
                ToolButton(systemImage: "arrow.right.doc.on.clipboard", tooltip: "Переместить (F6)") { vm.triggerMove() }
                ToolbarSeparator()
                ToolButton(systemImage: "folder.badge.plus", tooltip: "Новая папка (F7)") { vm.prepareNewFolder() }
                ToolbarSeparator()
                ToolButton(systemImage: "trash", tooltip: "Удалить (F8 / Delete)") { vm.triggerDelete() }
                ToolbarSeparator()
                ToolButton(systemImage: "textformat.abc", tooltip: "Групповое переименование (Ctrl+M)") { vm.triggerBatchRename() }
                ToolbarSeparator()
                ToolButton(systemImage: "rectangle.2.swap", tooltip: "Сравнить папки", isActive: vm.isComparing) { vm.comparePanes() }
            }
            
            // Правая часть
            HStack(spacing: 2) {
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
                    
                    ToolbarSeparator()
                }
                
                ToolButton(systemImage: "magnifyingglass", tooltip: "Поиск файлов (Cmd+F)") { vm.showSearchDialog = true }
                ToolbarSeparator()
                
                QueueToolbarButton(count: vm.queueManager.tasks.count) {
                    vm.showQueueDialog = true
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

public struct ToolbarSeparator: View {
    public init() {}
    
    public var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.65))
            .frame(width: 1, height: 15)
            .padding(.horizontal, 2)
    }
}

public struct QueueToolbarButton: View {
    public let count: Int
    public let action: () -> Void
    @State private var isHovered: Bool = false
    
    public init(count: Int, action: @escaping () -> Void) {
        self.count = count
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "tray.full")
                    .font(.system(size: 11, weight: .medium))
                Text("Очередь (\(count))")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isHovered ? .primary : .secondary)
            .padding(.horizontal, 8)
            .frame(height: 25)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color(nsColor: .separatorColor).opacity(0.22) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .help("Очередь операций")
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
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isActive ? .accentColor : (isHovered ? .primary : .secondary))
                .frame(width: 38, height: 25)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isActive
                                ? Color.accentColor.opacity(0.18)
                                : (isHovered ? Color(nsColor: .separatorColor).opacity(0.22) : Color.clear)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            isActive ? Color.accentColor.opacity(0.4) : Color.clear,
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .help(tooltip)
    }
}
