import SwiftUI
import AppKit

public struct ConflictResolutionModalView: View {
    public let conflict: ConflictContext
    public let onResolve: (ConflictResolutionResult) -> Void
    public let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedAction: ConflictResolutionStrategy = .autoRename
    @State private var applyToAll: Bool = true
    @State private var sourceFileName: String = ""
    @State private var selectionTrigger: UUID = UUID()
    
    public init(
        conflict: ConflictContext,
        onResolve: @escaping (ConflictResolutionResult) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.conflict = conflict
        self.onResolve = onResolve
        self.onCancel = onCancel
        _sourceFileName = State(initialValue: generateAutoRename(filename: conflict.sourceItem.name))
    }
    
    public init(
        conflict: ConflictContext,
        onSelectStrategy: @escaping (ConflictResolutionStrategy, Bool) -> Void
    ) {
        self.conflict = conflict
        self.onResolve = { result in
            onSelectStrategy(result.action, result.applyToAll)
        }
        self.onCancel = {}
        _sourceFileName = State(initialValue: generateAutoRename(filename: conflict.sourceItem.name))
    }
    
    private var isSingle: Bool {
        !conflict.canSkip
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                Text("File already exists")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(ConflictColors.titleText)
                Spacer()
                ConflictCloseButton(action: cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)
            
            // Files comparison box
            VStack(spacing: 0) {
                // Source row
                HStack(spacing: 5) {
                    Text("Source")
                        .font(.system(size: 13))
                        .foregroundColor(ConflictColors.tagText)
                        .frame(width: 70, alignment: .leading)
                    
                    HStack(spacing: 0) {
                        ConflictFileNameTextField(
                            text: $sourceFileName,
                            selectionTrigger: selectionTrigger,
                            onCommit: {
                                applyAction()
                            },
                            onCancel: {
                                cancelAction()
                            }
                        )
                        .frame(height: 18)
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 5)
                    .background(ConflictColors.inputFocusBg)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(ConflictColors.inputFocusBorder, lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, 5)
                    
                    Text("\(formatBytes(conflict.sourceItem.size)) · \(formatDate(conflict.sourceItem.mtime))")
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundColor(ConflictColors.metaText)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                
                Rectangle()
                    .fill(ConflictColors.filesDivider)
                    .frame(height: 1)
                
                // Target row
                HStack(spacing: 10) {
                    Text("Target")
                        .font(.system(size: 13))
                        .foregroundColor(ConflictColors.tagText)
                        .frame(width: 70, alignment: .leading)
                    
                    Text(conflict.targetItem.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(ConflictColors.nameText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Text("\(formatBytes(conflict.targetItem.size)) · \(formatDate(conflict.targetItem.mtime))")
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundColor(ConflictColors.metaText)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
            }
            .background(ConflictColors.filesBg)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(ConflictColors.filesBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            
            // Actions choices (Skip, Auto-rename, Overwrite, Overwrite old)
            HStack(spacing: 5) {
                choiceButton(title: "Skip", action: .skip)
                choiceButton(title: "Auto-rename", action: .autoRename)
                choiceButton(title: "Overwrite", action: .overwrite)
                choiceButton(title: "Overwrite old", action: .overwriteIfNewer)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, isSingle ? 20 : 0)
            
            if !isSingle {
                // for All checkbox
                ConflictCheckbox(isChecked: $applyToAll, label: "for All")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 14)
                    .padding(.bottom, 16)
                
                // Footer
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") {
                        cancelAction()
                    }
                    .buttonStyle(ConflictSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    
                    Button("Continue") {
                        applyAction()
                    }
                    .buttonStyle(ConflictPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 13)
                .background(ConflictColors.footerBg)
                .overlay(
                    Rectangle()
                        .fill(ConflictColors.footerBorder)
                        .frame(height: 1),
                    alignment: .top
                )
            }
        }
        .frame(width: 530)
        .background(ConflictColors.dialogBg)
        .cornerRadius(15)
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .stroke(ConflictColors.dialogBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .background(WindowClearBackgroundModifier())
        .background {
            if isSingle {
                Button("") { cancelAction() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                Button("") { applyAction() }
                    .keyboardShortcut(.defaultAction)
                    .opacity(0)
            }
        }
        .onAppear {
            if selectedAction == .autoRename {
                sourceFileName = generateAutoRename(filename: conflict.sourceItem.name)
            }
            selectionTrigger = UUID()
        }
        .onChange(of: conflict.id) {
            sourceFileName = generateAutoRename(filename: conflict.sourceItem.name)
            selectedAction = .autoRename
            selectionTrigger = UUID()
        }
    }
    
    @ViewBuilder
    private func choiceButton(title: String, action: ConflictResolutionStrategy) -> some View {
        let isSelected = selectedAction == action
        
        Button {
            handleChoiceClick(action)
        } label: {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? ConflictColors.choiceSelectedText : ConflictColors.choiceUnselectedText)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 37)
                .background(isSelected ? ConflictColors.choiceSelectedBg : ConflictColors.choiceUnselectedBg)
                .cornerRadius(7)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isSelected ? ConflictColors.choiceSelectedBorder : ConflictColors.choiceUnselectedBorder, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private func handleChoiceClick(_ action: ConflictResolutionStrategy) {
        // Клик по Skip всегда немедленно пропускает данный файл и переходит к следующему
        if action == .skip || action == .skipIfIdentical {
            let result = ConflictResolutionResult(action: .skip, applyToAll: false, customName: nil)
            onResolve(result)
            if isSingle {
                dismiss()
            }
            return
        }
        
        if isSingle {
            // В режиме одного файла клик сразу выполняет действие:
            switch action {
            case .skip, .skipIfIdentical:
                let result = ConflictResolutionResult(action: .skip, applyToAll: false, customName: nil)
                onResolve(result)
                dismiss()
            case .autoRename:
                let trimmed = sourceFileName.trimmingCharacters(in: .whitespacesAndNewlines)
                let customName = (!trimmed.isEmpty && trimmed != conflict.sourceItem.name) ? trimmed : nil
                let result = ConflictResolutionResult(action: .autoRename, applyToAll: false, customName: customName)
                onResolve(result)
                dismiss()
            case .overwrite:
                let result = ConflictResolutionResult(action: .overwrite, applyToAll: false, customName: nil)
                onResolve(result)
                dismiss()
            case .overwriteIfNewer:
                let result = ConflictResolutionResult(action: .overwriteIfNewer, applyToAll: false, customName: nil)
                onResolve(result)
                dismiss()
            case .customRename:
                break
            }
            return
        }
        
        // В режиме нескольких файлов клик выбирает режим:
        selectedAction = action
        if action == .autoRename {
            sourceFileName = generateAutoRename(filename: conflict.sourceItem.name)
            selectionTrigger = UUID()
        } else if action == .overwrite || action == .overwriteIfNewer {
            sourceFileName = conflict.sourceItem.name
            selectionTrigger = UUID()
        }
    }
    
    private func applyAction() {
        let trimmedName = sourceFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let customName: String?
        if !trimmedName.isEmpty && trimmedName != conflict.sourceItem.name {
            customName = trimmedName
        } else {
            customName = nil
        }
        
        let result = ConflictResolutionResult(
            action: selectedAction,
            applyToAll: isSingle ? false : applyToAll,
            customName: customName
        )
        onResolve(result)
        dismiss()
    }
    
    private func cancelAction() {
        onCancel()
        dismiss()
    }
    
    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            let kb = Double(bytes) / 1024.0
            return String(format: "%.1f KB", kb)
        } else if bytes < 1024 * 1024 * 1024 {
            let mb = Double(bytes) / (1024.0 * 1024.0)
            return String(format: "%.1f MB", mb)
        } else {
            let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
            return String(format: "%.1f GB", gb)
        }
    }
    
    private func formatDate(_ timestamp: Double) -> String {
        guard timestamp > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: timestamp)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MMM dd, HH:mm"
        return df.string(from: date)
    }
}

// MARK: - NSTextField with 1:1 Filename Selection (without extension)

final class FocusableSelectableTextField: NSTextField {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onTextChange: ((String) -> Void)?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        textColor = NSColor(ConflictColors.nameText)
        cell?.wraps = false
        cell?.isScrollable = true
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.selectBaseName()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.selectBaseName()
            }
        }
    }
    
    func selectBaseName() {
        guard let window = self.window else { return }
        window.makeFirstResponder(self)
        self.selectText(nil)
        
        if let editor = currentEditor() as? NSTextView {
            // Точный цвет выделения #6c9dcc и белый цвет текста из CSS:
            // .name-input::selection { background: #6c9dcc; color: #ffffff; }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(red: 0x6c/255.0, green: 0x9d/255.0, blue: 0xcc/255.0, alpha: 1.0),
                .foregroundColor: NSColor.white
            ]
            editor.insertionPointColor = NSColor(red: 0x27/255.0, green: 0x33/255.0, blue: 0x41/255.0, alpha: 1.0)
            
            let text = stringValue
            let dotIndex = text.lastIndex(of: ".")
            let length: Int
            if let dot = dotIndex, dot > text.startIndex {
                length = text.distance(from: text.startIndex, to: dot)
            } else {
                length = text.count
            }
            editor.setSelectedRange(NSRange(location: 0, length: length))
        }
    }
    
    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        onTextChange?(stringValue)
    }
    
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36 { // Return
            onCommit?()
            return true
        } else if event.keyCode == 53 { // Escape
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

fileprivate struct ConflictFileNameTextField: NSViewRepresentable {
    @Binding var text: String
    var selectionTrigger: UUID
    var onCommit: () -> Void
    var onCancel: () -> Void
    
    func makeNSView(context: Context) -> FocusableSelectableTextField {
        let tf = FocusableSelectableTextField()
        tf.stringValue = text
        tf.onTextChange = { newText in
            DispatchQueue.main.async {
                self.text = newText
            }
        }
        tf.onCommit = onCommit
        tf.onCancel = onCancel
        return tf
    }
    
    func updateNSView(_ nsView: FocusableSelectableTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.onCommit = onCommit
        nsView.onCancel = onCancel
        nsView.onTextChange = { newText in
            DispatchQueue.main.async {
                self.text = newText
            }
        }
        
        if context.coordinator.lastTrigger != selectionTrigger {
            context.coordinator.lastTrigger = selectionTrigger
            DispatchQueue.main.async {
                nsView.selectBaseName()
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var lastTrigger: UUID?
    }
}

// MARK: - Custom Close Button

public struct ConflictCloseButton: View {
    public let action: () -> Void
    @State private var isHovered = false
    
    public init(action: @escaping () -> Void) {
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            Text("×")
                .font(.system(size: 21, weight: .regular))
                .foregroundColor(isHovered ? ConflictColors.titleText : ConflictColors.closeButton)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Custom "for All" Checkbox

fileprivate struct ConflictCheckbox: View {
    @Binding var isChecked: Bool
    let label: String
    
    var body: some View {
        Button {
            isChecked.toggle()
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(isChecked ? ConflictColors.forAllAccent : Color.white)
                        .frame(width: 15, height: 15)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5)
                                .stroke(isChecked ? ConflictColors.forAllAccent : Color(hex: "#dfe5eb"), lineWidth: 1)
                        )
                    if isChecked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                Text(label)
                    .font(.system(size: 14))
                    .foregroundColor(ConflictColors.forAllText)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Window Background Clear Modifier

public struct WindowClearBackgroundModifier: NSViewRepresentable {
    public init() {}
    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.isOpaque = false
                window.backgroundColor = .clear
            }
        }
        return view
    }
    public func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Color Palette Matching file_conflict_dialog.html

public enum ConflictColors {
    // Dialog
    public static let dialogBg = Color.dynamic(light: "#ffffff", dark: "#1e2227")
    public static let dialogBorder = Color.dynamic(light: "#e0e5eb", dark: "#2d333b")
    
    // Header
    public static let titleText = Color.dynamic(light: "#273341", dark: "#e6edf3")
    public static let closeButton = Color.dynamic(light: "#8b96a4", dark: "#8b949e")
    
    // Files comparison box
    public static let filesBg = Color.dynamic(light: "#ffffff", dark: "#161b22")
    public static let filesBorder = Color.dynamic(light: "#e9edf1", dark: "#30363d")
    public static let filesDivider = Color.dynamic(light: "#eef0f3", dark: "#21262d")
    public static let tagText = Color.dynamic(light: "#8a96a2", dark: "#8b949e")
    public static let nameText = Color.dynamic(light: "#273341", dark: "#e6edf3")
    public static let metaText = Color.dynamic(light: "#8a96a2", dark: "#8b949e")
    
    // Name input focused
    public static let inputFocusBg = Color.dynamic(light: "#edf3f9", dark: "#1f2937")
    public static let inputFocusBorder = Color.dynamic(light: "#92aec8", dark: "#58a6ff")
    public static let renameInputBg = Color.dynamic(light: "#dce7f2", dark: "#212c3b")
    
    // Action choices
    public static let choiceUnselectedBg = Color.dynamic(light: "#ffffff", dark: "#21262d")
    public static let choiceUnselectedBorder = Color.dynamic(light: "#e2e7ec", dark: "#30363d")
    public static let choiceUnselectedText = Color.dynamic(light: "#556372", dark: "#8b949e")
    
    public static let choiceSelectedBg = Color.dynamic(light: "#edf3f9", dark: "#1c2d42")
    public static let choiceSelectedBorder = Color.dynamic(light: "#92aec8", dark: "#388bfd")
    public static let choiceSelectedText = Color.dynamic(light: "#345f83", dark: "#79c0ff")
    
    // for All
    public static let forAllText = Color.dynamic(light: "#647282", dark: "#8b949e")
    public static let forAllAccent = Color.dynamic(light: "#668aa9", dark: "#58a6ff")
    
    // Footer
    public static let footerBg = Color.dynamic(light: "#fafbfc", dark: "#161b22")
    public static let footerBorder = Color.dynamic(light: "#eef0f3", dark: "#21262d")
    
    // Cancel button
    public static let cancelBtnBg = Color.dynamic(light: "#ffffff", dark: "#21262d")
    public static let cancelBtnBorder = Color.dynamic(light: "#dfe5eb", dark: "#30363d")
    public static let cancelBtnText = Color.dynamic(light: "#4d5c69", dark: "#c9d1d9")
    
    // Continue button
    public static let continueBtnBg = Color.dynamic(light: "#617f99", dark: "#316dca")
    public static let continueBtnBorder = Color.dynamic(light: "#617f99", dark: "#316dca")
    public static let continueBtnText = Color(hex: "#ffffff")
}

// MARK: - Button Styles

public struct ConflictSecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .foregroundColor(ConflictColors.cancelBtnText)
            .frame(height: 36)
            .padding(.horizontal, 19)
            .background(configuration.isPressed ? ConflictColors.inputFocusBg : ConflictColors.cancelBtnBg)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(ConflictColors.cancelBtnBorder, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

public struct ConflictPrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(ConflictColors.continueBtnText)
            .frame(height: 36)
            .padding(.horizontal, 19)
            .background(configuration.isPressed ? ConflictColors.continueBtnBg.opacity(0.85) : ConflictColors.continueBtnBg)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(ConflictColors.continueBtnBorder, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.9 : 1.0)
    }
}

// MARK: - Hex Color Helper

fileprivate extension Color {
    init(hex: String) {
        let cleanHex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleanHex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch cleanHex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
    
    static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            let isDark = (match == .darkAqua)
            return isDark ? NSColor(Color(hex: dark)) : NSColor(Color(hex: light))
        }))
    }
}
