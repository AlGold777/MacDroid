import SwiftUI

public enum BatchRenameCaseMode: String, CaseIterable, Identifiable {
    case none = "Без изменений"
    case lower = "все строчные (abc)"
    case upper = "ВСЕ ПРОПИСНЫЕ (ABC)"
    case title = "Первые Прописные (Abc Def)"
    case sentence = "Первая буква прописная (Abc def)"
    
    public var id: String { rawValue }
}

public struct BatchRenameModalView: View {
    public let items: [FileItem]
    public let onApplyRename: ([(oldItem: FileItem, newName: String)]) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vm: DualPaneViewModel
    
    // Маски
    @State private var nameMask: String = "[N]"
    @State private var extensionMask: String = "[E]"
    
    // Поиск и замена
    @State private var findText: String = ""
    @State private var replaceText: String = ""
    @State private var caseSensitive: Bool = false
    @State private var useRegex: Bool = false
    
    // Регистр букв
    @State private var caseMode: BatchRenameCaseMode = .none
    
    // Счётчик [C]
    @State private var counterStart: Int = 1
    @State private var counterStep: Int = 1
    @State private var counterDigits: Int = 2
    
    public init(items: [FileItem], onApplyRename: @escaping ([(oldItem: FileItem, newName: String)]) -> Void) {
        self.items = items
        self.onApplyRename = onApplyRename
    }
    
    // MARK: - Substring Range Helper
    private static func extractSubrange(from str: String, start: Int, end: Int?) -> String {
        guard !str.isEmpty else { return "" }
        let chars = Array(str)
        let sIdx = max(0, min(start - 1, chars.count))
        let eIdx: Int
        if let end = end {
            eIdx = max(sIdx, min(end, chars.count))
        } else {
            eIdx = chars.count
        }
        guard sIdx < chars.count else { return "" }
        return String(chars[sIdx..<eIdx])
    }
    
    // MARK: - Token Evaluator
    private func evaluateMask(_ mask: String, item: FileItem, counterValue: Int, isExtension: Bool) -> String {
        let fullName = item.name
        let url = URL(fileURLWithPath: fullName)
        let ext = url.pathExtension
        let baseName = url.deletingPathExtension().lastPathComponent
        let counterStr = String(format: "%0\(counterDigits)d", counterValue)
        
        let mtimeDate = Date(timeIntervalSince1970: TimeInterval(item.mtime))
        let dateFormatter = DateFormatter()
        
        dateFormatter.dateFormat = "yyyyMMdd"
        let ymd = dateFormatter.string(from: mtimeDate)
        
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let ymdDash = dateFormatter.string(from: mtimeDate)
        
        dateFormatter.dateFormat = "HHmmss"
        let hms = dateFormatter.string(from: mtimeDate)
        
        dateFormatter.dateFormat = "HH-mm-ss"
        let hmsDash = dateFormatter.string(from: mtimeDate)
        
        var result = mask
        
        // Диапазоны в круглых скобках (N#-#)
        if let regexRange = try? NSRegularExpression(pattern: #"\([Nn](\d+)-(\d+)?\)"#) {
            let nsResult = result as NSString
            let matches = regexRange.matches(in: result, range: NSRange(location: 0, length: nsResult.length))
            for match in matches.reversed() {
                let r1 = match.range(at: 1)
                let startVal = Int(nsResult.substring(with: r1)) ?? 1
                var endVal: Int? = nil
                if match.numberOfRanges > 2 {
                    let r2 = match.range(at: 2)
                    if r2.location != NSNotFound {
                        endVal = Int(nsResult.substring(with: r2))
                    }
                }
                let sub = Self.extractSubrange(from: baseName, start: startVal, end: endVal)
                result = (result as NSString).replacingCharacters(in: match.range, with: sub)
            }
        }
        
        // Диапазоны в квадратных скобках [N#-#]
        if let regexRangeBracket = try? NSRegularExpression(pattern: #"\[[Nn](\d+)-(\d+)?\]"#) {
            let nsResult = result as NSString
            let matches = regexRangeBracket.matches(in: result, range: NSRange(location: 0, length: nsResult.length))
            for match in matches.reversed() {
                let r1 = match.range(at: 1)
                let startVal = Int(nsResult.substring(with: r1)) ?? 1
                var endVal: Int? = nil
                if match.numberOfRanges > 2 {
                    let r2 = match.range(at: 2)
                    if r2.location != NSNotFound {
                        endVal = Int(nsResult.substring(with: r2))
                    }
                }
                let sub = Self.extractSubrange(from: baseName, start: startVal, end: endVal)
                result = (result as NSString).replacingCharacters(in: match.range, with: sub)
            }
        }
        
        // Замена базовых токенов
        result = result.replacingOccurrences(of: "[N]", with: baseName)
        result = result.replacingOccurrences(of: "[n]", with: baseName)
        result = result.replacingOccurrences(of: "[E]", with: ext)
        result = result.replacingOccurrences(of: "[e]", with: ext)
        result = result.replacingOccurrences(of: "[C]", with: counterStr)
        result = result.replacingOccurrences(of: "[c]", with: counterStr)
        result = result.replacingOccurrences(of: "[YMD]", with: ymd)
        result = result.replacingOccurrences(of: "[Y-M-D]", with: ymdDash)
        result = result.replacingOccurrences(of: "[hms]", with: hms)
        result = result.replacingOccurrences(of: "[h-m-s]", with: hmsDash)
        
        return result
    }
    
