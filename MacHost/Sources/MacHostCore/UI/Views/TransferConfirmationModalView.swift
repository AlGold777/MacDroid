import SwiftUI
import AppKit

public struct TransferConfirmationContext: Identifiable, Sendable {
    public let id: String
    public let items: [FileItem]
    public let paths: [String]
    public let isMove: Bool
    public let fromSource: FileSource
    public let toSide: PaneSide
    public let targetDirPath: String
    public let totalSize: UInt64
    
    public init(
        items: [FileItem],
        paths: [String],
        isMove: Bool,
        fromSource: FileSource,
        toSide: PaneSide,
        targetDirPath: String,
        totalSize: UInt64
    ) {
        self.id = UUID().uuidString
        self.items = items
        self.paths = paths
        self.isMove = isMove
        self.fromSource = fromSource
        self.toSide = toSide
        self.targetDirPath = targetDirPath
        self.totalSize = totalSize
    }
}

public struct TransferConfirmationModalView: View {
    public let context: TransferConfirmationContext
    public let onConfirm: (String) -> Void
    public let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var targetPath: String = ""
    
    public init(
        context: TransferConfirmationContext,
        onConfirm: @escaping (String) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.context = context
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _targetPath = State(initialValue: context.targetDirPath)
    }
    
    private var sourceDisplayTitle: String {
        if context.items.count == 1, let first = context.items.first {
            return first.name
        } else if let first = context.items.first {
            return "\(first.name) and \(context.items.count - 1) more"
        } else if let firstPath = context.paths.first {
            let name = URL(fileURLWithPath: firstPath).lastPathComponent
            return context.paths.count > 1 ? "\(name) and \(context.paths.count - 1) more" : name
        } else {
            return "Selected files"
        }
    }
    
    private var sourceMetaText: String {
        if context.items.count == 1, let first = context.items.first {
            return "\(formatBytes(context.totalSize)) · \(formatDate(first.mtime))"
        } else {
            let count = max(context.items.count, context.paths.count)
            return "\(formatBytes(context.totalSize)) · \(count) files"
        }
    }
    
    private var targetLocationLabel: String {
        // Если передаем из localMac, цель - Android, и наоборот
        return context.fromSource == .localMac ? "Android" : "Mac"
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                Text(context.isMove ? "Move files" : "Copy files")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(ConflictColors.titleText)
                Spacer()
                ConflictCloseButton(action: cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)
            
            // Files & destination box
            VStack(spacing: 0) {
                // Source row
                HStack(spacing: 5) {
                    Text("Source")
                        .font(.system(size: 13))
                        .foregroundColor(ConflictColors.tagText)
                        .frame(width: 70, alignment: .leading)
                    
                    Text(sourceDisplayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(ConflictColors.nameText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.vertical, 2)
                        .padding(.leading, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Text(sourceMetaText)
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
                HStack(spacing: 5) {
                    Text("Target")
                        .font(.system(size: 13))
                        .foregroundColor(ConflictColors.tagText)
                        .frame(width: 70, alignment: .leading)
                    
                    HStack(spacing: 0) {
                        TextField("", text: $targetPath)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(ConflictColors.nameText)
                            .lineLimit(1)
                            .onSubmit {
                                confirmAction()
                            }
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
                    
                    Text(targetLocationLabel)
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
            
            // Footer
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    cancelAction()
                }
                .buttonStyle(ConflictSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                
                Button(context.isMove ? "Move" : "Copy") {
                    confirmAction()
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
        .frame(width: 530)
        .background(ConflictColors.dialogBg)
        .cornerRadius(15)
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .stroke(ConflictColors.dialogBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .background(WindowClearBackgroundModifier())
    }
    
    private func confirmAction() {
        let trimmed = targetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        onConfirm(trimmed.isEmpty ? context.targetDirPath : trimmed)
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
