import SwiftUI
import ImageIO

public struct ImageViewerModalView: View {
    public let images: [FileItem]
    @State public var currentIndex: Int
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var vm: DualPaneViewModel
    
    @State private var currentImage: NSImage?
    @State private var scale: CGFloat = 1.0
    @State private var preloadedImages: [Int: NSImage] = [:]
    
    public init(images: [FileItem], startIndex: Int) {
        self.images = images
        self._currentIndex = State(initialValue: startIndex)
    }
    
    public var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if let img = currentImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .gesture(MagnificationGesture().onChanged { val in self.scale = val })
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                    Text("Загрузка изображения...")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            
            // Навигационные стрелки
            HStack {
                Button(action: prev) {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .padding(.leading, 20)
                .opacity(currentIndex > 0 ? 1.0 : 0.2)
                .disabled(currentIndex == 0)
                
                Spacer()
                
                Button(action: next) {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .padding(.trailing, 20)
                .opacity(currentIndex + 1 < images.count ? 1.0 : 0.2)
                .disabled(currentIndex + 1 >= images.count)
            }
            
            // Верхняя плашка
            VStack {
                HStack(spacing: 12) {
                    if currentIndex < images.count {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(images[currentIndex].name)
                                .foregroundColor(.white)
                                .font(.headline)
                                .shadow(radius: 2)
                            Text("\(currentIndex + 1) из \(images.count)")
                                .foregroundColor(.white.opacity(0.7))
                                .font(.caption2)
                        }
                    }
                    
                    Spacer()
                    
                    // Кнопка вызова нативного системного Quick Look
                    Button(action: openInSystemQuickLook) {
                        HStack(spacing: 4) {
                            Image(systemName: "eye.circle.fill")
                            Text("Quick Look")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    .help("Открыть в системном Quick Look macOS (Пробел)")
                    
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding()
                Spacer()
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            loadCurrentImage()
            prefetchNeighbors()
        }
    }
    
    private func next() {
        if currentIndex + 1 < images.count {
            currentIndex += 1
            scale = 1.0
            loadCurrentImage()
            prefetchNeighbors()
        }
    }
    
    private func prev() {
        if currentIndex > 0 {
            currentIndex -= 1
            scale = 1.0
            loadCurrentImage()
            prefetchNeighbors()
        }
    }
    
    private func loadCurrentImage() {
        if let preloaded = preloadedImages[currentIndex] {
            self.currentImage = preloaded
            return
        }
        guard currentIndex < images.count else { return }
        let item = images[currentIndex]
        self.currentImage = nil
        
        if FileManager.default.fileExists(atPath: item.path) {
            DispatchQueue.global(qos: .userInitiated).async {
                let img = self.decodeHEICorStandard(url: URL(fileURLWithPath: item.path))
                DispatchQueue.main.async {
                    self.currentImage = img
                    if let img = img {
                        self.preloadedImages[self.currentIndex] = img
                    }
                }
            }
        } else if let cachedURL = QuickLookCacheManager.shared.isCached(for: item) {
            DispatchQueue.global(qos: .userInitiated).async {
                let img = self.decodeHEICorStandard(url: cachedURL)
                DispatchQueue.main.async {
                    self.currentImage = img
                    if let img = img {
                        self.preloadedImages[self.currentIndex] = img
                    }
                }
            }
        } else {
            Task {
                if let localURL = await vm.downloadRemoteFile(item: item) {
                    let img = self.decodeHEICorStandard(url: localURL)
                    await MainActor.run {
                        self.currentImage = img
                        if let img = img {
                            self.preloadedImages[self.currentIndex] = img
                        }
                    }
                }
            }
        }
    }
    
    private func prefetchNeighbors() {
        Task {
            for offset in [-1, 1, -2, 2] {
                let idx = self.currentIndex + offset
                guard idx >= 0 && idx < self.images.count && self.preloadedImages[idx] == nil else { continue }
                let item = self.images[idx]
                
                let localURL: URL?
                if FileManager.default.fileExists(atPath: item.path) {
                    localURL = URL(fileURLWithPath: item.path)
                } else if let cached = QuickLookCacheManager.shared.isCached(for: item) {
                    localURL = cached
                } else {
                    localURL = await vm.downloadRemoteFile(item: item)
                }
                
                if let url = localURL, let img = self.decodeHEICorStandard(url: url) {
                    await MainActor.run {
                        self.preloadedImages[idx] = img
                    }
                }
            }
        }
    }
    
    private func openInSystemQuickLook() {
        guard currentIndex < images.count else { return }
        let item = images[currentIndex]
        if FileManager.default.fileExists(atPath: item.path) {
            QuickLookBridge.shared.preview(url: URL(fileURLWithPath: item.path))
        } else if let cached = QuickLookCacheManager.shared.isCached(for: item) {
            QuickLookBridge.shared.preview(url: cached)
        } else {
            Task {
                if let url = await vm.downloadRemoteFile(item: item) {
                    await MainActor.run {
                        QuickLookBridge.shared.preview(url: url)
                    }
                }
            }
        }
    }
    
    private func decodeHEICorStandard(url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSImage(contentsOf: url)
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 3840,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
    }
}
