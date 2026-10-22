import Foundation

public enum WhitespaceOption: String, CaseIterable, Sendable, Codable {
    case none = "none"
    case trimLeadingTrailing = "trim"
    case ignoreAll = "all"
    
    public var title: String {
        switch self {
        case .none: return "Учитывать пробелы"
        case .trimLeadingTrailing: return "Игнорировать пробелы по краям"
        case .ignoreAll: return "Игнорировать все пробелы"
        }
    }
}

public struct DiffOptions: Equatable, Hashable, Sendable, Codable {
    public var whitespace: WhitespaceOption
    public var ignoreCase: Bool
    public var ignoreLineEndings: Bool
    
    public init(
        whitespace: WhitespaceOption = .none,
        ignoreCase: Bool = false,
        ignoreLineEndings: Bool = false
    ) {
        self.whitespace = whitespace
        self.ignoreCase = ignoreCase
        self.ignoreLineEndings = ignoreLineEndings
    }
}

public enum DiffLineKind: Sendable, Equatable {
    case equal
    case added
    case deleted
    case modified
}

public struct DiffHighlightRange: Sendable, Equatable, Identifiable {
    public var id: String { "\(range.lowerBound)-\(range.upperBound)" }
    public let range: Range<Int>
    
    public init(range: Range<Int>) {
        self.range = range
    }
}

public struct DiffAlignedLine: Identifiable, Sendable, Equatable {
    public let id: Int
    public let kind: DiffLineKind
    public let leftLineNumber: Int?
    public let leftContent: String?
    public let rightLineNumber: Int?
    public let rightContent: String?
    public let leftIntraHighlights: [DiffHighlightRange]
    public let rightIntraHighlights: [DiffHighlightRange]
    public let isHunkStart: Bool
    
    public init(
        id: Int,
        kind: DiffLineKind,
        leftLineNumber: Int?,
        leftContent: String?,
        rightLineNumber: Int?,
        rightContent: String?,
        leftIntraHighlights: [DiffHighlightRange] = [],
        rightIntraHighlights: [DiffHighlightRange] = [],
        isHunkStart: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.leftLineNumber = leftLineNumber
        self.leftContent = leftContent
        self.rightLineNumber = rightLineNumber
        self.rightContent = rightContent
        self.leftIntraHighlights = leftIntraHighlights
        self.rightIntraHighlights = rightIntraHighlights
        self.isHunkStart = isHunkStart
    }
}

public struct DiffHunk: Identifiable, Sendable, Equatable {
    public let id: Int
    public let startRowIndex: Int
    public let lineCount: Int
    public let leftLineStart: Int
    public let rightLineStart: Int
}

public struct DiffResult: Sendable, Equatable {
    public let alignedLines: [DiffAlignedLine]
    public let hunks: [DiffHunk]
    public let isIdentical: Bool
    public let addedCount: Int
    public let deletedCount: Int
    public let modifiedCount: Int
    
    public var totalDifferences: Int {
        return hunks.count
    }
}

public enum TextDiffEngine {
    
    /// Нормализует строку для сравнения в соответствии с DiffOptions
    public static func normalizeForComparison(_ line: String, options: DiffOptions) -> String {
        var str = line
        
        if options.ignoreLineEndings {
            if str.hasSuffix("\r\n") {
                str.removeLast(2)
            } else if str.hasSuffix("\n") || str.hasSuffix("\r") {
                str.removeLast()
            }
        }
        
        if options.ignoreCase {
            str = str.lowercased()
        }
        
        switch options.whitespace {
        case .none:
            break
        case .trimLeadingTrailing:
            str = str.trimmingCharacters(in: .whitespaces)
        case .ignoreAll:
            str = str.filter { !$0.isWhitespace }
        }
        
        return str
    }
    
