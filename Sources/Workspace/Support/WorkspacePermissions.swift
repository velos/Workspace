import Foundation

/// A filesystem operation that may require authorization.
public enum WorkspacePermissionOperation: String, Sendable, Hashable {
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
public struct WorkspacePermissionRequest: Sendable, Hashable {
    /// The operation being requested.
    public var operation: WorkspacePermissionOperation
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
        operation: WorkspacePermissionOperation,
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
public enum WorkspacePermissionDecision: Sendable {
    /// Allows the operation once.
    case allow
    /// Allows the operation and caches the decision for equivalent future requests in the session.
    case allowForSession
    /// Denies the operation, optionally providing a user-facing message.
    case deny(message: String?)
}

/// An authorization policy for workspace filesystem operations.
public protocol WorkspacePermissionAuthorizing: Sendable {
    /// Returns the authorization decision for `request`.
    func authorize(_ request: WorkspacePermissionRequest) async -> WorkspacePermissionDecision
}

/// An actor-backed authorization policy with built-in support for session-scoped approvals.
public actor WorkspacePermissionAuthorizer: WorkspacePermissionAuthorizing {
    /// The asynchronous callback used to evaluate requests.
    public typealias Handler = @Sendable (WorkspacePermissionRequest) async -> WorkspacePermissionDecision

    private let handler: Handler
    private var sessionAllows: Set<WorkspacePermissionRequest> = []

    /// Creates an authorizer from an asynchronous decision handler.
    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Returns the authorization decision for `request`, reusing session approvals when available.
    public func authorize(_ request: WorkspacePermissionRequest) async -> WorkspacePermissionDecision {
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
public final class PermissionedWorkspaceFilesystem: WorkspaceFilesystem, @unchecked Sendable {
    private let base: any WorkspaceFilesystem
    private let authorizer: any WorkspacePermissionAuthorizing

    /// Creates a permission-enforcing wrapper around `base`.
    public init(
        base: any WorkspaceFilesystem,
        authorizer: any WorkspacePermissionAuthorizing
    ) {
        self.base = base
        self.authorizer = authorizer
    }

    /// See ``WorkspaceFilesystem/configure(rootDirectory:)``.
    public func configure(rootDirectory: URL) throws {
        try base.configure(rootDirectory: rootDirectory)
    }

    /// See ``WorkspaceFilesystem/stat(path:)``.
    public func stat(path: WorkspacePath) async throws -> FileInfo {
        let normalized = normalizedPath(path)
        try await authorize(.init(operation: .stat, path: normalized))
        return try await base.stat(path: normalized)
    }

    /// See ``WorkspaceFilesystem/listDirectory(path:)``.
    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        let normalized = normalizedPath(path)
        try await authorize(.init(operation: .listDirectory, path: normalized))
        return try await base.listDirectory(path: normalized)
    }

    /// See ``WorkspaceFilesystem/readFile(path:)``.
    public func readFile(path: WorkspacePath) async throws -> Data {
        let normalized = normalizedPath(path)
        try await authorize(.init(operation: .readFile, path: normalized))
        return try await base.readFile(path: normalized)
    }

    /// See ``WorkspaceFilesystem/writeFile(path:data:append:)``.
    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        let normalized = normalizedPath(path)
        try await authorize(.init(operation: .writeFile, path: normalized, append: append))
        try await base.writeFile(path: normalized, data: data, append: append)
    }

    /// See ``WorkspaceFilesystem/createDirectory(path:recursive:)``.
    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        let normalized = normalizedPath(path)
        try await authorize(.init(operation: .createDirectory, path: normalized, recursive: recursive))
        try await base.createDirectory(path: normalized, recursive: recursive)
    }

    /// See ``WorkspaceFilesystem/remove(path:recursive:)``.
    public func remove(path: WorkspacePath, recursive: Bool) async throws {
        let normalized = normalizedPath(path)
        try await authorize(.init(operation: .remove, path: normalized, recursive: recursive))
        try await base.remove(path: normalized, recursive: recursive)
    }

