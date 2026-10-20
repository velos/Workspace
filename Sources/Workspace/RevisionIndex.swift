import Foundation

struct RevisionIndex: Sendable, Equatable {
    indirect enum Entry: Sendable, Equatable {
        case missing(path: WorkspacePath)
        case file(path: WorkspacePath, size: UInt64, permissions: POSIXPermissions, contentID: String)
        case directory(path: WorkspacePath, permissions: POSIXPermissions, children: [Entry])
        case symbolicLink(path: WorkspacePath, target: String, permissions: POSIXPermissions)

        var path: WorkspacePath {
            switch self {
            case let .missing(path), let .file(path, _, _, _), let .directory(path, _, _),
                 let .symbolicLink(path, _, _):
                path
            }
        }

        var kind: FileTree.Kind? {
            switch self {
            case .missing: nil
            case .file: .file
            case .directory: .directory
            case .symbolicLink: .symlink
            }
        }

        var permissions: POSIXPermissions? {
            switch self {
            case .missing: nil
            case let .file(_, _, permissions, _), let .directory(_, permissions, _),
                 let .symbolicLink(_, _, permissions):
                permissions
            }
        }

        var size: UInt64 {
            if case let .file(_, size, _, _) = self { return size }
            if case let .symbolicLink(_, target, _) = self { return UInt64(target.utf8.count) }
            return 0
        }
    }

    var id: UUID
    var root: WorkspacePath
    var entry: Entry

    init(id: UUID, root: WorkspacePath, entry: Entry) {
        self.id = id
        self.root = root
        self.entry = entry
    }

    init(snapshot: Snapshot) {
        id = snapshot.id
        root = snapshot.rootPath
        entry = Self.index(snapshot.entry)
    }

    private static func index(_ entry: Snapshot.Entry) -> Entry {
        switch entry {
        case let .missing(value): .missing(path: value.path)
        case let .file(value):
            .file(
                path: value.path,
                size: UInt64(value.data.count),
                permissions: value.permissions,
                contentID: SHA256.hexDigest(of: value.data)
            )
        case let .directory(value):
            .directory(path: value.path, permissions: value.permissions, children: value.children.map(index))
        case let .symlink(value):
            .symbolicLink(path: value.path, target: value.target, permissions: value.permissions)
        }
    }

    func entry(at path: WorkspacePath) -> Entry? {
        Self.entry(at: path, in: entry)
    }

    /// Resolve each component in the revision namespace, including directory symlinks.
    func readableFile(at path: WorkspacePath) throws -> (path: WorkspacePath, size: UInt64) {
        var pending = path.components
        var current = WorkspacePath.root
        var hops = 0
        while !pending.isEmpty {
            let component = pending.removeFirst()
            current = current.appending(component)
            guard let entry = entry(at: current) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
            }
            switch entry {
            case let .symbolicLink(_, target, _):
                guard hops < 64 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ELOOP)) }
                hops += 1
                let targetPath = try WorkspacePath(target, relativeTo: current.parent)
                pending = targetPath.components + pending
                current = .root
            case let .file(_, size, _, _):
                guard pending.isEmpty else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR)) }
                return (current, size)
            case .directory:
                continue
            case .missing:
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
            }
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EISDIR))
    }

    private static func entry(at path: WorkspacePath, in entry: Entry) -> Entry? {
        if entry.path == path { return entry }
        guard case let .directory(_, _, children) = entry else { return nil }
        for child in children where path.isWithin(child.path) {
            return self.entry(at: path, in: child)
        }
        return nil
    }
}
