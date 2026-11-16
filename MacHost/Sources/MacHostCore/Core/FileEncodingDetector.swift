import Foundation
import AppKit
import PDFKit

public struct TextEncodingOption: Identifiable, Hashable, Sendable {
    public var id: UInt { encoding.rawValue }
    public let name: String
    public let encoding: String.Encoding
    
    public init(name: String, encoding: String.Encoding) {
        self.name = name
        self.encoding = encoding
    }
    
    public static let availableEncodings: [TextEncodingOption] = [
        TextEncodingOption(name: "UTF-8", encoding: .utf8),
        TextEncodingOption(name: "Windows-1251 (Кириллица)", encoding: .windowsCP1251),
        TextEncodingOption(name: "Windows-1252 (Western)", encoding: .windowsCP1252),
        TextEncodingOption(name: "KOI8-R (Кириллица)", encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.KOI8_R.rawValue)))),
        TextEncodingOption(name: "UTF-16 LE", encoding: .utf16LittleEndian),
        TextEncodingOption(name: "UTF-16 BE", encoding: .utf16BigEndian),
        TextEncodingOption(name: "ASCII", encoding: .ascii),
        TextEncodingOption(name: "ISO Latin 1", encoding: .isoLatin1)
    ]
}

public enum TextValidationResult: Sendable {
    case validText(text: String, encoding: String.Encoding, encodingName: String, isPresumed: Bool)
    case binary(reason: String)
    case tooLarge(size: UInt64, limit: UInt64)
    case tooManyLines(count: Int, limit: Int)
    case readError(reason: String)
}

public struct DocumentExtractionError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum FileEncodingDetector {
    public static let defaultMaxSizeBytes: UInt64 = 10 * 1024 * 1024 // 10 МБ (п. 7)
    public static let defaultMaxLineCount: Int = 200_000 // 200 000 строк (п. 7 FR-18)
    public static let nulCheckChunkSize: Int = 8192 // 8 КБ (п. 7)
    public static let fallbackSampleSize: Int = 65536 // 64 КБ (п. 7)
    
    /// Известные бинарные расширения для вспомогательного предупреждения UX (FR-19)
    public static let knownBinaryExtensions: Set<String> = [
        "exe", "dll", "so", "dylib", "bin", "o", "a",
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "heic", "tiff",
        "mp3", "wav", "flac", "aac", "ogg", "m4a",
        "mp4", "mkv", "mov", "avi", "webm",
        "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "apk", "jar",
        "xls", "xlsx", "ppt", "pptx"
    ]

    /// Поддерживаемые форматы документов для извлечения текста и сравнения (PDF, DOCX, DOC, RTF)
    public static let knownDocumentExtensions: Set<String> = [
        "pdf", "doc", "docx", "rtf"
    ]

    public static func isDocumentExtension(_ filename: String) -> Bool {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        return knownDocumentExtensions.contains(ext)
    }

    /// Извлечение текста из PDF документа
    public static func extractPDFText(fileURL: URL) -> Result<String, DocumentExtractionError> {
        guard let pdf = PDFDocument(url: fileURL) else {
            return .failure(DocumentExtractionError("Не удалось открыть PDF документ"))
        }
        if pdf.isLocked {
            return .failure(DocumentExtractionError("PDF документ защищен паролем"))
        }
        if pdf.pageCount == 0 {
            return .success("")
        }

        var pagesText: [String] = []
        for i in 0..<pdf.pageCount {
            if let page = pdf.page(at: i), let pageString = page.string {
                pagesText.append(pageString)
            }
        }

        let fullText = pagesText.isEmpty ? (pdf.string ?? "") : pagesText.joined(separator: "\n")
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .failure(DocumentExtractionError("В PDF нет распознанного текста (возможно, это скан или изображение)"))
        }

