import Foundation

/// A ``BookmarkStore`` backed by `UserDefaults`.
public actor UserDefaultsBookmarkStore: BookmarkStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    /// Creates a bookmark store backed by a `UserDefaults` suite.
    ///
    /// - Parameters:
    ///   - suiteName: The suite to use. When `nil`, `UserDefaults.standard` is used.
    ///   - keyPrefix: The prefix applied to every stored bookmark key.
    public init(suiteName: String? = nil, keyPrefix: String = "workspace.bookmark.") {
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.keyPrefix = keyPrefix
    }

    /// Stores bookmark data for `id`.
    public func saveBookmark(_ data: Data, for id: String) async throws {
        defaults.set(data, forKey: key(for: id))
    }

    /// Retrieves bookmark data for `id`, or `nil` when no bookmark exists.
    public func loadBookmark(for id: String) async throws -> Data? {
        defaults.data(forKey: key(for: id))
    }

    /// Removes any bookmark stored for `id`.
    public func deleteBookmark(for id: String) async throws {
        defaults.removeObject(forKey: key(for: id))
    }

    private func key(for id: String) -> String {
        keyPrefix + id
    }
}
