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

    static func buildEntryTree(
        from nodes: [WorkspacePath: MergeNode],
        rootPermissions: POSIXPermissions
    ) -> Snapshot.Entry {
        var childNames: [WorkspacePath: [String]] = [:]
        for path in nodes.keys {
            childNames[path.parent, default: []].append(path.name)
        }

        func subtree(at path: WorkspacePath, node: MergeNode?) -> Snapshot.Entry {
            switch node?.kind ?? .directory {
            case .file:
                return .file(
                    .init(
                        path: path,
                        data: node?.fileData ?? Data(),
                        permissions: node?.permissions ?? .defaultFile
                    )
                )
            case .symlink:
                return .symlink(
                    .init(
                        path: path,
                        target: node?.symlinkTarget ?? "",
                        permissions: node?.permissions ?? POSIXPermissions(0o777)
                    )
                )
            case .directory:
                return .directory(
                    .init(
                        path: path,
                        permissions: node?.permissions ?? .defaultDirectory,
                        children: (childNames[path] ?? []).sorted().map { name in
                            let child = path.appending(name)
                            return subtree(at: child, node: nodes[child])
                        }
                    )
                )
            }
        }
        return subtree(at: .root, node: MergeNode(kind: .directory, permissions: rootPermissions))
    }
}
