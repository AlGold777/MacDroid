import SwiftUI
import AppKit
import ImageIO

public struct QuickViewPaneView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    public let item: FileItem?
    
    @State private var loadedImage: NSImage? = nil
    @State private var imageResolution: CGSize = .zero
    @State private var isLoading: Bool = false
    @State private var loadError: String? = nil
    
    private static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "dng", "webp", "gif", "bmp", "tiff", "tif"
    ]
    
    public init(item: FileItem?) {
        self.item = item
    }
    
    private var isImage: Bool {
        guard let item = item else { return false }
        let ext = URL(fileURLWithPath: item.name).pathExtension.lowercased()
        return Self.supportedImageExtensions.contains(ext)
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Верхняя плашка управления режимом
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "eye.fill")
                        .foregroundColor(.accentColor)
                    Text("Быстрый просмотр (Quick View)")
                        .font(.system(size: 11, weight: .semibold))
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
            loadImageIfNeeded()
        }
        .onChange(of: item?.id) { _ in
            loadImageIfNeeded()
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
                    Text(item.source == .localMac ? "MacBook" : "Xiaomi 14 Ultra")
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
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 64))
                .foregroundColor(item.isDirectory ? .yellow : .blue)
            
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
    
    private func loadImageIfNeeded() {
        guard let item = item, isImage else {
            loadedImage = nil
            imageResolution = .zero
            isLoading = false
            loadError = nil
            return
        }
        
        loadedImage = nil
        imageResolution = .zero
        loadError = nil
        isLoading = true
        
        // Проверяем кэш миниатюр
        if let cached = ThumbnailCacheManager.shared.getThumbnail(for: item.path) {
            self.loadedImage = cached
            self.imageResolution = cached.size
            self.isLoading = false
            return
        }
        
        if item.source == .localMac {
            DispatchQueue.global(qos: .userInitiated).async {
                let url = URL(fileURLWithPath: item.path)
                let img = self.decodeImage(url: url)
                DispatchQueue.main.async {
                    self.isLoading = false
                    if let img = img {
                        self.loadedImage = img
                        self.imageResolution = img.size
                        ThumbnailCacheManager.shared.storeThumbnail(image: img, for: item.path)
                    } else {
                        self.loadError = "Не удалось декодировать изображение"
                    }
                }
            }
        } else {
            // Удалённый файл с телефона: скачиваем во временный кэш
            let fileName = item.name
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacDroidQuickView")
                .appendingPathComponent(fileName)
            
            Task {
                do {
                    try FileManager.default.createDirectory(
                        at: tempURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    
                    try await vm.downloadRemoteFile(
                        remotePath: item.path,
                        targetURL: tempURL,
                        totalSize: item.size
                    )
                    
                    let img = self.decodeImage(url: tempURL)
                    await MainActor.run {
                        self.isLoading = false
                        if let img = img {
                            self.loadedImage = img
                            self.imageResolution = img.size
                            ThumbnailCacheManager.shared.storeThumbnail(image: img, for: item.path)
                        } else {
                            self.loadError = "Не удалось декодировать фото с телефона"
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.isLoading = false
                        self.loadError = "Ошибка загрузки: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
    
    private func decodeImage(url: URL) -> NSImage? {
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
