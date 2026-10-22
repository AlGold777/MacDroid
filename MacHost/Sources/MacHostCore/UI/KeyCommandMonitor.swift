import AppKit

public enum TextShortcutAction {
    case copy
    case paste
    case cut
    case selectAll
}

/// Routes Ctrl+C/A/V/X and Cmd+C/A/V/X to the focused text editor instead of file-manager commands,
/// and ensures text editing controls receive all key events (including Space, Backspace, Return).
public final class KeyCommandMonitor {
    private static var monitor: Any?
    @MainActor public static var activeViewModel: DualPaneViewModel? {
        get { _activeViewModel ?? DualPaneViewModel.shared }
        set {
            _activeViewModel = newValue
            if let val = newValue {
                DualPaneViewModel.shared = val
            }
        }
    }
    private static weak var _activeViewModel: DualPaneViewModel?

    public static func installGlobalMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                handleEvent(event)
            }
        }
    }

    /// Determines if the responder is an active, editable or selectable text view / field.
    public static func isTextEditingResponder(_ responder: NSResponder?) -> Bool {
        guard let responder = responder else { return false }

        // Must not be a table view or outline view
        if responder is NSTableView || responder is NSOutlineView {
            return false
        }

        // Standard AppKit text view (including field editor in NSTextField & SwiftUI)
        if let tv = responder as? NSTextView {
            return tv.isEditable || tv.isSelectable
        }

        // NSTextField
        if let tf = responder as? NSTextField {
            return tf.isEditable || tf.isSelectable
        }

        // NSText base class
        if let text = responder as? NSText {
            return text.isEditable || text.isSelectable
        }

        // Any view conforming to NSTextInputClient (SwiftUI text views, WebKit, etc.)
        if responder is NSTextInputClient {
            return true
        }

        // Responders that handle copy or paste explicitly (e.g. MockTextResponder in tests)
        if responder.responds(to: #selector(NSText.copy(_:))) || responder.responds(to: #selector(NSText.paste(_:))) {
            return true
        }

        let className = String(describing: type(of: responder))
        if className.contains("TextField") || className.contains("TextView") || className.contains("TextEditor") {
            return true
        }

        return false
    }

    /// Checks whether text editing is currently active either via an editable responder in the window
    /// or via the DualPaneViewModel's editing states (inline rename, modal dialogs, manual path input, etc.).
    @MainActor
    public static func isTextEditingActive(in vm: DualPaneViewModel? = nil) -> Bool {
        if let vm = vm {
            if vm.editingItemId != nil { return true }
            if vm.showRenameDialog || vm.showNewFolderDialog || vm.showCreateArchiveDialog || vm.showSearchDialog { return true }
            if vm.isEditingLeftPath || vm.isEditingRightPath { return true }
            if vm.showPropertiesDialog || vm.showConflictDialog || vm.showQueueDialog || vm.batchRenameSession != nil || vm.isDuplicating || vm.showDuplicationModal { return true }
        }
        let responder = activeResponder()
        return isTextEditingResponder(responder)
    }

    /// Finds the active responder in the target window or key window.
    public static func activeResponder(for event: NSEvent? = nil, targetResponder: NSResponder? = nil) -> NSResponder? {
        if let target = targetResponder {
            return target
        }
        if let event = event, let w = event.window, let fr = w.firstResponder {
            return fr
        }
        let app = NSApplication.shared
        if let w = app.keyWindow, let fr = w.firstResponder {
            return fr
        }
        if let w = app.mainWindow, let fr = w.firstResponder {
            return fr
        }
        for w in app.windows where (w.isKeyWindow || w.isMainWindow || w.isVisible) && !w.className.contains("Desktop") {
            if let fr = w.firstResponder {
                return fr
            }
        }
        return nil
    }

    /// Identifies the shortcut action (Copy, Paste, Cut, Select All) from an NSEvent.
    public static func textAction(for event: NSEvent) -> TextShortcutAction? {
        let hasControl = event.modifierFlags.contains(.control) && !event.modifierFlags.contains(.command)
        let hasCommand = event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control)

        guard (hasControl || hasCommand), !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.shift) else {
            return nil
        }

        let code = Int(event.keyCode)
        let chars = event.charactersIgnoringModifiers?.lowercased()

        // Keycode 8 = C, Cyrillic 'с'
        if code == 8 || chars == "c" || chars == "с" {
            return .copy
        }
        // Keycode 9 = V, Cyrillic 'м'
        if code == 9 || chars == "v" || chars == "м" {
            return .paste
        }
        // Keycode 7 = X, Cyrillic 'ч'
        if code == 7 || chars == "x" || chars == "ч" {
            return .cut
        }
        // Keycode 0 = A, Cyrillic 'ф'
        if code == 0 || chars == "a" || chars == "ф" {
            return .selectAll
        }

        return nil
    }

    /// Returns nil when the event was handled (consuming the event).
    /// Returns the event unchanged when not handled or when responder is editing text.
    @MainActor
    public static func handleEvent(_ event: NSEvent, targetResponder: NSResponder? = nil) -> NSEvent? {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(event.keyCode)
        let chars = event.characters?.lowercased()
        let charsNoMods = event.charactersIgnoringModifiers?.lowercased()

        let hasControl = mods.contains(.control) && !mods.contains(.option)
        let hasCommand = mods.contains(.command) && !mods.contains(.option)
        let isCtrlOrCmd = (hasControl || hasCommand)

        // KeyCode 17 = T (English 't', Russian 'е', ASCII 20 \u{14})
        let isT = (code == 17 || chars == "\u{14}" || chars == "t" || chars == "е" || charsNoMods == "\u{14}" || charsNoMods == "t" || charsNoMods == "е")

        // KeyCode 15 = R (English 'r', Russian 'к', ASCII 18 \u{12})
        let isR = (code == 15 || chars == "\u{12}" || chars == "r" || chars == "к" || charsNoMods == "\u{12}" || charsNoMods == "r" || charsNoMods == "к")

        // Блокировка всех операций и клавиш при активном дублировании (Esc отменяет дублирование)
        if let vm = activeViewModel, vm.isDuplicating {
            if code == 53 && mods.isEmpty {
                vm.cancelDuplicate()
            }
            return nil
        }

        // 1. Создание новой вкладки: Ctrl+T или Cmd+T
        if isCtrlOrCmd && isT {
            if let vm = activeViewModel {
                if !vm.showRenameDialog && !vm.showNewFolderDialog && !vm.showCreateArchiveDialog && vm.editingItemId == nil {
                    print("KEY_MONITOR: Intercepted New Tab (Ctrl+T/Cmd+T) on side \(vm.activePane)")
                    vm.addTab(side: vm.activePane)
                    return nil
                }
            }
        }

        // 2. Обновление содержимого активной панели: Ctrl+R или Cmd+R
        if isCtrlOrCmd && isR {
            if let vm = activeViewModel {
                if !vm.showRenameDialog && !vm.showNewFolderDialog && !vm.showCreateArchiveDialog && vm.editingItemId == nil {
                    let targetSide = vm.activePane
                    print("KEY_MONITOR: Intercepted Refresh Tab (Ctrl+R/Cmd+R) on side \(targetSide)")
                    vm.refreshPaneToActiveTab(side: targetSide)
                    return nil
                }
            }
        }

        // 3. Закрытие поиска или сравнения файлов по клавише Esc (keyCode 53)
        if code == 53 && mods.isEmpty {
            if let vm = activeViewModel {
                if vm.isSearchActive(for: vm.activePane) {
                    vm.closeSearch(side: vm.activePane)
                    return nil
                }
                if vm.isFileDiffActive {
                    vm.closeFileDiff()
                    return nil
                }
            }
        }

        let responder = activeResponder(for: event, targetResponder: targetResponder)
        
        // 3. Если фокус находится в текстовом редакторе — обрабатываем только действия текста (копировать, вставить, вырезать, выделить всё)
        if isTextEditingResponder(responder) {
            if let action = textAction(for: event) {
                return performTextAction(action, targetResponder: responder) ? nil : event
            }
            return event
        }

        // Если открыт диалог ввода (переименование, модальные окна, ручной ввод пути), не перехватываем горячие клавиши
        if let vm = activeViewModel, isTextEditingActive(in: vm) {
            return event
        }

        // 4. Переключение между панелями: Tab или Shift+Tab (keyCode 48)
        if (code == 48 || chars == "\t" || charsNoMods == "\t") && (mods.isEmpty || mods == .shift) {
            if let vm = activeViewModel {
                print("KEY_MONITOR: Intercepted Tab switch pane")
                vm.toggleActivePane()
                return nil
            }
        }

        // 4. Горячие клавиши буфера обмена для файлов и папок (когда фокус в панели/таблице/сетке, а не в поле ввода текста)
        if let vm = activeViewModel {
            let hasShift = mods.contains(.shift)
            let isC = (code == 8 || charsNoMods == "c" || charsNoMods == "с" || chars == "c" || chars == "с" || chars == "\u{3}")
            let isX = (code == 7 || charsNoMods == "x" || charsNoMods == "ч" || chars == "x" || chars == "ч" || chars == "\u{18}")
            let isV = (code == 9 || charsNoMods == "v" || charsNoMods == "м" || chars == "v" || chars == "м" || chars == "\u{16}")

            // Ctrl+Shift+C или Cmd+Shift+C: Копирование имени объектов (с расширением)
            if isCtrlOrCmd && hasShift && isC {
                print("KEY_MONITOR: Intercepted Copy Names (Ctrl+Shift+C / Cmd+Shift+C) on side \(vm.activePane)")
                vm.copySelectedNamesToClipboard(side: vm.activePane)
                return nil
            }

            // Шорткаты без Shift:
            if isCtrlOrCmd && !hasShift {
                if isC {
                    print("KEY_MONITOR: Intercepted Copy Items (Ctrl+C / Cmd+C) on side \(vm.activePane)")
                    vm.copyToClipboard(side: vm.activePane)
                    return nil
                }
                if isX {
                    print("KEY_MONITOR: Intercepted Cut Items (Ctrl+X / Cmd+X) on side \(vm.activePane)")
                    vm.cutToClipboard(side: vm.activePane)
                    return nil
                }
                if isV {
                    print("KEY_MONITOR: Intercepted Paste Items (Ctrl+V / Cmd+V) on side \(vm.activePane)")
                    vm.pasteFromClipboard(targetSide: vm.activePane)
                    return nil
                }
            }
        }

        return event
    }

    /// Performs the specified text shortcut action on the active responder.
    @discardableResult
    public static func performTextAction(_ action: TextShortcutAction, targetResponder: NSResponder? = nil) -> Bool {
        guard let responder = activeResponder(targetResponder: targetResponder), isTextEditingResponder(responder) else {
            return false
        }

        let editor: NSTextView?
        if let tv = responder as? NSTextView {
            editor = tv
        } else if let tf = responder as? NSTextField {
            editor = tf.currentEditor() as? NSTextView
        } else {
            editor = nil
        }

        if let editor = editor {
            switch action {
            case .paste:
                guard editor.isEditable else { return false }
                if let str = NSPasteboard.general.string(forType: .string) {
                    editor.insertText(str, replacementRange: editor.selectedRange())
                } else {
                    editor.paste(nil)
                }
                return true
            case .copy:
                guard editor.isSelectable else { return false }
                editor.copy(nil)
                return true
            case .cut:
                guard editor.isEditable else { return false }
                editor.cut(nil)
                return true
            case .selectAll:
                guard editor.isSelectable else { return false }
                editor.selectAll(nil)
                return true
            }
        }

        switch action {
        case .paste:
            if let tf = responder as? NSTextField, tf.isEditable {
                if let str = NSPasteboard.general.string(forType: .string) {
                    tf.stringValue = str
                    return true
                }
            }
            return responder.tryToPerform(#selector(NSText.paste(_:)), with: nil)
        case .copy:
            if let tf = responder as? NSTextField, tf.isSelectable {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tf.stringValue, forType: .string)
                return true
            }
            return responder.tryToPerform(#selector(NSText.copy(_:)), with: nil)
        case .cut:
            if let tf = responder as? NSTextField, tf.isEditable {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tf.stringValue, forType: .string)
                tf.stringValue = ""
                return true
            }
            return responder.tryToPerform(#selector(NSText.cut(_:)), with: nil)
        case .selectAll:
            if let tf = responder as? NSTextField {
                tf.selectText(nil)
                return true
            }
            return responder.tryToPerform(#selector(NSText.selectAll(_:)), with: nil)
        }
    }

    /// Handles shortcut by keyCode (0: A, 7: X, 8: C, 9: V).
    /// Returns false when the first responder is not an editable/selectable text field.
    @discardableResult
    public static func performTextShortcut(keyCode: Int, targetResponder: NSResponder? = nil) -> Bool {
        let action: TextShortcutAction
        switch keyCode {
        case 9: action = .paste
        case 8: action = .copy
        case 7: action = .cut
        case 0: action = .selectAll
        default: return false
        }
        return performTextAction(action, targetResponder: targetResponder)
    }
}