    /// See ``WorkspaceFilesystem/move(from:to:)``.
    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        let source = normalizedPath(sourcePath)
        let destination = normalizedPath(destinationPath)
        try await authorize(.init(operation: .move, sourcePath: source, destinationPath: destination))
        try await base.move(from: source, to: destination)
    }

    /// See ``WorkspaceFilesystem/copy(from:to:recursive:)``.
    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool)
        async throws
    {
        let source = normalizedPath(sourcePath)
        let destination = normalizedPath(destinationPath)
        try await authorize(
            .init(operation: .copy, sourcePath: source, destinationPath: destination, recursive: recursive)
        )
        try await base.copy(from: source, to: destination, recursive: recursive)
    }

    /// See ``WorkspaceFilesystem/createSymlink(path:target:)``.
    public func createSymlink(path: WorkspacePath, target: String) async throws {
        let normalized = normalizedPath(path)
        try WorkspacePath.validate(target)
        let normalizedTarget = WorkspacePath.normalized(
            target,
            relativeTo: normalized.dirname
        )
        try await authorize(.init(operation: .createSymlink, path: normalized, destinationPath: normalizedTarget))
        try await base.createSymlink(path: normalized, target: target)
    }

    /// See ``WorkspaceFilesystem/createHardLink(path:target:)``.
    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        let normalized = normalizedPath(path)
        let normalizedTarget = normalizedPath(target)
        try await authorize(.init(operation: .createHardLink, path: normalized, destinationPath: normalizedTarget))
        try await base.createHardLink(path: normalized, target: normalizedTarget)
    }

    /// See ``WorkspaceFilesystem/readSymlink(path:)``.
    public func readSymlink(path: WorkspacePath) async throws -> String {
        let normalized = normalizedPath(path)
        try await authorize(.init(operation: .readSymlink, path: normalized))
        return try await base.readSymlink(path: normalized)
    }

    /// See ``WorkspaceFilesystem/setPermissions(path:permissions:)``.
    public func setPermissions(path: WorkspacePath, permissions: Int) async throws {
        let normalized = normalizedPath(path)
        try await authorize(.init(operation: .setPermissions, path: normalized))
        try await base.setPermissions(path: normalized, permissions: permissions)
    }

    /// See ``WorkspaceFilesystem/resolveRealPath(path:)``.
    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        let normalized = normalizedPath(path)
        try await authorize(.init(operation: .resolveRealPath, path: normalized))
        return try await base.resolveRealPath(path: normalized)
    }

    /// See ``WorkspaceFilesystem/exists(path:)``.
    public func exists(path: WorkspacePath) async -> Bool {
        do {
            let normalized = normalizedPath(path)
            try await authorize(.init(operation: .exists, path: normalized))
            return await base.exists(path: normalized)
        } catch {
            return false
        }
    }

    /// See ``WorkspaceFilesystem/glob(pattern:currentDirectory:)``.
    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try WorkspacePath.validate(pattern)
        let normalizedCurrentDirectory = normalizedPath(currentDirectory)
        let normalizedPattern = WorkspacePath.normalized(
            pattern,
            relativeTo: normalizedCurrentDirectory
        )
        try await authorize(
            .init(operation: .glob, path: normalizedPattern, destinationPath: normalizedCurrentDirectory)
        )
        return try await base.glob(pattern: normalizedPattern.description, currentDirectory: normalizedCurrentDirectory)
    }

    private func normalizedPath(_ path: WorkspacePath) -> WorkspacePath {
        WorkspacePath(normalizing: path.string)
    }

    private func authorize(_ request: WorkspacePermissionRequest) async throws {
        let decision = await authorizer.authorize(request)
        if case let .deny(message) = decision {
            throw WorkspaceError.unsupported(
                message ?? "workspace access denied: \(request.operation.rawValue)"
            )
        }
    }
}
