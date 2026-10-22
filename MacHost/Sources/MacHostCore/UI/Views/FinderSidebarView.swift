import SwiftUI

/// Боковая панель в стиле macOS Finder (режим F)
/// Шириной примерно 20 символов текста с разделами Избранное, Connect и Tags.
public struct FinderSidebarView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    @Environment(\.colorScheme) var colorScheme
    
    public init() {}
    
    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                // Секция 1: Избранное
                favoritesSection
                
                // Секция 2: Connect
                connectSection
                
                // Секция 3: Tags
                tagsSection
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 145, idealWidth: 166, maxWidth: 220)
        .background(
            Color(nsColor: .controlBackgroundColor)
                .opacity(colorScheme == .dark ? 0.45 : 0.65)
        )
    }
    
    // MARK: - 1. Секция «Избранное»
    
    private var currentActivePath: String {
        vm.activePane == .left ? vm.leftPath : vm.rightPath
    }
    
    private var currentActiveSource: FileSource {
        vm.activePane == .left ? vm.leftSource : vm.rightSource
    }
    
    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Избранное")
            
            sidebarRow(
                title: "Недавние",
                icon: "clock.fill",
                iconColor: .cyan,
                isSelected: false,
                action: {
                    vm.navigateToRecents(side: vm.activePane)
                }
            )
            
            sidebarRow(
                title: "Программы",
                icon: "app.fill",
                iconColor: .blue,
                isSelected: currentActiveSource == .localMac && currentActivePath == "/Applications",
                action: {
                    vm.navigateToApplications(side: vm.activePane)
                }
            )
            
            sidebarRow(
                title: "Рабочий стол",
                icon: "display",
                iconColor: .blue,
                isSelected: isDesktopActive,
                action: {
                    vm.navigateToDesktop(side: vm.activePane)
                }
            )
            
            sidebarRow(
                title: "Документы",
                icon: "doc.fill",
                iconColor: .blue,
                isSelected: isDocumentsActive,
                action: {
                    vm.navigateToDocuments(side: vm.activePane)
                }
            )
            
            sidebarRow(
                title: "Загрузки",
                icon: "arrow.down.circle.fill",
                iconColor: .blue,
                isSelected: isDownloadsActive,
                action: {
                    vm.navigateToDownloads(side: vm.activePane)
                }
            )
        }
    }
    
    // MARK: - 2. Секция «Connect»
    
    private var connectSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Connect")
            
            deviceRow(name: "Redmi")
            deviceRow(name: "Xiaomi")
            
            // Дополнительные зарегистрированные устройства, если их имя не Redmi/Xiaomi
            ForEach(extraDevices, id: \.id) { dev in
                deviceRow(name: dev.name, deviceId: dev.id)
            }
        }
    }
    
    // MARK: - 3. Секция «Tags»
    
    private var tagList: [FileTag] {
        FileTag.allTags
    }
    
    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Tags:")
            
            ForEach(tagList) { tag in
                let isSelected = (vm.selectedTagFilter == tag.id)
                tagRow(tag: tag, isSelected: isSelected)
            }
            
            sidebarRow(
                title: "All tags ...",
                icon: "circle.circle",
                iconColor: .secondary,
                isSelected: vm.selectedTagFilter == nil,
                action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        vm.selectedTagFilter = nil
                    }
                }
            )
        }
    }
    
    // MARK: - Строка устройства Connect
    
    private func deviceRow(name: String, deviceId: String? = nil) -> some View {
        let isConnectedDevice = vm.isPhoneConnected && vm.remoteDriver.isConnected &&
            vm.connectedPhoneShortName.localizedCaseInsensitiveContains(name)
        let isRemoteActive = (currentActiveSource == .remotePhone)
        let isSelected = isConnectedDevice && isRemoteActive
        
        return SidebarDeviceRow(
            name: name,
            isConnected: isConnectedDevice,
            isConnecting: vm.isConnectingPhone,
            isSelected: isSelected,
            onConnect: {
                vm.connectOrNavigateToDevice(named: name, side: vm.activePane)
            },
            onDisconnect: {
                vm.disconnectPhone()
            }
        )
    }
    
    // MARK: - Строка тега
    
    private func tagRow(tag: FileTag, isSelected: Bool) -> some View {
        SidebarRowButton(
            isSelected: isSelected,
            action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if vm.selectedTagFilter == tag.id {
                        vm.selectedTagFilter = nil
                    } else {
                        vm.selectedTagFilter = tag.id
                    }
                }
            }
        ) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tag.color)
                    .frame(width: 9, height: 9)
                    .padding(.leading, 3)
                
                Text(tag.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(.primary)
                
                Spacer(minLength: 0)
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.vertical, 3.5)
            .padding(.horizontal, 6)
        }
    }
    
    // MARK: - Стандартная строка сайдбара
    
    private func sidebarRow(
        title: String,
        icon: String,
        iconColor: Color,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        SidebarRowButton(isSelected: isSelected, action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? .accentColor : iconColor)
                    .frame(width: 18, alignment: .center)
                
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3.5)
            .padding(.horizontal, 6)
        }
    }
    
    // MARK: - Заголовок секции
    
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
    
    // MARK: - Вычисляемые свойства путей
    
    private var isDesktopActive: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return currentActiveSource == .localMac && currentActivePath == "\(home)/Desktop"
    }
    
    private var isDocumentsActive: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return currentActiveSource == .localMac && currentActivePath == "\(home)/Documents"
    }
    
    private var isDownloadsActive: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return currentActiveSource == .localMac && currentActivePath == "\(home)/Downloads"
    }
    
    private var extraDevices: [TrustedDevice] {
        DeviceRegistry.shared.allDevices().filter { dev in
            let n = dev.name.lowercased()
            return !n.contains("redmi") && !n.contains("xiaomi") && !n.isEmpty
        }
    }
}

// MARK: - Строка устройства с возможностью отключения

private struct SidebarDeviceRow: View {
    let name: String
    let isConnected: Bool
    let isConnecting: Bool
    let isSelected: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isConnected ? .accentColor : .secondary)
                .frame(width: 18, alignment: .center)
            
            Text(name)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(.primary)
                .lineLimit(1)
            
            Spacer(minLength: 0)
            
            if isConnected {
                if isHovered {
                    Button(action: onDisconnect) {
                        Image(systemName: "eject.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Отключить устройство")
                } else {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                }
            } else if isConnecting {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 3.5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.18)
                        : (isHovered ? Color(nsColor: .separatorColor).opacity(0.18) : Color.clear)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            onConnect()
        }
    }
}

// MARK: - Базовая интерактивная кнопка строки

private struct SidebarRowButton<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    let content: Content
    
    @State private var isHovered: Bool = false
    
    init(isSelected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.action = action
        self.content = content()
    }
    
    var body: some View {
        Button(action: action) {
            content
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isSelected
                                ? Color.accentColor.opacity(0.18)
                                : (isHovered ? Color(nsColor: .separatorColor).opacity(0.18) : Color.clear)
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
    }
}
