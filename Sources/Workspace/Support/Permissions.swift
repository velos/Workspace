import Foundation

/// A filesystem operation that may require authorization.
public enum PermissionOperation: String, Sendable, Hashable, Codable {
    /// Metadata lookup for a single path.
    case stat
    /// Directory listing for a single path.
    case listDirectory
    /// File read access.
    case readFile
    /// File write access.
    case writeFile
    /// Directory creation.
    case createDirectory
    /// Entry removal.
    case remove
    /// Entry move or rename.
    case move
    /// Entry copy.
    case copy
    /// Symbolic link creation.
    case createSymlink
    /// Hard link creation.
    case createHardLink
    /// Symbolic link target lookup.
    case readSymlink
    /// Permission mutation.
    case setPermissions
    /// Real path resolution.
    case resolveRealPath
    /// Existence lookup.
    case exists
    /// Glob expansion.
    case glob
}

/// A permission request describing the operation and paths involved.
public struct PermissionRequest: Sendable, Hashable {
    /// The operation being requested.
    public var operation: PermissionOperation
    /// The primary path associated with the request when applicable.
    public var path: WorkspacePath?
    /// The source path for operations that move or copy from another entry.
    public var sourcePath: WorkspacePath?
    /// The destination path for operations that create, move, or copy entries.
    public var destinationPath: WorkspacePath?
    /// Whether a write operation appends to an existing file.
    public var append: Bool
    /// Whether an operation may recurse into directories.
    public var recursive: Bool

    /// Creates a permission request.
    public init(
        operation: PermissionOperation,
        path: WorkspacePath? = nil,
        sourcePath: WorkspacePath? = nil,
        destinationPath: WorkspacePath? = nil,
        append: Bool = false,
        recursive: Bool = false
    ) {
        self.operation = operation
        self.path = path
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.append = append
        self.recursive = recursive
    }
}

/// The outcome of an authorization request.
public enum PermissionDecision: Sendable {
    /// Allows the operation once.
    case allow
    /// Allows the operation and caches the decision for equivalent future requests in the session.
    case allowForSession
    /// Denies the operation, optionally providing a user-facing message.
    case deny(message: String?)
}

/// An authorization policy for workspace filesystem operations.
public protocol PermissionAuthorizing: Sendable {
    /// Returns the authorization decision for `request`.
    func authorize(_ request: PermissionRequest) async -> PermissionDecision
}

/// An actor-backed authorization policy with built-in support for session-scoped approvals.
public actor PermissionAuthorizer: PermissionAuthorizing {
    /// The asynchronous callback used to evaluate requests.
    public typealias Handler = @Sendable (PermissionRequest) async -> PermissionDecision

    private let handler: Handler
    private var sessionAllows: Set<PermissionRequest> = []

    /// Creates an authorizer from an asynchronous decision handler.
    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Returns the authorization decision for `request`, reusing session approvals when available.
    public func authorize(_ request: PermissionRequest) async -> PermissionDecision {
        if sessionAllows.contains(request) {
            return .allow
        }

        let decision = await handler(request)
        if case .allowForSession = decision {
            sessionAllows.insert(request)
            return .allow
        }

        return decision
    }
}

/// A filesystem wrapper that authorizes each operation before forwarding it to another filesystem.
public final class PermissionedFileSystem: FileSystem, Sendable {
    private let base: any FileSystem
    private let authorizer: any PermissionAuthorizing

    /// Creates a permission-enforcing wrapper around `base`.
    public init(
        base: any FileSystem,
        authorizer: any PermissionAuthorizing
    ) {
        self.base = base
        self.authorizer = authorizer
    }

    /// See ``FileSystem/configure(rootDirectory:)``.
    public func configure(rootDirectory: URL) async throws {
        try await base.configure(rootDirectory: rootDirectory)
    }

