import Foundation
import SwiftUI
import AppKit

/// Описание тега (метки), используемого в сайдбаре, контекстном меню и колонке тегов
public struct FileTag: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let colorName: String
    
    public init(id: String, name: String, colorName: String) {
        self.id = id
        self.name = name
        self.colorName = colorName
    }
    
    public var color: Color {
        switch colorName.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green", "greem": return .green
        case "blue": return .blue
        case "gray", "grey": return Color(nsColor: .systemGray).opacity(0.48)
        case "purple": return .purple
        default: return .secondary
        }
    }
    
    public var nsColor: NSColor {
        switch colorName.lowercased() {
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "yellow": return .systemYellow
        case "green", "greem": return .systemGreen
        case "blue": return .systemBlue
        case "gray", "grey": return NSColor.systemGray.withAlphaComponent(0.48)
        case "purple": return .systemPurple
        default: return .secondaryLabelColor
        }
    }
    
    public static let allTags: [FileTag] = [
        FileTag(id: "Red", name: "Red", colorName: "red"),
        FileTag(id: "Orange", name: "Orange", colorName: "orange"),
        FileTag(id: "Yellow", name: "Yellow", colorName: "yellow"),
        FileTag(id: "Green", name: "Green", colorName: "green"),
        FileTag(id: "Blue", name: "Blue", colorName: "blue"),
        FileTag(id: "Grey", name: "Grey", colorName: "gray")
    ]
    
    public static func tag(for idOrName: String) -> FileTag? {
        let lower = idOrName.lowercased()
        if let direct = allTags.first(where: { $0.id.lowercased() == lower || $0.name.lowercased() == lower }) {
            return direct
        }
        for tag in allTags {
            if isTagMatching(idOrName, tagIdOrName: tag.id) {
                return tag
            }
        }
        return nil
    }

    public static func isTagMatching(_ a: String, tagIdOrName b: String) -> Bool {
        let aLower = a.lowercased()
        let bLower = b.lowercased()
        if aLower == bLower { return true }
        
        let redSynonyms = ["red", "красный", "червоний"]
        let orangeSynonyms = ["orange", "оранжевый", "оранжевий", "помаранчевий"]
        let yellowSynonyms = ["yellow", "желтый", "жовтий"]
        let greenSynonyms = ["green", "greem", "зеленый", "зелений"]
        let blueSynonyms = ["blue", "синий", "синій", "голубой", "блакитний"]
        let greySynonyms = ["grey", "gray", "серый", "сірий"]
        let purpleSynonyms = ["purple", "фиолетовый", "бузковий"]
        
        let groups = [redSynonyms, orangeSynonyms, yellowSynonyms, greenSynonyms, blueSynonyms, greySynonyms, purpleSynonyms]
        for g in groups {
            if g.contains(aLower) && g.contains(bLower) {
                return true
            }
        }
        return false
    }
}

/// Менеджер тегов файлов и папок:
/// - Для локального Mac сохраняет теги в файловой системе (NSURL.tagNamesKey), совместимо с Finder
/// - Для удаленных устройств (Android / Phone) сохраняет теги в UserDefaults
public final class TagsManager: @unchecked Sendable {
    public static let shared = TagsManager()
    
    private let userDefaultsKey = "com.macdroid.remoteItemTags"
    private let lock = NSLock()
    private var remoteItemTags: [String: [String]] = [:]
    
    private init() {
        loadRemoteTags()
    }
    
