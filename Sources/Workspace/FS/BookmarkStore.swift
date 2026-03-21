import Foundation

/// Persists security-scoped bookmark data outside the filesystem implementation.
public protocol BookmarkStore: Sendable {
    /// Saves bookmark data for a logical identifier.
    func saveBookmark(_ data: Data, for id: String) async throws
    /// Loads bookmark data for a logical identifier.
    func loadBookmark(for id: String) async throws -> Data?
    /// Deletes any bookmark associated with a logical identifier.
    func deleteBookmark(for id: String) async throws
}
