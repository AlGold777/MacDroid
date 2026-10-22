import SwiftUI

/// Набор иконок тулбара в едином векторном контурном стиле (Lucide / Lumina).
public enum ToolbarIcon: Sendable {
    case copy
    case move
    case newFolder
    case delete
    case rename
    case comparePanes
    case compareFiles
    case search
    case refresh
    case viewGrid
    case viewTable
    case foldersSeparate
    case foldersMixed
    case filter
    case mirrorLeft
    case mirrorRight
    case queue
    case info
    case navBack
    case navForward
    case centerSplitReset
    case list
}

public struct ToolbarIconShape: Shape {
    public let icon: ToolbarIcon
    
    public init(icon: ToolbarIcon) {
        self.icon = icon
    }
    
    public func path(in rect: CGRect) -> Path {
        let base = base24Path(for: icon)
        let scale = min(rect.width / 24.0, rect.height / 24.0)
        let dx = (rect.width - 24.0 * scale) / 2.0
        let dy = (rect.height - 24.0 * scale) / 2.0
        
        let transform = CGAffineTransform(translationX: dx, y: dy)
            .scaledBy(x: scale, y: scale)
        return base.applying(transform)
    }
    
    private func base24Path(for icon: ToolbarIcon) -> Path {
        var path = Path()
        
        switch icon {
        case .copy:
            // Передний документ (скруглённый прямоугольник 13x13 rx=2)
            path.addRoundedRect(in: CGRect(x: 9, y: 9, width: 13, height: 13), cornerSize: CGSize(width: 2, height: 2))
            // Задний лист (открытый контур)
            path.move(to: CGPoint(x: 5, y: 15))
            path.addLine(to: CGPoint(x: 4, y: 15))
            path.addArc(tangent1End: CGPoint(x: 2, y: 15), tangent2End: CGPoint(x: 2, y: 13), radius: 2)
            path.addLine(to: CGPoint(x: 2, y: 4))
            path.addArc(tangent1End: CGPoint(x: 2, y: 2), tangent2End: CGPoint(x: 4, y: 2), radius: 2)
            path.addLine(to: CGPoint(x: 13, y: 2))
            path.addArc(tangent1End: CGPoint(x: 15, y: 2), tangent2End: CGPoint(x: 15, y: 4), radius: 2)
            path.addLine(to: CGPoint(x: 15, y: 5))
            
        case .move:
            // В стиле новой иконки копирования: исходный документ со скруглением rx=2 и динамическая стрелка перемещения направо
            path.addRoundedRect(in: CGRect(x: 3, y: 5, width: 11, height: 14), cornerSize: CGSize(width: 2, height: 2))
            path.move(to: CGPoint(x: 9, y: 12))
            path.addLine(to: CGPoint(x: 21, y: 12))
            path.move(to: CGPoint(x: 17, y: 8))
            path.addLine(to: CGPoint(x: 21, y: 12))
            path.addLine(to: CGPoint(x: 17, y: 16))
            
        case .newFolder:
            // Контур папки с вкладкой
            path.move(to: CGPoint(x: 20, y: 20))
            path.addArc(tangent1End: CGPoint(x: 22, y: 20), tangent2End: CGPoint(x: 22, y: 18), radius: 2)
            path.addLine(to: CGPoint(x: 22, y: 8))
            path.addArc(tangent1End: CGPoint(x: 22, y: 6), tangent2End: CGPoint(x: 20, y: 6), radius: 2)
            path.addLine(to: CGPoint(x: 12.1, y: 6))
            path.addLine(to: CGPoint(x: 10.4, y: 3.9))
            path.addArc(tangent1End: CGPoint(x: 9.6, y: 3), tangent2End: CGPoint(x: 7.9, y: 3), radius: 2)
            path.addLine(to: CGPoint(x: 4, y: 3))
            path.addArc(tangent1End: CGPoint(x: 2, y: 3), tangent2End: CGPoint(x: 2, y: 5), radius: 2)
            path.addLine(to: CGPoint(x: 2, y: 18))
            path.addArc(tangent1End: CGPoint(x: 2, y: 20), tangent2End: CGPoint(x: 4, y: 20), radius: 2)
            path.closeSubpath()
            // Плюс внутри папки
            path.move(to: CGPoint(x: 12, y: 10))
            path.addLine(to: CGPoint(x: 12, y: 16))
            path.move(to: CGPoint(x: 9, y: 13))
            path.addLine(to: CGPoint(x: 15, y: 13))
            
        case .delete:
            // Крышка
            path.move(to: CGPoint(x: 3, y: 6))
            path.addLine(to: CGPoint(x: 21, y: 6))
            path.move(to: CGPoint(x: 8, y: 6))
            path.addLine(to: CGPoint(x: 8, y: 4))
            path.addArc(tangent1End: CGPoint(x: 8, y: 2), tangent2End: CGPoint(x: 10, y: 2), radius: 2)
            path.addLine(to: CGPoint(x: 14, y: 2))
            path.addArc(tangent1End: CGPoint(x: 16, y: 2), tangent2End: CGPoint(x: 16, y: 4), radius: 2)
            path.addLine(to: CGPoint(x: 16, y: 6))
            // Корзина
            path.move(to: CGPoint(x: 19, y: 6))
            path.addLine(to: CGPoint(x: 19, y: 20))
            path.addArc(tangent1End: CGPoint(x: 19, y: 22), tangent2End: CGPoint(x: 17, y: 22), radius: 2)
            path.addLine(to: CGPoint(x: 7, y: 22))
            path.addArc(tangent1End: CGPoint(x: 5, y: 22), tangent2End: CGPoint(x: 5, y: 20), radius: 2)
            path.addLine(to: CGPoint(x: 5, y: 6))
            
        case .rename:
            // Текст рендерится в ToolbarIconView напрямую
            break
            
        case .comparePanes:
            // Внешняя рамка (скругленный квадрат 17x17, rx=3)
            path.addRoundedRect(in: CGRect(x: 3.5, y: 3.5, width: 17, height: 17), cornerSize: CGSize(width: 3, height: 3))
            // Горизонтальная линия разделения панелей
            path.move(to: CGPoint(x: 3.5, y: 12))
            path.addLine(to: CGPoint(x: 20.5, y: 12))
            
        case .compareFiles:
            // Основной документ со скруглением rx=2.5
            path.addRoundedRect(in: CGRect(x: 5, y: 3.5, width: 14, height: 17), cornerSize: CGSize(width: 2.5, height: 2.5))
            // Три строки текста внутри документа
            path.move(to: CGPoint(x: 9, y: 8))
            path.addLine(to: CGPoint(x: 15, y: 8))
            path.move(to: CGPoint(x: 9, y: 11.5))
            path.addLine(to: CGPoint(x: 15, y: 11.5))
            path.move(to: CGPoint(x: 9, y: 15))
            path.addLine(to: CGPoint(x: 15, y: 15))
            // Дополнительные листы/страницы справа для сравнения документов
            path.move(to: CGPoint(x: 19, y: 5))
            path.addLine(to: CGPoint(x: 19, y: 19))
            path.move(to: CGPoint(x: 21.5, y: 5))
            path.addLine(to: CGPoint(x: 21.5, y: 19))
            
        case .search:
            path.addEllipse(in: CGRect(x: 3, y: 3, width: 15, height: 15))
            path.move(to: CGPoint(x: 15.8, y: 15.8))
            path.addLine(to: CGPoint(x: 21, y: 21))
            
        case .refresh:
            // Верхняя дуга по часовой стрелке
            path.addArc(center: CGPoint(x: 12, y: 12), radius: 8.5, startAngle: .degrees(180), endAngle: .degrees(335), clockwise: false)
            path.move(to: CGPoint(x: 20.5, y: 3.5))
            path.addLine(to: CGPoint(x: 20.5, y: 8.5))
            path.addLine(to: CGPoint(x: 15.5, y: 8.5))
            // Нижняя дуга по часовой стрелке
            path.addArc(center: CGPoint(x: 12, y: 12), radius: 8.5, startAngle: .degrees(0), endAngle: .degrees(155), clockwise: false)
            path.move(to: CGPoint(x: 8.5, y: 15.5))
            path.addLine(to: CGPoint(x: 3.5, y: 15.5))
            path.addLine(to: CGPoint(x: 3.5, y: 20.5))
            
        case .viewGrid:
            path.addRoundedRect(in: CGRect(x: 3, y: 3, width: 7, height: 7), cornerSize: CGSize(width: 1.5, height: 1.5))
            path.addRoundedRect(in: CGRect(x: 14, y: 3, width: 7, height: 7), cornerSize: CGSize(width: 1.5, height: 1.5))
            path.addRoundedRect(in: CGRect(x: 3, y: 14, width: 7, height: 7), cornerSize: CGSize(width: 1.5, height: 1.5))
            path.addRoundedRect(in: CGRect(x: 14, y: 14, width: 7, height: 7), cornerSize: CGSize(width: 1.5, height: 1.5))
            
        case .viewTable, .list:
            // Иконка "Список": 3 горизонтальные линии (длина 13, x: 8...21) и 3 круглые точки-маркера слева (x: 3)
            path.move(to: CGPoint(x: 8, y: 6))
            path.addLine(to: CGPoint(x: 21, y: 6))
            path.move(to: CGPoint(x: 8, y: 12))
            path.addLine(to: CGPoint(x: 21, y: 12))
            path.move(to: CGPoint(x: 8, y: 18))
            path.addLine(to: CGPoint(x: 21, y: 18))
            // Маркеры-точки с круглым наконечником
            path.move(to: CGPoint(x: 3, y: 6))
            path.addLine(to: CGPoint(x: 3.01, y: 6))
            path.move(to: CGPoint(x: 3, y: 12))
            path.addLine(to: CGPoint(x: 3.01, y: 12))
            path.move(to: CGPoint(x: 3, y: 18))
            path.addLine(to: CGPoint(x: 3.01, y: 18))
            
        case .foldersSeparate:
            // Папка в верхней части (компактная слева, x: 2.5...9.5)
            path.move(to: CGPoint(x: 2.5, y: 4.5))
            path.addLine(to: CGPoint(x: 5.5, y: 4.5))
            path.addLine(to: CGPoint(x: 7.0, y: 6.0))
            path.addLine(to: CGPoint(x: 9.5, y: 6.0))
            path.addLine(to: CGPoint(x: 9.5, y: 10.5))
            path.addLine(to: CGPoint(x: 2.5, y: 10.5))
            path.closeSubpath()
            // Строка имени папки (с четким зазором от папки, x: 13.5...21.5)
            path.move(to: CGPoint(x: 13.5, y: 8.5))
            path.addLine(to: CGPoint(x: 21.5, y: 8.5))
            
            // Разделитель между группами (папки отдельно - файлы отдельно)
            path.move(to: CGPoint(x: 2.5, y: 13.5))
            path.addLine(to: CGPoint(x: 21.5, y: 13.5))
            
            // Файл/квадратик в нижней части (компактный слева, x: 2.5...9.5)
            path.addRoundedRect(in: CGRect(x: 2.5, y: 16.0, width: 7.0, height: 6.0), cornerSize: CGSize(width: 1, height: 1))
            // Строка имени файла (с четким зазором от файла, x: 13.5...21.5)
            path.move(to: CGPoint(x: 13.5, y: 19.0))
            path.addLine(to: CGPoint(x: 21.5, y: 19.0))
            
        case .foldersMixed:
            // Единый список в стиле Finder: папка и файл чередуются без разделителя
            // Строка 1: папка (x: 2.5...9.0)
            path.move(to: CGPoint(x: 2.5, y: 4.5))
            path.addLine(to: CGPoint(x: 5.0, y: 4.5))
            path.addLine(to: CGPoint(x: 6.5, y: 6.0))
            path.addLine(to: CGPoint(x: 9.0, y: 6.0))
            path.addLine(to: CGPoint(x: 9.0, y: 9.2))
            path.addLine(to: CGPoint(x: 2.5, y: 9.2))
            path.closeSubpath()
            // Линия строки 1 (с зазором, x: 13.5...21.5)
            path.move(to: CGPoint(x: 13.5, y: 7.0))
            path.addLine(to: CGPoint(x: 21.5, y: 7.0))
            
            // Строка 2: документ/квадратик (x: 2.5...8.5)
            path.addRoundedRect(in: CGRect(x: 2.5, y: 11.5, width: 6.0, height: 5.0), cornerSize: CGSize(width: 1, height: 1))
            // Линия строки 2 (с зазором, x: 13.5...21.5)
            path.move(to: CGPoint(x: 13.5, y: 14.0))
            path.addLine(to: CGPoint(x: 21.5, y: 14.0))
            
            // Строка 3: папка (x: 2.5...9.0)
            path.move(to: CGPoint(x: 2.5, y: 18.0))
            path.addLine(to: CGPoint(x: 5.0, y: 18.0))
            path.addLine(to: CGPoint(x: 6.5, y: 19.5))
            path.addLine(to: CGPoint(x: 9.0, y: 19.5))
            path.addLine(to: CGPoint(x: 9.0, y: 22.5))
            path.addLine(to: CGPoint(x: 2.5, y: 22.5))
            path.closeSubpath()
            // Линия строки 3 (с зазором, x: 13.5...21.5)
            path.move(to: CGPoint(x: 13.5, y: 20.5))
            path.addLine(to: CGPoint(x: 21.5, y: 20.5))
            
        case .filter:
            path.move(to: CGPoint(x: 2.5, y: 3.5))
            path.addLine(to: CGPoint(x: 21.5, y: 3.5))
            path.addLine(to: CGPoint(x: 13.8, y: 12.5))
            path.addLine(to: CGPoint(x: 13.8, y: 20))
            path.addLine(to: CGPoint(x: 10.2, y: 18))
            path.addLine(to: CGPoint(x: 10.2, y: 12.5))
            path.closeSubpath()
            
        case .mirrorLeft:
            path.move(to: CGPoint(x: 19, y: 12))
            path.addLine(to: CGPoint(x: 5, y: 12))
            path.move(to: CGPoint(x: 12, y: 19))
            path.addLine(to: CGPoint(x: 5, y: 12))
            path.addLine(to: CGPoint(x: 12, y: 5))
            
        case .mirrorRight:
            path.move(to: CGPoint(x: 5, y: 12))
            path.addLine(to: CGPoint(x: 19, y: 12))
            path.move(to: CGPoint(x: 12, y: 5))
            path.addLine(to: CGPoint(x: 19, y: 12))
            path.addLine(to: CGPoint(x: 12, y: 19))
            
        case .navBack:
            path.move(to: CGPoint(x: 16.0, y: 20.4))
            path.addLine(to: CGPoint(x: 7.6, y: 12.0))
            path.addLine(to: CGPoint(x: 16.0, y: 3.6))
            
        case .navForward:
            path.move(to: CGPoint(x: 8.0, y: 3.6))
            path.addLine(to: CGPoint(x: 16.4, y: 12.0))
            path.addLine(to: CGPoint(x: 8.0, y: 20.4))
            
        case .queue:
            path.move(to: CGPoint(x: 22, y: 12))
            path.addLine(to: CGPoint(x: 18, y: 12))
            path.addLine(to: CGPoint(x: 15, y: 15))
            path.addLine(to: CGPoint(x: 9, y: 15))
            path.addLine(to: CGPoint(x: 6, y: 12))
            path.addLine(to: CGPoint(x: 2, y: 12))
            path.move(to: CGPoint(x: 5.4, y: 5.1))
            path.addLine(to: CGPoint(x: 2, y: 12))
            path.addLine(to: CGPoint(x: 2, y: 18))
            path.addArc(tangent1End: CGPoint(x: 2, y: 20), tangent2End: CGPoint(x: 4, y: 20), radius: 2)
            path.addLine(to: CGPoint(x: 20, y: 20))
            path.addArc(tangent1End: CGPoint(x: 22, y: 20), tangent2End: CGPoint(x: 22, y: 18), radius: 2)
            path.addLine(to: CGPoint(x: 22, y: 12))
            path.addLine(to: CGPoint(x: 18.6, y: 5.1))
            path.addArc(tangent1End: CGPoint(x: 17.5, y: 4), tangent2End: CGPoint(x: 16.8, y: 4), radius: 2)
            path.addLine(to: CGPoint(x: 7.2, y: 4))
            path.addArc(tangent1End: CGPoint(x: 6.5, y: 4), tangent2End: CGPoint(x: 5.4, y: 5.1), radius: 2)
            
        case .info:
            // Круг с буквой "i"
            path.addEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 18))
            path.move(to: CGPoint(x: 12, y: 7.2))
            path.addLine(to: CGPoint(x: 12, y: 7.8))
            path.move(to: CGPoint(x: 12, y: 11))
            path.addLine(to: CGPoint(x: 12, y: 16))
            path.move(to: CGPoint(x: 10.5, y: 16))
            path.addLine(to: CGPoint(x: 13.5, y: 16))
            
