import SwiftUI
import AppKit
import ImageIO
import WebKit

public struct QuickViewPaneView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    public let item: FileItem?
    
    @State private var loadedImage: NSImage? = nil
    @State private var imageResolution: CGSize = .zero
    @State private var markdownHTML: String? = nil
    @State private var isLoading: Bool = false
    @State private var loadError: String? = nil
    @State private var loadGeneration: Int = 0
    
    private static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "dng", "webp", "gif", "bmp", "tiff", "tif"
    ]
    
    private static let supportedMarkdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn"
    ]
    
    public init(item: FileItem?) {
        self.item = item
    }
    
    private var isImage: Bool {
        guard let item = item else { return false }
        let ext = URL(fileURLWithPath: item.name).pathExtension.lowercased()
        return Self.supportedImageExtensions.contains(ext)
    }
    
    private var isMarkdown: Bool {
        guard let item = item else { return false }
        let ext = URL(fileURLWithPath: item.name).pathExtension.lowercased()
        return Self.supportedMarkdownExtensions.contains(ext)
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Верхняя плашка управления режимом
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "eye.fill")
                        .foregroundColor(.accentColor)
                    Text("Быстрый просмотр (Quick View)")
                        .font(.system(size: 12, weight: .semibold))
                }
                Spacer()
                Button(action: { vm.isQuickViewActive = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Закрыть быстрый просмотр")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // Основная область содержимого
            if let currentItem = item {
                if isImage {
                    imagePreviewArea(item: currentItem)
                } else if isMarkdown {
                    markdownPreviewArea(item: currentItem)
                } else {
                    filePreviewArea(item: currentItem)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 44))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Выберите файл для просмотра")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .onAppear {
            loadContentIfNeeded()
        }
        .onChange(of: item?.id) { _, _ in
            loadContentIfNeeded()
        }
    }
    
    @ViewBuilder
    private func markdownPreviewArea(item: FileItem) -> some View {
        VStack(spacing: 0) {
            if let html = markdownHTML {
                MarkdownWebView(htmlContent: html)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Рендеринг Markdown (GFM)...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(.orange)
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            Divider()
            
            // Информационный подвал с метаданными
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                    Text("GFM Markdown Документ")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text(item.source == .localMac ? "Mac" : "Phone")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
    
    @ViewBuilder
    private func imagePreviewArea(item: FileItem) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.85)
                
                if let img = loadedImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else if isLoading {
                    VStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                        Text("Загрузка изображения...")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                } else if let err = loadError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 32))
                            .foregroundColor(.orange)
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Divider()
            
            // Информационный подвал с метаданными
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                    if imageResolution != .zero {
                        Text("\(Int(imageResolution.width)) × \(Int(imageResolution.height)) px")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text(item.source == .localMac ? "Mac" : "Phone")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
    
    @ViewBuilder
    private func filePreviewArea(item: FileItem) -> some View {
        VStack(spacing: 16) {
            FileItemIconView(isDirectory: item.isDirectory, fileName: item.name, size: 64)
            
            VStack(spacing: 4) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                
                Text(item.isDirectory ? "Папка" : ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Text("Путь: \(item.path)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal)
            }
            
            Button("Открыть файл") {
                vm.openFile(item: item)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private func loadContentIfNeeded() {
        guard let item = item else {
            loadGeneration += 1
            loadedImage = nil
            imageResolution = .zero
            markdownHTML = nil
            isLoading = false
            loadError = nil
            return
        }
        
        // Поколение загрузки: результат устаревшей загрузки (элемент уже сменился) не применяется.
        loadGeneration += 1
        let generation = loadGeneration
        
        if isImage {
            loadImage(for: item, generation: generation)
        } else if isMarkdown {
            loadMarkdown(for: item, generation: generation)
        } else {
            loadedImage = nil
            imageResolution = .zero
            markdownHTML = nil
            isLoading = false
            loadError = nil
        }
    }
    
    private func loadMarkdown(for item: FileItem, generation: Int) {
        loadedImage = nil
        imageResolution = .zero
        markdownHTML = nil
        loadError = nil
        isLoading = true
        
        if item.source == .localMac {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let url = URL(fileURLWithPath: item.path)
                    let data = try Data(contentsOf: url)
                    let mdStr = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                    let html = GFMMarkdownRenderer.shared.renderToHTML(markdown: mdStr, title: item.name)
                    DispatchQueue.main.async {
                        guard generation == self.loadGeneration else { return }
                        self.isLoading = false
                        self.markdownHTML = html
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard generation == self.loadGeneration else { return }
                        self.isLoading = false
                        self.loadError = "Не удалось прочитать Markdown файл: \(error.localizedDescription)"
                    }
                }
            }
        } else {
            // Удалённый файл
            Task {
                if let cached = QuickLookCacheManager.shared.isCached(for: item) {
                    do {
                        let data = try Data(contentsOf: cached)
                        let mdStr = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                        let html = GFMMarkdownRenderer.shared.renderToHTML(markdown: mdStr, title: item.name)
                        await MainActor.run {
                            guard generation == self.loadGeneration else { return }
                            self.isLoading = false
                            self.markdownHTML = html
                        }
                        return
                    } catch {}
                }
                
                let targetURL = QuickLookCacheManager.shared.cacheURL(for: item)
                do {
                    try await vm.downloadRemoteFile(
                        remotePath: item.path,
                        targetURL: targetURL,
                        totalSize: item.size
                    )
                    let data = try Data(contentsOf: targetURL)
                    let mdStr = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                    let html = GFMMarkdownRenderer.shared.renderToHTML(markdown: mdStr, title: item.name)
                    await MainActor.run {
                        guard generation == self.loadGeneration else { return }
                        self.isLoading = false
                        self.markdownHTML = html
                    }
                } catch {
                    await MainActor.run {
                        guard generation == self.loadGeneration else { return }
                        self.isLoading = false
                        self.loadError = "Ошибка загрузки Markdown: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
    
    private func loadImage(for item: FileItem, generation: Int) {
        markdownHTML = nil
        loadedImage = nil
        imageResolution = .zero
        loadError = nil
        isLoading = true
        
        // Кэш миниатюр по тому же ключу, что и в сетке (путь + размер + mtime)
        if let cached = ThumbnailCacheManager.shared.getThumbnail(for: item) {
            self.loadedImage = cached
            self.imageResolution = cached.size
            self.isLoading = false
            return
        }
        
        if item.source == .localMac {
            DispatchQueue.global(qos: .userInitiated).async {
                let url = URL(fileURLWithPath: item.path)
                let img = QuickViewPaneView.decodeImage(url: url)
                DispatchQueue.main.async {
                    if let img = img {
                        ThumbnailCacheManager.shared.storeThumbnail(image: img, for: item)
                    }
                    guard generation == self.loadGeneration else { return }
                    self.isLoading = false
                    if let img = img {
                        self.loadedImage = img
                        self.imageResolution = img.size
                    } else {
                        self.loadError = "Не удалось декодировать изображение"
                    }
                }
            }
        } else {
            // Удалённый файл с телефона: уникальный временный каталог на каждую загрузку,
            // чтобы параллельные загрузки файлов с одинаковым именем не портили друг друга.
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacDroidQuickView", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let tempURL = workDir.appendingPathComponent(item.name)
            
            Task {
                defer { try? FileManager.default.removeItem(at: workDir) }
                do {
                    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                    
                    try await vm.downloadRemoteFile(
                        remotePath: item.path,
                        targetURL: tempURL,
                        totalSize: item.size
                    )
                    
                    // Декод вне главного потока
                    let img = await Task.detached(priority: .userInitiated) {
                        QuickViewPaneView.decodeImage(url: tempURL)
                    }.value
                    await MainActor.run {
                        if let img = img {
                            ThumbnailCacheManager.shared.storeThumbnail(image: img, for: item)
                        }
                        guard generation == self.loadGeneration else { return }
                        self.isLoading = false
                        if let img = img {
                            self.loadedImage = img
                            self.imageResolution = img.size
                        } else {
                            self.loadError = "Не удалось декодировать фото с телефона"
                        }
                    }
                } catch {
                    await MainActor.run {
                        guard generation == self.loadGeneration else { return }
                        self.isLoading = false
                        self.loadError = "Ошибка загрузки: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
    
    private static func decodeImage(url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSImage(contentsOf: url)
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        if let cgImg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
        }
        return NSImage(contentsOf: url)
    }
}

/// Нативный веб-компонент WebKit для отображения GFM Markdown в панели быстрого просмотра
struct MarkdownWebView: NSViewRepresentable {
    let htmlContent: String
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadHTMLString(htmlContent, baseURL: nil)
    }
}
