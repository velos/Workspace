import Foundation

public enum WorkspacePermissionOperation: String, Sendable, Hashable {
    case stat
    case listDirectory
    case readFile
    case writeFile
    case createDirectory
    case remove
    case move
    case copy
    case createSymlink
    case createHardLink
    case readSymlink
    case setPermissions
    case resolveRealPath
    case exists
    case glob
}

public struct WorkspacePermissionRequest: Sendable, Hashable {
    public var operation: WorkspacePermissionOperation
    public var path: String?
    public var sourcePath: String?
    public var destinationPath: String?
    public var append: Bool
    public var recursive: Bool

    public init(
        operation: WorkspacePermissionOperation,
        path: String? = nil,
        sourcePath: String? = nil,
        destinationPath: String? = nil,
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

public enum WorkspacePermissionDecision: Sendable {
    case allow
    case allowForSession
    case deny(message: String?)
}

public protocol WorkspacePermissionAuthorizing: Sendable {
    func authorize(_ request: WorkspacePermissionRequest) async -> WorkspacePermissionDecision
}

public actor WorkspacePermissionAuthorizer: WorkspacePermissionAuthorizing {
    public typealias Handler = @Sendable (WorkspacePermissionRequest) async -> WorkspacePermissionDecision

    private let handler: Handler
    private var sessionAllows: Set<WorkspacePermissionRequest> = []

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

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

public final class PermissionedWorkspaceFilesystem: SessionConfigurableFilesystem, @unchecked Sendable {
    private let base: any WorkspaceFilesystem
    private let authorizer: any WorkspacePermissionAuthorizing

    public init(
        base: any WorkspaceFilesystem,
        authorizer: any WorkspacePermissionAuthorizing
    ) {
        self.base = base
        self.authorizer = authorizer
    }

    public func configure(rootDirectory: URL) throws {
        try base.configure(rootDirectory: rootDirectory)
    }

    public func configureForSession() throws {
        guard let configurable = base as? any SessionConfigurableFilesystem else {
            throw WorkspaceError.unsupported("filesystem requires rootDirectory initializer")
        }
        try configurable.configureForSession()
    }

    public func stat(path: String) async throws -> FileInfo {
        let normalized = try normalizedPath(path)
        try await authorize(.init(operation: .stat, path: normalized))
        return try await base.stat(path: normalized)
    }

    public func listDirectory(path: String) async throws -> [DirectoryEntry] {
        let normalized = try normalizedPath(path)
        try await authorize(.init(operation: .listDirectory, path: normalized))
        return try await base.listDirectory(path: normalized)
    }

    public func readFile(path: String) async throws -> Data {
        let normalized = try normalizedPath(path)
        try await authorize(.init(operation: .readFile, path: normalized))
        return try await base.readFile(path: normalized)
    }

    public func writeFile(path: String, data: Data, append: Bool) async throws {
        let normalized = try normalizedPath(path)
        try await authorize(.init(operation: .writeFile, path: normalized, append: append))
        try await base.writeFile(path: normalized, data: data, append: append)
    }

    public func createDirectory(path: String, recursive: Bool) async throws {
        let normalized = try normalizedPath(path)
        try await authorize(.init(operation: .createDirectory, path: normalized, recursive: recursive))
        try await base.createDirectory(path: normalized, recursive: recursive)
    }

    public func remove(path: String, recursive: Bool) async throws {
        let normalized = try normalizedPath(path)
        try await authorize(.init(operation: .remove, path: normalized, recursive: recursive))
        try await base.remove(path: normalized, recursive: recursive)
    }

    public func move(from sourcePath: String, to destinationPath: String) async throws {
        let source = try normalizedPath(sourcePath)
        let destination = try normalizedPath(destinationPath)
        try await authorize(.init(operation: .move, sourcePath: source, destinationPath: destination))
        try await base.move(from: source, to: destination)
    }

    public func copy(from sourcePath: String, to destinationPath: String, recursive: Bool) async throws {
        let source = try normalizedPath(sourcePath)
        let destination = try normalizedPath(destinationPath)
        try await authorize(
            .init(operation: .copy, sourcePath: source, destinationPath: destination, recursive: recursive)
        )
        try await base.copy(from: source, to: destination, recursive: recursive)
    }

    public func createSymlink(path: String, target: String) async throws {
        let normalized = try normalizedPath(path)
        try WorkspacePath.validate(target)
        let normalizedTarget = WorkspacePath.normalize(
            path: target,
            currentDirectory: WorkspacePath.dirname(normalized)
        )
        try await authorize(.init(operation: .createSymlink, path: normalized, destinationPath: normalizedTarget))
        try await base.createSymlink(path: normalized, target: target)
    }

    public func createHardLink(path: String, target: String) async throws {
        let normalized = try normalizedPath(path)
        let normalizedTarget = try normalizedPath(target)
        try await authorize(.init(operation: .createHardLink, path: normalized, destinationPath: normalizedTarget))
        try await base.createHardLink(path: normalized, target: normalizedTarget)
    }

    public func readSymlink(path: String) async throws -> String {
        let normalized = try normalizedPath(path)
        try await authorize(.init(operation: .readSymlink, path: normalized))
        return try await base.readSymlink(path: normalized)
    }

    public func setPermissions(path: String, permissions: Int) async throws {
        let normalized = try normalizedPath(path)
        try await authorize(.init(operation: .setPermissions, path: normalized))
        try await base.setPermissions(path: normalized, permissions: permissions)
    }

    public func resolveRealPath(path: String) async throws -> String {
        let normalized = try normalizedPath(path)
        try await authorize(.init(operation: .resolveRealPath, path: normalized))
        return try await base.resolveRealPath(path: normalized)
    }

    public func exists(path: String) async -> Bool {
        do {
            let normalized = try normalizedPath(path)
            try await authorize(.init(operation: .exists, path: normalized))
            return await base.exists(path: normalized)
        } catch {
            return false
        }
    }

    public func glob(pattern: String, currentDirectory: String) async throws -> [String] {
        try WorkspacePath.validate(pattern)
        let normalizedCurrentDirectory = try normalizedPath(currentDirectory)
        let normalizedPattern = WorkspacePath.normalize(
            path: pattern,
            currentDirectory: normalizedCurrentDirectory
        )
        try await authorize(
            .init(operation: .glob, path: normalizedPattern, destinationPath: normalizedCurrentDirectory)
        )
        return try await base.glob(pattern: normalizedPattern, currentDirectory: normalizedCurrentDirectory)
    }

    private func normalizedPath(_ path: String) throws -> String {
        try WorkspacePath.validate(path)
        return WorkspacePath.normalize(path: path, currentDirectory: "/")
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
