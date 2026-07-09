#if canImport(Darwin)
import Foundation

/// A disk-backed filesystem rooted at a security-scoped URL.
///
/// This adapter is intended for iOS and macOS workflows where filesystem access must be granted through
/// a bookmark or document picker URL.
public final class SecurityScopedFilesystem: FileSystem, @unchecked Sendable {
    /// The permitted mutability for the scoped filesystem.
    public enum AccessMode: Sendable {
        /// Only read operations are allowed.
        case readOnly
        /// Read and write operations are allowed.
        case readWrite
    }

    private let mode: AccessMode
    private let backing: ReadWriteFilesystem
    private let stateLock = NSLock()

    private var scopedURL: URL
    private var cachedBookmarkData: Data?
    private var didStartSecurityScope = false

    private func withLock<R>(_ body: () throws -> R) rethrows -> R {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

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
        throw WorkspaceError.unsupported("security-scoped URLs not supported on this platform")
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
        stateLock.lock()
        defer { stateLock.unlock() }
        if didStartSecurityScope {
            scopedURL.stopAccessingSecurityScopedResource()
        }
        #endif
    }

    /// Produces bookmark data for the currently scoped URL.
    public func makeBookmarkData() throws -> Data {
        #if os(tvOS) || os(watchOS)
        throw WorkspaceError.unsupported("security-scoped URLs not supported on this platform")
        #else
        try withLock {
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
        }
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
            throw WorkspaceError.unsupported("bookmark not found: \(id)")
        }
        return try SecurityScopedFilesystem(bookmarkData: data, mode: mode, fileManager: fileManager)
    }

    /// See ``FileSystem/configure(rootDirectory:)``.
    public func configure(rootDirectory: URL) async throws {
        try withLock {
            stopAccessingSecurityScopeIfNeeded()
            scopedURL = rootDirectory.standardizedFileURL
            cachedBookmarkData = nil
            try configureBackingForCurrentURL()
        }
    }

    /// See ``FileSystem/stat(path:)``.
    public func stat(path: WorkspacePath) async throws -> FileInfo {
        try await backing.stat(path: path)
    }

    /// See ``FileSystem/listDirectory(path:)``.
    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await backing.listDirectory(path: path)
    }

    /// See ``FileSystem/readFile(path:)``.
    public func readFile(path: WorkspacePath) async throws -> Data {
        try await backing.readFile(path: path)
    }

    /// See ``FileSystem/writeFile(path:data:append:)``.
    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        try ensureWritable()
        try await backing.writeFile(path: path, data: data, append: append)
    }

    /// See ``FileSystem/createDirectory(path:recursive:)``.
    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        try ensureWritable()
        try await backing.createDirectory(path: path, recursive: recursive)
    }

    /// See ``FileSystem/remove(path:recursive:)``.
    public func remove(path: WorkspacePath, recursive: Bool) async throws {
        try ensureWritable()
        try await backing.remove(path: path, recursive: recursive)
    }

    /// See ``FileSystem/move(from:to:)``.
    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        try ensureWritable()
        try await backing.move(from: sourcePath, to: destinationPath)
    }

    /// See ``FileSystem/copy(from:to:recursive:)``.
    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool)
        async throws
    {
        try ensureWritable()
        try await backing.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }

    /// See ``FileSystem/createSymlink(path:target:)``.
    public func createSymlink(path: WorkspacePath, target: String) async throws {
        try ensureWritable()
        try await backing.createSymlink(path: path, target: target)
    }

    /// See ``FileSystem/createHardLink(path:target:)``.
    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        try ensureWritable()
        try await backing.createHardLink(path: path, target: target)
    }

    /// See ``FileSystem/readSymlink(path:)``.
    public func readSymlink(path: WorkspacePath) async throws -> String {
        try await backing.readSymlink(path: path)
    }

    /// See ``FileSystem/setPermissions(path:permissions:)``.
    public func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        try ensureWritable()
        try await backing.setPermissions(path: path, permissions: permissions)
    }

    /// See ``FileSystem/resolveRealPath(path:)``.
    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        try await backing.resolveRealPath(path: path)
    }

    /// See ``FileSystem/exists(path:)``.
    public func exists(path: WorkspacePath) async -> Bool {
        await backing.exists(path: path)
    }

    /// See ``FileSystem/glob(pattern:currentDirectory:)``.
    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try await backing.glob(pattern: pattern, currentDirectory: currentDirectory)
    }

    private func ensureWritable() throws {
        guard mode == .readWrite else {
            throw WorkspaceError.readOnly
        }
    }

    private func configureBackingForCurrentURL() throws {
        try beginAccessingSecurityScopeIfNeeded()
        try backing.applyConfiguration(rootDirectory: scopedURL)
    }

    private func beginAccessingSecurityScopeIfNeeded() throws {
        #if os(tvOS) || os(watchOS)
        throw WorkspaceError.unsupported("security-scoped URLs not supported on this platform")
        #elseif os(iOS)
        if !didStartSecurityScope {
            guard scopedURL.startAccessingSecurityScopedResource() else {
                throw WorkspaceError.unsupported("could not start security-scoped access")
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
#endif
