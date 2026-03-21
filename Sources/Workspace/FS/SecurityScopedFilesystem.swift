import Foundation

public final class SecurityScopedFilesystem: WorkspaceFilesystem, @unchecked Sendable {
    public enum AccessMode: Sendable {
        case readOnly
        case readWrite
    }

    private let mode: AccessMode
    private let backing: ReadWriteFilesystem

    private var scopedURL: URL
    private var cachedBookmarkData: Data?
    private var didStartSecurityScope = false

    public init(url: URL, mode: AccessMode = .readWrite, fileManager: FileManager = .default) throws {
        self.mode = mode
        backing = ReadWriteFilesystem(fileManager: fileManager)
        scopedURL = url.standardizedFileURL
        cachedBookmarkData = nil
        try configureBackingForCurrentURL()
    }

    public init(bookmarkData: Data, mode: AccessMode = .readWrite, fileManager: FileManager = .default) throws {
        #if os(tvOS) || os(watchOS)
        throw ShellError.unsupported("security-scoped URLs not supported on this platform")
        #else
        self.mode = mode
        backing = ReadWriteFilesystem(fileManager: fileManager)

        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: bookmarkData,
            options: Self.bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        scopedURL = resolvedURL.standardizedFileURL
        if isStale {
            cachedBookmarkData = try scopedURL.bookmarkData(
                options: Self.bookmarkCreationOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } else {
            cachedBookmarkData = bookmarkData
        }

        try configureBackingForCurrentURL()
        #endif
    }

    deinit {
        #if os(iOS) || os(macOS)
        if didStartSecurityScope {
            scopedURL.stopAccessingSecurityScopedResource()
        }
        #endif
    }

    public func makeBookmarkData() throws -> Data {
        #if os(tvOS) || os(watchOS)
        throw ShellError.unsupported("security-scoped URLs not supported on this platform")
        #else
        if let cachedBookmarkData {
            return cachedBookmarkData
        }

        let bookmarkData = try scopedURL.bookmarkData(
            options: Self.bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        cachedBookmarkData = bookmarkData
        return bookmarkData
        #endif
    }

    public func saveBookmark(id: String, store: any BookmarkStore) async throws {
        let data = try makeBookmarkData()
        try await store.saveBookmark(data, for: id)
    }

    public static func loadBookmark(
        id: String,
        store: any BookmarkStore,
        mode: AccessMode = .readWrite,
        fileManager: FileManager = .default
    ) async throws -> SecurityScopedFilesystem {
        guard let data = try await store.loadBookmark(for: id) else {
            throw ShellError.unsupported("bookmark not found: \(id)")
        }
        return try SecurityScopedFilesystem(bookmarkData: data, mode: mode, fileManager: fileManager)
    }

    public func configure(rootDirectory: URL) throws {
        stopAccessingSecurityScopeIfNeeded()
        scopedURL = rootDirectory.standardizedFileURL
        cachedBookmarkData = nil
        try configureBackingForCurrentURL()
    }

    public func stat(path: String) async throws -> FileInfo {
        try await backing.stat(path: path)
    }

    public func listDirectory(path: String) async throws -> [DirectoryEntry] {
        try await backing.listDirectory(path: path)
    }

    public func readFile(path: String) async throws -> Data {
        try await backing.readFile(path: path)
    }

    public func writeFile(path: String, data: Data, append: Bool) async throws {
        try ensureWritable()
        try await backing.writeFile(path: path, data: data, append: append)
    }

    public func createDirectory(path: String, recursive: Bool) async throws {
        try ensureWritable()
        try await backing.createDirectory(path: path, recursive: recursive)
    }

    public func remove(path: String, recursive: Bool) async throws {
        try ensureWritable()
        try await backing.remove(path: path, recursive: recursive)
    }

    public func move(from sourcePath: String, to destinationPath: String) async throws {
        try ensureWritable()
        try await backing.move(from: sourcePath, to: destinationPath)
    }

    public func copy(from sourcePath: String, to destinationPath: String, recursive: Bool) async throws {
        try ensureWritable()
        try await backing.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }

    public func createSymlink(path: String, target: String) async throws {
        try ensureWritable()
        try await backing.createSymlink(path: path, target: target)
    }

    public func createHardLink(path: String, target: String) async throws {
        try ensureWritable()
        try await backing.createHardLink(path: path, target: target)
    }

    public func readSymlink(path: String) async throws -> String {
        try await backing.readSymlink(path: path)
    }

    public func setPermissions(path: String, permissions: Int) async throws {
        try ensureWritable()
        try await backing.setPermissions(path: path, permissions: permissions)
    }

    public func resolveRealPath(path: String) async throws -> String {
        try await backing.resolveRealPath(path: path)
    }

    public func exists(path: String) async -> Bool {
        await backing.exists(path: path)
    }

    public func glob(pattern: String, currentDirectory: String) async throws -> [String] {
        try await backing.glob(pattern: pattern, currentDirectory: currentDirectory)
    }

    private func ensureWritable() throws {
        guard mode == .readWrite else {
            throw ShellError.unsupported("filesystem is read-only")
        }
    }

    private func configureBackingForCurrentURL() throws {
        try beginAccessingSecurityScopeIfNeeded()
        try backing.configure(rootDirectory: scopedURL)
    }

    private func beginAccessingSecurityScopeIfNeeded() throws {
        #if os(tvOS) || os(watchOS)
        throw ShellError.unsupported("security-scoped URLs not supported on this platform")
        #elseif os(iOS)
        if !didStartSecurityScope {
            guard scopedURL.startAccessingSecurityScopedResource() else {
                throw ShellError.unsupported("could not start security-scoped access")
            }
            didStartSecurityScope = true
        }
        #elseif os(macOS)
        if !didStartSecurityScope {
            didStartSecurityScope = scopedURL.startAccessingSecurityScopedResource()
        }
        #endif
    }

    private func stopAccessingSecurityScopeIfNeeded() {
        #if os(iOS) || os(macOS)
        if didStartSecurityScope {
            scopedURL.stopAccessingSecurityScopedResource()
            didStartSecurityScope = false
        }
        #endif
    }

    #if os(macOS) || targetEnvironment(macCatalyst)
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
    #endif
}
