import SwiftUI

/// Компактная полоса области поиска (Scope Bar) в стиле macOS Finder: «Место поиска: Этот Mac | «Папка»»
public struct PaneSearchView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    public let side: PaneSide
    
    public init(side: PaneSide) {
        self.side = side
    }
    
    private var scopeBinding: Binding<SearchScope> {
        Binding(
            get: { side == .left ? vm.leftSearchScope : vm.rightSearchScope },
            set: { newValue in
                if side == .left {
                    vm.leftSearchScope = newValue
                } else {
                    vm.rightSearchScope = newValue
                }
                vm.startSearch(side: side)
            }
        )
    }
    
    private var isSearching: Bool {
        side == .left ? vm.isLeftSearching : vm.isRightSearching
    }
    
    private var searchResultsCount: Int {
        (side == .left ? vm.leftSearchResults : vm.rightSearchResults).count
    }
    
    private var currentFolderName: String {
        let path = (side == .left ? vm.leftPath : vm.rightPath)
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "/" : name
    }
    
    private var currentSource: FileSource {
        side == .left ? vm.leftSource : vm.rightSource
    }
    
    public var body: some View {
        HStack(spacing: 8) {
            Text("Место поиска:")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            
            ScopePillButton(
                title: currentSource == .localMac ? "Этот Mac" : "Телефон",
                isSelected: scopeBinding.wrappedValue == .everywhere
            ) {
                scopeBinding.wrappedValue = .everywhere
            }
            
            ScopePillButton(
                title: "«\(currentFolderName)»",
                isSelected: scopeBinding.wrappedValue == .currentFolder
            ) {
                scopeBinding.wrappedValue = .currentFolder
            }
            
            Spacer()
            
            if isSearching {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.65)
                    Text("Поиск...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    
                    Button("Стоп") {
                        vm.stopSearch(side: side)
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            } else if searchResultsCount > 0 {
                Text("Найдено: \(searchResultsCount)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            
            Button(action: {
                vm.closeSearch(side: side)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(3)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Закрыть поиск (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }
}

/// Кнопка области охвата поиска
private struct ScopePillButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }
}
