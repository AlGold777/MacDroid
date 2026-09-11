import Foundation

/// Менеджер избранных папок (закладок) для быстрой навигации.
/// Хранит пользовательские и предустановленные закладки в UserDefaults.
public final class BookmarksManager: ObservableObject {
    public static let shared = BookmarksManager()
    
    /// Закладка — сохранённый путь с меткой и источником
    public struct Bookmark: Codable, Identifiable, Hashable, Sendable {
        public let id: UUID
        public let name: String
        public let path: String
        public let source: FileSource
        public let icon: String
        
        public init(id: UUID = UUID(), name: String, path: String, source: FileSource, icon: String = "folder.fill") {
            self.id = id
            self.name = name
            self.path = path
            self.source = source
            self.icon = icon
        }
    }
    
    /// Предустановленные закладки (Mac)
    public static let defaultMacBookmarks: [Bookmark] = [
        Bookmark(name: "Домой", path: FileManager.default.homeDirectoryForCurrentUser.path, source: .localMac, icon: "house.fill"),
        Bookmark(name: "Рабочий стол", path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path, source: .localMac, icon: "display"),
        Bookmark(name: "Загрузки", path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path, source: .localMac, icon: "arrow.down.circle.fill"),
        Bookmark(name: "Документы", path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents").path, source: .localMac, icon: "doc.fill"),
        Bookmark(name: "Изображения", path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures").path, source: .localMac, icon: "photo.fill"),
    ]
    
    /// Предустановленные закладки (Android)
    public static let defaultPhoneBookmarks: [Bookmark] = [
        Bookmark(name: "Хранилище", path: "/storage/emulated/0", source: .remotePhone, icon: "iphone"),
        Bookmark(name: "DCIM/Camera", path: "/storage/emulated/0/DCIM/Camera", source: .remotePhone, icon: "camera.fill"),
        Bookmark(name: "Screenshots", path: "/storage/emulated/0/DCIM/Screenshots", source: .remotePhone, icon: "rectangle.dashed.and.paperclip"),
        Bookmark(name: "Pictures", path: "/storage/emulated/0/Pictures", source: .remotePhone, icon: "photo.fill"),
        Bookmark(name: "Download", path: "/storage/emulated/0/Download", source: .remotePhone, icon: "arrow.down.circle.fill"),
        Bookmark(name: "Movies", path: "/storage/emulated/0/Movies", source: .remotePhone, icon: "film.fill"),
        Bookmark(name: "Music", path: "/storage/emulated/0/Music", source: .remotePhone, icon: "music.note"),
        Bookmark(name: "Documents", path: "/storage/emulated/0/Documents", source: .remotePhone, icon: "doc.fill"),
    ]
    
    private let userBookmarksKey = "userBookmarks"
    private let recentPathsKey = "recentPaths"
    private let maxRecentPaths = 20
    
    @Published public var userBookmarks: [Bookmark] = []
    @Published public var recentPaths: [Bookmark] = []
    
    private init() {
        loadUserBookmarks()
        loadRecentPaths()
    }
    
    /// Все закладки: предустановленные + пользовательские
    public var allBookmarks: [Bookmark] {
        Self.defaultMacBookmarks + Self.defaultPhoneBookmarks + userBookmarks
    }
    
    /// Закладки отфильтрованные по источнику
    public func bookmarks(for source: FileSource) -> [Bookmark] {
        let defaults = source == .localMac ? Self.defaultMacBookmarks : Self.defaultPhoneBookmarks
        let custom = userBookmarks.filter { $0.source == source }
        return defaults + custom
    }
    
    /// Добавить пользовательскую закладку
    public func addBookmark(name: String, path: String, source: FileSource) {
        let bookmark = Bookmark(name: name, path: path, source: source)
        userBookmarks.append(bookmark)
        saveUserBookmarks()
    }
    
    /// Удалить пользовательскую закладку
    public func removeBookmark(id: UUID) {
        userBookmarks.removeAll { $0.id == id }
        saveUserBookmarks()
    }
    
    /// Добавить путь в список недавних
    public func addRecentPath(path: String, source: FileSource) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let recent = Bookmark(name: name.isEmpty ? "/" : name, path: path, source: source, icon: "clock.fill")
        
        // Удалить дубликаты
        recentPaths.removeAll { $0.path == path && $0.source == source }
        
        // Добавить в начало
        recentPaths.insert(recent, at: 0)
        
        // Ограничить количество
        if recentPaths.count > maxRecentPaths {
            recentPaths = Array(recentPaths.prefix(maxRecentPaths))
        }
        
        saveRecentPaths()
    }
    
    // MARK: - Persistence
    
    private func saveUserBookmarks() {
        if let data = try? JSONEncoder().encode(userBookmarks) {
            UserDefaults.standard.set(data, forKey: userBookmarksKey)
        }
    }
    
    private func loadUserBookmarks() {
        if let data = UserDefaults.standard.data(forKey: userBookmarksKey),
           let bookmarks = try? JSONDecoder().decode([Bookmark].self, from: data) {
            userBookmarks = bookmarks
        }
    }
    
    private func saveRecentPaths() {
        if let data = try? JSONEncoder().encode(recentPaths) {
            UserDefaults.standard.set(data, forKey: recentPathsKey)
        }
    }
    
    private func loadRecentPaths() {
        if let data = UserDefaults.standard.data(forKey: recentPathsKey),
           let paths = try? JSONDecoder().decode([Bookmark].self, from: data) {
            recentPaths = paths
        }
    }
}