    /// Разбивает текст на строки с сохранением содержимого
    public static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines: [String] = []
        text.enumerateLines(invoking: { line, _ in
            lines.append(line)
        })
        if text.hasSuffix("\n") || text.hasSuffix("\r") {
            // Если текст оканчивается переносом строки, enumerateLines не добавляет пустую строку
            lines.append("")
        }
        return lines
    }
    
    /// Чистая функция построчного diff
    public static func diff(textA: String, textB: String, options: DiffOptions = DiffOptions()) -> DiffResult {
        let rawLinesA = splitLines(textA)
        let rawLinesB = splitLines(textB)
        
        // Быстрая проверка на идентичность
        if rawLinesA.count == rawLinesB.count {
            var identical = true
            for i in 0..<rawLinesA.count {
                let normA = normalizeForComparison(rawLinesA[i], options: options)
                let normB = normalizeForComparison(rawLinesB[i], options: options)
                if normA != normB {
                    identical = false
                    break
                }
            }
            if identical {
                var lines: [DiffAlignedLine] = []
                for i in 0..<rawLinesA.count {
                    lines.append(DiffAlignedLine(
                        id: i,
                        kind: .equal,
                        leftLineNumber: i + 1,
                        leftContent: rawLinesA[i],
                        rightLineNumber: i + 1,
                        rightContent: rawLinesB[i]
                    ))
                }
                return DiffResult(
                    alignedLines: lines,
                    hunks: [],
                    isIdentical: true,
                    addedCount: 0,
                    deletedCount: 0,
                    modifiedCount: 0
                )
            }
        }
        
        let normLinesA = rawLinesA.map { normalizeForComparison($0, options: options) }
        let normLinesB = rawLinesB.map { normalizeForComparison($0, options: options) }
        
        let edits = myersDiff(normLinesA, normLinesB)
        return alignEdits(rawLinesA: rawLinesA, rawLinesB: rawLinesB, edits: edits)
    }
    
    private enum EditOp {
        case keep(indexA: Int, indexB: Int)
        case delete(indexA: Int)
        case insert(indexB: Int)
    }
    
    private static func myersDiff(_ a: [String], _ b: [String]) -> [EditOp] {
        let n = a.count
        let m = b.count
        
        // Общий префикс
        var prefixLen = 0
        while prefixLen < n && prefixLen < m && a[prefixLen] == b[prefixLen] {
            prefixLen += 1
        }
        
        // Общий суффикс
        var suffixLen = 0
        while suffixLen < (n - prefixLen) && suffixLen < (m - prefixLen) && a[n - 1 - suffixLen] == b[m - 1 - suffixLen] {
            suffixLen += 1
        }
        
        let midA = Array(a[prefixLen..<(n - suffixLen)])
        let midB = Array(b[prefixLen..<(m - suffixLen)])
        
        var ops: [EditOp] = []
        for i in 0..<prefixLen {
            ops.append(.keep(indexA: i, indexB: i))
        }
        
        let midOps = runMyers(midA, midB, offsetA: prefixLen, offsetB: prefixLen)
        ops.append(contentsOf: midOps)
        
        for i in 0..<suffixLen {
            ops.append(.keep(indexA: n - suffixLen + i, indexB: m - suffixLen + i))
        }
        
        return ops
    }
    
    private static func runMyers(_ a: [String], _ b: [String], offsetA: Int, offsetB: Int) -> [EditOp] {
        let n = a.count
        let m = b.count
        if n == 0 {
            return (0..<m).map { .insert(indexB: offsetB + $0) }
        }
        if m == 0 {
            return (0..<n).map { .delete(indexA: offsetA + $0) }
        }
        
        let maxD = n + m
        var v = [Int](repeating: 0, count: 2 * maxD + 2)
        var trace: [[Int]] = []
        
        var foundD = -1
        for d in 0...maxD {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                let kIndex = k + maxD
                var x: Int
                if k == -d || (k != d && v[kIndex - 1] < v[kIndex + 1]) {
                    x = v[kIndex + 1]
                } else {
                    x = v[kIndex - 1] + 1
                }
                var y = x - k
                while x < n && y < m && a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[kIndex] = x
                if x >= n && y >= m {
                    foundD = d
                    break
                }
            }
            if foundD != -1 { break }
        }
        
        // Восстановление пути
        var ops: [EditOp] = []
        var x = n
        var y = m
        for d in stride(from: foundD, through: 1, by: -1) {
            let vPrev = trace[d]
            let k = x - y
            let kIndex = k + maxD
            let prevK: Int
            if k == -d || (k != d && vPrev[kIndex - 1] < vPrev[kIndex + 1]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = vPrev[prevK + maxD]
            let prevY = prevX - prevK
            
            while x > prevX && y > prevY {
                x -= 1
                y -= 1
                ops.append(.keep(indexA: offsetA + x, indexB: offsetB + y))
            }
            
            if d > 0 {
                if prevX == x {
                    y -= 1
                    ops.append(.insert(indexB: offsetB + y))
                } else {
                    x -= 1
                    ops.append(.delete(indexA: offsetA + x))
                }
            }
        }
        
        while x > 0 && y > 0 {
            x -= 1
            y -= 1
            ops.append(.keep(indexA: offsetA + x, indexB: offsetB + y))
        }
        
        return ops.reversed()
    }
    
    private static func alignEdits(rawLinesA: [String], rawLinesB: [String], edits: [EditOp]) -> DiffResult {
        var aligned: [DiffAlignedLine] = []
        var hunks: [DiffHunk] = []
        
        var i = 0
        var currentHunkStartRow: Int? = nil
        var currentHunkLeftStart = 1
        var currentHunkRightStart = 1
        var addedCount = 0
        var deletedCount = 0
        var modifiedCount = 0
        
        func finishHunkIfNeeded() {
            if let startRow = currentHunkStartRow {
                let hunk = DiffHunk(
                    id: hunks.count,
                    startRowIndex: startRow,
                    lineCount: aligned.count - startRow,
                    leftLineStart: currentHunkLeftStart,
                    rightLineStart: currentHunkRightStart
                )
                hunks.append(hunk)
                currentHunkStartRow = nil
            }
        }
        
        while i < edits.count {
            switch edits[i] {
            case .keep(let idxA, let idxB):
                finishHunkIfNeeded()
                aligned.append(DiffAlignedLine(
                    id: aligned.count,
                    kind: .equal,
                    leftLineNumber: idxA + 1,
                    leftContent: rawLinesA[idxA],
                    rightLineNumber: idxB + 1,
                    rightContent: rawLinesB[idxB]
                ))
                i += 1
                
            case .delete, .insert:
                var delIndices: [Int] = []
                var insIndices: [Int] = []
                
                while i < edits.count {
                    if case .delete(let aIdx) = edits[i] {
                        delIndices.append(aIdx)
                        i += 1
                    } else if case .insert(let bIdx) = edits[i] {
                        insIndices.append(bIdx)
                        i += 1
                    } else {
                        break
                    }
                }
                
                let isFirstDifferenceInHunk = currentHunkStartRow == nil
                if isFirstDifferenceInHunk {
                    currentHunkStartRow = aligned.count
                    currentHunkLeftStart = (delIndices.first ?? 0) + 1
                    currentHunkRightStart = (insIndices.first ?? 0) + 1
                }
                
                let pairCount = min(delIndices.count, insIndices.count)
                for p in 0..<pairCount {
                    let aIdx = delIndices[p]
                    let bIdx = insIndices[p]
                    let lineA = rawLinesA[aIdx]
                    let lineB = rawLinesB[bIdx]
                    
                    let (leftHigh, rightHigh) = computeIntraLineDiff(lineA: lineA, lineB: lineB)
                    let isStart = isFirstDifferenceInHunk && (p == 0)
                    
                    aligned.append(DiffAlignedLine(
                        id: aligned.count,
                        kind: .modified,
                        leftLineNumber: aIdx + 1,
                        leftContent: lineA,
                        rightLineNumber: bIdx + 1,
                        rightContent: lineB,
                        leftIntraHighlights: leftHigh,
                        rightIntraHighlights: rightHigh,
                        isHunkStart: isStart
                    ))
                    modifiedCount += 1
                }
                
                if delIndices.count > pairCount {
                    for d in pairCount..<delIndices.count {
                        let aIdx = delIndices[d]
                        let isStart = isFirstDifferenceInHunk && (pairCount == 0) && (d == 0)
                        aligned.append(DiffAlignedLine(
                            id: aligned.count,
                            kind: .deleted,
                            leftLineNumber: aIdx + 1,
                            leftContent: rawLinesA[aIdx],
                            rightLineNumber: nil,
                            rightContent: nil,
                            isHunkStart: isStart
                        ))
                        deletedCount += 1
                    }
                } else if insIndices.count > pairCount {
                    for s in pairCount..<insIndices.count {
                        let bIdx = insIndices[s]
                        let isStart = isFirstDifferenceInHunk && (pairCount == 0) && (s == 0)
                        aligned.append(DiffAlignedLine(
                            id: aligned.count,
                            kind: .added,
                            leftLineNumber: nil,
                            leftContent: nil,
                            rightLineNumber: bIdx + 1,
                            rightContent: rawLinesB[bIdx],
                            isHunkStart: isStart
                        ))
                        addedCount += 1
                    }
                }
            }
        }
        
        finishHunkIfNeeded()
        
        return DiffResult(
            alignedLines: aligned,
            hunks: hunks,
            isIdentical: hunks.isEmpty,
            addedCount: addedCount,
            deletedCount: deletedCount,
            modifiedCount: modifiedCount
        )
    }
    
    /// FR-33: Внутристрочный diff ограничивается первыми 1000 символами строки
    public static func computeIntraLineDiff(lineA: String, lineB: String) -> ([DiffHighlightRange], [DiffHighlightRange]) {
        let maxIntraLen = 1000
        if lineA.count > maxIntraLen || lineB.count > maxIntraLen {
            let leftFull = [DiffHighlightRange(range: 0..<lineA.count)]
            let rightFull = [DiffHighlightRange(range: 0..<lineB.count)]
            return (leftFull, rightFull)
        }
        
        let charsA = Array(lineA)
        let charsB = Array(lineB)
        
        var prefix = 0
        while prefix < charsA.count && prefix < charsB.count && charsA[prefix] == charsB[prefix] {
            prefix += 1
        }
        
        var suffixA = charsA.count - 1
        var suffixB = charsB.count - 1
        while suffixA >= prefix && suffixB >= prefix && charsA[suffixA] == charsB[suffixB] {
            suffixA -= 1
            suffixB -= 1
        }
        
        var leftRanges: [DiffHighlightRange] = []
        var rightRanges: [DiffHighlightRange] = []
        
        if prefix <= suffixA {
            leftRanges.append(DiffHighlightRange(range: prefix..<(suffixA + 1)))
        }
        if prefix <= suffixB {
            rightRanges.append(DiffHighlightRange(range: prefix..<(suffixB + 1)))
        }
        
        return (leftRanges, rightRanges)
    }
}
