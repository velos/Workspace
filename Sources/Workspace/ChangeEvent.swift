import Foundation

/// A change observed from a workspace mutation.
public struct ChangeEvent: Sendable, Codable, Equatable {
    /// The logical change kind.
    public enum Kind: String, Sendable, Codable {
        /// A new entry was created.
        case created
        /// An existing entry's content changed.
        case modified
        /// An existing entry was deleted.
        case deleted
        /// An entry was moved or renamed.
        case moved
        /// An entry was copied to a new path.
        case copied
        /// An entry's metadata changed without changing content.
        case metadataModified
    }

    /// The change kind.
    public var kind: Kind
    /// The affected path after the change.
    public var path: WorkspacePath
    /// The original path for move and copy operations when applicable.
    public var sourcePath: WorkspacePath?
    /// The logical kind of the affected node.
    public var nodeKind: FileTree.Kind

    /// Creates a change event.
    public init(
        kind: Kind,
        path: WorkspacePath,
        sourcePath: WorkspacePath? = nil,
        nodeKind: FileTree.Kind
    ) {
        self.kind = kind
        self.path = path
        self.sourcePath = sourcePath
        self.nodeKind = nodeKind
    }
}