        let normalized = fullText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return .success(normalized)
    }

    /// Извлечение текста из офисных документов (Word .docx, .doc, .rtf)
    public static func extractOfficeDocumentText(fileURL: URL, ext: String) -> Result<String, DocumentExtractionError> {
        var docType: NSAttributedString.DocumentType? = nil
        if ext == "docx" {
            docType = .officeOpenXML
        } else if ext == "doc" {
            docType = .docFormat
        } else if ext == "rtf" {
            docType = .rtf
        }

        // 1. Попытка через NSAttributedString с явным docType
        if let dt = docType,
           let attrStr = try? NSAttributedString(url: fileURL, options: [.documentType: dt], documentAttributes: nil) {
            let normalized = attrStr.string
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            return .success(normalized)
        }

        // 2. Попытка через NSAttributedString с автоопределением формата
        if let attrStr = try? NSAttributedString(url: fileURL, options: [:], documentAttributes: nil) {
            let normalized = attrStr.string
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            return .success(normalized)
        }

        // 3. Fallback через системную утилиту /usr/bin/textutil
        if let textutilStr = extractWithTextUtil(fileURL: fileURL) {
            let normalized = textutilStr
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            return .success(normalized)
        }

        return .failure(DocumentExtractionError("Не удалось прочитать документ \(ext.uppercased())"))
    }

    private static func extractWithTextUtil(fileURL: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", fileURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)
            }
        } catch {
            return nil
        }
        return nil
    }
    
    /// Известные текстовые форматы, гарантированно поддерживаемые для сравнения (*.txt, *.md, *.css и др.)
    public static let knownTextExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "css", "scss", "sass", "less",
        "json", "xml", "html", "htm", "js", "ts", "jsx", "tsx", "swift",
        "py", "c", "cpp", "h", "hpp", "java", "kt", "sh", "bash", "zsh",
        "yaml", "yml", "ini", "conf", "cfg", "log", "sql", "csv", "tsv"
    ]
    
    public static func isKnownBinaryExtension(_ filename: String) -> Bool {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        return knownBinaryExtensions.contains(ext)
    }

    public static func isKnownTextExtension(_ filename: String) -> Bool {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        return knownTextExtensions.contains(ext)
    }
    
    /// Определение BOM в данных
    public static func detectBOM(data: Data) -> (encoding: String.Encoding, name: String, bomLength: Int)? {
        let count = data.count
        if count >= 4 {
            if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
                return (.utf32LittleEndian, "UTF-32 LE (BOM)", 4)
            }
            if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
                return (.utf32BigEndian, "UTF-32 BE (BOM)", 4)
            }
        }
        if count >= 3 {
            if data.starts(with: [0xEF, 0xBB, 0xBF]) {
                return (.utf8, "UTF-8 (BOM)", 3)
            }
        }
        if count >= 2 {
            if data.starts(with: [0xFF, 0xFE]) {
                return (.utf16LittleEndian, "UTF-16 LE (BOM)", 2)
            }
            if data.starts(with: [0xFE, 0xFF]) {
                return (.utf16BigEndian, "UTF-16 BE (BOM)", 2)
            }
        }
        return nil
    }
    
    /// Проверка на NUL-байт (0x00) в первых 8 КБ (п. 7 шаг 3)
    public static func containsNulByte(in data: Data) -> Bool {
        let checkLength = min(data.count, nulCheckChunkSize)
        return data.prefix(checkLength).contains(0x00)
    }
    
    /// Эвристика автодетекта кодировки (п. 7 шаг 5)
    public static func detectEncoding(from data: Data) -> (encoding: String.Encoding, name: String, isPresumed: Bool)? {
        // 1. Проверка BOM
        if let bom = detectBOM(data: data) {
            return (bom.encoding, bom.name, false)
        }
        
        // 2. Если есть NUL байт, это бинарный файл
        if containsNulByte(in: data) {
            return nil
        }
        
        // 3. Строгая валидация UTF-8
        if let utf8Str = String(data: data, encoding: .utf8) {
            _ = utf8Str
            return (.utf8, "UTF-8", false)
        }
        
        // 4. Fallback эвристика по первым 64 КБ
        let sample = data.prefix(fallbackSampleSize)
        
        // Проверяем Windows-1251 (частый случай для русскоязычных текстовых файлов)
        if let str1251 = String(data: sample, encoding: .windowsCP1251) {
            // Простая частотная эвристика для кириллицы (буквы а-я, А-Я в UTF-16 диапазоне)
            let cyrillicCount = str1251.unicodeScalars.filter { ($0.value >= 0x0400 && $0.value <= 0x04FF) }.count
            if cyrillicCount > 10 {
                return (.windowsCP1251, "Windows-1251", false)
            }
        }
        
        // Fallback по умолчанию: Windows-1252 (cp1252) с пометкой «кодировка предположительна»
        if String(data: sample, encoding: .windowsCP1252) != nil {
            return (.windowsCP1252, "Windows-1252 (предположительно)", true)
        }
        
        if String(data: sample, encoding: .isoLatin1) != nil {
            return (.isoLatin1, "ISO-8859-1 (предположительно)", true)
        }
        
        return nil
    }
    
    /// Полный анализ содержимого файла на текстовость, кодировку и лимиты строк/размера
    public static func validateTextFile(
        fileURL: URL,
        maxSize: UInt64 = defaultMaxSizeBytes,
        maxLines: Int = defaultMaxLineCount
    ) -> TextValidationResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            return .readError(reason: "Файл недоступен")
        }
        
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path) else {
            return .readError(reason: "Нет доступа к файлу")
        }
        
        let size = (attrs[.size] as? UInt64) ?? 0
        if size > maxSize {
            return .tooLarge(size: size, limit: maxSize)
        }
        
        let ext = fileURL.pathExtension.lowercased()
        
        // Обработка PDF документов
        if ext == "pdf" {
            switch extractPDFText(fileURL: fileURL) {
            case .success(let text):
                var lineCount = 0
                text.enumerateLines { _, stop in
                    lineCount += 1
                    if lineCount > maxLines {
                        stop = true
                    }
                }
                if lineCount > maxLines {
                    return .tooManyLines(count: lineCount, limit: maxLines)
                }
                return .validText(
                    text: text,
                    encoding: .utf8,
                    encodingName: "PDF",
                    isPresumed: false
                )
            case .failure(let error):
                return .binary(reason: error.message)
            }
        }
        
        // Обработка Word / Rich Text документов (doc, docx, rtf)
        if ext == "doc" || ext == "docx" || ext == "rtf" {
            switch extractOfficeDocumentText(fileURL: fileURL, ext: ext) {
            case .success(let text):
                var lineCount = 0
                text.enumerateLines { _, stop in
                    lineCount += 1
                    if lineCount > maxLines {
                        stop = true
                    }
                }
                if lineCount > maxLines {
                    return .tooManyLines(count: lineCount, limit: maxLines)
                }
                return .validText(
                    text: text,
                    encoding: .utf8,
                    encodingName: ext.uppercased(),
                    isPresumed: false
                )
            case .failure(let error):
                return .binary(reason: error.message)
            }
        }
        
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return .readError(reason: "Не удалось прочитать файл")
        }
        
        if data.isEmpty {
            return .validText(text: "", encoding: .utf8, encodingName: "UTF-8", isPresumed: false)
        }
        
        // Дополнительная проверка на случай PDF без расширения (начинается с %PDF-)
        if data.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2D]) {
            switch extractPDFText(fileURL: fileURL) {
            case .success(let text):
                return .validText(text: text, encoding: .utf8, encodingName: "PDF", isPresumed: false)
            case .failure(let error):
                return .binary(reason: error.message)
            }
        }
        
        guard let detection = detectEncoding(from: data) else {
            return .binary(reason: "Файл не текстовый")
        }
        
        // Попытка декодировать целиком с определенной кодировкой
        var decodedText: String?
        if let bom = detectBOM(data: data) {
            let dataWithoutBOM = data.dropFirst(bom.bomLength)
            decodedText = String(data: dataWithoutBOM, encoding: bom.encoding)
        } else {
            decodedText = String(data: data, encoding: detection.encoding)
        }
        
        guard let text = decodedText else {
            return .binary(reason: "Не удалось декодировать текст")
        }
        
        // Проверка лимита строк (FR-18)
        var lineCount = 0
        text.enumerateLines { _, stop in
            lineCount += 1
            if lineCount > maxLines {
                stop = true
            }
        }
        
        if lineCount > maxLines {
            return .tooManyLines(count: lineCount, limit: maxLines)
        }
        
        return .validText(
            text: text,
            encoding: detection.encoding,
            encodingName: detection.name,
            isPresumed: detection.isPresumed
        )
    }
    
    /// Декодирование с принудительно заданной кодировкой (для ручного переключения пользователем, FR-17)
    public static func decodeWithEncoding(fileURL: URL, encoding: String.Encoding) -> String? {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "pdf" {
            if case .success(let text) = extractPDFText(fileURL: fileURL) {
                return text
            }
            return nil
        }
        if ext == "doc" || ext == "docx" || ext == "rtf" {
            if case .success(let text) = extractOfficeDocumentText(fileURL: fileURL, ext: ext) {
                return text
            }
            return nil
        }
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
        if let bom = detectBOM(data: data), bom.encoding == encoding {
            let dataWithoutBOM = data.dropFirst(bom.bomLength)
            return String(data: dataWithoutBOM, encoding: encoding)
        }
        return String(data: data, encoding: encoding)
    }
}
