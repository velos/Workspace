import Foundation

/// A recursive tree node returned from workspace tree traversal APIs.
public struct FileTree: Sendable, Codable {
    /// The logical kind of a node in a workspace tree.
    public enum Kind: String, Sendable, Codable {
        /// A regular file.
        case file
        /// A directory.
        case directory
        /// A symbolic link.
        case symlink
    }

    /// The normalized path for the node.
    public var path: WorkspacePath
    /// The node's kind.
    public var kind: Kind
    /// The size of the node in bytes.
    public var size: UInt64
    /// The node's POSIX permissions.
    public var permissions: POSIXPermissions
    /// The node's last modification timestamp when available.
    public var modificationDate: Date?
    /// Child nodes for directories when the traversal includes them.
    public var children: [FileTree]?

    /// Creates a tree node.
    public init(
        path: WorkspacePath,
        kind: Kind,
        size: UInt64,
        permissions: POSIXPermissions,
        modificationDate: Date?,
        children: [FileTree]? = nil
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.permissions = permissions
        self.modificationDate = modificationDate
        self.children = children
    }
}

extension FileTree {
    /// Aggregate information for an already-loaded metadata tree.
    public struct Summary: Sendable, Codable {
        public struct Entry: Sendable, Codable {
            public var path: WorkspacePath
            public var kind: FileTree.Kind
            public var size: UInt64
            public var permissions: POSIXPermissions

            public init(path: WorkspacePath, kind: FileTree.Kind, size: UInt64, permissions: POSIXPermissions) {
                self.path = path
                self.kind = kind
                self.size = size
                self.permissions = permissions
            }
        }

        public var path: WorkspacePath
        public var fileCount: Int
        public var directoryCount: Int
        public var symlinkCount: Int
        public var totalBytes: UInt64
        public var children: [Entry]

        public init(
            path: WorkspacePath,
            fileCount: Int,
            directoryCount: Int,
            symlinkCount: Int,
            totalBytes: UInt64,
            children: [Entry]
        ) {
            self.path = path
            self.fileCount = fileCount
            self.directoryCount = directoryCount
            self.symlinkCount = symlinkCount
            self.totalBytes = totalBytes
            self.children = children
        }
    }

    /// Aggregate information for this already-loaded metadata tree.
    public var summary: Summary {
        var fileCount = 0
        var directoryCount = 0
        var symlinkCount = 0
        var totalBytes: UInt64 = 0

        func collect(_ node: FileTree) {
            switch node.kind {
            case .file:
                fileCount += 1
                totalBytes += node.size
            case .directory:
                directoryCount += 1
            case .symlink:
                symlinkCount += 1
            }
            node.children?.forEach(collect)
        }
        collect(self)

        return Summary(
            path: path,
            fileCount: fileCount,
            directoryCount: directoryCount,
            symlinkCount: symlinkCount,
            totalBytes: totalBytes,
            children: (children ?? []).map {
                Summary.Entry(path: $0.path, kind: $0.kind, size: $0.size, permissions: $0.permissions)
            }
        )
    }
}
