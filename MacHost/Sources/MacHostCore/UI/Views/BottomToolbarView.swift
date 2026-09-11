import SwiftUI

public struct BottomToolbarView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    
    public init() {}
    
    public var body: some View {
        ZStack {
            HStack(spacing: 4) {
                ToolButton(systemImage: "doc.on.doc", tooltip: "Копировать (F5)") { vm.triggerCopy() }
                ToolButton(systemImage: "arrow.right.doc.on.clipboard", tooltip: "Переместить (F6)") { vm.triggerMove() }
                ToolButton(systemImage: "folder.badge.plus", tooltip: "Новая папка (F7)") { vm.showNewFolderDialog = true }
                ToolButton(systemImage: "trash", tooltip: "Удалить (F8)") { vm.triggerDelete() }
                ToolButton(systemImage: "textformat.abc", tooltip: "Групповое переименование (Ctrl+M)") { vm.triggerBatchRename() }
                ToolButton(systemImage: "equal.circle", tooltip: "Сравнить папки", isActive: vm.isComparing) { vm.comparePanes() }
                ToolButton(systemImage: vm.isQuickViewActive ? "eye.fill" : "eye", tooltip: "Быстрый просмотр (Ctrl+Q)", isActive: vm.isQuickViewActive) { vm.toggleQuickView() }
                
                Spacer()
                
                ToolButton(systemImage: "magnifyingglass", tooltip: "Поиск файлов (Cmd+F)") { vm.showSearchDialog = true }
                
                Button(action: { vm.showQueueDialog = true }) {
                    Text("Очередь (\(vm.queueManager.tasks.count))")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Очередь операций")
                
                if vm.isConnectingPhone {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 26, height: 24)
                        .help("Подключение к телефону...")
                } else {
                    ToolButton(systemImage: "rectangle.2.swap", tooltip: "Подключить телефон (фоновый запуск ADB, проброс портов и авто-настройка)") {
                        vm.connectPhone()
                    }
                }
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