        case .centerSplitReset:
            // Две гармоничные вертикальные пунктирные линии, каждая из трёх пунктиров
            // Расстояние увеличено на 150%: с 6.0 pt до 15.0 pt (симметрично x = 4.5 и x = 19.5)
            // Левая линия (x = 4.5): три штриха длиной 3.6 pt с промежутками 2.6 pt
            path.move(to: CGPoint(x: 4.5, y: 4.0)); path.addLine(to: CGPoint(x: 4.5, y: 7.6))
            path.move(to: CGPoint(x: 4.5, y: 10.2)); path.addLine(to: CGPoint(x: 4.5, y: 13.8))
            path.move(to: CGPoint(x: 4.5, y: 16.4)); path.addLine(to: CGPoint(x: 4.5, y: 20.0))
            
            // Правая линия (x = 19.5): три штриха длиной 3.6 pt с промежутками 2.6 pt
            path.move(to: CGPoint(x: 19.5, y: 4.0)); path.addLine(to: CGPoint(x: 19.5, y: 7.6))
            path.move(to: CGPoint(x: 19.5, y: 10.2)); path.addLine(to: CGPoint(x: 19.5, y: 13.8))
            path.move(to: CGPoint(x: 19.5, y: 16.4)); path.addLine(to: CGPoint(x: 19.5, y: 20.0))
        }
        
        return path
    }
}

