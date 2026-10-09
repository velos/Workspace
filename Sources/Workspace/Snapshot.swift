import Foundation

/// The private materialized tree used by revisions, transactions, and archives.
///
/// A snapshot captures the file contents, symbolic links, directory structure, and
/// POSIX permissions of an entire tree at a single point in time. It is `Codable`
/// so it can be persisted, transmitted, or compared to other snapshots.
///
struct Snapshot: Sendable, Codable, Equatable {
    /// A node within a snapshot tree.
    indirect enum Entry: Sendable, Codable, Equatable {
        /// A path that did not exist when the snapshot was captured.
        case missing(Missing)
        /// A regular file with captured contents and permissions.
        case file(File)
        /// A directory with captured permissions and recursively captured children.
        case directory(Directory)
        /// A symbolic link pointing at `target`.
        case symlink(Symlink)

        /// The workspace path of the entry.
        var path: WorkspacePath {
            switch self {
            case let .missing(entry): entry.path
            case let .file(entry): entry.path
            case let .directory(entry): entry.path
            case let .symlink(entry): entry.path
            }
        }
    }

    /// A snapshot entry representing a path that does not exist.
    struct Missing: Sendable, Codable, Equatable {
        /// The captured path.
        var path: WorkspacePath

        /// Creates a missing entry.
        init(path: WorkspacePath) {
            self.path = path
        }
    }

    /// A snapshot entry representing a regular file.
    struct File: Sendable, Codable, Equatable {
        /// The captured path.
        var path: WorkspacePath
        /// The file's contents at the time of capture.
        var data: Data
        /// The file's POSIX permissions at the time of capture.
        var permissions: POSIXPermissions

        /// Creates a file entry.
        init(path: WorkspacePath, data: Data, permissions: POSIXPermissions) {
            self.path = path
            self.data = data
            self.permissions = permissions
        }
    }

    /// A snapshot entry representing a directory.
    struct Directory: Sendable, Codable, Equatable {
        /// The captured path.
        var path: WorkspacePath
        /// The directory's POSIX permissions at the time of capture.
        var permissions: POSIXPermissions
        /// The directory's children, sorted by name.
        var children: [Entry]

        /// Creates a directory entry.
        init(path: WorkspacePath, permissions: POSIXPermissions, children: [Entry]) {
            self.path = path
            self.permissions = permissions
            self.children = children
        }
    }

    /// A snapshot entry representing a symbolic link.
    struct Symlink: Sendable, Codable, Equatable {
        /// The captured path.
        var path: WorkspacePath
        /// The symbolic link's target string.
        var target: String
        /// The symbolic link's POSIX permissions at the time of capture.
        var permissions: POSIXPermissions

        /// Creates a symlink entry.
        init(path: WorkspacePath, target: String, permissions: POSIXPermissions) {
            self.path = path
            self.target = target
            self.permissions = permissions
        }
    }

    /// A stable identifier for the snapshot.
    var id: UUID
    /// The path that was used as the snapshot root.
    var rootPath: WorkspacePath
    /// The captured root entry.
    var entry: Entry

    /// Creates a snapshot from a previously captured tree.
    init(id: UUID = UUID(), rootPath: WorkspacePath, entry: Entry) {
        self.id = id
        self.rootPath = rootPath
        self.entry = entry
    }
}

// MARK: - Capture / Restore

extension Snapshot {
    static func capture(
        from target: any FileSystem,
        at path: WorkspacePath = .root,
        snapshotId: UUID = UUID()
    ) async throws -> Snapshot {
        Snapshot(
            id: snapshotId,
            rootPath: path,
            entry: try await captureEntry(from: target, at: path)
        )
    }

    static func restore(_ snapshot: Snapshot, to target: any FileSystem) async throws {
        try await restoreEntry(snapshot.entry, to: target)
    }

    static func infoIfPresent(at path: WorkspacePath, on target: any FileSystem) async throws -> FileInfo? {
        do {
            return try await target.stat(path: path)
        } catch {
            guard isMissingEntry(error) else { throw error }
            return nil
        }
    }

    static func isMissingEntry(_ error: any Error) -> Bool {
        if let posix = error as? POSIXError {
            return posix.code == .ENOENT || posix.code == .ENOTDIR
        }
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain {
            return error.code == POSIXError.Code.ENOENT.rawValue || error.code == POSIXError.Code.ENOTDIR.rawValue
        }
        if error.domain == NSCocoaErrorDomain,
           error.code == CocoaError.fileNoSuchFile.rawValue || error.code == CocoaError.fileReadNoSuchFile.rawValue {
            return true
        }
        // swift-corelibs-foundation stores the underlying error as a Swift `Error`, not an `NSError`.
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error {
            return isMissingEntry(underlying)
        }
        return false
    }