    private func loadRemoteTags() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let dict = try? JSONDecoder().decode([String: [String]].self, from: data) {
            remoteItemTags = dict
        }
    }
    
    private func saveRemoteTags() {
        if let data = try? JSONEncoder().encode(remoteItemTags) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }
    
    /// Получить теги для объекта
    public func getTags(for item: FileItem) -> [String] {
        if !item.tags.isEmpty {
            return item.tags
        }
        if item.source == .localMac {
            let url = URL(fileURLWithPath: item.path)
            if let tags = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames {
                return tags
            }
            return []
        } else {
            lock.lock()
            defer { lock.unlock() }
            return remoteItemTags[item.path] ?? []
        }
    }
    
    /// Проверить, имеет ли объект (файл или папка) теги
    public func hasTags(for item: FileItem) -> Bool {
        if item.source == .localMac {
            let url = URL(fileURLWithPath: item.path)
            if FileManager.default.fileExists(atPath: item.path) {
                if let tags = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames {
                    return !tags.isEmpty
                }
                return false
            }
            return !item.tags.isEmpty
        } else {
            lock.lock()
            defer { lock.unlock() }
            if let tags = remoteItemTags[item.path] {
                return !tags.isEmpty
            }
            return !item.tags.isEmpty
        }
    }
    
    /// Проверить, содержит ли папка вложенные файлы или папки с тегами
    public func containsTaggedItems(folderPath: String, source: FileSource) -> Bool {
        if source == .localMac {
            let url = URL(fileURLWithPath: folderPath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else {
                return false
            }
            if let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.tagNamesKey, .isDirectoryKey],
                options: [.skipsPackageDescendants]
            ) {
                while let fileURL = enumerator.nextObject() as? URL {
                    if let tags = (try? fileURL.resourceValues(forKeys: [.tagNamesKey]))?.tagNames, !tags.isEmpty {
                        return true
                    }
                }
            }
            return false
        } else {
            lock.lock()
            defer { lock.unlock() }
            let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
            return remoteItemTags.contains { key, tags in
                key.hasPrefix(prefix) && !tags.isEmpty
            }
        }
    }
    
    /// Проверить, защищен ли объект (файл или папка) от удаления наличием тегов у себя или внутри
    public func isItemOrContentsTagged(item: FileItem) -> (isTagged: Bool, reason: String?) {
        if hasTags(for: item) {
            let kind = item.isDirectory ? "Папка" : "Файл"
            return (true, "\(kind) «\(item.name)» имеет теги")
        }
        if item.isDirectory {
            if containsTaggedItems(folderPath: item.path, source: item.source) {
                return (true, "Папка «\(item.name)» содержит объекты с тегами")
            }
        }
        return (false, nil)
    }
    
    /// Установить теги для объекта
    public func setTags(_ tags: [String], for item: FileItem) {
        if item.source == .localMac {
            let url = URL(fileURLWithPath: item.path)
            try? (url as NSURL).setResourceValue(tags as NSArray, forKey: .tagNamesKey)
        } else {
            lock.lock()
            if tags.isEmpty {
                remoteItemTags.removeValue(forKey: item.path)
            } else {
                remoteItemTags[item.path] = tags
            }
            saveRemoteTags()
            lock.unlock()
        }
    }
    
    /// Полностью очистить теги для объекта по пути (и рекурсивно для всех вложенных объектов, если это папка)
    public func clearTags(at path: String, source: FileSource) {
        if source == .localMac {
            let url = URL(fileURLWithPath: path)
            try? (url as NSURL).setResourceValue(nil, forKey: .tagNamesKey)
            try? (url as NSURL).setResourceValue([] as NSArray, forKey: .tagNamesKey)
            removexattr(path, "com.apple.metadata:_kMDItemUserTags", 0)
            
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                if let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.tagNamesKey],
                    options: []
                ) {
                    while let fileURL = enumerator.nextObject() as? URL {
                        try? (fileURL as NSURL).setResourceValue(nil, forKey: .tagNamesKey)
                        try? (fileURL as NSURL).setResourceValue([] as NSArray, forKey: .tagNamesKey)
                        removexattr(fileURL.path, "com.apple.metadata:_kMDItemUserTags", 0)
                    }
                }
            }
        } else {
            lock.lock()
            defer { lock.unlock() }
            remoteItemTags.removeValue(forKey: path)
            let prefix = path.hasSuffix("/") ? path : path + "/"
            remoteItemTags = remoteItemTags.filter { key, _ in
                !key.hasPrefix(prefix)
            }
            saveRemoteTags()
        }
    }
    
    /// Переключить тег для объекта (добавить, если нет; удалить, если уже есть)
    @discardableResult
    public func toggleTag(_ tag: String, for item: FileItem) -> [String] {
        var current = getTags(for: item)
        if let idx = current.firstIndex(where: { FileTag.isTagMatching($0, tagIdOrName: tag) }) {
            current.remove(at: idx)
        } else {
            current.append(tag)
        }
        setTags(current, for: item)
        return current
    }
    
    /// Применить тег к массиву объектов:
    /// Если ВСЕ объекты уже имеют этот тег — снимаем его.
    /// Иначе — добавляем этот тег ко всем выбранным объектам.
    public func applyTagToggle(_ tag: String, to items: [FileItem]) -> [String: [String]] {
        let allHaveTag = items.allSatisfy { item in
            let tags = getTags(for: item)
            return tags.contains(where: { FileTag.isTagMatching($0, tagIdOrName: tag) })
        }
        
        var result: [String: [String]] = [:]
        for item in items {
            var tags = getTags(for: item)
            let existingIdx = tags.firstIndex(where: { FileTag.isTagMatching($0, tagIdOrName: tag) })
            
            if allHaveTag {
                if let idx = existingIdx {
                    tags.remove(at: idx)
                }
            } else {
                if existingIdx == nil {
                    tags.append(tag)
                }
            }
            setTags(tags, for: item)
            result[item.id] = tags
        }
        return result
    }
}
