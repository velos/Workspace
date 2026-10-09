import Foundation

extension Workspace {
    /// A flat tree node used by transaction three-way commits.
    struct MergeNode: Equatable {
        var kind: FileTree.Kind
        var permissions: POSIXPermissions
        var fileData: Data?
        var symlinkTarget: String?
    }

    static func flattenMergeNodes(_ entry: Snapshot.Entry, into nodes: inout [WorkspacePath: MergeNode]) {
        switch entry {
        case .missing:
            return
        case let .file(file):
            nodes[file.path] = MergeNode(kind: .file, permissions: file.permissions, fileData: file.data)
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
        draft: [WorkspacePath: MergeNode]
    ) -> Set<WorkspacePath> {
        var conflicts: Set<WorkspacePath> = []
        let paths = Set(base.keys).union(parent.keys).union(draft.keys)
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

    static func buildEntryTree(from nodes: [WorkspacePath: MergeNode]) throws -> Snapshot.Entry {
        guard let root = nodes[.root], root.kind == .directory else {
            throw WorkspaceError.mutationFailed("merged tree must have a directory root")
        }
        var childNames: [WorkspacePath: [(String, MergeNode)]] = [:]
        for (path, node) in nodes where !path.isRoot {
            // Checking every immediate parent proves the full ancestry inductively,
            // since WorkspacePath parents strictly shorten toward the validated root.
            guard nodes[path.parent]?.kind == .directory else {
                throw WorkspaceError.mutationFailed("merged node \(path) has no directory parent")
            }
            childNames[path.parent, default: []].append((path.name, node))
        }

        func subtree(at path: WorkspacePath, node: MergeNode) -> Snapshot.Entry {
            switch node.kind {
            case .file:
                return .file(.init(path: path, data: node.fileData ?? Data(), permissions: node.permissions))
            case .symlink:
                return .symlink(.init(path: path, target: node.symlinkTarget ?? "", permissions: node.permissions))
            case .directory:
                return .directory(
                    .init(
                        path: path,
                        permissions: node.permissions,
                        children: (childNames[path] ?? []).sorted { $0.0 < $1.0 }.map { name, child in
                            subtree(at: path.appending(name), node: child)
                        }
                    )
                )
            }
        }
        return subtree(at: .root, node: root)
    }
}