private let comparePanesSvgString = """
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="1.5">
  <rect x="3.5" y="3.5" width="17" height="17" rx="3"/>
  <line x1="3.5" y1="12" x2="20.5" y2="12"/>
  <text x="8.4" y="10.4" font-size="6.5" fill="black" stroke="none" text-anchor="middle" font-family="-apple-system, BlinkMacSystemFont, sans-serif" font-weight="600">A</text>
  <text x="15.6" y="18.6" font-size="6.5" fill="black" stroke="none" text-anchor="middle" font-family="-apple-system, BlinkMacSystemFont, sans-serif" font-weight="600">B</text>
</svg>
"""

private let comparePanesTemplateImage: NSImage? = {
    if let bundlePath = Bundle.main.path(forResource: "toolbar_compare_panes", ofType: "svg"),
       let img = NSImage(contentsOfFile: bundlePath) {
        img.isTemplate = true
        return img
    }
    if let bundlePath = Bundle.main.path(forResource: "toolbar_compare_panes", ofType: "png"),
       let img = NSImage(contentsOfFile: bundlePath) {
        img.isTemplate = true
        return img
    }
    if let data = comparePanesSvgString.data(using: .utf8),
       let img = NSImage(data: data) {
        img.isTemplate = true
        return img
    }
    return nil
}()

