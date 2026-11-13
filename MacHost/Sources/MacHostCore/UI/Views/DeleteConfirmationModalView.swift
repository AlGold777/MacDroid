import SwiftUI
import AppKit

public enum DeleteDialogButton: Hashable, Sendable {
    case cancel
    case delete
}

public struct DeleteConfirmationModalView: View {
    @Binding public var isPresented: Bool
    public var vm: DualPaneViewModel?
    public var targetSide: PaneSide?
    public var customMessage: String?
    public var onConfirm: (() -> Void)?
    public var onCancel: (() -> Void)?

    @State private var focusedButton: DeleteDialogButton = .cancel
    @State private var hasExecuted: Bool = false

    public init(
        isPresented: Binding<Bool>,
        vm: DualPaneViewModel? = nil,
        targetSide: PaneSide? = nil,
        customMessage: String? = nil,
        onConfirm: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self._isPresented = isPresented
        self.vm = vm
        self.targetSide = targetSide
        self.customMessage = customMessage
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    private var messageText: String {
        if let customMessage = customMessage, !customMessage.isEmpty {
            return customMessage
        }
        guard let vm = vm else {
            return "Вы действительно хотите переместить выбранные объекты в Корзину?"
        }
        let side = targetSide ?? vm.activePane
        let activeSource = (side == .left ? vm.leftSource : vm.rightSource)
        let selectedIds = (side == .left ? vm.leftSelection : vm.rightSelection)
        let items = (side == .left ? vm.leftItems : vm.rightItems)
        let count = selectedIds.count

        let singleItemName: String? = {
            if count == 1, let firstId = selectedIds.first {
                if let matched = items.first(where: { $0.id == firstId || $0.path == firstId }) {
                    return matched.name
                }
                return URL(fileURLWithPath: firstId).lastPathComponent
            }
            return nil
        }()

        if activeSource == .localMac {
            if let name = singleItemName, !name.isEmpty {
                return "Вы действительно хотите переместить «\(name)» в Корзину?"
            } else {
                return "Вы действительно хотите переместить в Корзину \(count) выбранных объектов?"
            }
        } else {
            if let name = singleItemName, !name.isEmpty {
                return "Переместить «\(name)» в Корзину телефона? Файл можно восстановить через меню «Корзина телефона…»."
            } else {
                return "Переместить \(count) выбранных объектов в Корзину телефона? Их можно восстановить через меню «Корзина телефона…»."
            }
        }
    }

    private func doConfirm() {
        guard !hasExecuted else { return }
        hasExecuted = true
        isPresented = false
        if let onConfirm = onConfirm {
            onConfirm()
        } else if let vm = vm {
            vm.showDeleteConfirmDialog = false
            vm.confirmDelete()
        }
    }

    private func doCancel() {
        guard !hasExecuted else { return }
        hasExecuted = true
        isPresented = false
        if let onCancel = onCancel {
            onCancel()
        } else if let vm = vm {
            vm.showDeleteConfirmDialog = false
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Подтверждение удаления")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.primary)

                    Text(messageText)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Spacer()

                // Кнопка «Отмена»
                Button(action: {
                    focusedButton = .cancel
                    doCancel()
                }) {
                    Text("Отмена")
                        .font(.system(size: 13, weight: focusedButton == .cancel ? .semibold : .regular))
                        .foregroundColor(focusedButton == .cancel ? Color.white : ConflictColors.cancelBtnText)
                        .frame(minWidth: 76)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(focusedButton == .cancel ? Color.accentColor : ConflictColors.cancelBtnBg)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(
                                    focusedButton == .cancel ? Color.accentColor : ConflictColors.cancelBtnBorder,
                                    lineWidth: focusedButton == .cancel ? 2 : 1
                                )
                        )
                        .shadow(color: focusedButton == .cancel ? Color.accentColor.opacity(0.35) : Color.clear, radius: 2, y: 1)
                }
                .buttonStyle(.plain)

                // Кнопка «Удалить»
                Button(action: {
                    focusedButton = .delete
                    doConfirm()
                }) {
                    Text("Удалить")
                        .font(.system(size: 13, weight: focusedButton == .delete ? .semibold : .regular))
                        .foregroundColor(focusedButton == .delete ? Color.white : Color.red)
                        .frame(minWidth: 76)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(focusedButton == .delete ? Color.red : Color.red.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(
                                    focusedButton == .delete ? Color.red : Color.red.opacity(0.35),
                                    lineWidth: focusedButton == .delete ? 2 : 1
                                )
                        )
                        .shadow(color: focusedButton == .delete ? Color.red.opacity(0.4) : Color.clear, radius: 3, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
        )
        .background(
            DeleteConfirmationKeyHandler(
                focusedButton: $focusedButton,
                onConfirm: { doConfirm() },
                onCancel: { doCancel() }
            )
        )
    }
}

private struct DeleteConfirmationKeyHandler: NSViewRepresentable {
    @Binding var focusedButton: DeleteDialogButton
    let onConfirm: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        updateCallbacks(in: view)
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        updateCallbacks(in: view)
    }

    private func updateCallbacks(in view: KeyView) {
        view.focusedButton = focusedButton
        view.onFocusChanged = { newFocus in
            focusedButton = newFocus
        }
        view.onConfirm = onConfirm
        view.onCancel = onCancel
    }

    static func dismantleNSView(_ view: KeyView, coordinator: ()) {
        view.removeMonitor()
    }

    final class KeyView: NSView {
        var focusedButton: DeleteDialogButton = .cancel
        var onFocusChanged: ((DeleteDialogButton) -> Void)?
        var onConfirm: (() -> Void)?
        var onCancel: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                installMonitor()
            } else {
                removeMonitor()
            }
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self, let win = self.window else { return event }
                guard event.window === win || win.isKeyWindow || NSApp.keyWindow === win else {
                    return event
                }

                switch event.keyCode {
                case 123, 126: // Left Arrow, Up Arrow -> Отмена
                    self.focusedButton = .cancel
                    self.onFocusChanged?(.cancel)
                    return nil
                case 124, 125: // Right Arrow, Down Arrow -> Удалить
                    self.focusedButton = .delete
                    self.onFocusChanged?(.delete)
                    return nil
                case 48: // Tab
                    if event.modifierFlags.contains(.shift) {
                        self.focusedButton = .cancel
                    } else {
                        self.focusedButton = (self.focusedButton == .cancel ? .delete : .cancel)
                    }
                    self.onFocusChanged?(self.focusedButton)
                    return nil
                case 36, 76: // Enter / Return, Keypad Enter
                    if self.focusedButton == .delete {
                        self.onConfirm?()
                    } else {
                        self.onCancel?()
                    }
                    return nil
                case 49: // Space
                    if self.focusedButton == .delete {
                        self.onConfirm?()
                    } else {
                        self.onCancel?()
                    }
                    return nil
                case 53: // Escape
                    self.onCancel?()
                    return nil
                default:
                    return event
                }
            }
        }

        func removeMonitor() {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}
