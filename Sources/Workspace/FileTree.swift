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

/// Aggregate information about a subtree in the workspace.
public struct FileTreeSummary: Sendable, Codable {
    /// A summary entry for a direct child in a tree summary.
    public struct Entry: Sendable, Codable {
        /// The normalized path for the child entry.
        public var path: WorkspacePath
        /// The child entry's kind.
        public var kind: FileTree.Kind
        /// The child entry's size in bytes.
        public var size: UInt64
        /// The child entry's POSIX permissions.
        public var permissions: POSIXPermissions

        /// Creates a summary entry.
        public init(path: WorkspacePath, kind: FileTree.Kind, size: UInt64, permissions: POSIXPermissions) {
            self.path = path
            self.kind = kind
            self.size = size
            self.permissions = permissions
        }
    }

    /// The root path that was summarized.
    public var path: WorkspacePath
    /// The number of files in the summarized subtree.
    public var fileCount: Int
    /// The number of directories in the summarized subtree.
    public var directoryCount: Int
    /// The number of symlinks in the summarized subtree.
    public var symlinkCount: Int
    /// The total size in bytes across the summarized subtree.
    public var totalBytes: UInt64
    /// Direct child entries of the summarized root.
    public var children: [Entry]

    /// Creates a tree summary.
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
