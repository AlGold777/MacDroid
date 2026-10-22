# Резервная копия старой иконки режима сортировки (FolderSortIconView)

Сохранено перед заменой на иконку "Список" по запросу пользователя.

## Исходный код FolderSortIconView

```swift
public struct FolderSortIconView: View {
    public let mode: FolderSortMode
    public var size: CGFloat = 15
    
    public init(mode: FolderSortMode, size: CGFloat = 15) {
        self.mode = mode
        self.size = size
    }
    
    public var body: some View {
        Canvas { context, sz in
            let w = sz.width
            let h = sz.height
            let strokeW: CGFloat = 1.2
            
            if mode == .separate {
                // Режим .separate: Папки сверху, разделитель, файлы снизу
                // 1. Верхняя папка (четкий контур)
                var folderPath = Path()
                let fx: CGFloat = 1.0
                let fy: CGFloat = 1.5
                let fw: CGFloat = 5.8
                let fh: CGFloat = 4.8
                let tabW: CGFloat = 2.4
                let tabH: CGFloat = 1.0
                
                folderPath.move(to: CGPoint(x: fx, y: fy + tabH))
                folderPath.addLine(to: CGPoint(x: fx + tabW, y: fy + tabH))
                folderPath.addLine(to: CGPoint(x: fx + tabW + 0.8, y: fy + tabH + 0.8))
                folderPath.addLine(to: CGPoint(x: fx + fw, y: fy + tabH + 0.8))
                folderPath.addLine(to: CGPoint(x: fx + fw, y: fy + fh))
                folderPath.addLine(to: CGPoint(x: fx, y: fy + fh))
                folderPath.closeSubpath()
                context.stroke(folderPath, with: .color(.primary), style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round))
                
                // Текстовая полоска папки
                var line1 = Path()
                line1.move(to: CGPoint(x: 8.8, y: fy + fh / 2 + 0.4))
                line1.addLine(to: CGPoint(x: w - 1.0, y: fy + fh / 2 + 0.4))
                context.stroke(line1, with: .color(.primary), style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
                
                // Четкий разделитель между группами (папки отдельно - файлы отдельно)
                var sepLine = Path()
                let sepY = h / 2
                sepLine.move(to: CGPoint(x: 1.0, y: sepY))
                sepLine.addLine(to: CGPoint(x: w - 1.0, y: sepY))
                context.stroke(sepLine, with: .color(.primary.opacity(0.4)), style: StrokeStyle(lineWidth: 1.0, lineCap: .round))
                
                // 2. Нижний документ/файл
                let docRect = CGRect(x: 1.2, y: sepY + 1.8, width: 5.4, height: 5.0)
                let docPath = Path(roundedRect: docRect, cornerRadius: 1.2)
                context.stroke(docPath, with: .color(.primary), style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round))
                
                // Текстовая полоска файла
                var line2 = Path()
                line2.move(to: CGPoint(x: 8.8, y: docRect.midY))
                line2.addLine(to: CGPoint(x: w - 1.0, y: docRect.midY))
                context.stroke(line2, with: .color(.primary), style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
            } else {
                // Режим .mixed (как в Finder: папка и файл чередуются в едином списке)
                // Строка 1: Папка
                var folderPath1 = Path()
                let fx: CGFloat = 1.0
                let fy1: CGFloat = 1.2
                let fw: CGFloat = 5.4
                let fh: CGFloat = 3.8
                folderPath1.move(to: CGPoint(x: fx, y: fy1 + 0.8))
                folderPath1.addLine(to: CGPoint(x: fx + 2.0, y: fy1 + 0.8))
                folderPath1.addLine(to: CGPoint(x: fx + 2.6, y: fy1 + 1.4))
                folderPath1.addLine(to: CGPoint(x: fx + fw, y: fy1 + 1.4))
                folderPath1.addLine(to: CGPoint(x: fx + fw, y: fy1 + fh))
                folderPath1.addLine(to: CGPoint(x: fx, y: fy1 + fh))
                folderPath1.closeSubpath()
                context.stroke(folderPath1, with: .color(.primary), style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round))
                
                var line1 = Path()
                line1.move(to: CGPoint(x: 8.5, y: fy1 + fh / 2 + 0.3))
                line1.addLine(to: CGPoint(x: w - 1.0, y: fy1 + fh / 2 + 0.3))
                context.stroke(line1, with: .color(.primary), style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
                
                // Строка 2: Документ
                let docRect = CGRect(x: 1.2, y: fy1 + fh + 1.6, width: 5.0, height: 3.8)
                let docPath = Path(roundedRect: docRect, cornerRadius: 1.0)
                context.stroke(docPath, with: .color(.primary), style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round))
                
                var line2 = Path()
                line2.move(to: CGPoint(x: 8.5, y: docRect.midY))
                line2.addLine(to: CGPoint(x: w - 1.0, y: docRect.midY))
                context.stroke(line2, with: .color(.primary), style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
                
                // Строка 3: Папка
                var folderPath2 = Path()
                let fy2 = docRect.maxY + 1.6
                folderPath2.move(to: CGPoint(x: fx, y: fy2 + 0.8))
                folderPath2.addLine(to: CGPoint(x: fx + 2.0, y: fy2 + 0.8))
                folderPath2.addLine(to: CGPoint(x: fx + 2.6, y: fy2 + 1.4))
                folderPath2.addLine(to: CGPoint(x: fx + fw, y: fy2 + 1.4))
                folderPath2.addLine(to: CGPoint(x: fx + fw, y: fy2 + fh))
                folderPath2.addLine(to: CGPoint(x: fx, y: fy2 + fh))
                folderPath2.closeSubpath()
                context.stroke(folderPath2, with: .color(.primary), style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round))
                
                var line3 = Path()
                line3.move(to: CGPoint(x: 8.5, y: fy2 + fh / 2 + 0.3))
                line3.addLine(to: CGPoint(x: w - 1.0, y: fy2 + fh / 2 + 0.3))
                context.stroke(line3, with: .color(.primary), style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
    }
}
```
