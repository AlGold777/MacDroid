import SwiftUI

public struct FileDiffOverlayView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    @Environment(\.colorScheme) var colorScheme
    
    public var baseHeight: CGFloat
    public var minHeight: CGFloat
    public var maxHeight: CGFloat
    
    @State private var hoveredHunkIndex: Int? = nil
    @State private var isResizeHandleHovered: Bool = false
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging: Bool = false
    
    public init(
        baseHeight: CGFloat = 400,
        minHeight: CGFloat = 160,
        maxHeight: CGFloat = 800
    ) {
        self.baseHeight = baseHeight
        self.minHeight = minHeight
        self.maxHeight = maxHeight
    }
    
    private var effectiveHeight: CGFloat {
        let raw: CGFloat
        if vm.fileDiffDockPosition == .bottom {
            raw = baseHeight - dragOffset
        } else {
            raw = baseHeight + dragOffset
        }
        return min(maxHeight, max(minHeight, raw))
    }
    
    public var body: some View {
        GeometryReader { outerGeo in
            let totalWidth = outerGeo.size.width
            let columnWidth = max(50, (totalWidth - 1) / 2)
            
            VStack(spacing: 0) {
                // Если примагничено снизу: ручка изменения высоты на верхнем краю
                if vm.fileDiffDockPosition == .bottom {
                    resizeHandleView(isTopEdge: true)
                }
                
                // 1. Панель управления (Опции, навигация по отличиям, статистика, примагничивание, закрыть)
                headerToolbar
                
                Divider()
                
                // Баннер изменения файла на диске (FR-38, FR-39)
                if let side = vm.fileDiffChangedAlertSide {
                    fileChangedBanner(for: side)
                }
                
                // 2. Заголовки двух панелей (Левая панель | Правая панель)
                HStack(spacing: 0) {
                    panelColumnHeader(
                        target: vm.activeDiffLeftTarget,
                        encoding: vm.leftFileEncoding,
                        encodingName: vm.leftFileEncodingName,
                        isPresumed: vm.leftFileEncodingPresumed,
                        side: .left
                    )
                    .frame(width: columnWidth)
                    
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1)
                    
                    panelColumnHeader(
                        target: vm.activeDiffRightTarget,
                        encoding: vm.rightFileEncoding,
                        encodingName: vm.rightFileEncodingName,
                        isPresumed: vm.rightFileEncodingPresumed,
                        side: .right
                    )
                    .frame(width: columnWidth)
                }
                .frame(width: totalWidth, height: 32)
                .background(Color(nsColor: .windowBackgroundColor))
                
                Divider()
                
                // 3. ДВЕ ПАНЕЛИ СОДЕРЖИМОГО
                ZStack {
                    Color(nsColor: .textBackgroundColor)
                    
                    if let result = vm.activeFileDiffResult {
                        // Обе стороны готовы: двухколоночный синхронный список различий
                        ScrollViewReader { scrollProxy in
                            diffContentTable(result: result, proxy: scrollProxy, totalWidth: totalWidth, columnWidth: columnWidth)
                        }
                        
                        if result.isIdentical {
                            VStack {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Файлы совпадают: содержимое полностью идентично")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Color(nsColor: .windowBackgroundColor))
                                .cornerRadius(16)
                                .shadow(color: Color.black.opacity(0.18), radius: 5, x: 0, y: 2)
                                .padding(.top, 10)
                                
                                Spacer()
                            }
                        }
                    } else {
                        // Режим ожидания выбора файлов / предпросмотра: две независимые панели рядом
                        HStack(spacing: 0) {
                            // Левая панель
                            singlePaneContent(
                                side: .left,
                                target: vm.activeDiffLeftTarget,
                                statusMessage: vm.diffLeftStatusMessage,
                                previewLines: vm.diffLeftPreviewLines,
                                paneWidth: columnWidth
                            )
                            .frame(width: columnWidth)
                            .frame(maxHeight: .infinity)
                            
                            Rectangle()
                                .fill(Color(nsColor: .separatorColor))
                                .frame(width: 1)
                            
                            // Правая панель
                            singlePaneContent(
                                side: .right,
                                target: vm.activeDiffRightTarget,
                                statusMessage: vm.diffRightStatusMessage,
                                previewLines: vm.diffRightPreviewLines,
                                paneWidth: columnWidth
                            )
                            .frame(width: columnWidth)
                            .frame(maxHeight: .infinity)
                        }
                        .frame(width: totalWidth)
                        .frame(maxHeight: .infinity)
                    }
                    
                    // Индикатор загрузки
                    if vm.isDiffLoading {
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.regular)
                            Text("Сравнение файлов...")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .padding(16)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                        .cornerRadius(10)
                        .shadow(radius: 6)
                    }
                }
                .frame(width: totalWidth)
                .frame(maxHeight: .infinity)
                
                // 4. Ручка изменения высоты окна (нижний край, если примагничено сверху)
                if vm.fileDiffDockPosition == .top {
                    resizeHandleView(isTopEdge: false)
                }
            }
            .frame(width: totalWidth, height: effectiveHeight)
        }
        .frame(height: effectiveHeight)
        .animation(nil, value: effectiveHeight)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Верхний тулбар управления
    private var headerToolbar: some View {
        HStack(spacing: 12) {
            // Навигация по различиям (п. 11)
            diffNavigationControl
            
            Divider()
                .frame(height: 20)
            
            // Опции игнорирования (п. 10)
            Picker("Пробелы:", selection: $vm.diffOptions.whitespace) {
                ForEach(WhitespaceOption.allCases, id: \.self) { opt in
                    Text(opt.title).tag(opt)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
            
            Toggle("Игнорировать регистр", isOn: $vm.diffOptions.ignoreCase)
                .toggleStyle(.checkbox)
            
            Toggle("Игнорировать EOL (CRLF/LF)", isOn: $vm.diffOptions.ignoreLineEndings)
                .toggleStyle(.checkbox)
            
            Toggle("Синхронная прокрутка", isOn: $vm.isDiffSyncScrollEnabled)
                .toggleStyle(.checkbox)
            
            Spacer()
            
            // Статистика различий
            if let res = vm.activeFileDiffResult, !res.isIdentical {
                HStack(spacing: 8) {
                    Text("+\(res.addedCount)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.green)
                    Text("-\(res.deletedCount)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.red)
                    Text("~\(res.modifiedCount)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(4)
            }
            
            // Кнопка примагничивания/перемещения (сверху / снизу)
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    vm.fileDiffDockPosition = (vm.fileDiffDockPosition == .top) ? .bottom : .top
                }
            }) {
                Image(systemName: vm.fileDiffDockPosition == .top ? "arrow.down.to.line.compact" : "arrow.up.to.line.compact")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(vm.fileDiffDockPosition == .top ? "Примагнитить окно сравнения к низу" : "Примагнитить окно сравнения к верху")
            
            // Кнопка закрытия окна
            Button(action: { vm.closeFileDiff() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Закрыть сравнение (Esc)")
            .keyboardShortcut(.cancelAction)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Заголовок колонки панели
    private func panelColumnHeader(
        target: CompareTarget?,
        encoding: String.Encoding,
        encodingName: String,
        isPresumed: Bool,
        side: PaneSide
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: target?.isRemote == true ? "iphone" : "internaldrive")
                .font(.system(size: 14))
                .foregroundColor(target != nil ? .accentColor : .secondary)
            
            if let t = target {
                Text(t.fileItem.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Text("(\(formatFileSize(t.fileItem.size)))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                Text("файл не выбран")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.secondary)
            }
            
            Spacer(minLength: 0)
            
            if target != nil {
                Menu {
                    ForEach(TextEncodingOption.availableEncodings) { enc in
                        Button(enc.name) {
                            vm.changeFileEncoding(side: side, encoding: enc.encoding, name: enc.name)
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(encodingName)
                            .font(.system(size: 11, weight: .medium))
                        if isPresumed {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(isPresumed ? "Кодировка определена предположительно. Нажмите для смены." : "Кодировка файла")
            }
        }
        .padding(.horizontal, 10)
    }
    
    // MARK: - Содержимое отдельной панели в режиме ожидания/предпросмотра
    @ViewBuilder
    private func singlePaneContent(
        side: PaneSide,
        target: CompareTarget?,
        statusMessage: String,
        previewLines: [String],
        paneWidth: CGFloat
    ) -> some View {
        if target != nil && !previewLines.isEmpty {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(previewLines.enumerated()), id: \.offset) { idx, line in
                        HStack(spacing: 0) {
                            Text("\(idx + 1)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                                .frame(width: 44, alignment: .trailing)
                                .padding(.trailing, 8)
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(minWidth: paneWidth, alignment: .leading)
                        .frame(height: 19)
                    }
                }
                .frame(minWidth: paneWidth, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(width: paneWidth)
            .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: side == .left ? "arrow.left.circle.fill" : "arrow.right.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.accentColor.opacity(0.75))
                Text(side == .left ? "Левая панель" : "Правая панель")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Text(statusMessage.isEmpty ? "Выберите текстовый файл" : statusMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Text("Кликните файл в соответствующей панели снизу")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.75))
            }
            .frame(width: paneWidth)
            .frame(maxHeight: .infinity)
        }
    }
    
    // Блок навигации по различиям
    private var diffNavigationControl: some View {
        HStack(spacing: 6) {
            Button(action: { vm.prevDiffDifference() }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.bordered)
            .disabled(vm.diffCurrentHunkIndex <= 0 || (vm.activeFileDiffResult?.hunks.isEmpty ?? true))
            .help("Предыдущее отличие (Shift+F7)")
            
            if let result = vm.activeFileDiffResult, !result.hunks.isEmpty {
                Text("\(vm.diffCurrentHunkIndex + 1) из \(result.hunks.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .frame(minWidth: 55)
            } else {
                Text("0 из 0")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 55)
            }
            
            Button(action: { vm.nextDiffDifference() }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.bordered)
            .disabled(vm.diffCurrentHunkIndex >= ((vm.activeFileDiffResult?.hunks.count ?? 1) - 1))
            .help("Следующее отличие (F7)")
        }
        .fixedSize()
    }
    
    // Баннер изменения файла (FR-38, FR-39)
    private func fileChangedBanner(for side: PaneSide) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundColor(.orange)
            Text("Файл в \(side == .left ? "левой" : "правой") панели изменился на диске")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button("Перезагрузить") {
                vm.reloadModifiedDiffFile(side: side)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            
            Button("Оставить") {
                vm.fileDiffChangedAlertSide = nil
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.15))
    }
    
    // MARK: - Таблица содержимого diff
    private func diffContentTable(
        result: DiffResult,
        proxy: ScrollViewProxy,
        totalWidth: CGFloat,
        columnWidth: CGFloat
    ) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(result.alignedLines) { line in
                    diffLineRow(line: line, totalWidth: totalWidth, columnWidth: columnWidth)
                        .id(line.id)
                }
            }
            .frame(width: totalWidth, alignment: .leading)
        }
        .frame(width: totalWidth)
        .frame(maxHeight: .infinity)
        .onChange(of: vm.diffCurrentHunkIndex) { _, newIndex in
            if newIndex >= 0 && newIndex < result.hunks.count {
                let targetRow = result.hunks[newIndex].startRowIndex
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(targetRow, anchor: .center)
                }
            }
        }
    }
    
    // Строка пары строк
    private func diffLineRow(
        line: DiffAlignedLine,
        totalWidth: CGFloat,
        columnWidth: CGFloat
    ) -> some View {
        let (bgColor, gutterSign) = styleForKind(line.kind)
        
        return HStack(spacing: 0) {
            // ЛЕВАЯ КОЛОНКА
            HStack(spacing: 0) {
                // Номер строки
                Text(line.leftLineNumber.map { "\($0)" } ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                    .frame(width: 44, alignment: .trailing)
                    .padding(.trailing, 4)
                
                // Gutter маркер (+/-/~ для доступности, п. 11.2)
                Text(line.kind == .deleted || line.kind == .modified ? gutterSign : " ")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(colorForKind(line.kind))
                    .frame(width: 14, alignment: .center)
                
                // Текст левой строки
                if let content = line.leftContent {
                    renderedLineText(
                        content: content,
                        highlights: line.leftIntraHighlights,
                        highlightColor: Color.red.opacity(0.35)
                    )
                } else {
                    // Выравнивающая пустая строка для добавленного блока справа
                    spacerBackground
                }
                
                Spacer(minLength: 0)
            }
            .frame(width: columnWidth, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(line.leftContent != nil ? bgColor : Color.clear)
            .clipped()
            
            // Разделитель колонок (ровно по центру между панелями)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
            
            // ПРАВАЯ КОЛОНКА
            HStack(spacing: 0) {
                // Номер строки
                Text(line.rightLineNumber.map { "\($0)" } ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                    .frame(width: 44, alignment: .trailing)
                    .padding(.trailing, 4)
                
                // Gutter маркер
                Text(line.kind == .added || line.kind == .modified ? gutterSign : " ")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(colorForKind(line.kind))
                    .frame(width: 14, alignment: .center)
                
                // Текст правой строки
                if let content = line.rightContent {
                    renderedLineText(
                        content: content,
                        highlights: line.rightIntraHighlights,
                        highlightColor: Color.green.opacity(0.35)
                    )
                } else {
                    // Выравнивающая пустая строка для удаленного блока слева
                    spacerBackground
                }
                
                Spacer(minLength: 0)
            }
            .frame(width: columnWidth, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(line.rightContent != nil ? bgColor : Color.clear)
            .clipped()
        }
        .frame(width: totalWidth, alignment: .leading)
        .frame(height: 20)
        .overlay(
            line.isHunkStart ?
                Rectangle()
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(height: 1)
                : nil,
            alignment: .top
        )
    }
    
    private func buildAttributedLineText(
        content: String,
        highlights: [DiffHighlightRange],
        highlightColor: Color
    ) -> AttributedString {
        let chars = Array(content)
        var attr = AttributedString(content)
        attr.font = .system(size: 11, design: .monospaced)
        attr.foregroundColor = .primary
        
        for h in highlights {
            let lower = max(0, min(chars.count, h.range.lowerBound))
            let upper = max(0, min(chars.count, h.range.upperBound))
            if lower < upper {
                let strStart = content.index(content.startIndex, offsetBy: lower)
                let strEnd = content.index(content.startIndex, offsetBy: upper)
                if let attrStart = AttributedString.Index(strStart, within: attr),
                   let attrEnd = AttributedString.Index(strEnd, within: attr) {
                    attr[attrStart..<attrEnd].backgroundColor = highlightColor
                }
            }
        }
        return attr
    }
    
    // Текст строки с внутристрочной подсветкой
    @ViewBuilder
    private func renderedLineText(
        content: String,
        highlights: [DiffHighlightRange],
        highlightColor: Color
    ) -> some View {
        if highlights.isEmpty {
            Text(content)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
                .padding(.horizontal, 4)
        } else {
            let attr = buildAttributedLineText(content: content, highlights: highlights, highlightColor: highlightColor)
            Text(attr)
                .lineLimit(1)
                .padding(.horizontal, 4)
        }
    }
    
    // Выравнивающий пустой фон
    private var spacerBackground: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.06))
            .frame(maxWidth: .infinity, minHeight: 18)
    }
    
    private func styleForKind(_ kind: DiffLineKind) -> (Color, String) {
        switch kind {
        case .equal:
            return (Color.clear, " ")
        case .added:
            return (Color.green.opacity(0.12), "+")
        case .deleted:
            return (Color.red.opacity(0.12), "-")
        case .modified:
            return (Color.orange.opacity(0.12), "~")
        }
    }
    
    private func colorForKind(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .equal: return Color.clear
        case .added: return Color.green
        case .deleted: return Color.red
        case .modified: return Color.orange
        }
    }
    
    // MARK: - Ручка изменения высоты окна сравнения (верхний или нижний край)
    private func resizeHandleView(isTopEdge: Bool) -> some View {
        VStack(spacing: 0) {
            if !isTopEdge {
                Divider()
            }
            
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                
                // Визуальный индикатор (grip bar)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isResizeHandleHovered ? Color.secondary.opacity(0.7) : Color.secondary.opacity(0.35))
                    .frame(width: 44, height: 3)
            }
            .frame(height: 10)
            .contentShape(Rectangle())
            .onHover { hovering in
                isResizeHandleHovered = hovering
                if hovering {
                    NSCursor.resizeUpDown.set()
                } else if !isDragging {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { gesture in
                        isDragging = true
                        NSCursor.resizeUpDown.set()
                        dragOffset = gesture.translation.height
                    }
                    .onEnded { gesture in
                        let delta = gesture.translation.height
                        
                        // Проверяем, если пользователь сильно потянул ручку к противоположному краю (жест примагничивания):
                        // Если было .top и потянули вниз почти на всю высоту экрана (delta > 350) -> можно примагнитить вниз
                        // Если было .bottom и потянули вверх почти на всю высоту (delta < -350) -> можно примагнитить вверх
                        let shouldSnapToOpposite: Bool
                        if vm.fileDiffDockPosition == .top {
                            shouldSnapToOpposite = (delta > (maxHeight * 0.75))
                        } else {
                            shouldSnapToOpposite = (delta < -(maxHeight * 0.75))
                        }
                        
                        dragOffset = 0
                        isDragging = false
                        
                        if shouldSnapToOpposite {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                vm.fileDiffDockPosition = (vm.fileDiffDockPosition == .top) ? .bottom : .top
                            }
                        } else {
                            let rawHeight = isTopEdge ? (baseHeight - delta) : (baseHeight + delta)
                            let finalHeight = min(maxHeight, max(minHeight, rawHeight))
                            vm.fileDiffHeight = finalHeight
                        }
                        
                        if isResizeHandleHovered {
                            NSCursor.resizeUpDown.set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    }
            )
            .onTapGesture(count: 2) {
                // Двойной клик сбрасывает высоту к значению по умолчанию
                vm.fileDiffHeight = nil
            }
            .help(isTopEdge
                ? "Потяните за верхний край для изменения высоты окна сравнения (двойной клик — сброс)"
                : "Потяните за нижний край для изменения высоты окна сравнения (двойной клик — сброс)")
            
            if isTopEdge {
                Divider()
            }
        }
    }
    
    private func formatFileSize(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
