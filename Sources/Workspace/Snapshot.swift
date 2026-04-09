import Foundation

/// A durable recursive snapshot of a workspace subtree.
struct Snapshot: Sendable, Codable, Equatable {
    /// A snapshot entry in the captured tree.
    indirect enum Entry: Sendable, Codable, Equatable {
        /// The captured path did not exist.
        case missing(Missing)
        /// A regular file with captured bytes.
        case file(File)
        /// A directory with recursive children.
        case directory(Directory)
        /// A symbolic link and its captured target.
        case symlink(Symlink)
    }

    /// A missing path entry.
    struct Missing: Sendable, Codable, Equatable {
        /// The missing path.
        var path: WorkspacePath

        /// Creates a missing entry.
        init(path: WorkspacePath) {
            self.path = path
        }
    }

    /// A file entry.
    struct File: Sendable, Codable, Equatable {
        /// The file path.
        var path: WorkspacePath
        /// The file contents.
        var data: Data
        /// The file permissions.
        var permissions: POSIXPermissions

        /// Creates a file entry.
        init(path: WorkspacePath, data: Data, permissions: POSIXPermissions) {
            self.path = path
            self.data = data
            self.permissions = permissions
        }
    }

    /// A directory entry.
    struct Directory: Sendable, Codable, Equatable {
        /// The directory path.
        var path: WorkspacePath
        /// The directory permissions.
        var permissions: POSIXPermissions
        /// The captured child entries.
        var children: [Entry]

        /// Creates a directory entry.
        init(path: WorkspacePath, permissions: POSIXPermissions, children: [Entry]) {
            self.path = path
            self.permissions = permissions
            self.children = children
        }
    }

    /// A symbolic link entry.
    struct Symlink: Sendable, Codable, Equatable {
        /// The symlink path.
        var path: WorkspacePath
        /// The symlink target string.
        var target: String
        /// The symlink permissions.
        var permissions: POSIXPermissions

        /// Creates a symlink entry.
        init(path: WorkspacePath, target: String, permissions: POSIXPermissions) {
            self.path = path
            self.target = target
            self.permissions = permissions
        }
    }

    /// The snapshot identifier.
    var id: UUID
    /// The root path represented by the snapshot.
    var rootPath: WorkspacePath
    /// The captured entry tree at `rootPath`.
    var entry: Entry

    /// Creates a workspace snapshot.
    init(id: UUID = UUID(), rootPath: WorkspacePath, entry: Entry) {
        self.id = id
        self.rootPath = rootPath
        self.entry = entry
    }
}

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

    static func path(of entry: Entry) -> WorkspacePath {
        switch entry {
        case let .missing(entry):
            entry.path
        case let .file(entry):
            entry.path
        case let .directory(entry):
            entry.path
        case let .symlink(entry):
            entry.path
        }
    }

    private static func captureEntry(from target: any FileSystem, at path: WorkspacePath) async throws -> Entry {
        guard await target.exists(path: path) else {
            return .missing(.init(path: path))
        }

        let info = try await target.stat(path: path)
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
            if await target.exists(path: file.path) {
                let info = try await target.stat(path: file.path)
                if info.kind == .file {
                    rewriteRequired = try await target.readFile(path: file.path) != file.data
                } else {
                    try await target.remove(path: file.path, recursive: true)
                    rewriteRequired = true
                }
            } else {
                rewriteRequired = true
            }

            if rewriteRequired {
                try await target.writeFile(path: file.path, data: file.data, append: false)
            }
            try await target.setPermissions(path: file.path, permissions: file.permissions)
        case let .symlink(symlink):
            try await ensureParentDirectory(for: symlink.path, on: target)

            var rewriteRequired = true
            if await target.exists(path: symlink.path) {
                let info = try await target.stat(path: symlink.path)
                if info.kind == .symlink, try await target.readSymlink(path: symlink.path) == symlink.target {
                    rewriteRequired = false
                } else {
                    try await target.remove(path: symlink.path, recursive: true)
                }
            }

            if rewriteRequired {
                try await target.createSymlink(path: symlink.path, target: symlink.target)
            }
            try await target.setPermissions(path: symlink.path, permissions: symlink.permissions)
        case let .directory(directory):
            try await ensureDirectory(at: directory.path, permissions: directory.permissions, on: target)
            try await syncChildren(directory.children, under: directory.path, on: target)
            try await target.setPermissions(path: directory.path, permissions: directory.permissions)
        }
    }

    private static func ensureParentDirectory(for path: WorkspacePath, on target: any FileSystem) async throws {
        let parent = path.dirname
        guard !parent.isRoot else {
            return
        }
        try await ensureDirectory(at: parent, permissions: .defaultDirectory, on: target)
    }

    private static func ensureDirectory(
        at path: WorkspacePath,
        permissions: POSIXPermissions,
        on target: any FileSystem
    ) async throws {
        if await target.exists(path: path) {
            let info = try await target.stat(path: path)
            if info.kind == .directory {
                return
            }
            try await target.remove(path: path, recursive: true)
        }

        if !path.isRoot {
            try await target.createDirectory(path: path, recursive: true)
        }
        try await target.setPermissions(path: path, permissions: permissions)
    }

    private static func syncChildren(
        _ expectedChildren: [Entry],
        under parentPath: WorkspacePath,
        on target: any FileSystem
    ) async throws {
        let expectedNames = Set(expectedChildren.map { path(of: $0).basename })
        let existingEntries = (try? await target.listDirectory(path: parentPath)) ?? []

        for entry in existingEntries where !expectedNames.contains(entry.name) {
            try await target.remove(path: parentPath.appending(entry.name), recursive: true)
        }

        for child in expectedChildren.sorted(by: { path(of: $0) < path(of: $1) }) {
            try await restoreEntry(child, to: target)
        }
    }

    private static func removeEntryIfPresent(at path: WorkspacePath, on target: any FileSystem) async throws {
        guard await target.exists(path: path) else {
            return
        }

        if path.isRoot {
            let existingEntries = try await target.listDirectory(path: path)
            for entry in existingEntries {
                try await target.remove(path: path.appending(entry.name), recursive: true)
            }
            return
        }

        let info = try await target.stat(path: path)
        if info.kind == .directory {
            let existingEntries = try await target.listDirectory(path: path)
            for entry in existingEntries {
                try await target.remove(path: path.appending(entry.name), recursive: true)
            }
        }
        try await target.remove(path: path, recursive: true)
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