public struct ToolbarIconView: View {
    public let icon: ToolbarIcon
    public var size: CGFloat
    public var lineWidth: CGFloat
    
    public init(icon: ToolbarIcon, size: CGFloat = 16.7, lineWidth: CGFloat = 1.65) {
        self.icon = icon
        self.size = size
        self.lineWidth = lineWidth
    }
    
    public var body: some View {
        if icon == .rename {
            Text("Абв")
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .lineLimit(1)
                .fixedSize()
        } else if icon == .comparePanes, let img = comparePanesTemplateImage {
            Image(nsImage: img)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            let effectiveLineWidth: CGFloat = (icon == .navBack || icon == .navForward) ? (lineWidth * 1.15) : lineWidth
            ToolbarIconShape(icon: icon)
                .stroke(
                    style: StrokeStyle(
                        lineWidth: effectiveLineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: size, height: size)
        }
    }
}

public struct FileItemIconView: View {
    public let isDirectory: Bool
    public let fileName: String
    public var size: CGFloat
    
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif",
        "bmp", "tiff", "tif", "svg", "ico", "raw", "cr2", "nef", "dng", "avif"
    ]
    
    private static let codeExtensions: Set<String> = [
        "swift", "kt", "kts", "java", "c", "cpp", "cc", "cxx",
        "h", "hpp", "m", "mm", "py", "js", "jsx", "ts", "tsx",
        "html", "htm", "css", "scss", "sass", "json", "sh", "bash",
        "zsh", "xml", "yml", "yaml", "sql", "rs", "go", "rb", "php",
        "gradle", "properties", "toml", "lua", "r", "dart", "apk", "app"
    ]
    
