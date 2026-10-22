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
    
    private var isExpandedView: Bool {
        isExpanded || !currentFilter.isEmpty
    }
    
    private var filterBinding: Binding<String> {
        Binding(
            get: { vm.activeFilterText },
            set: { vm.activeFilterText = $0 }
        )
    }
    
    public var body: some View {
        Group {
            if isExpandedView {
                expandedFilterField
            } else {
                collapsedFilterButton
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isExpandedView)
        .onChange(of: vm.filterFocusTrigger) { _ in
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
                    if !isFocused && currentFilter.trimmingCharacters(in: .whitespaces).isEmpty {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isExpanded = false
                        }
                    }
                }
            }
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
        .frame(width: isFocused || !currentFilter.isEmpty ? 180 : 140, height: 23)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isFocused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isFocused ? 1.5 : 1)
        )
        .transition(.asymmetric(
            insertion: .scale(scale: 0.85, anchor: .trailing).combined(with: .opacity),
            removal: .scale(scale: 0.85, anchor: .trailing).combined(with: .opacity)
        ))
    }
    
    private var collapsedFilterButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isFocused = true
            }
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
        .transition(.opacity)
    }
    
    private func clearAndCloseFilter() {
        vm.activeFilterText = ""
        withAnimation(.easeInOut(duration: 0.18)) {
            isExpanded = false
        }
        isFocused = false
    }
}
