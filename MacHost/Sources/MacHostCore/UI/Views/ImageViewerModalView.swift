import SwiftUI
import ImageIO

extension KeyEquivalent {
    fileprivate static let f8Key = KeyEquivalent(Character(Unicode.Scalar(Int(NSF8FunctionKey))!))
}

public struct ImageViewerModalView: View {
    public let images: [FileItem]
    @State private var currentImages: [FileItem]
    @State public var currentIndex: Int
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var vm: DualPaneViewModel
    
    @State private var currentImage: NSImage?
    @State private var scale: CGFloat = 1.0
    @State private var preloadedImages: [Int: NSImage] = [:]
    @State private var showDeleteConfirm: Bool = false
    @State private var showTaggedError: Bool = false
    @State private var showDeleteError: Bool = false
    @State private var deleteErrorMessage: String = ""
    @State private var isDeleting: Bool = false
    /// Окно предзагрузки: только текущее изображение ±2, остальное вытесняется (защита от OOM).
    private static let preloadRadius = 2

    public init(images: [FileItem], startIndex: Int) {
        self.images = images
        self._currentImages = State(initialValue: images)
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
                .opacity(currentIndex + 1 < currentImages.count ? 1.0 : 0.2)
                .disabled(currentIndex + 1 >= currentImages.count)
            }
            
            // Верхняя плашка
            VStack {
                HStack(spacing: 12) {
                    if currentIndex < currentImages.count {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(currentImages[currentIndex].name)
                                .foregroundColor(.white)
                                .font(.headline)
                                .shadow(radius: 2)
                            Text("\(currentIndex + 1) из \(currentImages.count)")
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
                    
                    // Кнопка удаления файла
                    Button(action: promptDelete) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash.fill")
                            Text("Удалить")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.7))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.delete, modifiers: [])
                    .help("Удалить файл (⌫)")
                    .disabled(isDeleting || currentImages.isEmpty)
                    
                    // Дополнительные комбинации клавиш для удаления (Cmd+Delete и F8)
                    Button(action: promptDelete) { EmptyView() }
                        .keyboardShortcut(.delete, modifiers: [.command])
                        .frame(width: 0, height: 0)
                        .opacity(0)