    /// See ``FileSystem/stat(path:)``.
    public func stat(path: WorkspacePath) async throws -> FileInfo {
        try await authorize(.init(operation: .stat, path: path))
        return try await base.stat(path: path)
    }

    /// See ``FileSystem/listDirectory(path:)``.
    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await authorize(.init(operation: .listDirectory, path: path))
        return try await base.listDirectory(path: path)
    }

    /// See ``FileSystem/readFile(path:)``.
    public func readFile(path: WorkspacePath) async throws -> Data {
        try await authorize(.init(operation: .readFile, path: path))
        return try await base.readFile(path: path)
    }

    /// See ``FileSystem/writeFile(path:data:append:)``.
    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        try await authorize(.init(operation: .writeFile, path: path, append: append))
        try await base.writeFile(path: path, data: data, append: append)
    }

    /// See ``FileSystem/createDirectory(path:recursive:)``.
    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        try await authorize(.init(operation: .createDirectory, path: path, recursive: recursive))
        try await base.createDirectory(path: path, recursive: recursive)
    }

    /// See ``FileSystem/remove(path:recursive:)``.
    public func remove(path: WorkspacePath, recursive: Bool) async throws {
        try await authorize(.init(operation: .remove, path: path, recursive: recursive))
        try await base.remove(path: path, recursive: recursive)
    }

    /// See ``FileSystem/move(from:to:)``.
    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        try await authorize(.init(operation: .move, sourcePath: sourcePath, destinationPath: destinationPath))
        try await base.move(from: sourcePath, to: destinationPath)
    }

    /// See ``FileSystem/copy(from:to:recursive:)``.
    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool)
        async throws
    {
        try await authorize(
            .init(operation: .copy, sourcePath: sourcePath, destinationPath: destinationPath, recursive: recursive)
        )
        try await base.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }

    /// See ``FileSystem/createSymlink(path:target:)``.
    public func createSymlink(path: WorkspacePath, target: String) async throws {
        let normalizedTarget = try WorkspacePath(
            validating: target,
            relativeTo: path.dirname
        )
        try await authorize(.init(operation: .createSymlink, path: path, destinationPath: normalizedTarget))
        try await base.createSymlink(path: path, target: target)
    }

    /// See ``FileSystem/createHardLink(path:target:)``.
    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        try await authorize(.init(operation: .createHardLink, path: path, destinationPath: target))
        try await base.createHardLink(path: path, target: target)
    }

    /// See ``FileSystem/readSymlink(path:)``.
    public func readSymlink(path: WorkspacePath) async throws -> String {
        try await authorize(.init(operation: .readSymlink, path: path))
        return try await base.readSymlink(path: path)
    }

    /// See ``FileSystem/setPermissions(path:permissions:)``.
    public func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        try await authorize(.init(operation: .setPermissions, path: path))
        try await base.setPermissions(path: path, permissions: permissions)
    }

    /// See ``FileSystem/resolveRealPath(path:)``.
    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        try await authorize(.init(operation: .resolveRealPath, path: path))
        return try await base.resolveRealPath(path: path)
    }

    /// See ``FileSystem/exists(path:)``.
    public func exists(path: WorkspacePath) async -> Bool {
        do {
            try await authorize(.init(operation: .exists, path: path))
            return await base.exists(path: path)
        } catch {
            return false
        }
    }

    /// See ``FileSystem/glob(pattern:currentDirectory:)``.
    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        let normalizedPattern = try WorkspacePath(
            validating: pattern,
            relativeTo: currentDirectory
        )
        try await authorize(
            .init(operation: .glob, path: normalizedPattern, destinationPath: currentDirectory)
        )
        return try await base.glob(pattern: normalizedPattern.description, currentDirectory: currentDirectory)
    }

    private func authorize(_ request: PermissionRequest) async throws {
        let decision = await authorizer.authorize(request)
        if case let .deny(message) = decision {
            throw WorkspaceError.accessDenied(operation: request.operation.rawValue, message: message)
        }
    }
}
