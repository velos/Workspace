import Foundation

public protocol BookmarkStore: Sendable {
    func saveBookmark(_ data: Data, for id: String) async throws
    func loadBookmark(for id: String) async throws -> Data?
    func deleteBookmark(for id: String) async throws
}