                    Button(action: promptDelete) { EmptyView() }
                        .keyboardShortcut(.f8Key, modifiers: [])
                        .frame(width: 0, height: 0)
                        .opacity(0)
                    
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
        .alert("Подтверждение удаления", isPresented: $showDeleteConfirm) {
            Button("Удалить", role: .destructive) {
                deleteCurrentItem()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            if currentIndex < currentImages.count {
                let item = currentImages[currentIndex]
                if item.source == .localMac {
                    Text("Вы действительно хотите переместить «\(item.name)» в Корзину?")
                } else {
                    Text("Переместить «\(item.name)» в Корзину телефона? Файл можно восстановить через меню «Корзина телефона…».")
                }
            }
        }
        .alert("Удаление невозможно", isPresented: $showTaggedError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Чтобы удалить файл, вам необходимо снять тег.")
        }
        .alert("Ошибка удаления", isPresented: $showDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage)
        }
    }
    
    private func promptDelete() {
        guard !isDeleting, currentIndex >= 0, currentIndex < currentImages.count else { return }
        let item = currentImages[currentIndex]
        let (isTagged, _) = TagsManager.shared.isItemOrContentsTagged(item: item)
        if isTagged {
            showTaggedError = true
            return
        }
        showDeleteConfirm = true
    }
    
    private func deleteCurrentItem() {
        guard !isDeleting, currentIndex >= 0, currentIndex < currentImages.count else { return }
        let item = currentImages[currentIndex]
        isDeleting = true
        let driver: FileSystemDriver = (item.source == .localMac) ? vm.localDriver : vm.remoteDriver
        
        Task {
            do {
                try await driver.deleteItem(at: item.path, moveToTrash: true)
                await MainActor.run {
                    isDeleting = false
                    preloadedImages.removeValue(forKey: currentIndex)
                    var shifted: [Int: NSImage] = [:]
                    for (k, v) in preloadedImages {
                        if k < currentIndex {
                            shifted[k] = v
                        } else if k > currentIndex {
                            shifted[k - 1] = v
                        }
                    }
                    preloadedImages = shifted
                    
                    currentImages.remove(at: currentIndex)
                    vm.viewerImages = currentImages
                    
                    if vm.activePane == .left {
                        vm.leftSelection.remove(item.id)
                        vm.leftSelection.remove(item.path)
                    } else {
                        vm.rightSelection.remove(item.id)
                        vm.rightSelection.remove(item.path)
                    }
                    
                    if currentImages.isEmpty {
                        vm.showImageViewer = false
                        vm.refreshPane(side: vm.activePane)
                        if QuickLookBridge.shared.isVisible {
                            QuickLookBridge.shared.close()
                        }
                        dismiss()
                    } else {
                        if currentIndex >= currentImages.count {
                            currentIndex = currentImages.count - 1
                        }
                        vm.viewerStartIndex = currentIndex
                        vm.refreshPane(side: vm.activePane, selectNextAfterIndex: currentIndex)
                        scale = 1.0
                        pruneOutsideWindow()
                        loadCurrentImage()
                        prefetchNeighbors()
                        
                        if QuickLookBridge.shared.isVisible {
                            openInSystemQuickLook()
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    isDeleting = false
                    deleteErrorMessage = error.localizedDescription
                    showDeleteError = true
                }
            }
        }
    }
    
    private func next() {
        if currentIndex + 1 < currentImages.count {
            currentIndex += 1
            scale = 1.0
            pruneOutsideWindow()
            loadCurrentImage()
            prefetchNeighbors()
        }
    }

    private func prev() {
        if currentIndex > 0 {
            currentIndex -= 1
            scale = 1.0
            pruneOutsideWindow()
            loadCurrentImage()
            prefetchNeighbors()
        }
    }

    /// Удаляет предзагруженные изображения вне окна ±preloadRadius от текущего.
    private func pruneOutsideWindow() {
        let center = currentIndex
        preloadedImages = preloadedImages.filter { abs($0.key - center) <= Self.preloadRadius }
    }

    /// Сохраняет декодированное изображение только если оно входит в окно предзагрузки.
    private func storePreloaded(_ img: NSImage, at idx: Int) {
        guard abs(idx - currentIndex) <= Self.preloadRadius else { return }
        preloadedImages[idx] = img
        pruneOutsideWindow()
    }

    private func loadCurrentImage() {
        if let preloaded = preloadedImages[currentIndex] {
            self.currentImage = preloaded
            return
        }
        guard currentIndex < currentImages.count else { return }
        let item = currentImages[currentIndex]
        self.currentImage = nil

        if FileManager.default.fileExists(atPath: item.path) {
            DispatchQueue.global(qos: .userInitiated).async {
                let img = self.decodeHEICorStandard(url: URL(fileURLWithPath: item.path))
                DispatchQueue.main.async {
                    self.currentImage = img
                    if let img = img {
                        self.storePreloaded(img, at: self.currentIndex)
                    }
                }
            }
        } else if let cachedURL = QuickLookCacheManager.shared.isCached(for: item) {
            DispatchQueue.global(qos: .userInitiated).async {
                let img = self.decodeHEICorStandard(url: cachedURL)
                DispatchQueue.main.async {
                    self.currentImage = img
                    if let img = img {
                        self.storePreloaded(img, at: self.currentIndex)
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
                            self.storePreloaded(img, at: self.currentIndex)
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
                guard idx >= 0 && idx < self.currentImages.count && self.preloadedImages[idx] == nil else { continue }
                let item = self.currentImages[idx]

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
                        self.storePreloaded(img, at: idx)
                    }
                }
            }
        }
    }
    
    private func openInSystemQuickLook() {
        guard currentIndex < currentImages.count else { return }
        let item = currentImages[currentIndex]
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
