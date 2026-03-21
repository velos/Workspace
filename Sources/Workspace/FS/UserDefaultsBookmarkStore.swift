import Foundation

public actor UserDefaultsBookmarkStore: BookmarkStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(suiteName: String? = nil, keyPrefix: String = "bashswift.bookmark.") {
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.keyPrefix = keyPrefix
    }

    public func saveBookmark(_ data: Data, for id: String) async throws {
        defaults.set(data, forKey: key(for: id))
    }

    public func loadBookmark(for id: String) async throws -> Data? {
        defaults.data(forKey: key(for: id))
    }

    public func deleteBookmark(for id: String) async throws {
        defaults.removeObject(forKey: key(for: id))
    }

    private func key(for id: String) -> String {
        keyPrefix + id
    }
}
