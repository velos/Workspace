import Foundation

/// A disk-backed filesystem rooted at a security-scoped URL.
///
/// This adapter is intended for iOS and macOS workflows where filesystem access must be granted through
/// a bookmark or document picker URL.
public final class SecurityScopedFilesystem: WorkspaceFilesystem, @unchecked Sendable {
    /// The permitted mutability for the scoped filesystem.
    public enum AccessMode: Sendable {
        /// Only read operations are allowed.
        case readOnly
        /// Read and write operations are allowed.
        case readWrite
    }

    private let mode: AccessMode
    private let backing: ReadWriteFilesystem

    private var scopedURL: URL
    private var cachedBookmarkData: Data?
    private var didStartSecurityScope = false

    /// Creates a filesystem rooted at a security-scoped URL.
    public init(url: URL, mode: AccessMode = .readWrite, fileManager: FileManager = .default) throws {
        self.mode = mode
        backing = ReadWriteFilesystem(fileManager: fileManager)
        scopedURL = url.standardizedFileURL
        cachedBookmarkData = nil
        try configureBackingForCurrentURL()
    }

    /// Creates a filesystem from previously saved bookmark data.
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

    /// Produces bookmark data for the currently scoped URL.
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

    /// Saves bookmark data for later reuse.
    public func saveBookmark(id: String, store: any BookmarkStore) async throws {
        let data = try makeBookmarkData()
        try await store.saveBookmark(data, for: id)
    }

    /// Loads bookmark data from `store` and creates a security-scoped filesystem from it.
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

    /// See ``WorkspaceFilesystem/configure(rootDirectory:)``.
    public func configure(rootDirectory: URL) throws {
        stopAccessingSecurityScopeIfNeeded()
        scopedURL = rootDirectory.standardizedFileURL
        cachedBookmarkData = nil
        try configureBackingForCurrentURL()
    }

    /// See ``WorkspaceFilesystem/stat(path:)``.
    public func stat(path: WorkspacePath) async throws -> FileInfo {
        try await backing.stat(path: path)
    }

    /// See ``WorkspaceFilesystem/listDirectory(path:)``.
    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await backing.listDirectory(path: path)
    }

    /// See ``WorkspaceFilesystem/readFile(path:)``.
    public func readFile(path: WorkspacePath) async throws -> Data {
        try await backing.readFile(path: path)
    }

    /// See ``WorkspaceFilesystem/writeFile(path:data:append:)``.
    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        try ensureWritable()
        try await backing.writeFile(path: path, data: data, append: append)
    }

    /// See ``WorkspaceFilesystem/createDirectory(path:recursive:)``.
    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        try ensureWritable()
        try await backing.createDirectory(path: path, recursive: recursive)
    }

    /// See ``WorkspaceFilesystem/remove(path:recursive:)``.
    public func remove(path: WorkspacePath, recursive: Bool) async throws {
        try ensureWritable()
        try await backing.remove(path: path, recursive: recursive)
    }

    /// See ``WorkspaceFilesystem/move(from:to:)``.
    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        try ensureWritable()
        try await backing.move(from: sourcePath, to: destinationPath)
    }

    /// See ``WorkspaceFilesystem/copy(from:to:recursive:)``.
    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool)
        async throws
    {
        try ensureWritable()
        try await backing.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }

    /// See ``WorkspaceFilesystem/createSymlink(path:target:)``.
    public func createSymlink(path: WorkspacePath, target: String) async throws {
        try ensureWritable()
        try await backing.createSymlink(path: path, target: target)
    }

    /// See ``WorkspaceFilesystem/createHardLink(path:target:)``.
    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        try ensureWritable()
        try await backing.createHardLink(path: path, target: target)
    }

    /// See ``WorkspaceFilesystem/readSymlink(path:)``.
    public func readSymlink(path: WorkspacePath) async throws -> String {
        try await backing.readSymlink(path: path)
    }

    /// See ``WorkspaceFilesystem/setPermissions(path:permissions:)``.
    public func setPermissions(path: WorkspacePath, permissions: Int) async throws {
        try ensureWritable()
        try await backing.setPermissions(path: path, permissions: permissions)
    }

    /// See ``WorkspaceFilesystem/resolveRealPath(path:)``.
    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        try await backing.resolveRealPath(path: path)
    }

    /// See ``WorkspaceFilesystem/exists(path:)``.
    public func exists(path: WorkspacePath) async -> Bool {
        await backing.exists(path: path)
    }

    /// See ``WorkspaceFilesystem/glob(pattern:currentDirectory:)``.
    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
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
