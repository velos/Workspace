import Foundation

struct RevisionIndex: Sendable, Equatable {
    indirect enum Entry: Sendable, Equatable {
        case missing(path: WorkspacePath)
        case file(path: WorkspacePath, size: UInt64, permissions: POSIXPermissions, contentID: String)
        case directory(path: WorkspacePath, permissions: POSIXPermissions, children: [Entry])
        case symbolicLink(path: WorkspacePath, target: String, permissions: POSIXPermissions)

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case let (.missing(a), .missing(b)): return a == b
            case let (.file(a, sizeA, modeA, idA), .file(b, sizeB, modeB, idB)):
                return a == b && sizeA == sizeB && modeA == modeB && idA == idB
            case let (.directory(a, modeA, childrenA), .directory(b, modeB, childrenB)):
                return a == b && modeA == modeB && childrenA == childrenB
            case let (.symbolicLink(a, targetA, modeA), .symbolicLink(b, targetB, modeB)):
                return a == b && modeA == modeB && targetA.utf8.elementsEqual(targetB.utf8)
            default: return false
            }
        }

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
                contentID: value.contentID ?? SHA256.hexDigest(of: value.data)
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
        try Self.resolveReadableFile(at: path) { entry(at: $0) }
    }

    /// Shared by tree-backed and materialized revisions; keep symlink semantics in one place.
    static func resolveReadableFile(
        at path: WorkspacePath, lookup: (WorkspacePath) throws -> Entry?
    ) throws -> (path: WorkspacePath, size: UInt64) {
        var pending = path.components
        var current = WorkspacePath.root
        var hops = 0
        while !pending.isEmpty {
            let component = pending.removeFirst()
            current = current.appending(component)
            guard let entry = try lookup(current) else {
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
        let components = path.components
        guard path.isWithin(entry.path) else { return nil }
        let prefix = entry.path.components
        var current = entry
        for component in components.dropFirst(prefix.count) {
            guard case let .directory(_, _, children) = current,
                  let child = children.first(where: { PathName($0.path.name) == PathName(component) }) else { return nil }
            current = child
        }
        return current
    }
}
