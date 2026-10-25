import SwiftUI

/// Выплывающее поле фильтра в верхнем тулбаре с параметрами контура, идентичными поиску
public struct TopToolbarFilterView: View {
    @ObservedObject var vm: DualPaneViewModel
    @FocusState private var isFocused: Bool
    @State private var isExpanded: Bool = false
    @State private var isHovered: Bool = false
    
    public init(vm: DualPaneViewModel) {
        self.vm = vm
    }
    
    private var currentFilter: String {
        vm.activeFilterText
    }
    
    private var filterBinding: Binding<String> {
        Binding(
            get: { vm.activeFilterText },
            set: { vm.activeFilterText = $0 }
        )
    }
    
    public var body: some View {
        collapsedFilterButton
            // Keep the native toolbar item's width constant while editing.
            .popover(isPresented: $isExpanded, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    expandedFilterField
                }
                .padding(10)
                .onAppear { isFocused = true }
                .onExitCommand { clearAndCloseFilter() }
            }
            .onChange(of: vm.filterFocusTrigger) { _ in
                isExpanded = true
                isFocused = true
            }
    }
    
    private var expandedFilterField: some View {
        HStack(spacing: 5) {
            ToolbarIconView(icon: .filter, size: 12.65, lineWidth: 1.3)
                .foregroundColor(isFocused ? .accentColor : Color(nsColor: .darkGray))
            
            TextField("Фильтр...", text: filterBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($isFocused)
                .onExitCommand {
                    clearAndCloseFilter()
                }
            
            if !currentFilter.isEmpty {
                Button(action: {
                    vm.activeFilterText = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Очистить фильтр (Esc)")
            } else {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded = false
                    }
                    isFocused = false
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
        .frame(width: 220, height: 23)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isFocused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isFocused ? 1.5 : 1)
        )
    }
    
    private var collapsedFilterButton: some View {
        Button(action: {
            isExpanded = true
        }) {
            ToolbarIconView(icon: .filter, size: 15, lineWidth: 1.3)
                .foregroundColor(!currentFilter.isEmpty ? .accentColor : (isHovered ? .primary : Color(nsColor: .darkGray)))
                .frame(width: 28, height: 23)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            !currentFilter.isEmpty
                                ? Color.accentColor.opacity(0.18)
                                : (isHovered ? Color(nsColor: .separatorColor).opacity(0.22) : Color.clear)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            !currentFilter.isEmpty
                                ? Color.accentColor.opacity(0.4)
                                : (isHovered ? Color(nsColor: .separatorColor).opacity(0.35) : Color.clear),
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Фильтр файлов (\(vm.activePane == .left ? "левая панель" : "правая панель"))")
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    private func clearAndCloseFilter() {
        vm.activeFilterText = ""
        withAnimation(.easeInOut(duration: 0.18)) {
            isExpanded = false
        }
        isFocused = false
    }
}