    // MARK: - Full Name Generation
    private func computeNewName(for item: FileItem, counterValue: Int) -> String {
        var base = evaluateMask(nameMask, item: item, counterValue: counterValue, isExtension: false)
        let resolvedExt = evaluateMask(extensionMask, item: item, counterValue: counterValue, isExtension: true)
        
        // Поиск и замена
        if !findText.isEmpty {
            if useRegex {
                if let regex = try? NSRegularExpression(pattern: findText, options: caseSensitive ? [] : [.caseInsensitive]) {
                    let range = NSRange(location: 0, length: base.utf16.count)
                    base = regex.stringByReplacingMatches(in: base, options: [], range: range, withTemplate: replaceText)
                }
            } else {
                base = base.replacingOccurrences(of: findText, with: replaceText, options: caseSensitive ? [] : [.caseInsensitive])
            }
        }
        
        // Регистр
        switch caseMode {
        case .none:
            break
        case .lower:
            base = base.lowercased()
        case .upper:
            base = base.uppercased()
        case .title:
            base = base.capitalized
        case .sentence:
            if let first = base.first {
                base = String(first).uppercased() + base.dropFirst().lowercased()
            }
        }
        
        let rawResult = resolvedExt.isEmpty ? base : "\(base).\(resolvedExt)"
        return rawResult.precomposedStringWithCanonicalMapping
    }
    
    // MARK: - Mappings & Conflict Detection
    private var previewMappings: [(oldItem: FileItem, newName: String, hasConflict: Bool)] {
        var results: [(oldItem: FileItem, newName: String, hasConflict: Bool)] = []
        var currentCounter = counterStart
        
        for item in items {
            let generated = computeNewName(for: item, counterValue: currentCounter)
            currentCounter += counterStep
            results.append((item, generated, false))
        }
        
        // Подсчёт дубликатов целевых имён для предотвращения случайной перезаписи
        var nameCounts: [String: Int] = [:]
        for res in results {
            nameCounts[res.newName, default: 0] += 1
        }
        
        return results.map { mapping in
            let conflict = (nameCounts[mapping.newName] ?? 0) > 1
            return (mapping.oldItem, mapping.newName, conflict)
        }
    }
    
    private var conflictCount: Int {
        previewMappings.filter { $0.hasConflict }.count
    }
    
    private var changedCount: Int {
        previewMappings.filter { $0.oldItem.name != $0.newName }.count
    }
    
