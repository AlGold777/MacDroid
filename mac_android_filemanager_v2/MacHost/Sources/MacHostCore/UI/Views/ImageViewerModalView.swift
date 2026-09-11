import SwiftUI
import ImageIO

public struct ImageViewerModalView: View {
    public let images: [FileItem]
    @State public var currentIndex: Int
    @Environment(\.dismiss) var dismiss
    
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
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            }
            
            // Навигационные стрелки
            HStack {
                Button(action: prev) {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .padding(.leading, 20)
                
                Spacer()
                
                Button(action: next) {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 20)
            }
            
            // Верхняя плашка
            VStack {
                HStack {
                    if currentIndex < images.count {
                        Text(images[currentIndex].name)
                            .foregroundColor(.white)
                            .font(.headline)
                            .shadow(radius: 2)
                    }
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
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
        
        DispatchQueue.global(qos: .userInitiated).async {
            let img = self.decodeHEICorStandard(url: URL(fileURLWithPath: item.path))
            DispatchQueue.main.async {
                self.currentImage = img
            }
        }
    }
    
    private func prefetchNeighbors() {
        DispatchQueue.global(qos: .background).async {
            for offset in [-2, -1, 1, 2] {
                let idx = self.currentIndex + offset
                if idx >= 0 && idx < self.images.count && self.preloadedImages[idx] == nil {
                    let url = URL(fileURLWithPath: self.images[idx].path)
                    if let img = self.decodeHEICorStandard(url: url) {
                        DispatchQueue.main.async {
                            self.preloadedImages[idx] = img
                        }
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
