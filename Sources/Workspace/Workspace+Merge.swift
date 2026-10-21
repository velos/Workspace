import Foundation

extension Workspace {
    /// A flat tree node used by transaction three-way commits.
    struct MergeNode: Equatable, Sendable {
        var kind: FileTree.Kind
        var permissions: POSIXPermissions
        let fileData: Data?
        var symlinkTarget: String?
        private var revisionContentID: String?
        private let digest: ContentDigest?
        var contentID: String? {
            get { revisionContentID ?? fileData.flatMap { digest?.value(for: $0) } }
            set { revisionContentID = newValue }
        }

        /// Shared by value copies of this immutable payload, synchronized for concurrent comparisons.
        private final class ContentDigest: @unchecked Sendable {
            private let lock = NSLock()
            private var cached: String?
            func value(for data: Data) -> String {
                lock.withLock {
                    if let cached { return cached }
                    let value = SHA256.hexDigest(of: data)
                    cached = value
                    return value
                }
            }
        }
        var size: UInt64 = 0

        init(kind: FileTree.Kind, permissions: POSIXPermissions, fileData: Data? = nil,
             symlinkTarget: String? = nil, contentID: String? = nil, size: UInt64 = 0) {
            self.kind = kind
            self.permissions = permissions
            self.fileData = fileData
            self.symlinkTarget = symlinkTarget
            self.revisionContentID = contentID
            self.digest = fileData == nil || contentID != nil ? nil : ContentDigest()
            self.size = size
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.kind == rhs.kind, lhs.permissions == rhs.permissions,
                  lhs.symlinkTarget.map(PathName.init) == rhs.symlinkTarget.map(PathName.init) else { return false }
            if let left = lhs.fileData, let right = rhs.fileData { return left == right }
            return lhs.contentID == rhs.contentID
        }
    }

    static func flattenMergeNodes(_ entry: Snapshot.Entry, into nodes: inout [WorkspacePath: MergeNode]) {
        switch entry {
        case .missing:
            return
        case let .file(file):
            nodes[file.path] = MergeNode(kind: .file, permissions: file.permissions, fileData: file.data, size: UInt64(file.data.count))
        case let .symlink(link):
            nodes[link.path] = MergeNode(
                kind: .symlink,
                permissions: link.permissions,
                symlinkTarget: link.target
            )
        case let .directory(directory):
            nodes[directory.path] = MergeNode(kind: .directory, permissions: directory.permissions)
            for child in directory.children {
                flattenMergeNodes(child, into: &nodes)
            }
        }
    }

    /// Report only the outermost removed/replaced directory for each surviving
    /// descendant change. Descendant deletions converge with ancestor removal.
    static func structuralMergeConflicts(
        base: [WorkspacePath: MergeNode],
        parent: [WorkspacePath: MergeNode],
        draft: [WorkspacePath: MergeNode],
        paths candidates: Set<WorkspacePath>? = nil
    ) -> Set<WorkspacePath> {
        var conflicts: Set<WorkspacePath> = []
        let paths = candidates ?? Set(base.keys).union(parent.keys).union(draft.keys)
        for path in paths where parent[path] != base[path] || draft[path] != base[path] {
            var ancestor = path
            var outermost: WorkspacePath?
            while !ancestor.isRoot {
                ancestor = ancestor.parent
                let parentReplaced = base[ancestor]?.kind == .directory
                    && parent[ancestor]?.kind != .directory && draft[ancestor]?.kind == .directory
                let draftReplaced = base[ancestor]?.kind == .directory
                    && draft[ancestor]?.kind != .directory && parent[ancestor]?.kind == .directory
                if (parentReplaced && draft[path] != nil && draft[path] != base[path])
                    || (draftReplaced && parent[path] != nil && parent[path] != base[path]) {
                    outermost = ancestor
                }
            }
            if let outermost { conflicts.insert(outermost) }
        }
        return conflicts
    }

    static func validateMergeNodes(_ nodes: [WorkspacePath: MergeNode]) throws {
        guard nodes[.root]?.kind == .directory else {
            throw WorkspaceError.mutationFailed("merged tree must have a directory root")
        }
        // Immediate parents prove full ancestry because paths shorten toward root.
        for path in nodes.keys where !path.isRoot && nodes[path.parent]?.kind != .directory {
            throw WorkspaceError.mutationFailed("merged node \(path) has no directory parent")
        }
    }
}
