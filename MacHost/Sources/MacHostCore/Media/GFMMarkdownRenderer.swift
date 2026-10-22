import Foundation

/// Высокопроизводительный парсер и рендерер Markdown по спецификации GitHub Flavored Markdown (GFM).
/// Поддерживает:
/// - GFM Pipe Tables с выравниванием (left, center, right), заголовками и ячейками
/// - Заголовки ATX (# - ######) и Setext (===, ---)
/// - Списки задач (Task lists: `- [ ]`, `- [x]`)
/// - Упорядоченные и маркированные списки с поддержкой вложенности
/// - Ограждённые блоки кода (fenced code blocks) с указанием языка
/// - Диаграммы Mermaid (```mermaid ... ```)
/// - Математические формулы LaTeX ($...$ и $$...$$) через KaTeX
/// - YAML Front Matter в начале файла
/// - Эмодзи-шорткоды GitHub (:smile:, :rocket:, :fire:, etc.)
/// - Вставки стандартных HTML-тегов (<details>, <summary>, <kbd>, <mark>, etc.)
/// - Цитаты и расширенные алерты GitHub (`[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`)
/// - Горизонтальные разделители (`---`, `***`, `___`)
/// - Инлайн-разметку: жирный, курсив, зачёркивание (`~~`), код (`` ` ``), ссылки, изображения, автоссылки
/// - Адаптивный CSS со светлой и тёмной темами для нативного Quick Look в macOS
public final class GFMMarkdownRenderer: Sendable {
    
    public static let shared = GFMMarkdownRenderer()
    
    public init() {}
    
    // MARK: - Публичные методы
    
    /// Рендерит сырой Markdown в полноценный автономный HTML-документ с нативными стилями macOS
    public func renderToHTML(markdown: String, title: String = "Markdown Preview") -> String {
        let bodyHTML = renderBody(markdown: markdown)
        return generateCompleteHTMLDocument(bodyHTML: bodyHTML, title: title)
    }
    
    /// Рендерит Markdown только в HTML-фрагмент (без doctype/head/body)
    public func renderBody(markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        
        var result: [String] = []
        var index = 0
        
        // 0. YAML Front Matter (в начале файла)
        if let first = lines.first?.trimmingCharacters(in: .whitespaces), first == "---" {
            if let (frontMatterHTML, nextIndex) = parseYAMLFrontMatter(lines: lines) {
                result.append(frontMatterHTML)
                index = nextIndex
            }
        }
        
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // 1. Пропуск пустых строк
            if trimmed.isEmpty {
                index += 1
                continue
            }
            
            // 2. Fenced Code Blocks (``` или ~~~)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let (codeHTML, nextIndex) = parseFencedCodeBlock(lines: lines, startIndex: index)
                result.append(codeHTML)
                index = nextIndex
                continue
            }
            
            // 3. LaTeX Display Math ($$ ... $$)
            if trimmed.hasPrefix("$$") {
                let (mathHTML, nextIndex) = parseDisplayMathBlock(lines: lines, startIndex: index)
                result.append(mathHTML)
                index = nextIndex
                continue
            }
            
            // 4. GFM Pipe Tables
            if isTableStart(lines: lines, index: index) {
                let (tableHTML, nextIndex) = parseTable(lines: lines, startIndex: index)
                result.append(tableHTML)
                index = nextIndex
                continue
            }
            
            // 5. ATX Headings (# ... ######)
            if let headingHTML = parseATXHeading(line: trimmed) {
                result.append(headingHTML)
                index += 1
                continue
            }
            
            // 6. Thematic Break / Horizontal Rule (---, ***, ___)
            if isThematicBreak(line: trimmed) {
                result.append("<hr />")
                index += 1
                continue
            }
            
            // 7. Blockquotes & GitHub Alerts
            if trimmed.hasPrefix(">") {
                let (quoteHTML, nextIndex) = parseBlockquote(lines: lines, startIndex: index)
                result.append(quoteHTML)
                index = nextIndex
                continue
            }
            
            // 8. Lists (Маркированные, нумерованные, списки задач)
            if isListItemStart(line: trimmed) {
                let (listHTML, nextIndex) = parseList(lines: lines, startIndex: index)
                result.append(listHTML)
                index = nextIndex
                continue
            }
            
            // 9. Setext Headings (Текст, за которым следует === или ---)
            if index + 1 < lines.count {
                let nextTrimmed = lines[index + 1].trimmingCharacters(in: .whitespaces)
                if isSetextH1Underline(nextTrimmed) {
                    let text = renderInline(trimmed)
                    result.append("<h1>\(text)</h1>")
                    index += 2
                    continue
                } else if isSetextH2Underline(nextTrimmed) {
                    let text = renderInline(trimmed)
                    result.append("<h2>\(text)</h2>")
                    index += 2
                    continue
                }
            }
            
