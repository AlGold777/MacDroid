import Foundation

public protocol FileSystemDriver: Sendable {
    func listDirectory(at path: String) async throws -> [FileItem]
    func createDirectory(at path: String) async throws
    func deleteItem(at path: String, moveToTrash: Bool) async throws
    func renameItem(from sourcePath: String, to destinationPath: String) async throws
    func checkFreeSpace(at path: String) async throws -> (free: UInt64, total: UInt64)
}
