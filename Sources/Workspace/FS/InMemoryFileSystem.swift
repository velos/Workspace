import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A purely in-memory filesystem implementation.
///
/// This implementation is useful for tests, previews, and transient workspaces where no host disk
/// interaction should occur.
///
/// Actor isolation serializes access to the tree so the filesystem can be shared safely across
/// concurrent tasks.
public actor InMemoryFileSystem: FileSystem, PotentialPathResolvingFileSystem, ExactTimestampFileSystem, TraversingFileSystem, MutationGenerationFileSystem {
    private var generation: UInt64 = 0
    package var mutationGeneration: UInt64? { generation }

    package nonisolated var hasExactContentTimestamps: Bool { true }
    private var lastTimestamp = Date().timeIntervalSinceReferenceDate

    private func nextTimestamp() -> Date {
        lastTimestamp = max(Date().timeIntervalSinceReferenceDate, lastTimestamp.nextUp)
        return Date(timeIntervalSinceReferenceDate: lastTimestamp)
    }
    private final class Node {
        enum Kind {
            case file(Data)
            case directory([PathName: Node])
            case symlink(String)
        }

        let inode: UInt64
        var linkCount: UInt64 = 1
        var kind: Kind
        var permissions: Int
        var modificationDate: Date

        init(inode: UInt64, kind: Kind, permissions: Int, modificationDate: Date = Date()) {
            self.inode = inode
            self.kind = kind
            self.permissions = permissions
            self.modificationDate = modificationDate
        }

        var isDirectory: Bool {
            if case .directory = kind {
                return true
            }
            return false
        }

        var isSymbolicLink: Bool {
            if case .symlink = kind {
                return true
            }
            return false
        }

        var size: UInt64 {
            switch kind {
            case let .file(data):
                return UInt64(data.count)
            case let .symlink(target):
                return UInt64(target.utf8.count)
            case .directory:
                return 0
            }
        }
    }

    private var root: Node
    private let device = UInt64.random(in: 1...UInt64.max)
    private var nextInode: UInt64 = 1

    /// Creates an empty in-memory filesystem rooted at `/`.
    public init() {
        root = Node(inode: 0, kind: .directory([:]), permissions: 0o755)
    }

    /// See ``FileSystem/configure(rootDirectory:)``.
    func configure(rootDirectory: URL) async throws {
        defer { generation &+= 1 }
        _ = rootDirectory
        root = makeNode(kind: .directory([:]), permissions: 0o755)
    }

    /// Clears the filesystem and recreates an empty root directory.
    public func reset() {
        defer { generation &+= 1 }
        root = makeNode(kind: .directory([:]), permissions: 0o755)
    }

    // Cursor frames and Node references stay on this actor. Visitors remain on their
    // caller's executor; only immutable metadata/content values cross that boundary.
    private final class WalkCursor {
        enum Frame {
            case entry(WorkspacePath, Node?, UInt64?)
            case directory(FileInfo)
        }
        var frames: [Frame]
        init(path: WorkspacePath) { frames = [.entry(path, nil, nil)] }
    }
    private struct WalkEntry: Sendable {
        var info: FileInfo
        var capturedAt: UInt64
        var data: Data?
        var target: String?
    }
    private var walkCursors: [UUID: WalkCursor] = [:]

    nonisolated(nonsending) package func walk(
        at path: WorkspacePath, skippingUnreadableDirectories: Bool, skippingVanishedEntries: Bool = false,
        visit: FileSystemWalkVisitor
    ) async throws {
        let id = await beginWalk(at: path)
        do {
            while let entry = try await nextWalkEntry(id, skippingVanishedEntries: skippingVanishedEntries) {
                try await visit(entry.info, { length in
                    try await self.readWalkFile(at: entry.info.path, capturedAt: entry.capturedAt,
                                                data: entry.data, length: length)
                }, {
                    try await self.readWalkLink(at: entry.info.path, capturedAt: entry.capturedAt, target: entry.target)
                })
            }
            await endWalk(id)
        } catch {
            await endWalk(id)
            throw error
        }
    }

    private func beginWalk(at path: WorkspacePath) -> UUID {
        let id = UUID()
        walkCursors[id] = WalkCursor(path: path)
        return id
    }

    private func endWalk(_ id: UUID) { walkCursors.removeValue(forKey: id) }

    private func nextWalkEntry(_ id: UUID, skippingVanishedEntries: Bool) throws -> WalkEntry? {
        let cursor = walkCursors[id]!
        while let frame = cursor.frames.popLast() {
            try Task.checkCancellation()
            switch frame {
            case let .directory(info):
                return WalkEntry(info: info, capturedAt: generation)
            case let .entry(path, listed, listedAt):
                let entry: Node
                do {
                    // Every mutation attempt advances generation before yielding. After
                    // reentrancy, resolve the listed path again, never detached nodes.
                    if let listed, listedAt == generation { entry = listed }
                    else { entry = try node(at: path, followFinalSymlink: false) }
                } catch {
                    guard (listed == nil || skippingVanishedEntries), Snapshot.isMissingEntry(error) else { throw error }
                    continue
                }
                let info = fileInfo(for: entry, path: path)
                switch entry.kind {
                case let .directory(children):
                    cursor.frames.append(.directory(info))
                    let ordered = children.map { name, child in
                        (name, child, walkSortKey(name: name.string, isDirectory: child.isDirectory))
                    }.sorted { $0.2.utf8.lexicographicallyPrecedes($1.2.utf8) }
                    for (name, child, _) in ordered.reversed() {
                        cursor.frames.append(.entry(path.appending(name.string), child, generation))
                    }
                case let .file(data):
                    return WalkEntry(info: info, capturedAt: generation, data: data)
                case let .symlink(target):
                    return WalkEntry(info: info, capturedAt: generation, target: target)
                }
            }
        }
        return nil
    }

    private func readWalkFile(at path: WorkspacePath, capturedAt: UInt64, data: Data?, length: Int?) async throws -> Data {
        if let length, length < 0 { throw WorkspaceError.unsupported("read length must not be negative") }
        guard capturedAt == generation, let data else {
            return try await readFile(path: path, offset: 0, length: length)
        }
        return length.map { Data(data.prefix($0)) } ?? data
    }

    private func readWalkLink(at path: WorkspacePath, capturedAt: UInt64, target: String?) async throws -> String {
        guard capturedAt == generation, let target else { return try await readSymlink(path: path) }
        return target
    }

    /// See ``FileSystem/stat(path:)``.
    public func stat(path: WorkspacePath) async throws -> FileInfo {
        let node = try node(at: path, followFinalSymlink: false)
        return fileInfo(for: node, path: path)
    }

    /// See ``FileSystem/listDirectory(path:)``.
    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        let node = try node(at: path, followFinalSymlink: true)

        guard case let .directory(children) = node.kind else {
            throw posixError(ENOTDIR)
        }

        return children.keys.sorted().compactMap { name in
            guard let child = children[name] else {
                return nil
            }
            let childPath = path.appending(name.string)
            return DirectoryEntry(name: name.string, info: fileInfo(for: child, path: childPath))
        }
    }

    /// See ``FileSystem/readFile(path:)``.
    public func readFile(path: WorkspacePath) async throws -> Data {
        let node = try node(at: path, followFinalSymlink: true)

        guard case let .file(data) = node.kind else {
            throw posixError(EISDIR)
        }

        return data
    }

    /// See ``FileSystem/capabilities()``.
    public func capabilities() async -> FileSystemFeatures {
        [.symlinks, .hardLinks, .permissions, .realPathResolution, .replacementFollowsFinalSymlink]
    }

    /// See ``FileSystem/createFile(path:data:)``. Actor isolation makes the existence check and
    /// write a single atomic step.
    public func createFile(path: WorkspacePath, data: Data) async throws {
        defer { generation &+= 1 }
        let destination = try resolvePath(path: path, followFinalSymlink: false,
                                          allowMissing: true, createParents: true)
        if (try? node(at: destination, followFinalSymlink: false)) != nil {
            throw posixError(EEXIST)
        }
        try write(path: destination, data: data, append: false)
    }

    /// See ``FileSystem/writeFile(path:data:append:)``.
    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        defer { generation &+= 1 }
        try write(path: path, data: data, append: append)
    }

    private func write(path: WorkspacePath, data: Data, append: Bool) throws {
        guard !path.isRoot else {
            throw posixError(EISDIR)
        }

        let writePath = try resolvePath(path: path, followFinalSymlink: true, allowMissing: true, createParents: true)

        let (parent, name) = try parentDirectoryAndName(for: writePath)
        var children = try directoryChildren(of: parent)

        if children[PathName(name)]?.isDirectory == true {
            throw posixError(EISDIR)
        }

        if append,
           let existing = children[PathName(name)],
           case let .file(existingData) = existing.kind {
            existing.kind = .file(existingData + data)
            existing.modificationDate = nextTimestamp()
            children[PathName(name)] = existing
        } else {
            if let existing = children[PathName(name)] { unlink(existing) }
            let node = makeNode(kind: .file(data), permissions: 0o644)
            children[PathName(name)] = node
        }

        parent.kind = .directory(children)
        parent.modificationDate = nextTimestamp()
    }

    /// See ``FileSystem/createDirectory(path:recursive:)``.
    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        defer { generation &+= 1 }
        if path.isRoot {
            return
        }

        let components = path.components
        var current = root

        for (index, component) in components.enumerated() {
            var children = try directoryChildren(of: current)
            let isLast = index == components.count - 1

            if let existing = children[PathName(component)] {
                guard existing.isDirectory else {
                    throw posixError(ENOTDIR)
                }

                if isLast, !recursive {
                    throw posixError(EEXIST)
                }

                current = existing
            } else {
                if !recursive, !isLast {
                    throw posixError(ENOENT)
                }

                let directory = makeNode(kind: .directory([:]), permissions: 0o755)
                children[PathName(component)] = directory
                current.kind = .directory(children)
                current.modificationDate = nextTimestamp()
                current = directory
            }
        }
    }

    /// See ``FileSystem/remove(path:recursive:)``.
    public func remove(path: WorkspacePath, recursive: Bool) async throws {
        defer { generation &+= 1 }
        if path.isRoot {
            throw posixError(EPERM)
        }

        guard let (parent, name, entry) = try parentDirectoryEntryIfPresent(for: path) else {
            return
        }

        if case let .directory(children) = entry.kind, !recursive, !children.isEmpty {
            throw posixError(ENOTEMPTY)
        }

        var parentChildren = try directoryChildren(of: parent)
        parentChildren.removeValue(forKey: PathName(name))
        unlink(entry)
        parent.kind = .directory(parentChildren)
        parent.modificationDate = nextTimestamp()
    }

    /// See ``FileSystem/move(from:to:)``.
    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        defer { generation &+= 1 }
        if sourcePath == destinationPath {
            return
        }

        guard let (sourceParent, sourceName, sourceNode) = try parentDirectoryEntryIfPresent(for: sourcePath) else {
            throw posixError(ENOENT)
        }

        let sourceEntry = try resolvePath(path: sourcePath, followFinalSymlink: false)
        let destinationEntry = try resolvePath(path: destinationPath, followFinalSymlink: false, allowMissing: true)
        if sourceNode.isDirectory,
           destinationEntry.isWithin(sourceEntry) {
            throw posixError(EINVAL)
        }

        let (destinationParent, destinationName) = try parentDirectoryAndName(for: destinationPath, createParents: true)
        if sourceParent === destinationParent {
            var children = try directoryChildren(of: sourceParent)
            if children[PathName(destinationName)] != nil {
                throw posixError(EEXIST)
            }

            children.removeValue(forKey: PathName(sourceName))
            children[PathName(destinationName)] = sourceNode
            sourceParent.kind = .directory(children)
            sourceParent.modificationDate = nextTimestamp()
            return
        }

        var destinationChildren = try directoryChildren(of: destinationParent)
        if destinationChildren[PathName(destinationName)] != nil {
            throw posixError(EEXIST)
        }

        var sourceChildren = try directoryChildren(of: sourceParent)
        sourceChildren.removeValue(forKey: PathName(sourceName))
        sourceParent.kind = .directory(sourceChildren)
        sourceParent.modificationDate = nextTimestamp()

        destinationChildren[PathName(destinationName)] = sourceNode
        destinationParent.kind = .directory(destinationChildren)
        destinationParent.modificationDate = nextTimestamp()
    }

    /// See ``FileSystem/copy(from:to:recursive:)``.
    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool)
        async throws
    {
        defer { generation &+= 1 }
        let sourceEntry: WorkspacePath
        if sourcePath.isRoot {
            sourceEntry = .root
        } else {
            let parent = try resolvePath(path: sourcePath.dirname, followFinalSymlink: true, requireDirectory: true)
            sourceEntry = parent.appending(sourcePath.basename)
        }
        let destinationEntry = try resolvePath(path: destinationPath, followFinalSymlink: false, allowMissing: true)
        guard !destinationEntry.isWithin(sourceEntry) else { throw posixError(EINVAL) }

        let (destinationParent, destinationName) = try parentDirectoryAndName(for: destinationPath, createParents: true)
        let sourceNode = try node(at: sourceEntry, followFinalSymlink: false)
        if sourceNode.isDirectory, !recursive {
            throw posixError(EISDIR)
        }
        var destinationChildren = try directoryChildren(of: destinationParent)
        if destinationChildren[PathName(destinationName)] != nil {
            throw posixError(EEXIST)
        }

        destinationChildren[PathName(destinationName)] = clone(sourceNode)
        destinationParent.kind = .directory(destinationChildren)
        destinationParent.modificationDate = nextTimestamp()
    }

    /// See ``FileSystem/createSymlink(path:target:)``.
    public func createSymlink(path: WorkspacePath, target: String) async throws {
        defer { generation &+= 1 }
        _ = try WorkspacePath(validating: target, relativeTo: path.dirname)
        guard !path.isRoot else {
            throw posixError(EEXIST)
        }

        let (parent, name) = try parentDirectoryAndName(for: path, createParents: true)
        var children = try directoryChildren(of: parent)
        if children[PathName(name)] != nil {
            throw posixError(EEXIST)
        }

        children[PathName(name)] = makeNode(kind: .symlink(target), permissions: 0o777)
        parent.kind = .directory(children)
        parent.modificationDate = nextTimestamp()
    }

    /// See ``FileSystem/createHardLink(path:target:)``.
    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        defer { generation &+= 1 }
        guard !path.isRoot else {
            throw posixError(EEXIST)
        }

        let sourceNode = try node(at: target, followFinalSymlink: false)
        if sourceNode.isDirectory {
            throw posixError(EPERM)
        }

        let (parent, name) = try parentDirectoryAndName(for: path, createParents: true)
        var children = try directoryChildren(of: parent)
        if children[PathName(name)] != nil {
            throw posixError(EEXIST)
        }

        sourceNode.linkCount += 1
        children[PathName(name)] = sourceNode
        parent.kind = .directory(children)
        parent.modificationDate = nextTimestamp()
    }

    /// See ``FileSystem/readSymlink(path:)``.
    public func readSymlink(path: WorkspacePath) async throws -> String {
        let node = try node(at: path, followFinalSymlink: false)

        guard case let .symlink(target) = node.kind else {
            throw posixError(EINVAL)
        }

        return target
    }

    /// See ``FileSystem/setPermissions(path:permissions:)``.
    public func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        defer { generation &+= 1 }
        let node = try node(at: path, followFinalSymlink: false)
        node.permissions = Int(permissions.rawValue)
        node.modificationDate = nextTimestamp()
    }

    /// See ``FileSystem/resolveRealPath(path:)``.
    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        try resolvePath(path: path, followFinalSymlink: true)
    }

    /// Returns entry existence without following the final symlink (lstat semantics).
    public func exists(path: WorkspacePath) async -> Bool {
        do {
            _ = try node(at: path, followFinalSymlink: false)
            return true
        } catch {
            return false
        }
    }

    /// See ``FileSystem/glob(pattern:currentDirectory:)``.
    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        let normalizedPattern = try WorkspacePath(validating: pattern, relativeTo: currentDirectory)
        if !WorkspacePath.containsGlob(normalizedPattern.string) {
            let exists: Bool = {
                do {
                    _ = try node(at: normalizedPattern, followFinalSymlink: false)
                    return true
                } catch {
                    return false
                }
            }()
            return exists ? [normalizedPattern] : []
        }

        let regex = try NSRegularExpression(pattern: WorkspacePath.globToRegex(normalizedPattern.string))
        let paths = allVirtualPaths()

        let matches = paths.filter { path in
            let range = NSRange(path.string.startIndex..<path.string.endIndex, in: path.string)
            return regex.firstMatch(in: path.string, range: range) != nil
        }

        return matches.sorted()
    }

    private func makeNode(kind: Node.Kind, permissions: Int, modificationDate: Date? = nil) -> Node {
        let inode = nextInode
        nextInode += 1
        return Node(inode: inode, kind: kind, permissions: permissions, modificationDate: modificationDate ?? nextTimestamp())
    }

    private func clone(_ node: Node) -> Node {
        let kind: Node.Kind
        switch node.kind {
        case let .file(data): kind = .file(data)
        case let .symlink(target): kind = .symlink(target)
        case let .directory(children): kind = .directory(children.mapValues { clone($0) })
        }
        return makeNode(kind: kind, permissions: node.permissions, modificationDate: node.modificationDate)
    }

    private func unlink(_ node: Node) {
        if case let .directory(children) = node.kind {
            for child in children.values { unlink(child) }
        }
        node.linkCount -= 1
    }

    private func allVirtualPaths() -> [WorkspacePath] {
        var paths: [WorkspacePath] = [.root]
        collectPaths(node: root, currentPath: .root, into: &paths)
        return paths
    }

    private func collectPaths(node: Node, currentPath: WorkspacePath, into paths: inout [WorkspacePath]) {
        guard case let .directory(children) = node.kind else {
            return
        }

        for (name, child) in children.sorted(by: { $0.key < $1.key }) {
            let childPath = currentPath.appending(name.string)
            paths.append(childPath)
            collectPaths(node: child, currentPath: childPath, into: &paths)
        }
    }

    private func fileKind(for node: Node) -> FileTree.Kind {
        if node.isDirectory {
            return .directory
        }
        if node.isSymbolicLink {
            return .symlink
        }
        return .file
    }

    private func fileInfo(for node: Node, path: WorkspacePath) -> FileInfo {
        FileInfo(
            path: path,
            kind: fileKind(for: node),
            size: node.size,
            permissions: POSIXPermissions(node.permissions),
            modificationDate: node.modificationDate,
            identity: FileIdentity(device: device, inode: node.inode),
            linkCount: node.isDirectory ? nil : node.linkCount
        )
    }

    private func directoryChildren(of node: Node) throws -> [PathName: Node] {
        guard case let .directory(children) = node.kind else {
            throw posixError(ENOTDIR)
        }
        return children
    }

    private func parentDirectoryAndName(for path: WorkspacePath, createParents: Bool = false) throws -> (Node, String) {
        guard !path.isRoot else {
            throw posixError(EPERM)
        }

        let parentPath = try resolvePath(path: path.dirname, followFinalSymlink: true,
                                         allowMissing: createParents, createParents: createParents, requireDirectory: true)
        let name = path.basename
        let parent = try node(at: parentPath, followFinalSymlink: true)
        _ = try directoryChildren(of: parent)
        return (parent, name)
    }

    private func parentDirectoryEntryIfPresent(for path: WorkspacePath) throws -> (Node, String, Node)? {
        let (parent, name) = try parentDirectoryAndName(for: path)
        let children = try directoryChildren(of: parent)
        guard let entry = children[PathName(name)] else {
            return nil
        }
        return (parent, name, entry)
    }

    private func node(at path: WorkspacePath, followFinalSymlink: Bool) throws -> Node {
        let resolved = try resolvePath(path: path, followFinalSymlink: followFinalSymlink)
        var current = root
        for component in resolved.components {
            guard let child = try directoryChildren(of: current)[PathName(component)] else {
                throw posixError(ENOENT)
            }
            current = child
        }
        return current
    }

    package func resolvePotentialPath(path: WorkspacePath) async throws -> WorkspacePath {
        try resolvePath(path: path, followFinalSymlink: true, allowMissing: true)
    }

    private func resolvePath(
        path: WorkspacePath, followFinalSymlink: Bool, allowMissing: Bool = false,
        createParents: Bool = false, requireDirectory: Bool = false
    ) throws -> WorkspacePath {
        var pending = path.components
        var nodes: [Node?] = [root]
        var resolved = WorkspacePath.root
        var hops = 0
        while !pending.isEmpty {
            let component = pending.removeFirst()
            if component == "." { continue }
            if component == ".." {
                guard !resolved.isRoot else { throw WorkspaceError.invalidPath(path.string) }
                resolved = resolved.dirname
                nodes.removeLast()
                continue
            }
            let current = nodes.last!
            var children = try current.map { try directoryChildren(of: $0) } ?? [:]
            let final = pending.isEmpty
            let child: Node?
            if let existing = children[PathName(component)] {
                child = existing
            } else if createParents && (!final || requireDirectory) {
                child = makeNode(kind: .directory([:]), permissions: 0o755)
                children[PathName(component)] = child
                current?.kind = .directory(children)
                current?.modificationDate = nextTimestamp()
            } else if allowMissing {
                child = nil
            } else {
                throw posixError(ENOENT)
            }
            if let child, case let .symlink(target) = child.kind, !final || followFinalSymlink {
                hops += 1
                guard hops <= 40 else { throw posixError(ELOOP) }
                if target.utf8.first == 47 {
                    nodes = [root]
                    resolved = .root
                }
                pending = WorkspacePath.splitComponents(target) + pending
                continue
            }
            if let child, !final || requireDirectory { _ = try directoryChildren(of: child) }
            nodes.append(child)
            resolved = resolved.appending(component)
        }
        return resolved
    }

    private func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

extension InMemoryFileSystem: PreviewSemanticsFileSystem {
    package func previewSemantics(at path: WorkspacePath) async -> FileSystemPreviewSemantics { .init(createsWriteParents: true) }
}

/// Optional exact revision for metadata accounting. Each attempted public mutation advances
/// once, including failures; nil means unavailable. Forwarders must preserve that rule.
/// Readers compare before/after a scan and before/after their own mutation.
package protocol MutationGenerationFileSystem: FileSystem {
    var mutationGeneration: UInt64? { get async }
}
