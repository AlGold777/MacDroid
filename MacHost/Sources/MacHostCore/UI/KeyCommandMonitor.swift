import AppKit

/// Перехватчик глобальных клавиатурных команд, обеспечивающий работу Ctrl+V, Ctrl+C, Ctrl+X, Ctrl+A
/// во всех текстовых полях приложения (фильтр, ручной ввод пути, поиск, переименование, модальные окна).
public final class KeyCommandMonitor {
    private static var monitor: Any?
    
    /// Устанавливает глобальный монитор событий нажатия клавиш
    public static func installGlobalMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            return handleEvent(event)
        }
    }
    
    /// Обрабатывает событие keyDown. Возвращает nil, если событие обработано и должно быть поглощено,
    /// либо возвращает исходное событие, если оно не относится к текстовым полям.
    public static func handleEvent(_ event: NSEvent, targetResponder: NSResponder? = nil) -> NSEvent? {
        // Проверяем наличие модификатора Control и отсутствие Command
        let isControl = event.modifierFlags.contains(.control) && !event.modifierFlags.contains(.command)
        guard isControl else { return event }
        
        let chars = event.charactersIgnoringModifiers?.lowercased()
        let isV = (chars == "v" || event.keyCode == 9)
        let isC = (chars == "c" || event.keyCode == 8)
        let isX = (chars == "x" || event.keyCode == 7)
        let isA = (chars == "a" || event.keyCode == 0)
        
        guard isV || isC || isX || isA else { return event }
        
        // Получаем текущий активный responder (или явно переданный responder)
        guard let responder = targetResponder ?? (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder else {
            return event
        }
        
        // Проверяем, является ли responder текстовым элементом
        let isTextInput = (responder is NSText) || (responder is NSTextView) || (responder is NSTextField) || responder.responds(to: #selector(NSText.paste(_:)))
        guard isTextInput else { return event }
        
        if isV {
            // Вставка текста из буфера обмена (Ctrl+V)
            if let tv = responder as? NSTextView, tv.isEditable {
                if let str = NSPasteboard.general.string(forType: .string) {
                    tv.insertText(str, replacementRange: tv.selectedRange())
                } else {
                    tv.paste(nil)
                }
                return nil
            } else if let tf = responder as? NSTextField, tf.isEditable {
                if let editor = tf.currentEditor() as? NSTextView {
                    if let str = NSPasteboard.general.string(forType: .string) {
                        editor.insertText(str, replacementRange: editor.selectedRange())
                    } else {
                        editor.paste(nil)
                    }
                } else {
                    _ = tf.tryToPerform(#selector(NSText.paste(_:)), with: nil)
                }
                return nil
            } else if responder.responds(to: #selector(NSText.paste(_:))) {
                _ = responder.tryToPerform(#selector(NSText.paste(_:)), with: nil)
                return nil
            }
        } else if isC {
            // Копирование текста в буфер обмена (Ctrl+C)
            if let tv = responder as? NSTextView {
                tv.copy(nil)
                return nil
            } else if let tf = responder as? NSTextField {
                if let editor = tf.currentEditor() as? NSTextView {
                    editor.copy(nil)
                } else {
                    _ = tf.tryToPerform(#selector(NSText.copy(_:)), with: nil)
                }
                return nil
            } else if responder.responds(to: #selector(NSText.copy(_:))) {
                _ = responder.tryToPerform(#selector(NSText.copy(_:)), with: nil)
                return nil
            }
        } else if isX {
            // Вырезание текста (Ctrl+X)
            if let tv = responder as? NSTextView, tv.isEditable {
                tv.cut(nil)
                return nil
            } else if let tf = responder as? NSTextField, tf.isEditable {
                if let editor = tf.currentEditor() as? NSTextView {
                    editor.cut(nil)
                } else {
                    _ = tf.tryToPerform(#selector(NSText.cut(_:)), with: nil)
                }
                return nil
            } else if responder.responds(to: #selector(NSText.cut(_:))) {
                _ = responder.tryToPerform(#selector(NSText.cut(_:)), with: nil)
                return nil
            }
        } else if isA {
            // Выделение всего текста (Ctrl+A)
            if let tv = responder as? NSTextView {
                tv.selectAll(nil)
                return nil
            } else if let tf = responder as? NSTextField {
                tf.selectText(nil)
                return nil
            } else if responder.responds(to: #selector(NSText.selectAll(_:))) {
                _ = responder.tryToPerform(#selector(NSText.selectAll(_:)), with: nil)
                return nil
            }
        }
        
        return event
    }
}