    public init(isDirectory: Bool, fileName: String, size: CGFloat = 13.5) {
        self.isDirectory = isDirectory
        self.fileName = fileName
        self.size = size
    }
    
    private var fileExtension: String {
        (fileName as NSString).pathExtension.lowercased()
    }
    
    public var body: some View {
        if isDirectory {
            Image(systemName: "folder.fill")
                .foregroundColor(.yellow)
                .font(.system(size: size))
        } else {
            let ext = fileExtension
            let strokeColor = Color.secondary.opacity(0.55)
            let strokeWidth = max(0.95, size * 0.07)
            
            if Self.imageExtensions.contains(ext) {
                // Графические файлы: иконка изображения (рамка с солнцем и горами) увеличена на 30% по ширине и высоте
                let frameSize = size * 0.88 * 1.30
                ZStack {
                    RoundedRectangle(cornerRadius: frameSize * 0.14, style: .continuous)
                        .fill(Color.white)
                        .frame(width: frameSize, height: frameSize)
                    
                    FileImageIconShape()
                        .stroke(
                            strokeColor,
                            style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
                        )
                        .frame(width: frameSize, height: frameSize)
                }
                .frame(width: frameSize, height: frameSize, alignment: .center)
            } else if Self.codeExtensions.contains(ext) {
                // Программные файлы: угловые скобки кода < > увеличены на 15%
                let frameSize = size * 0.88 * 1.15
                FileCodeIconShape()
                    .stroke(
                        strokeColor,
                        style: StrokeStyle(lineWidth: max(1.05, strokeWidth * 1.1), lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: frameSize, height: frameSize)
                    .frame(width: frameSize, height: frameSize, alignment: .center)
            } else {
                // Обычные файлы: белый документ с чётким векторным контуром в стиле иконок тулбара
                let fileWidth = size * 0.819
                FileDocumentShape()
                    .fill(Color.white)
                    .overlay(
                        FileDocumentShape()
                            .stroke(
                                strokeColor,
                                style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
                            )
                    )
                    .frame(width: fileWidth, height: fileWidth * 1.15)
                    .frame(width: size, alignment: .center)
            }
        }
    }
}

/// Контур иконки графического файла (рамка фото с солнцем и горами) в стиле Lucide/Lumina
public struct FileImageIconShape: Shape {
    public init() {}
    
