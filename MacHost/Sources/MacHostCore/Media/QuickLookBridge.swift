import Foundation
import AppKit
import Quartz

@MainActor
public final class QuickLookBridge: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    public static let shared = QuickLookBridge()
    private var previewURL: URL?
    private var currentItem: (any QLPreviewItem)?
    private var onCloseCleanup: (() -> Void)?
    
    public var onNavigateNext: (() -> Void)?
    public var onNavigatePrevious: (() -> Void)?
    
    public var isVisible: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return false }
        return QLPreviewPanel.shared()?.isVisible ?? false
    }
    
    public var currentPreviewURL: URL? {
        return previewURL
    }
    
    public var currentPreviewItem: (any QLPreviewItem)? {
        return currentItem
    }

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(previewWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }
    
    public func preview(url: URL, title: String? = nil, onClose: (() -> Void)? = nil) {
        let previousCleanup = replacePreviewState(url: url, title: title, onClose: onClose)
        defer { previousCleanup?() }
        guard NSApp != nil, !NSApp.windows.isEmpty else { return }
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        panel.refreshCurrentPreviewItem()
    }
    
    /// Динамическое обновление отображаемого файла в уже открытом окне без перехвата фокуса клавиатуры
    public func updatePreview(url: URL, title: String? = nil) {
        let previousCleanup = replacePreviewState(url: url, title: title, onClose: nil)
        defer { previousCleanup?() }
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.refreshCurrentPreviewItem()
    }
    
    public func close() {
        let cleanup = clearPreviewState()
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        }
        cleanup?()
    }

    private func replacePreviewState(url: URL, title: String?, onClose: (() -> Void)?) -> (() -> Void)? {
        let isNewURL = previewURL != url
        let previousCleanup: (() -> Void)?
        if isNewURL {
            previousCleanup = onCloseCleanup
            onCloseCleanup = onClose
        } else {
            previousCleanup = nil
            if onCloseCleanup == nil { onCloseCleanup = onClose }
        }
        previewURL = url
        currentItem = preparePreviewItem(for: url, title: title)
        return previousCleanup
    }

    /// Clears state before returning the callback so reentrant close notifications cannot run cleanup twice.
    private func clearPreviewState() -> (() -> Void)? {
        previewURL = nil
        currentItem = nil
        let cleanup = onCloseCleanup
        onCloseCleanup = nil
        return cleanup
    }

    @objc private func previewWindowWillClose(_ notification: Notification) {
        guard notification.object is QLPreviewPanel else { return }
        let cleanup = clearPreviewState()
        cleanup?()
    }
    
    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return currentItem != nil ? 1 : 0
    }
    
    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        return currentItem
    }
    
    // MARK: - Подготовка элемента Quick Look (включая GFM Markdown -> HTML)
    
    private func preparePreviewItem(for url: URL, title: String?) -> any QLPreviewItem {
        let displayTitle = title ?? url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let titleExt = URL(fileURLWithPath: displayTitle).pathExtension.lowercased()
        let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]
        
        let isMarkdown = markdownExtensions.contains(ext) || markdownExtensions.contains(titleExt)
        if isMarkdown {
            if let htmlURL = generateMarkdownPreviewHTML(from: url, title: displayTitle) {
                return QuickLookPreviewItem(url: htmlURL, title: displayTitle)
            }
        }
        
        return QuickLookPreviewItem(url: url, title: displayTitle)
    }
    
    private func generateMarkdownPreviewHTML(from sourceURL: URL, title: String) -> URL? {
        do {
            let data = try Data(contentsOf: sourceURL)
            let markdown: String
            if let str = String(data: data, encoding: .utf8) {
                markdown = str
            } else {
                markdown = String(decoding: data, as: UTF8.self)
            }
            
            let html = GFMMarkdownRenderer.shared.renderToHTML(markdown: markdown, title: title)
            
            let cacheDir = QuickLookCacheManager.shared.cacheDir.appendingPathComponent("md_previews")
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            
            let safeName = title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "preview"
            let fileHash = abs(sourceURL.path.hashValue)
            let htmlFilename = "\(safeName)_\(fileHash).html"
            let targetHTMLURL = cacheDir.appendingPathComponent(htmlFilename)
            
            try html.write(to: targetHTMLURL, atomically: true, encoding: .utf8)
            return targetHTMLURL
        } catch {
            print("ERROR: Failed to generate GFM preview for \(sourceURL): \(error)")
            return nil
        }
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

/// Элемент быстрого просмотра Quick Look, поддерживающий кастомный URL (например, сгенерированный HTML) и отображаемый заголовок
public final class QuickLookPreviewItem: NSObject, QLPreviewItem {
    public let previewItemURL: URL?
    public let previewItemTitle: String?
    
    public init(url: URL?, title: String? = nil) {
        self.previewItemURL = url
        self.previewItemTitle = title ?? url?.lastPathComponent
        super.init()
    }
}


