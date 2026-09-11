import SwiftUI

public struct BottomToolbarView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(vm.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            
            HStack(spacing: 4) {
                ToolButton(title: "F3 Просмотр", key: "F3") { vm.triggerQuickLook() }
                ToolButton(title: "F5 Копия", key: "F5") { vm.triggerCopy() }
                ToolButton(title: "F6 Перенос", key: "F6") { vm.triggerMove() }
                ToolButton(title: "F7 Папка", key: "F7") { vm.showNewFolderDialog = true }
                ToolButton(title: "F8 Удалить", key: "F8") { vm.triggerDelete() }
                ToolButton(title: "⇄ Поменять", key: "") { vm.swapPanes() }
                Spacer()
                ToolButton(title: "Tab Панель", key: "Tab") { vm.toggleActivePane() }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

public struct ToolButton: View {
    public let title: String
    public let key: String
    public let action: () -> Void
    
    public init(title: String, key: String, action: @escaping () -> Void) {
        self.title = title
        self.key = key
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 80, minHeight: 24)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color(nsColor: .controlColor))
        .foregroundColor(.primary)
    }
}
