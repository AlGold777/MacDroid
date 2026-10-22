import SwiftUI

/// Выплывающее поле поиска в верхнем тулбаре в стиле macOS Finder с выпадающим меню вариантов (Имя / Содержимое)
public struct TopToolbarSearchView: View {
    @ObservedObject var vm: DualPaneViewModel
    @FocusState private var isFocused: Bool
    @State private var debounceTask: Task<Void, Never>? = nil
    @State private var isExpanded: Bool = false
    @State private var isHovered: Bool = false
    
    public init(vm: DualPaneViewModel) {
        self.vm = vm
    }
    
    private var currentQuery: String {
        vm.activePane == .left ? vm.leftSearchQuery : vm.rightSearchQuery
    }
    
    private var currentMatchContent: Bool {
        vm.activePane == .left ? vm.leftSearchMatchContent : vm.rightSearchMatchContent
    }
    
    private var isSearching: Bool {
        vm.activePane == .left ? vm.isLeftSearching : vm.isRightSearching
    }
    
    private var isSearchActive: Bool {
        vm.isSearchActive(for: vm.activePane)
    }
    
    private var isExpandedView: Bool {
        isExpanded || !currentQuery.isEmpty
    }
    
    private var queryBinding: Binding<String> {
        Binding(
            get: { vm.activePane == .left ? vm.leftSearchQuery : vm.rightSearchQuery },
            set: { newValue in
                if vm.activePane == .left {
                    vm.leftSearchQuery = newValue
                    if !vm.isLeftSearchActive && !newValue.isEmpty {
                        vm.isLeftSearchActive = true
                    }
                } else {
                    vm.rightSearchQuery = newValue
                    if !vm.isRightSearchActive && !newValue.isEmpty {
                        vm.isRightSearchActive = true
                    }
                }
                triggerDebouncedSearch()
            }
        )
    }
    
    public var body: some View {
        Group {
            if isExpandedView {
                expandedSearchField
            } else {
                collapsedSearchButton
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isExpandedView)
        .onChange(of: vm.searchFocusTrigger) { _ in
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isFocused = true
            }
        }
        .onChange(of: isFocused) { focused in
            if !focused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    if !isFocused && currentQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        clearAndCloseSearch()
                    }
                }
            }
        }
    }
    
    private var expandedSearchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(isFocused ? .accentColor : Color(nsColor: .darkGray))
                .font(.system(size: 12, weight: .medium))
            
            TextField("Поиск", text: queryBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($isFocused)
                .onSubmit {
                    debounceTask?.cancel()
                    vm.startSearch(side: vm.activePane)
                }
                .onExitCommand {
                    clearAndCloseSearch()
                }
            
            if isSearching {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            } else if !currentQuery.isEmpty {
                Button(action: {
                    clearAndCloseSearch()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Очистить поиск (Esc)")
            } else {
                Button(action: {
                    clearAndCloseSearch()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary.opacity(0.7))
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Закрыть (Esc)")
            }
        }
        .padding(.horizontal, 7)
        .frame(width: isFocused || !currentQuery.isEmpty ? 200 : 160, height: 23)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isFocused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isFocused ? 1.5 : 1)
        )
        .overlay(alignment: .topTrailing) {
            // Выпадающее меню в стиле Finder (точно как на скриншоте)
            if isExpandedView {
                searchDropdownMenu
                    .offset(y: 28)
                    .zIndex(999)
            }
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.85, anchor: .trailing).combined(with: .opacity),
            removal: .scale(scale: 0.85, anchor: .trailing).combined(with: .opacity)
        ))
    }
    
    private var collapsedSearchButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded = true
                vm.openSearch(side: vm.activePane)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isFocused = true
            }
        }) {
            ToolbarIconView(icon: .search, size: 15, lineWidth: 1.3)
                .foregroundColor(isSearchActive ? .accentColor : (isHovered ? .primary : Color(nsColor: .darkGray)))
                .frame(width: 28, height: 23)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isSearchActive
                                ? Color.accentColor.opacity(0.18)
                                : (isHovered ? Color(nsColor: .separatorColor).opacity(0.22) : Color.clear)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            isSearchActive
                                ? Color.accentColor.opacity(0.4)
                                : (isHovered ? Color(nsColor: .separatorColor).opacity(0.35) : Color.clear),
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Поиск файлов (Cmd+F)")
        .onHover { hovering in
            isHovered = hovering
        }
        .transition(.opacity)
    }
    
    /// Меню подсказок / фильтров (Имена файлов / Содержание)
    @ViewBuilder
    private var searchDropdownMenu: some View {
        let cleanQuery = currentQuery.trimmingCharacters(in: .whitespaces)
        let displayQuery = cleanQuery.count > 25 ? String(cleanQuery.prefix(25)) + "..." : cleanQuery
        let titleFiles = cleanQuery.isEmpty ? "Имя содержит..." : "Имя содержит «\(displayQuery)»"
        let titleContent = cleanQuery.isEmpty ? "Содержит контент..." : "Содержит контент «\(displayQuery)»"
        
        VStack(alignment: .leading, spacing: 0) {
            // Секция 1: Имена файлов
            VStack(alignment: .leading, spacing: 3) {
                Text("Имена файлов")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 7)
                
                DropdownRowButton(
                    title: titleFiles,
                    isSelected: !currentMatchContent
                ) {
                    vm.setSearchMatchContent(false, side: vm.activePane)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isFocused = true
                    }
                }
            }
            
            Divider()
                .padding(.vertical, 4)
            
            // Секция 2: Содержание
            VStack(alignment: .leading, spacing: 3) {
                Text("Содержание")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                
                DropdownRowButton(
                    title: titleContent,
                    isSelected: currentMatchContent
                ) {
                    vm.setSearchMatchContent(true, side: vm.activePane)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isFocused = true
                    }
                }
            }
            .padding(.bottom, 6)
        }
        .frame(width: 250)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }
    
    private func triggerDebouncedSearch() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                vm.startSearch(side: vm.activePane)
            }
        }
    }
    
    private func clearAndCloseSearch() {
        debounceTask?.cancel()
        if vm.activePane == .left {
            vm.leftSearchQuery = ""
        } else {
            vm.rightSearchQuery = ""
        }
        vm.closeSearch(side: vm.activePane)
        withAnimation(.easeInOut(duration: 0.18)) {
            isExpanded = false
        }
        isFocused = false
    }
}

/// Строка пункта выпадающего меню поиска
private struct DropdownRowButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(isHovered ? .white : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(isHovered ? .white : .accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isHovered ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