    static func isPermissionDenied(_ error: any Error) -> Bool {
        if let posix = error as? POSIXError, posix.code == .EACCES || posix.code == .EPERM {
            return true
        }
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain,
           error.code == POSIXError.Code.EACCES.rawValue || error.code == POSIXError.Code.EPERM.rawValue {
            return true
        }
        if error.domain == NSCocoaErrorDomain,
           error.code == CocoaError.fileReadNoPermission.rawValue || error.code == CocoaError.fileWriteNoPermission.rawValue {
            return true
        }
        // corelibs Foundation may store a Swift Error rather than an NSError.
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error {
            return isPermissionDenied(underlying)
        }
        return false
    }

    private static func captureEntry(from target: any FileSystem, at path: WorkspacePath) async throws -> Entry {
        guard let info = try await infoIfPresent(at: path, on: target) else {
            return .missing(.init(path: path))
        }
        switch info.kind {
        case .directory:
            let entries = try await target.listDirectory(path: path)
            let children = try await entries
                .sorted { $0.name < $1.name }
                .snapshotAsyncMap { entry in
                    try await captureEntry(from: target, at: path.appending(entry.name))
                }
            return .directory(.init(path: path, permissions: info.permissions, children: children))
        case .symlink:
            return .symlink(
                .init(
                    path: path,
                    target: try await target.readSymlink(path: path),
                    permissions: info.permissions
                )
            )
        case .file:
            return .file(
                .init(
                    path: path,
                    data: try await target.readFile(path: path),
                    permissions: info.permissions
                )
            )
        }
    }

    private static func restoreEntry(_ entry: Entry, to target: any FileSystem) async throws {
        switch entry {
        case let .missing(missing):
            try await removeEntryIfPresent(at: missing.path, on: target)
        case let .file(file):
            try await ensureParentDirectory(for: file.path, on: target)

            let rewriteRequired: Bool
            if let info = try await infoIfPresent(at: file.path, on: target) {
                if info.kind == .file {
                    rewriteRequired = try await target.readFile(path: file.path) != file.data
                } else {
                    try await removeRecursively(at: file.path, on: target)
                    rewriteRequired = true
                }
            } else {
                rewriteRequired = true
            }

            if rewriteRequired {
                try await target.writeFile(path: file.path, data: file.data, append: false)
            }
            try await setPermissionsIfNeeded(file.permissions, at: file.path, on: target)
        case let .symlink(symlink):
            try await ensureParentDirectory(for: symlink.path, on: target)

            var rewriteRequired = true
            if let info = try await infoIfPresent(at: symlink.path, on: target) {
                if info.kind == .symlink, try await target.readSymlink(path: symlink.path) == symlink.target {
                    rewriteRequired = false
                } else {
                    try await removeRecursively(at: symlink.path, on: target)
                }
            }

            if rewriteRequired {
                try await target.createSymlink(path: symlink.path, target: symlink.target)
            }
        case let .directory(directory):
            try await ensureDirectory(at: directory.path, on: target)
            try await syncDirectoryChildren(
                directory.children, under: directory.path, finalPermissions: directory.permissions, on: target
            )
        }
    }

    private static func setPermissionsIfNeeded(
        _ permissions: POSIXPermissions, at path: WorkspacePath, on target: any FileSystem
    ) async throws {
        let info = try await target.stat(path: path)
        if info.kind != .symlink, info.permissions != permissions {
            try await target.setPermissions(path: path, permissions: permissions)
        }
    }

    private static func ensureParentDirectory(for path: WorkspacePath, on target: any FileSystem) async throws {
        let parent = path.dirname
        guard !parent.isRoot else {
            return
        }
        // A scoped restore owns the entry, not its existing parent. In
        // particular, do not replace a symlink used as a parent directory.
        if try await infoIfPresent(at: parent, on: target) == nil {
            try await target.createDirectory(path: parent, recursive: true)
        }
    }

    private static func ensureDirectory(
        at path: WorkspacePath,
        on target: any FileSystem
    ) async throws {
        if let info = try await infoIfPresent(at: path, on: target) {
            if info.kind == .directory {
                return
            }
            try await target.remove(path: path, recursive: true)
        }

        if !path.isRoot {
            try await target.createDirectory(path: path, recursive: true)
        }
    }