            // 10. Обычный параграф (накапливаем непрерывные строки до пустой строки или спец-блока)
            let (paraHTML, nextIndex) = parseParagraph(lines: lines, startIndex: index)
            result.append(paraHTML)
            index = nextIndex
        }
        
        return result.joined(separator: "\n")
    }
    
    // MARK: - 0. YAML Front Matter
    
    private func parseYAMLFrontMatter(lines: [String]) -> (html: String, nextIndex: Int)? {
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces), first == "---" else { return nil }
        
        var currentIndex = 1
        var yamlLines: [String] = []
        var foundClosing = false
        
        while currentIndex < lines.count {
            let line = lines[currentIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                foundClosing = true
                currentIndex += 1
                break
            }
            yamlLines.append(line)
            currentIndex += 1
        }
        
        guard foundClosing && !yamlLines.isEmpty else { return nil }
        
        var rowsHTML = ""
        for yLine in yamlLines {
            let trimmed = yLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            
            if let colonIdx = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let val = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                let cleanVal = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"\'"))
                rowsHTML += "<tr><td class=\"fm-key\">\(escapeHTML(key))</td><td class=\"fm-value\">\(renderInline(cleanVal))</td></tr>\n"
            } else if trimmed.hasPrefix("- ") {
                let item = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                rowsHTML += "<tr><td class=\"fm-key\"></td><td class=\"fm-value\">&bull; \(renderInline(item))</td></tr>\n"
            }
        }
        
        let html = """
        <div class="markdown-frontmatter">
            <div class="frontmatter-header">
                <span class="frontmatter-badge">YAML Metadata</span>
            </div>
            <table class="frontmatter-table">
                <tbody>
                    \(rowsHTML)
                </tbody>
            </table>
        </div>
        """
        return (html, currentIndex)
    }
    
    // MARK: - 1. GFM Pipe Tables
    
    private func isTableStart(lines: [String], index: Int) -> Bool {
        guard index + 1 < lines.count else { return false }
        let headerLine = lines[index].trimmingCharacters(in: .whitespaces)
        let delimiterLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
        
        guard isTableDelimiterRow(delimiterLine) else { return false }
        
        let headerCols = splitTableRow(headerLine)
        let delimCols = splitTableRow(delimiterLine)
        
        return headerCols.count > 1 && delimCols.count >= headerCols.count
    }
    
    private func isTableDelimiterRow(_ line: String) -> Bool {
        let row = line.trimmingCharacters(in: .whitespaces)
        guard row.contains("-") else { return false }
        
        let cols = splitTableRow(row)
        guard cols.count > 1 else { return false }
        
        for col in cols {
            let trimmedCol = col.trimmingCharacters(in: .whitespaces)
            if trimmedCol.isEmpty { return false }
            let allowed = CharacterSet(charactersIn: ":- ")
            if trimmedCol.unicodeScalars.contains(where: { !allowed.contains($0) }) {
                return false
            }
            if !trimmedCol.contains("-") {
                return false
            }
        }
        return true
    }
    
    private enum TableAlignment {
        case left, center, right, none
        
        var cssStyle: String {
            switch self {
            case .left: return "text-align: left;"
            case .center: return "text-align: center;"
            case .right: return "text-align: right;"
            case .none: return ""
            }
        }
    }
    
    private func parseTableAlignment(_ delimiterCell: String) -> TableAlignment {
        let cell = delimiterCell.trimmingCharacters(in: .whitespaces)
        let startsWithColon = cell.hasPrefix(":")
        let endsWithColon = cell.hasSuffix(":")
        
        if startsWithColon && endsWithColon {
            return .center
        } else if endsWithColon {
            return .right
        } else if startsWithColon {
            return .left
        } else {
            return .left
        }
    }
    
    private func parseTable(lines: [String], startIndex: Int) -> (html: String, nextIndex: Int) {
        let headerLine = lines[startIndex].trimmingCharacters(in: .whitespaces)
        let delimiterLine = lines[startIndex + 1].trimmingCharacters(in: .whitespaces)
        
        let headerCols = splitTableRow(headerLine)
        let delimiterCols = splitTableRow(delimiterLine)
        
        let alignments: [TableAlignment] = delimiterCols.map { parseTableAlignment($0) }
        let columnCount = delimiterCols.count
        
        var html = "<div class=\"markdown-table-wrapper\">\n<table>\n<thead>\n<tr>\n"
        
        for (i, col) in headerCols.enumerated() {
            let align = i < alignments.count ? alignments[i] : .left
            let styleAttr = align.cssStyle.isEmpty ? "" : " style=\"\(align.cssStyle)\""
            let renderedText = renderInline(col.trimmingCharacters(in: .whitespaces))
            html += "<th\(styleAttr)>\(renderedText)</th>\n"
        }
        
        if headerCols.count < columnCount {
            for i in headerCols.count..<columnCount {
                let align = alignments[i]
                let styleAttr = align.cssStyle.isEmpty ? "" : " style=\"\(align.cssStyle)\""
                html += "<th\(styleAttr)></th>\n"
            }
        }
        
        html += "</tr>\n</thead>\n<tbody>\n"
        
        var currentIndex = startIndex + 2
        while currentIndex < lines.count {
            let rawLine = lines[currentIndex]
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            
            if trimmedLine.isEmpty || isThematicBreak(line: trimmedLine) || trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("#") {
                break
            }
            
            if !trimmedLine.contains("|") {
                break
            }
            
            let rowCols = splitTableRow(trimmedLine)
            html += "<tr>\n"
            
            for i in 0..<columnCount {
                let cellText = (i < rowCols.count) ? rowCols[i].trimmingCharacters(in: .whitespaces) : ""
                let align = i < alignments.count ? alignments[i] : .left
                let styleAttr = align.cssStyle.isEmpty ? "" : " style=\"\(align.cssStyle)\""
                let renderedCell = renderInline(cellText)
                html += "<td\(styleAttr)>\(renderedCell)</td>\n"
            }
            
            html += "</tr>\n"
            currentIndex += 1
        }
        
        html += "</tbody>\n</table>\n</div>"
        return (html, currentIndex)
    }
    
    private func splitTableRow(_ line: String) -> [String] {
        var str = line.trimmingCharacters(in: .whitespaces)
        
        if str.hasPrefix("|") {
            str.removeFirst()
        }
        if str.hasSuffix("|") && !str.hasSuffix("\\|") {
            str.removeLast()
        }
        
        var columns: [String] = []
        var currentCell = ""
        var inBacktick = false
        var isEscaped = false
        
        for char in str {
            if isEscaped {
                currentCell.append(char)
                isEscaped = false
                continue
            }
            
            if char == "\\" {
                isEscaped = true
                currentCell.append(char)
                continue
            }
            
            if char == "`" {
                inBacktick.toggle()
                currentCell.append(char)
                continue
            }
            
            if char == "|" && !inBacktick {
                columns.append(currentCell)
                currentCell = ""
            } else {
                currentCell.append(char)
            }
        }
        
        columns.append(currentCell)
        return columns
    }
    
    // MARK: - 2. Fenced Code Blocks & Mermaid
    
    private func parseFencedCodeBlock(lines: [String], startIndex: Int) -> (html: String, nextIndex: Int) {
        let firstLine = lines[startIndex].trimmingCharacters(in: .whitespaces)
        let fenceChar = firstLine.first ?? "`"
        let fence = String(repeating: fenceChar, count: 3)
        let infoString = firstLine.drop(while: { $0 == fenceChar }).trimmingCharacters(in: .whitespaces)
        let language = infoString.components(separatedBy: .whitespaces).first?.lowercased() ?? ""
        
        var codeLines: [String] = []
        var currentIndex = startIndex + 1
        
        while currentIndex < lines.count {
            let line = lines[currentIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(fence) {
                currentIndex += 1
                break
            }
            codeLines.append(line)
            currentIndex += 1
        }
        
        let rawCode = codeLines.joined(separator: "\n")
        let escapedCode = escapeHTML(rawCode)
        
        // Диаграммы Mermaid
        if language == "mermaid" {
            let html = """
            <div class="mermaid-wrapper">
                <div class="mermaid-header"><span class="mermaid-badge">Mermaid Diagram</span></div>
                <pre class="mermaid">\(escapedCode)</pre>
            </div>
            """
            return (html, currentIndex)
        }
        
        // Блок формул LaTeX math
        if language == "math" || language == "latex" {
            let html = """
            <div class="math-display">
                $$\(rawCode)$$
            </div>
            """
            return (html, currentIndex)
        }
        
        let langClass = language.isEmpty ? "" : " class=\"language-\(escapeHTML(language))\""
        let langBadge = language.isEmpty ? "" : "<div class=\"code-header\"><span class=\"code-lang\">\(escapeHTML(language))</span></div>"
        
        let html = """
        <div class="code-block-wrapper">
        \(langBadge)
        <pre><code\(langClass)>\(escapedCode)</code></pre>
        </div>
        """
        return (html, currentIndex)
    }
    
    // MARK: - 3. LaTeX Display Math ($$ ... $$)
    
    private func parseDisplayMathBlock(lines: [String], startIndex: Int) -> (html: String, nextIndex: Int) {
        let firstLine = lines[startIndex].trimmingCharacters(in: .whitespaces)
        
        // Однострочная формула: $$ formula $$
        if firstLine.hasPrefix("$$") && firstLine.hasSuffix("$$") && firstLine.count > 4 {
            let content = String(firstLine.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            let html = "<div class=\"math-display\">$$\(content)$$</div>"
            return (html, startIndex + 1)
        }
        
        var mathLines: [String] = []
        if firstLine.count > 2 {
            mathLines.append(String(firstLine.dropFirst(2)))
        }
        
        var currentIndex = startIndex + 1
        while currentIndex < lines.count {
            let line = lines[currentIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("$$") {
                let inner = String(trimmed.dropLast(2))
                if !inner.isEmpty {
                    mathLines.append(inner)
                }
                currentIndex += 1
                break
            }
            mathLines.append(line)
            currentIndex += 1
        }
        
        let mathContent = mathLines.joined(separator: "\n")
        let html = "<div class=\"math-display\">$$\(mathContent)$$</div>"
        return (html, currentIndex)
    }
    
    // MARK: - 4. Headings
    
    private func parseATXHeading(line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        
        var level = 0
        var chars = line[...]
        while chars.first == "#" && level < 6 {
            level += 1
            chars = chars.dropFirst()
        }
        
        guard level >= 1 && level <= 6 else { return nil }
        guard chars.first == " " || chars.first == "\t" else { return nil }
        
        var content = chars.trimmingCharacters(in: .whitespaces)
        while content.hasSuffix("#") {
            content.removeLast()
        }
        content = content.trimmingCharacters(in: .whitespaces)
        
        let renderedText = renderInline(content)
        let headingID = slugify(content)
        if headingID.isEmpty {
            return "<h\(level)>\(renderedText)</h\(level)>"
        } else {
            return "<h\(level) id=\"\(headingID)\">\(renderedText)</h\(level)>"
        }
    }
    
    private func isSetextH1Underline(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        return line.allSatisfy { $0 == "=" }
    }
    
    private func isSetextH2Underline(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        return line.allSatisfy { $0 == "-" } && line.count >= 2
    }
    
    // MARK: - 5. Thematic Breaks
    
    private func isThematicBreak(line: String) -> Bool {
        let stripped = line.filter { $0 != " " && $0 != "\t" }
        guard stripped.count >= 3 else { return false }
        let first = stripped.first
        return (first == "-" || first == "*" || first == "_") && stripped.allSatisfy { $0 == first }
    }
    
    // MARK: - 6. Blockquotes & GitHub Alerts
    
    private func parseBlockquote(lines: [String], startIndex: Int) -> (html: String, nextIndex: Int) {
        var quoteLines: [String] = []
        var currentIndex = startIndex
        
        while currentIndex < lines.count {
            let line = lines[currentIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix(">") {
                var stripped = String(trimmed.dropFirst())
                if stripped.hasPrefix(" ") {
                    stripped.removeFirst()
                }
                quoteLines.append(stripped)
                currentIndex += 1
            } else if trimmed.isEmpty {
                break
            } else {
                quoteLines.append(line)
                currentIndex += 1
            }
        }
        
        if let first = quoteLines.first?.trimmingCharacters(in: .whitespaces),
           let alertType = extractAlertType(first) {
            let contentLines = Array(quoteLines.dropFirst())
            let alertContent = renderBody(markdown: contentLines.joined(separator: "\n"))
            let alertHTML = renderAlert(type: alertType, contentHTML: alertContent)
            return (alertHTML, currentIndex)
        }
        
        let innerHTML = renderBody(markdown: quoteLines.joined(separator: "\n"))
        let html = "<blockquote>\n\(innerHTML)\n</blockquote>"
        return (html, currentIndex)
    }
    
    private enum AlertType: String {
        case note = "NOTE"
        case tip = "TIP"
        case important = "IMPORTANT"
        case warning = "WARNING"
        case caution = "CAUTION"
        
        var title: String {
            switch self {
            case .note: return "Note"
            case .tip: return "Tip"
            case .important: return "Important"
            case .warning: return "Warning"
            case .caution: return "Caution"
            }
        }
        
        var iconSVG: String {
            switch self {
            case .note:
                return "<svg class=\"octicon\" viewBox=\"0 0 16 16\" width=\"16\" height=\"16\"><path fill=\"currentColor\" d=\"M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z\"></path></svg>"
            case .tip:
                return "<svg class=\"octicon\" viewBox=\"0 0 16 16\" width=\"16\" height=\"16\"><path fill=\"currentColor\" d=\"M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.868.409.629.629 1.25.629 1.825v.5h3v-.5c0-.575.22-1.196.629-1.825.203-.312.45-.604.673-.868l.214-.253c.56-.679.984-1.32.984-2.304 0-2.06-1.637-3.75-4-3.75ZM6 12v.5a1.5 1.5 0 0 0 3 0V12H6Zm-2-6.75C4 2.458 5.79 1 8 1s4 1.458 4 4.25c0 1.306-.575 2.06-1.188 2.802-.206.244-.41.487-.58.748-.258.397-.432.813-.432 1.2V11H6.2v-.999c0-.387-.174-.803-.432-1.2-.17-.261-.374-.504-.58-.748C4.575 7.31 4 6.556 4 5.25Z\"></path></svg>"
            case .important:
                return "<svg class=\"octicon\" viewBox=\"0 0 16 16\" width=\"16\" height=\"16\"><path fill=\"currentColor\" d=\"M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v9.5A1.75 1.75 0 0 1 14.25 13H9.06l-2.573 2.573A1.458 1.458 0 0 1 4 14.543V13H1.75A1.75 1.75 0 0 1 0 11.25Zm1.75-.25a.25.25 0 0 0-.25.25v9.5c0 .138.112.25.25.25h2.5a.75.75 0 0 1 .75.75v2.19l2.72-2.72a.749.749 0 0 1 .53-.22h6a.25.25 0 0 0 .25-.25v-9.5a.25.25 0 0 0-.25-.25ZM9 4.25a1 1 0 1 1-2 0 1 1 0 0 1 2 0Zm-.25 3a.75.75 0 0 0-1.5 0v2.5a.75.75 0 0 0 1.5 0Z\"></path></svg>"
            case .warning:
                return "<svg class=\"octicon\" viewBox=\"0 0 16 16\" width=\"16\" height=\"16\"><path fill=\"currentColor\" d=\"M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z\"></path></svg>"
            case .caution:
                return "<svg class=\"octicon\" viewBox=\"0 0 16 16\" width=\"16\" height=\"16\"><path fill=\"currentColor\" d=\"M4.47.04c.37-.04.74.1 1.01.37l9.15 9.15c.59.59.59 1.54 0 2.12l-4.24 4.24a1.5 1.5 0 0 1-2.12 0L.41 6.77A1.5 1.5 0 0 1 .41 4.65L4.47.04Zm.7.75L1.12 5.04a.5.5 0 0 0 0 .71l7.86 7.86a.5.5 0 0 0 .71 0l4.24-4.24a.5.5 0 0 0 0-.71L5.88.79a.5.5 0 0 0-.71 0ZM8 4a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4Zm0 6.5a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z\"></path></svg>"
            }
        }
    }
    
    private func extractAlertType(_ line: String) -> AlertType? {
        let pattern = #"^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }
        let range = Range(match.range(at: 1), in: line)!
        let name = String(line[range]).uppercased()
        return AlertType(rawValue: name)
    }
    
    private func renderAlert(type: AlertType, contentHTML: String) -> String {
        return """
        <div class="markdown-alert markdown-alert-\(type.rawValue.lowercased())">
            <p class="markdown-alert-title">
                \(type.iconSVG)
                \(type.title)
            </p>
            <div class="markdown-alert-body">
                \(contentHTML)
            </div>
        </div>
        """
    }
    
    // MARK: - 7. Lists & Task Lists
    
    private func isListItemStart(line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return true
        }
        if let match = line.range(of: #"^\s*\d+[\.\)]\s+"#, options: .regularExpression) {
            return !match.isEmpty
        }
        return false
    }
    
    private func parseList(lines: [String], startIndex: Int) -> (html: String, nextIndex: Int) {
        var currentIndex = startIndex
        
        struct RawItem {
            let indent: Int
            let isOrdered: Bool
            let content: String
            let isTask: Bool
            let isChecked: Bool
        }
        
        var items: [RawItem] = []
        
        while currentIndex < lines.count {
            let line = lines[currentIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.isEmpty {
                if currentIndex + 1 < lines.count && !isListItemStart(line: lines[currentIndex + 1]) {
                    break
                }
                currentIndex += 1
                continue
            }
            
            guard isListItemStart(line: line) else {
                break
            }
            
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            var isOrdered = false
            var itemText = ""
            
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                isOrdered = false
                itemText = String(trimmed.dropFirst(2))
            } else if let match = trimmed.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
                isOrdered = true
                itemText = String(trimmed[match.upperBound...])
            }
            
            var isTask = false
            var isChecked = false
            
            if itemText.hasPrefix("[ ] ") {
                isTask = true
                isChecked = false
                itemText = String(itemText.dropFirst(4))
            } else if itemText.hasPrefix("[x] ") || itemText.hasPrefix("[X] ") {
                isTask = true
                isChecked = true
                itemText = String(itemText.dropFirst(4))
            }
            
            items.append(RawItem(
                indent: indent,
                isOrdered: isOrdered,
                content: itemText,
                isTask: isTask,
                isChecked: isChecked
            ))
            
            currentIndex += 1
        }
        
        guard !items.isEmpty else { return ("", currentIndex) }
        
        let isGlobalOrdered = items.first?.isOrdered ?? false
        let listTag = isGlobalOrdered ? "ol" : "ul"
        var html = "<\(listTag)>\n"
        
        for item in items {
            let inlineText = renderInline(item.content)
            if item.isTask {
                let checkedAttr = item.isChecked ? " checked=\"\"" : ""
                let completedClass = item.isChecked ? " task-completed" : ""
                html += "<li class=\"task-list-item\(completedClass)\"><input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled=\"\"\(checkedAttr)> \(inlineText)</li>\n"
            } else {
                html += "<li>\(inlineText)</li>\n"
            }
        }
        
        html += "</\(listTag)>"
        return (html, currentIndex)
    }
    
    // MARK: - 8. Paragraphs
    
    private func parseParagraph(lines: [String], startIndex: Int) -> (html: String, nextIndex: Int) {
        var paraLines: [String] = []
        var currentIndex = startIndex
        
        while currentIndex < lines.count {
            let line = lines[currentIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.isEmpty {
                currentIndex += 1
                break
            }
            
            if currentIndex > startIndex && (
                trimmed.hasPrefix("#") ||
                trimmed.hasPrefix("```") ||
                trimmed.hasPrefix("~~~") ||
                trimmed.hasPrefix("$$") ||
                trimmed.hasPrefix(">") ||
                isListItemStart(line: line) ||
                isTableStart(lines: lines, index: currentIndex) ||
                isThematicBreak(line: trimmed)
            ) {
                break
            }
            
            paraLines.append(line)
            currentIndex += 1
        }
        
        var renderedLines: [String] = []
        for (i, pLine) in paraLines.enumerated() {
            let hasHardBreak = pLine.hasSuffix("  ") || pLine.hasSuffix("\\")
            var cleanLine = pLine.trimmingCharacters(in: .whitespaces)
            if cleanLine.hasSuffix("\\") {
                cleanLine.removeLast()
            }
            let rendered = renderInline(cleanLine)
            if hasHardBreak && i < paraLines.count - 1 {
                renderedLines.append(rendered + "<br />")
            } else {
                renderedLines.append(rendered)
            }
        }
        
        let content = renderedLines.joined(separator: " ")
        return ("<p>\(content)</p>", currentIndex)
    }
    
    // MARK: - 9. Inline Parsing
    
    public func renderInline(_ text: String) -> String {
        var str = text
        
        // 1. Извлекаем инлайн-код (`` `...` ``)
        var codeSpans: [String] = []
        let codePattern = #"(`+)(.+?)\1"#
        if let regex = try? NSRegularExpression(pattern: codePattern, options: []) {
            let matches = regex.matches(in: str, range: NSRange(str.startIndex..., in: str))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: str),
                      let contentRange = Range(match.range(at: 2), in: str) else { continue }
                let codeContent = String(str[contentRange])
                let token = "%%CODE_SPAN_\(codeSpans.count)%%"
                codeSpans.append("<code>\(escapeHTML(codeContent))</code>")
                str.replaceSubrange(fullRange, with: token)
            }
        }
        
        // 2. Извлекаем формулы LaTeX ($...$ и $$...$$)
        var mathSpans: [String] = []
        
        // 2a. Двойной доллар инлайн: $$...$$
        let displayMathPattern = #"\$\$(.+?)\$\$"#
        if let regex = try? NSRegularExpression(pattern: displayMathPattern, options: []) {
            let matches = regex.matches(in: str, range: NSRange(str.startIndex..., in: str))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: str),
                      let contentRange = Range(match.range(at: 1), in: str) else { continue }
                let mathContent = String(str[contentRange])
                let token = "%%MATH_SPAN_\(mathSpans.count)%%"
                mathSpans.append("<span class=\"math-display\">$$\(escapeHTML(mathContent))$$</span>")
                str.replaceSubrange(fullRange, with: token)
            }
        }
        
        // 2b. Одинарный доллар инлайн: $...$
        let inlineMathPattern = #"(?<!\\)\$(?!\s)(.+?)(?<!\s)(?<!\\)\$"#
        if let regex = try? NSRegularExpression(pattern: inlineMathPattern, options: []) {
            let matches = regex.matches(in: str, range: NSRange(str.startIndex..., in: str))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: str),
                      let contentRange = Range(match.range(at: 1), in: str) else { continue }
                let mathContent = String(str[contentRange])
                let token = "%%MATH_SPAN_\(mathSpans.count)%%"
                mathSpans.append("<span class=\"math-inline\">$\(escapeHTML(mathContent))$</span>")
                str.replaceSubrange(fullRange, with: token)
            }
        }
        
        // 3. Сохраняем разрешенные сырые HTML-теги
        var rawHTMLSpans: [String] = []
        let rawHTMLPattern = #"<\/?(?:details|summary|kbd|mark|sub|sup|br|hr|b|i|u|s|em|strong|del|span|div|p|font|code|pre|table|thead|tbody|tr|th|td|ul|ol|li|img|a)(?:\s+[^<>]*?)?\/?>"#
        if let regex = try? NSRegularExpression(pattern: rawHTMLPattern, options: [.caseInsensitive]) {
            let matches = regex.matches(in: str, range: NSRange(str.startIndex..., in: str))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: str) else { continue }
                let htmlTag = String(str[fullRange])
                let token = "%%RAW_HTML_\(rawHTMLSpans.count)%%"
                rawHTMLSpans.append(htmlTag)
                str.replaceSubrange(fullRange, with: token)
            }
        }
        
        // 4. Экранирование оставшихся специальных HTML-символов
        str = escapeHTMLBasic(str)
        
        // 5. Замена эмодзи-кодов (:smile:, :rocket:, :fire:, etc.)
        str = replaceEmojiShortcodes(str)
        
        // 6. Изображения: `![alt](url "title")`
        let imgPattern = #"!\[(.*?)\]\((.*?)(?:\s+"(.*?)")?\)"#
        if let regex = try? NSRegularExpression(pattern: imgPattern, options: []) {
            let matches = regex.matches(in: str, range: NSRange(str.startIndex..., in: str))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: str),
                      let altRange = Range(match.range(at: 1), in: str),
                      let urlRange = Range(match.range(at: 2), in: str) else { continue }
                let alt = String(str[altRange])
                let url = String(str[urlRange])
                var titleAttr = ""
                if match.numberOfRanges > 3, match.range(at: 3).location != NSNotFound,
                   let titleRange = Range(match.range(at: 3), in: str) {
                    titleAttr = " title=\"\(str[titleRange])\""
                }
                let imgTag = "<img src=\"\(url)\" alt=\"\(alt)\"\(titleAttr) />"
                str.replaceSubrange(fullRange, with: imgTag)
            }
        }
        
        // 7. Ссылки: `[text](url "title")`
        let linkPattern = #"\[(.*?)\]\((.*?)(?:\s+"(.*?)")?\)"#
        if let regex = try? NSRegularExpression(pattern: linkPattern, options: []) {
            let matches = regex.matches(in: str, range: NSRange(str.startIndex..., in: str))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: str),
                      let textRange = Range(match.range(at: 1), in: str),
                      let urlRange = Range(match.range(at: 2), in: str) else { continue }
                let text = String(str[textRange])
                let url = String(str[urlRange])
                var titleAttr = ""
                if match.numberOfRanges > 3, match.range(at: 3).location != NSNotFound,
                   let titleRange = Range(match.range(at: 3), in: str) {
                    titleAttr = " title=\"\(str[titleRange])\""
                }
                let linkTag = "<a href=\"\(url)\"\(titleAttr)>\(text)</a>"
                str.replaceSubrange(fullRange, with: linkTag)
            }
        }
        
        // 8. Автоссылки в скобках `<http://...>`
        let autolinkPattern = #"&lt;(https?://[^\s&]+)&gt;"#
        if let regex = try? NSRegularExpression(pattern: autolinkPattern, options: []) {
            str = regex.stringByReplacingMatches(
                in: str,
                range: NSRange(str.startIndex..., in: str),
                withTemplate: #"<a href="$1">$1</a>"#
            )
        }
        
        // 9. GFM Extended Autolinks (обычные URL без скобок)
        let bareURLPattern = #"(?<!["'=])(https?://[^\s<>"']+)(?!["'>])"#
        if let regex = try? NSRegularExpression(pattern: bareURLPattern, options: []) {
            str = regex.stringByReplacingMatches(
                in: str,
                range: NSRange(str.startIndex..., in: str),
                withTemplate: #"<a href="$1">$1</a>"#
            )
        }
        
        // 10. Strikethrough (GFM): `~~text~~`
        let strikePattern = #"~~(.+?)~~"#
        if let regex = try? NSRegularExpression(pattern: strikePattern, options: []) {
            str = regex.stringByReplacingMatches(
                in: str,
                range: NSRange(str.startIndex..., in: str),
                withTemplate: #"<del>$1</del>"#
            )
        }
        
        // 11. Жирный + Курсив (***text*** или ___text___)
        let boldItalicPattern = #"(\*\*\*|___)(.+?)\1"#
        if let regex = try? NSRegularExpression(pattern: boldItalicPattern, options: []) {
            str = regex.stringByReplacingMatches(
                in: str,
                range: NSRange(str.startIndex..., in: str),
                withTemplate: #"<strong><em>$2</em></strong>"#
            )
        }
        
        // 12. Жирный (**text** или __text__)
        let boldPattern = #"(\*\*|__)(.+?)\1"#
        if let regex = try? NSRegularExpression(pattern: boldPattern, options: []) {
            str = regex.stringByReplacingMatches(
                in: str,
                range: NSRange(str.startIndex..., in: str),
                withTemplate: #"<strong>$2</strong>"#
            )
        }
        
        // 13. Курсив (*text* или _text_)
        let italicPattern = #"(?<![a-zA-Z0-9])(\*|_)(.+?)\1(?![a-zA-Z0-9])"#
        if let regex = try? NSRegularExpression(pattern: italicPattern, options: []) {
            str = regex.stringByReplacingMatches(
                in: str,
                range: NSRange(str.startIndex..., in: str),
                withTemplate: #"<em>$2</em>"#
            )
        }
        
        // 14. Восстановление разрешенных сырых HTML-тегов
        for (i, replacement) in rawHTMLSpans.enumerated() {
            let token = "%%RAW_HTML_\(i)%%"
            str = str.replacingOccurrences(of: token, with: replacement)
        }
        
        // 15. Восстановление формул LaTeX
        for (i, replacement) in mathSpans.enumerated() {
            let token = "%%MATH_SPAN_\(i)%%"
            str = str.replacingOccurrences(of: token, with: replacement)
        }
        
        // 16. Восстановление инлайн-кода
        for (i, replacement) in codeSpans.enumerated() {
            let token = "%%CODE_SPAN_\(i)%%"
            str = str.replacingOccurrences(of: token, with: replacement)
        }
        
        // 17. Разэкранирование спецсимволов (\*, \_, \~, \|, etc.)
        str = unescapeMarkdownPunctuation(str)
        
        return str
    }
    
    // MARK: - Эмодзи GitHub
    
    private func replaceEmojiShortcodes(_ text: String) -> String {
        guard text.contains(":") else { return text }
        
        let pattern = #":([a-zA-Z0-9_+-]+):"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let nameRange = Range(match.range(at: 1), in: result) else { continue }
            let name = String(result[nameRange]).lowercased()
            if let emoji = emojiMap[name] {
                result.replaceSubrange(fullRange, with: emoji)
            }
        }
        return result
    }
    
    private let emojiMap: [String: String] = [
        "smile": "😄", "grinning": "😀", "joy": "😂", "sweat_smile": "😅", "rofl": "🤣",
        "wink": "😉", "blush": "😊", "innocent": "😇", "heart_eyes": "😍", "kissing_heart": "😘",
        "sunglasses": "😎", "thinking": "🤔", "sob": "😭", "scream": "😱", "rage": "😡",
        "neutral_face": "😐", "sleeping": "😴", "mask": "😷", "nerd_face": "🤓", "poop": "💩",
        "+1": "👍", "thumbsup": "👍", "-1": "👎", "thumbsdown": "👎", "clap": "👏",
        "wave": "👋", "pray": "🙏", "ok_hand": "👌", "muscle": "💪", "punch": "👊",
        "v": "✌️", "raised_hands": "🙌", "eyes": "👀", "heart": "❤️", "rocket": "🚀",
        "fire": "🔥", "zap": "⚡", "star": "⭐", "sparkles": "✨", "tada": "🎉",
        "party": "🎉", "check": "✅", "white_check_mark": "✅", "x": "❌", "cross_mark": "❌",
        "warning": "⚠️", "bulb": "💡", "memo": "📝", "pencil": "📝", "book": "📖",
        "link": "🔗", "lock": "🔒", "key": "🔑", "gear": "⚙️", "package": "📦",
        "wrench": "🔧", "hammer": "🔨", "bug": "🐛", "computer": "💻", "iphone": "📱",
        "calendar": "📅", "chart": "📊", "bar_chart": "📊", "bell": "🔔", "mag": "🔍",
        "folder": "📁", "file": "📄", "recycle": "♻️", "construction": "🚧", "art": "🎨",
        "coffee": "☕", "pizza": "🍕", "apple": "🍎", "gem": "💎", "crown": "👑",
        "100": "💯", "heavy_check_mark": "✔️", "question": "❓", "exclamation": "❗"
    ]
    
    // MARK: - Вспомогательные функции
    
    private func escapeHTML(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
    
    private func escapeHTMLBasic(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
    
    private func unescapeMarkdownPunctuation(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\\*", with: "*")
            .replacingOccurrences(of: "\\_", with: "_")
            .replacingOccurrences(of: "\\`", with: "`")
            .replacingOccurrences(of: "\\~", with: "~")
            .replacingOccurrences(of: "\\|", with: "|")
            .replacingOccurrences(of: "\\[", with: "[")
            .replacingOccurrences(of: "\\]", with: "]")
            .replacingOccurrences(of: "\\#", with: "#")
            .replacingOccurrences(of: "\\$", with: "$")
    }
    
    private func slugify(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let filtered = text.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(filtered))
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
    }
    
    // MARK: - CSS и генерация документа
    
    private func generateCompleteHTMLDocument(bodyHTML: String, title: String) -> String {
        let escapedTitle = escapeHTML(title)
        
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapedTitle)</title>
        
        <!-- KaTeX (LaTeX math) -->
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css">
        <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js"></script>
        <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/contrib/auto-render.min.js"></script>
        
        <!-- Mermaid (Diagrams) -->
        <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
        
        <script>
        document.addEventListener("DOMContentLoaded", function() {
            // Инициализация KaTeX
            if (typeof renderMathInElement !== "undefined") {
                renderMathInElement(document.body, {
                    delimiters: [
                        {left: '$$', right: '$$', display: true},
                        {left: '$', right: '$', display: false},
                        {left: '\\(', right: '\\)', display: false},
                        {left: '\\[', right: '\\]', display: true}
                    ],
                    throwOnError: false
                });
            }
            
            // Инициализация Mermaid
            if (typeof mermaid !== "undefined") {
                const isDark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
                mermaid.initialize({
                    startOnLoad: true,
                    theme: isDark ? 'dark' : 'default',
                    securityLevel: 'loose'
                });
            }
        });
        </script>
        
        <style>
        :root {
            --color-canvas-default: #ffffff;
            --color-canvas-subtle: #f6f8fa;
            --color-fg-default: #1f2328;
            --color-fg-muted: #656d76;
            --color-border-default: #d0d7de;
            --color-border-muted: #d8dee4;
            --color-accent-fg: #0969da;
            --color-code-bg: #f6f8fa;
            --color-inline-code-bg: rgba(175, 184, 193, 0.2);
            --color-table-row-even: #f6f8fa;
            --color-alert-note: #0969da;
            --color-alert-tip: #1a7f37;
            --color-alert-important: #8250df;
            --color-alert-warning: #9a6700;
            --color-alert-caution: #d1242f;
        }
        
        @media (prefers-color-scheme: dark) {
            :root {
                --color-canvas-default: #1e1e1e;
                --color-canvas-subtle: #252526;
                --color-fg-default: #e6edf3;
                --color-fg-muted: #848d97;
                --color-border-default: #3d444d;
                --color-border-muted: #30363d;
                --color-accent-fg: #4493f8;
                --color-code-bg: #161b22;
                --color-inline-code-bg: rgba(110, 118, 129, 0.4);
                --color-table-row-even: #21262d;
                --color-alert-note: #4493f8;
                --color-alert-tip: #3fb950;
                --color-alert-important: #a371f7;
                --color-alert-warning: #d29922;
                --color-alert-caution: #f85149;
            }
        }
        
        * {
            box-sizing: border-box;
        }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif;
            font-size: 14px;
            line-height: 1.6;
            word-wrap: break-word;
            color: var(--color-fg-default);
            background-color: var(--color-canvas-default);
            margin: 0;
            padding: 28px 36px;
        }
        
        h1, h2, h3, h4, h5, h6 {
            margin-top: 24px;
            margin-bottom: 14px;
            font-weight: 600;
            line-height: 1.25;
            color: var(--color-fg-default);
        }
        
        h1 {
            font-size: 2em;
            padding-bottom: 0.3em;
            border-bottom: 1px solid var(--color-border-muted);
        }
        
        h2 {
            font-size: 1.5em;
            padding-bottom: 0.3em;
            border-bottom: 1px solid var(--color-border-muted);
        }
        
        h3 { font-size: 1.25em; }
        h4 { font-size: 1em; }
        h5 { font-size: 0.875em; }
        h6 { font-size: 0.85em; color: var(--color-fg-muted); }
        
        p {
            margin-top: 0;
            margin-bottom: 16px;
        }
        
        a {
            color: var(--color-accent-fg);
            text-decoration: none;
        }
        a:hover {
            text-decoration: underline;
        }
        
        /* Таблицы GFM */
        .markdown-table-wrapper {
            width: 100%;
            overflow-x: auto;
            margin-top: 16px;
            margin-bottom: 20px;
        }
        
        table {
            border-spacing: 0;
            border-collapse: collapse;
            display: table;
            width: 100%;
            max-width: 100%;
            font-size: 13px;
        }
        
        table th, table td {
            padding: 8px 14px;
            border: 1px solid var(--color-border-default);
            vertical-align: middle;
        }
        
        table th {
            font-weight: 600;
            background-color: var(--color-canvas-subtle);
        }
        
        table tr:nth-child(even) td {
            background-color: var(--color-table-row-even);
        }
        
        /* YAML Front Matter */
        .markdown-frontmatter {
            margin: 0 0 24px 0;
            border: 1px solid var(--color-border-default);
            border-radius: 6px;
            background-color: var(--color-canvas-subtle);
            overflow: hidden;
            font-size: 12.5px;
        }
        
        .frontmatter-header {
            padding: 6px 12px;
            background-color: var(--color-canvas-subtle);
            border-bottom: 1px solid var(--color-border-default);
        }
        
        .frontmatter-badge {
            font-size: 10px;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            color: var(--color-fg-muted);
        }
        
        .frontmatter-table {
            width: 100%;
            border-collapse: collapse;
        }
        
        .frontmatter-table td {
            border: none;
            border-bottom: 1px solid var(--color-border-muted);
            padding: 6px 12px;
        }
        
        .frontmatter-table tr:last-child td {
            border-bottom: none;
        }
        
        .fm-key {
            width: 25%;
            font-weight: 600;
            color: var(--color-fg-muted);
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
        }
        
        .fm-value {
            color: var(--color-fg-default);
        }
        
        /* LaTeX Math */
        .math-display {
            margin: 16px 0;
            padding: 14px;
            text-align: center;
            overflow-x: auto;
            background-color: var(--color-canvas-subtle);
            border: 1px solid var(--color-border-muted);
            border-radius: 6px;
            font-size: 1.1em;
        }
        
        .math-inline {
            padding: 0 3px;
        }
        
        /* Mermaid Diagrams */
        .mermaid-wrapper {
            margin: 18px 0;
            padding: 16px;
            text-align: center;
            background-color: var(--color-canvas-subtle);
            border: 1px solid var(--color-border-muted);
            border-radius: 6px;
            overflow-x: auto;
        }
        
        .mermaid-header {
            display: flex;
            justify-content: flex-end;
            margin-bottom: 8px;
        }
        
        .mermaid-badge {
            font-size: 10px;
            font-weight: 700;
            text-transform: uppercase;
            color: var(--color-fg-muted);
        }
        
        /* Блоки кода */
        .code-block-wrapper {
            margin: 16px 0;
            border-radius: 6px;
            border: 1px solid var(--color-border-muted);
            background-color: var(--color-code-bg);
            overflow: hidden;
        }
        
        .code-header {
            display: flex;
            justify-content: flex-end;
            padding: 4px 12px;
            background-color: var(--color-canvas-subtle);
            border-bottom: 1px solid var(--color-border-muted);
            font-size: 11px;
            font-weight: 600;
            color: var(--color-fg-muted);
            text-transform: uppercase;
        }
        
        pre {
            margin: 0;
            padding: 14px 16px;
            overflow: auto;
            font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
            font-size: 12.5px;
            line-height: 1.45;
        }
        
        code {
            font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
            font-size: 85%;
            margin: 0;
            padding: 0.2em 0.4em;
            background-color: var(--color-inline-code-bg);
            border-radius: 4px;
        }
        
        pre code {
            padding: 0;
            background-color: transparent;
            font-size: 100%;
        }
        
        /* HTML вставки: kbd, details, summary, mark */
        kbd {
            display: inline-block;
            padding: 3px 6px;
            font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
            font-size: 11px;
            line-height: 10px;
            color: var(--color-fg-default);
            vertical-align: middle;
            background-color: var(--color-canvas-subtle);
            border: 1px solid var(--color-border-default);
            border-bottom: 2px solid var(--color-border-default);
            border-radius: 4px;
            box-shadow: inset 0 -1px 0 var(--color-border-muted);
        }
        
        details {
            margin: 16px 0;
            padding: 10px 14px;
            border: 1px solid var(--color-border-default);
            border-radius: 6px;
            background-color: var(--color-canvas-subtle);
        }
        
        summary {
            font-weight: 600;
            cursor: pointer;
            margin: -10px -14px;
            padding: 10px 14px;
        }
        
        mark {
            background-color: rgba(255, 230, 0, 0.35);
            color: inherit;
            padding: 0.15em 0.3em;
            border-radius: 3px;
        }
        
        /* Списки */
        ul, ol {
            padding-left: 2em;
            margin-top: 0;
            margin-bottom: 16px;
        }
        
        li {
            margin-top: 0.25em;
        }
        
        li.task-list-item {
            list-style-type: none;
            margin-left: -1.5em;
        }
        
        li.task-completed {
            color: var(--color-fg-muted);
        }
        
        input.task-list-item-checkbox {
            margin-right: 0.5em;
            vertical-align: middle;
            accent-color: var(--color-accent-fg);
            width: 14px;
            height: 14px;
        }
        
        /* Цитаты */
        blockquote {
            margin: 16px 0;
            padding: 0 1em;
            color: var(--color-fg-muted);
            border-left: 0.25em solid var(--color-border-default);
        }
        blockquote > :first-child { margin-top: 0; }
        blockquote > :last-child { margin-bottom: 0; }
        
        /* Алерты GitHub */
        .markdown-alert {
            padding: 10px 16px;
            margin-bottom: 16px;
            border-left: 0.25em solid;
            border-radius: 0 6px 6px 0;
            background-color: var(--color-canvas-subtle);
        }
        
        .markdown-alert-title {
            display: flex;
            align-items: center;
            font-weight: 600;
            font-size: 13px;
            line-height: 1;
            margin-bottom: 6px;
            margin-top: 2px;
        }
        
        .markdown-alert-title svg {
            margin-right: 8px;
            flex-shrink: 0;
        }
        
        .markdown-alert-note { border-color: var(--color-alert-note); }
        .markdown-alert-note .markdown-alert-title { color: var(--color-alert-note); }
        
        .markdown-alert-tip { border-color: var(--color-alert-tip); }
        .markdown-alert-tip .markdown-alert-title { color: var(--color-alert-tip); }
        
        .markdown-alert-important { border-color: var(--color-alert-important); }
        .markdown-alert-important .markdown-alert-title { color: var(--color-alert-important); }
        
        .markdown-alert-warning { border-color: var(--color-alert-warning); }
        .markdown-alert-warning .markdown-alert-title { color: var(--color-alert-warning); }
        
        .markdown-alert-caution { border-color: var(--color-alert-caution); }
        .markdown-alert-caution .markdown-alert-title { color: var(--color-alert-caution); }
        
        /* Разделитель */
        hr {
            height: 0.25em;
            padding: 0;
            margin: 24px 0;
            background-color: var(--color-border-default);
            border: 0;
        }
        
        img {
            max-width: 100%;
            height: auto;
            border-radius: 4px;
        }
        </style>
        </head>
        <body>
        \(bodyHTML)
        </body>
        </html>
        """
    }
}