    // MARK: - Body
    public var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "pencil.and.list.clipboard")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Групповое переименование (Total Commander)")
                        .font(.headline)
                    Text("\(items.count) объектов в очереди • \(changedCount) к изменению")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                
                if vm.canUndoBatchRename {
                    Button(action: {
                        vm.undoBatchRename()
                        dismiss()
                    }) {
                        Label("Откат последнего переименования", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            
            Divider()
            
            // Настройки шаблонов в стиле Total Commander (2 колонки)
            HStack(alignment: .top, spacing: 16) {
                // Левая колонка: Маски [N], [E]
                VStack(alignment: .leading, spacing: 10) {
                    Text("Шаблон переименования:")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Маска для имени файла:")
                                .font(.caption)
                            Spacer()
                        }
                        TextField("Маска имени...", text: $nameMask)
                            .textFieldStyle(.roundedBorder)
                        
                        // Кнопки быстрой вставки токенов
                        HStack(spacing: 4) {
                            Button("[N] Имя") { nameMask += "[N]" }
                            Button("[N1-5]") { nameMask += "[N1-5]" }
                            Button("[N2-]") { nameMask += "[N2-]" }
                            Button("[C] Счётчик") { nameMask += "[C]" }
                            Button("[YMD]") { nameMask += "[YMD]" }
                            Button("[hms]") { nameMask += "[hms]" }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Маска для расширения:")
                            .font(.caption)
                        TextField("Маска расширения...", text: $extensionMask)
                            .textFieldStyle(.roundedBorder)
                        
                        HStack(spacing: 4) {
                            Button("[E] Расширение") { extensionMask = "[E]" }
                            Button("[C] Счётчик") { extensionMask += "[C]" }
                            Button("Очистить") { extensionMask = "" }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    
                    // Параметры счётчика [C]
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Старт [C]:")
                                .font(.caption2)
                            Stepper("\(counterStart)", value: $counterStart, in: 0...99999)
                                .controlSize(.small)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Шаг [C]:")
                                .font(.caption2)
                            Stepper("\(counterStep)", value: $counterStep, in: 1...100)
                                .controlSize(.small)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Разрядность:")
                                .font(.caption2)
                            Picker("", selection: $counterDigits) {
                                Text("1 (1, 2)").tag(1)
                                Text("2 (01, 02)").tag(2)
                                Text("3 (001, 002)").tag(3)
                                Text("4 (0001)").tag(4)
                                Text("5 (00001)").tag(5)
                            }
                            .labelsHidden()
                            .controlSize(.small)
                        }
                    }
                    .padding(6)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .cornerRadius(6)
                }
                .frame(maxWidth: .infinity)
                
                Divider()
                
                // Правая колонка: Поиск и Замена, Регистр
                VStack(alignment: .leading, spacing: 10) {
                    Text("Поиск, замена и регистр:")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Найти:")
                            .font(.caption)
                        TextField("Текст для поиска...", text: $findText)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Заменить на:")
                            .font(.caption)
                        TextField("Текст замены...", text: $replaceText)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    HStack(spacing: 12) {
                        Toggle("Учитывать регистр", isOn: $caseSensitive)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                        Toggle("RegEx", isOn: $useRegex)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .help("Регулярные выражения")
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Изменение регистра букв:")
                            .font(.caption)
                        Picker("", selection: $caseMode) {
                            ForEach(BatchRenameCaseMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .labelsHidden()
                    }
                    
                    Button("Сбросить шаблоны к [N].[E]") {
                        nameMask = "[N]"
                        extensionMask = "[E]"
                        findText = ""
                        replaceText = ""
                        caseSensitive = false
                        useRegex = false
                        caseMode = .none
                        counterStart = 1
                        counterStep = 1
                        counterDigits = 2
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            
            Divider()
            
            // Предупреждение о конфликтах
            if conflictCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text("Обнаружено конфликтов имён: \(conflictCount). Разные файлы получат одинаковое имя! Добавьте [C] в маску для устранения коллизии.")
                        .font(.caption)
                        .foregroundColor(.red)
                        .fontWeight(.semibold)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.12))
            }
            
            // Таблица предпросмотра (Side-by-side / Table)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Предпросмотр результата переименования:")
                        .font(.caption)
                        .fontWeight(.bold)
                    Spacer()
                    Text("Всего: \(items.count) | Изменится: \(changedCount) | Конфликтов: \(conflictCount)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                
                List {
                    ForEach(previewMappings, id: \.oldItem.id) { pair in
                        HStack(spacing: 10) {
                            // Старое имя
                            Text(pair.oldItem.name)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundColor(pair.hasConflict ? .red : (pair.oldItem.name != pair.newName ? .accentColor : .secondary))
                            
                            // Новое имя
                            Text(pair.newName)
                                .font(.system(size: 11, weight: pair.oldItem.name != pair.newName ? .semibold : .regular, design: .monospaced))
                                .foregroundColor(pair.hasConflict ? .red : (pair.oldItem.name != pair.newName ? Color.primary : .secondary))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            // Статус
                            if pair.hasConflict {
                                Text("Конфликт")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.red)
                                    .foregroundColor(.white)
                                    .cornerRadius(4)
                            } else if pair.oldItem.name != pair.newName {
                                Text("Изменится")
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .foregroundColor(.accentColor)
                                    .cornerRadius(4)
                            } else {
                                Text("Без изм.")
                                    .font(.system(size: 9))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.gray.opacity(0.12))
                                    .foregroundColor(.secondary)
                                    .cornerRadius(4)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 180, maxHeight: .infinity)
            }
            
            Divider()
            
            // Кнопки управления
            HStack(spacing: 12) {
                Button("Отмена (Esc)") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Выполнить переименование (Enter)") {
                    let finalMappings = previewMappings.map { ($0.oldItem, $0.newName) }
                    onApplyRename(finalMappings)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(conflictCount > 0 || changedCount == 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(minWidth: 840, idealWidth: 880, minHeight: 620, idealHeight: 660)
    }
}
