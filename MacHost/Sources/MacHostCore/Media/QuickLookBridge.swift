import Foundation
import AppKit
import Quartz

@MainActor
public final class QuickLookBridge: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    public static let shared = QuickLookBridge()
    private var previewURL: URL?
    
    public var onNavigateNext: (() -> Void)?
    public var onNavigatePrevious: (() -> Void)?
    
    public var isVisible: Bool {
        guard Thread.isMainThread else { return false }
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return false }
        return QLPreviewPanel.shared()?.isVisible ?? false
    }
    
    public var currentPreviewURL: URL? {
        return previewURL
    }
    
    public func preview(url: URL) {
        guard Thread.isMainThread else { return }
        self.previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        panel.refreshCurrentPreviewItem()
    }
    
    /// Динамическое обновление отображаемого файла в уже открытом окне без перехвата фокуса клавиатуры
    public func updatePreview(url: URL) {
        guard Thread.isMainThread else { return }
        self.previewURL = url
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.refreshCurrentPreviewItem()
    }
    
    public func close() {
        self.previewURL = nil
        guard Thread.isMainThread else { return }
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.orderOut(nil)
    }
    
    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return previewURL != nil ? 1 : 0
    }
    
    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        return previewURL as NSURL?
    }
    
    // Перехват событий клавиатуры, когда окно Quick Look находится в фокусе (как в macOS Finder)
    public func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        
        // Space (49) без модификаторов -> закрытие предпросмотра (toggle)
        if event.keyCode == 49 && modifiers.isEmpty {
            close()
            return true
        }
        
        // Esc (53) -> закрытие
        if event.keyCode == 53 && modifiers.isEmpty {
            close()
            return true
        }
        
        // Стрелка вниз (125) или вправо (124) -> следующий файл
        if (event.keyCode == 125 || event.keyCode == 124) && modifiers.isEmpty {
            if let onNavigateNext = onNavigateNext {
                onNavigateNext()
                return true
            }
        }
        
        // Стрелка вверх (126) или влево (123) -> предыдущий файл
        if (event.keyCode == 126 || event.keyCode == 123) && modifiers.isEmpty {
            if let onNavigatePrevious = onNavigatePrevious {
                onNavigatePrevious()
                return true
            }
        }
        
        return false
    }
}

// Интеграция с responder chain окон macOS, чтобы панель Quick Look не закрывалась при смене фокуса
extension NSWindow {
    @objc open override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        return true
    }
    
    @objc open override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLookBridge.shared
        panel.delegate = QuickLookBridge.shared
    }
    
    @objc open override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    }
}