    /// Most backends need no mode adjustment. Retry only a real permission denial,
    /// and preserve the original mode on failure after granting temporary access.
    private static func syncDirectoryChildren(
        _ children: [Entry],
        under path: WorkspacePath,
        finalPermissions: POSIXPermissions? = nil,
        on target: any FileSystem
    ) async throws {
        do {
            try await syncChildren(children, under: path, on: target)
        } catch let deniedError {
            guard isPermissionDenied(deniedError) else { throw deniedError }
            let original = try await target.stat(path: path).permissions
            let working = POSIXPermissions(rawValue: original.rawValue | 0o700)
            guard working != original else { throw deniedError }
            do {
                try await target.setPermissions(path: path, permissions: working)
            } catch {
                // The original denial explains the failure better than a refused grant.
                throw deniedError
            }
            do {
                // Synchronization is idempotent even if the first attempt made progress.
                try await syncChildren(children, under: path, on: target)
                try await setPermissionsIfNeeded(finalPermissions ?? original, at: path, on: target)
            } catch {
                do {
                    try await setPermissionsIfNeeded(original, at: path, on: target)
                } catch let cleanupError {
                    throw WorkspaceRollbackError(originalError: error, rollbackError: cleanupError)
                }
                throw error
            }
            return
        }
        if let finalPermissions {
            try await setPermissionsIfNeeded(finalPermissions, at: path, on: target)
        }
    }

    private static func syncChildren(
        _ expectedChildren: [Entry],
        under parentPath: WorkspacePath,
        on target: any FileSystem
    ) async throws {
        let expectedNames = Set(expectedChildren.map { $0.path.basename })
        let existingEntries = try await target.listDirectory(path: parentPath)

        for entry in existingEntries where !expectedNames.contains(entry.name) {
            try await removeRecursively(at: parentPath.appending(entry.name), on: target)
        }

        for child in expectedChildren.sorted(by: { $0.path < $1.path }) {
            try await restoreEntry(child, to: target)
        }
    }

    private static func removeRecursively(at path: WorkspacePath, on target: any FileSystem) async throws {
        do {
            try await target.remove(path: path, recursive: true)
        } catch {
            guard isPermissionDenied(error) else { throw error }
            // The failure may come from a restrictive descendant, rather than
            // this directory. Each directory grants access only after its own
            // child synchronization fails, and restores its mode before removal.
            try await removeEntryIfPresent(at: path, on: target)
        }
    }

    private static func removeEntryIfPresent(at path: WorkspacePath, on target: any FileSystem) async throws {
        guard let info = try await infoIfPresent(at: path, on: target) else { return }
        if info.kind == .directory {
            try await syncDirectoryChildren([], under: path, on: target)
        }
        if !path.isRoot {
            try await target.remove(path: path, recursive: true)
        }
    }
}

private extension Array {
    func snapshotAsyncMap<T: Sendable>(
        _ transform: @escaping @Sendable (Element) async throws -> T
    ) async throws -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self {
            values.append(try await transform(element))
        }
        return values
    }
}

// A journal holds disjoint subtrees, preserving the state before the first edit
// affecting each path. Expanding a root folds previously captured children back
// into the newly captured ancestor, rather than recording intermediate edits.
struct SnapshotJournal {
    private(set) var snapshots: [Snapshot] = []

    mutating func capture(_ paths: [WorkspacePath], from filesystem: any FileSystem) async throws {
        for path in paths.sorted() {
            if snapshots.contains(where: { Snapshot.contains($0.rootPath, path) }) { continue }
            var snapshot = try await Snapshot.capture(from: filesystem, at: path)
            for old in snapshots where Snapshot.contains(path, old.rootPath) {
                snapshot.entry = Snapshot.replacing(snapshot.entry, with: old.entry)
            }
            snapshots.removeAll { Snapshot.contains(path, $0.rootPath) }
            snapshots.append(snapshot)
        }
    }

    func captureAfter(from filesystem: any FileSystem) async throws -> [Snapshot] {
        var result: [Snapshot] = []
        for snapshot in snapshots {
            result.append(try await Snapshot.capture(from: filesystem, at: snapshot.rootPath))
        }
        return result
    }
}

extension Snapshot {
    static func contains(_ root: WorkspacePath, _ path: WorkspacePath) -> Bool {
        root.isRoot || root == path || path.string.hasPrefix(root.string + "/")
    }

    static func replacing(_ tree: Entry, with replacement: Entry) -> Entry {
        if tree.path == replacement.path { return replacement }
        guard case var .directory(directory) = tree, contains(tree.path, replacement.path) else { return tree }
        if let index = directory.children.firstIndex(where: { contains($0.path, replacement.path) }) {
            directory.children[index] = replacing(directory.children[index], with: replacement)
        } else if replacement.path.dirname == tree.path {
            directory.children.append(replacement)
        }
        if case .missing = replacement {
            directory.children.removeAll { $0.path == replacement.path }
        }
        directory.children.sort { $0.path < $1.path }
        return .directory(directory)
    }
}
