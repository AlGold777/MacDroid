import AppKit

/// Routes Ctrl+C/A/V/X to the focused text editor instead of file-manager commands.
public final class KeyCommandMonitor {
    private static var monitor: Any?

    public static func installGlobalMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleEvent(event)
        }
    }

    /// Returns nil when the event was handled in the focused text editor.
    public static func handleEvent(_ event: NSEvent, targetResponder: NSResponder? = nil) -> NSEvent? {
        guard event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command) else {
            return event
        }

        return performTextShortcut(keyCode: Int(event.keyCode), targetResponder: targetResponder) ? nil : event
    }

    /// Handles a Control shortcut when a menu command wins key-equivalent routing.
    /// Returns false when the first responder is not an editable/selectable text field.
    @discardableResult
    public static func performTextShortcut(keyCode: Int, targetResponder: NSResponder? = nil) -> Bool {
        guard keyCode == 9 || keyCode == 8 || keyCode == 7 || keyCode == 0 else { return false }
        guard let responder = targetResponder ?? (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder else {
            return false
        }

        let editor: NSTextView?
        if let textView = responder as? NSTextView {
            editor = textView
        } else if let textField = responder as? NSTextField {
            editor = textField.currentEditor() as? NSTextView
        } else {
            return false
        }

        guard let editor else { return false }

        switch keyCode {
        case 9: // Ctrl+V
            guard editor.isEditable else { return false }
            editor.paste(nil)
        case 8: // Ctrl+C
            guard editor.isSelectable else { return false }
            editor.copy(nil)
        case 7: // Ctrl+X
            guard editor.isEditable else { return false }
            editor.cut(nil)
        case 0: // Ctrl+A
            guard editor.isSelectable else { return false }
            editor.selectAll(nil)
        default:
            return false
        }

        return true
    }
}