    public func path(in rect: CGRect) -> Path {
        var base = Path()
        let scale = min(rect.width / 24.0, rect.height / 24.0)
        let dx = (rect.width - 24.0 * scale) / 2.0
        let dy = (rect.height - 24.0 * scale) / 2.0
        let transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
        
        // Внешняя рамка изображения со скруглением
        base.addRoundedRect(in: CGRect(x: 3, y: 3, width: 18, height: 18), cornerSize: CGSize(width: 2.4, height: 2.4))
        
        // Солнце
        base.addEllipse(in: CGRect(x: 7.2, y: 7.2, width: 2.8, height: 2.8))
        
        // Вершина горы
        base.move(to: CGPoint(x: 21, y: 15))
        base.addLine(to: CGPoint(x: 16, y: 10))
        base.addLine(to: CGPoint(x: 6, y: 20))
        
        return base.applying(transform)
    }
}

/// Контур иконки программного файла (угловые скобки кода < >) в стиле Lucide/Lumina
public struct FileCodeIconShape: Shape {
    public init() {}
    
    public func path(in rect: CGRect) -> Path {
        var base = Path()
        let scale = min(rect.width / 24.0, rect.height / 24.0)
        let dx = (rect.width - 24.0 * scale) / 2.0
        let dy = (rect.height - 24.0 * scale) / 2.0
        let transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
        
        // Левая угловая скобка <
        base.move(to: CGPoint(x: 8.5, y: 5))
        base.addLine(to: CGPoint(x: 2.5, y: 12))
        base.addLine(to: CGPoint(x: 8.5, y: 19))
        
        // Правая угловая скобка >
        base.move(to: CGPoint(x: 15.5, y: 5))
        base.addLine(to: CGPoint(x: 21.5, y: 12))
        base.addLine(to: CGPoint(x: 15.5, y: 19))
        
        return base.applying(transform)
    }
}

/// Контур векторного документа со скруглёнными углами и загнутым уголком в стиле Lucide/Lumina
public struct FileDocumentShape: Shape {
    public init() {}
    
    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let corner: CGFloat = min(w, h) * 0.16
        let fold: CGFloat = min(w, h) * 0.35
        
        // Внешний контур документа со скошенным уголком справа вверху
        path.move(to: CGPoint(x: corner, y: 0))
        path.addLine(to: CGPoint(x: w - fold, y: 0))
        path.addLine(to: CGPoint(x: w, y: fold))
        path.addLine(to: CGPoint(x: w, y: h - corner))
        path.addQuadCurve(to: CGPoint(x: w - corner, y: h), control: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: corner, y: h))
        path.addQuadCurve(to: CGPoint(x: 0, y: h - corner), control: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: 0, y: corner))
        path.addQuadCurve(to: CGPoint(x: corner, y: 0), control: CGPoint(x: 0, y: 0))
        path.closeSubpath()
        
        // Линия отгиба уголка
        path.move(to: CGPoint(x: w - fold, y: 0))
        path.addLine(to: CGPoint(x: w - fold, y: fold))
        path.addLine(to: CGPoint(x: w, y: fold))
        
        return path
    }
}
