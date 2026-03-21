import Foundation

/// A purely in-memory filesystem implementation.
///
/// This implementation is useful for tests, previews, and transient workspaces where no host disk
/// interaction should occur.
public final class InMemoryFilesystem: WorkspaceFilesystem, @unchecked Sendable {
    private final class Node {
        enum Kind {
            case file(Data)
            case directory([String: Node])
            case symlink(String)
        }

        var kind: Kind
        var permissions: Int
        var modificationDate: Date

        init(kind: Kind, permissions: Int, modificationDate: Date = Date()) {
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

        func clone() -> Node {
            switch kind {
            case let .file(data):
                return Node(kind: .file(data), permissions: permissions, modificationDate: modificationDate)
            case let .symlink(target):
                return Node(kind: .symlink(target), permissions: permissions, modificationDate: modificationDate)
            case let .directory(children):
                var copiedChildren: [String: Node] = [:]
                copiedChildren.reserveCapacity(children.count)
                for (name, child) in children {
                    copiedChildren[name] = child.clone()
                }
                return Node(kind: .directory(copiedChildren), permissions: permissions, modificationDate: modificationDate)
            }
        }
    }

    private var root: Node

    /// Creates an empty in-memory filesystem rooted at `/`.
    public init() {
        root = Node(kind: .directory([:]), permissions: 0o755)
    }

    /// See ``WorkspaceFilesystem/configure(rootDirectory:)``.
    public func configure(rootDirectory: URL) throws {
        _ = rootDirectory
        reset()
    }

    /// Clears the filesystem and recreates an empty root directory.
    public func reset() {
        root = Node(kind: .directory([:]), permissions: 0o755)
    }

    /// See ``WorkspaceFilesystem/stat(path:)``.
    public func stat(path: WorkspacePath) async throws -> FileInfo {
        let node = try node(at: path, followFinalSymlink: false)
        return fileInfo(for: node, path: path)
    }

    /// See ``WorkspaceFilesystem/listDirectory(path:)``.
    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        let node = try node(at: path, followFinalSymlink: true)

        guard case let .directory(children) = node.kind else {
            throw posixError(ENOTDIR)
        }

        return children.keys.sorted().compactMap { name in
            guard let child = children[name] else {
                return nil
            }
            let childPath = path.appending(name)
            return DirectoryEntry(name: name, info: fileInfo(for: child, path: childPath))
        }
    }

    /// See ``WorkspaceFilesystem/readFile(path:)``.
    public func readFile(path: WorkspacePath) async throws -> Data {
        let node = try node(at: path, followFinalSymlink: true)

        guard case let .file(data) = node.kind else {
            throw posixError(EISDIR)
        }

        return data
    }

    /// See ``WorkspaceFilesystem/writeFile(path:data:append:)``.
    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        guard !path.isRoot else {
            throw posixError(EISDIR)
        }

        if let symlinkTarget = try symlinkTargetIfPresent(at: path) {
            let targetPath = WorkspacePath(normalizing: symlinkTarget, relativeTo: path.dirname)
            try await writeFile(path: targetPath, data: data, append: append)
            return
        }

        let (parent, name) = try parentDirectoryAndName(for: path)
        var children = try directoryChildren(of: parent)

        if append,
           let existing = children[name],
           case let .file(existingData) = existing.kind {
            existing.kind = .file(existingData + data)
            existing.modificationDate = Date()
            children[name] = existing
        } else {
            let node = Node(kind: .file(data), permissions: 0o644)
            children[name] = node
        }

        parent.kind = .directory(children)
        parent.modificationDate = Date()
    }

    /// See ``WorkspaceFilesystem/createDirectory(path:recursive:)``.
    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        if path.isRoot {
            return
        }

        let components = path.components
        var current = root

        for (index, component) in components.enumerated() {
            var children = try directoryChildren(of: current)
            let isLast = index == components.count - 1

            if let existing = children[component] {
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

                let directory = Node(kind: .directory([:]), permissions: 0o755)
                children[component] = directory
                current.kind = .directory(children)
                current.modificationDate = Date()
                current = directory
            }
        }
    }

    /// See ``WorkspaceFilesystem/remove(path:recursive:)``.
    public func remove(path: WorkspacePath, recursive: Bool) async throws {
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
        parentChildren.removeValue(forKey: name)
        parent.kind = .directory(parentChildren)
        parent.modificationDate = Date()
    }

    /// See ``WorkspaceFilesystem/move(from:to:)``.
    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        if sourcePath == destinationPath {
            return
        }

        guard let (sourceParent, sourceName, sourceNode) = try parentDirectoryEntryIfPresent(for: sourcePath) else {
            throw posixError(ENOENT)
        }

        if sourceNode.isDirectory,
           (destinationPath == sourcePath || destinationPath.string.hasPrefix(sourcePath.string + "/")) {
            throw posixError(EINVAL)
        }

        let (destinationParent, destinationName) = try parentDirectoryAndName(for: destinationPath)
        if sourceParent === destinationParent {
            var children = try directoryChildren(of: sourceParent)
            if children[destinationName] != nil {
                throw posixError(EEXIST)
            }

            children.removeValue(forKey: sourceName)
            children[destinationName] = sourceNode
            sourceParent.kind = .directory(children)
            sourceParent.modificationDate = Date()
            return
        }

        var destinationChildren = try directoryChildren(of: destinationParent)
        if destinationChildren[destinationName] != nil {
            throw posixError(EEXIST)
        }

        var sourceChildren = try directoryChildren(of: sourceParent)
        sourceChildren.removeValue(forKey: sourceName)
        sourceParent.kind = .directory(sourceChildren)
        sourceParent.modificationDate = Date()

        destinationChildren[destinationName] = sourceNode
        destinationParent.kind = .directory(destinationChildren)
        destinationParent.modificationDate = Date()
    }

    /// See ``WorkspaceFilesystem/copy(from:to:recursive:)``.
    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool)
        async throws
    {
        let sourceNode = try node(at: sourcePath, followFinalSymlink: false)
        if sourceNode.isDirectory, !recursive {
            throw posixError(EISDIR)
        }

        let (destinationParent, destinationName) = try parentDirectoryAndName(for: destinationPath)
        var destinationChildren = try directoryChildren(of: destinationParent)
        if destinationChildren[destinationName] != nil {
            throw posixError(EEXIST)
        }

        destinationChildren[destinationName] = sourceNode.clone()
        destinationParent.kind = .directory(destinationChildren)
        destinationParent.modificationDate = Date()
    }

    /// See ``WorkspaceFilesystem/createSymlink(path:target:)``.
    public func createSymlink(path: WorkspacePath, target: String) async throws {
        _ = try WorkspacePath(validating: target, relativeTo: path.dirname)
        guard !path.isRoot else {
            throw posixError(EEXIST)
        }

        let (parent, name) = try parentDirectoryAndName(for: path)
        var children = try directoryChildren(of: parent)
        if children[name] != nil {
            throw posixError(EEXIST)
        }

        children[name] = Node(kind: .symlink(target), permissions: 0o777)
        parent.kind = .directory(children)
        parent.modificationDate = Date()
    }

    /// See ``WorkspaceFilesystem/createHardLink(path:target:)``.
    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        guard !path.isRoot else {
            throw posixError(EEXIST)
        }

        let sourceNode = try node(at: target, followFinalSymlink: false)
        if sourceNode.isDirectory {
            throw posixError(EPERM)
        }

        let (parent, name) = try parentDirectoryAndName(for: path)
        var children = try directoryChildren(of: parent)
        if children[name] != nil {
            throw posixError(EEXIST)
        }

        children[name] = sourceNode
        parent.kind = .directory(children)
        parent.modificationDate = Date()
    }

    /// See ``WorkspaceFilesystem/readSymlink(path:)``.
    public func readSymlink(path: WorkspacePath) async throws -> String {
        let node = try node(at: path, followFinalSymlink: false)

        guard case let .symlink(target) = node.kind else {
            throw posixError(EINVAL)
        }

        return target
    }

    /// See ``WorkspaceFilesystem/setPermissions(path:permissions:)``.
    public func setPermissions(path: WorkspacePath, permissions: Int) async throws {
        let node = try node(at: path, followFinalSymlink: false)
        node.permissions = permissions
        node.modificationDate = Date()
    }

    /// See ``WorkspaceFilesystem/resolveRealPath(path:)``.
    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        try resolvePath(path: path, followFinalSymlink: true, symlinkDepth: 0)
    }

    /// See ``WorkspaceFilesystem/exists(path:)``.
    public func exists(path: WorkspacePath) async -> Bool {
        do {
            _ = try node(at: path, followFinalSymlink: true)
            return true
        } catch {
            return false
        }
    }

    /// See ``WorkspaceFilesystem/glob(pattern:currentDirectory:)``.
    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        let normalizedPattern = try WorkspacePath(validating: pattern, relativeTo: currentDirectory)
        if !WorkspacePath.containsGlob(normalizedPattern.string) {
            return await exists(path: normalizedPattern) ? [normalizedPattern] : []
        }

        let regex = try NSRegularExpression(pattern: WorkspacePath.globToRegex(normalizedPattern.string))
        let paths = allVirtualPaths()

        let matches = paths.filter { path in
            let range = NSRange(path.string.startIndex..<path.string.endIndex, in: path.string)
            return regex.firstMatch(in: path.string, range: range) != nil
        }

        return matches.sorted()
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
            let childPath = currentPath.appending(name)
            paths.append(childPath)
            collectPaths(node: child, currentPath: childPath, into: &paths)
        }
    }

    private func fileInfo(for node: Node, path: WorkspacePath) -> FileInfo {
        FileInfo(
            path: path,
            isDirectory: node.isDirectory,
            isSymbolicLink: node.isSymbolicLink,
            size: node.size,
            permissions: node.permissions,
            modificationDate: node.modificationDate
        )
    }

    private func directoryChildren(of node: Node) throws -> [String: Node] {
        guard case let .directory(children) = node.kind else {
            throw posixError(ENOTDIR)
        }
        return children
    }

    private func parentDirectoryAndName(for path: WorkspacePath) throws -> (Node, String) {
        guard !path.isRoot else {
            throw posixError(EPERM)
        }

        let parentPath = path.dirname
        let name = path.basename
        let parent = try node(at: parentPath, followFinalSymlink: true)
        _ = try directoryChildren(of: parent)
        return (parent, name)
    }

    private func parentDirectoryEntryIfPresent(for path: WorkspacePath) throws -> (Node, String, Node)? {
        let (parent, name) = try parentDirectoryAndName(for: path)
        let children = try directoryChildren(of: parent)
        guard let entry = children[name] else {
            return nil
        }
        return (parent, name, entry)
    }

    private func symlinkTargetIfPresent(at path: WorkspacePath) throws -> String? {
        guard let (_, _, entry) = try parentDirectoryEntryIfPresent(for: path) else {
            return nil
        }

        if case let .symlink(target) = entry.kind {
            return target
        }

        return nil
    }

    private func node(at path: WorkspacePath, followFinalSymlink: Bool, symlinkDepth: Int = 0) throws -> Node {
        if symlinkDepth > 64 {
            throw posixError(ELOOP)
        }

        if path.isRoot {
            return root
        }

        let components = path.components
        var current = root
        var currentPath = WorkspacePath.root

        for (index, component) in components.enumerated() {
            guard case let .directory(children) = current.kind else {
                throw posixError(ENOTDIR)
            }

            guard let child = children[component] else {
                throw posixError(ENOENT)
            }

            let isFinal = index == components.count - 1
            if case let .symlink(target) = child.kind,
               (!isFinal || followFinalSymlink) {
                let base = currentPath
                let targetPath = WorkspacePath(normalizing: target, relativeTo: base)
                let remaining = components.suffix(from: index + 1).joined(separator: "/")
                let combined = remaining.isEmpty ? targetPath : targetPath.appending(remaining)
                return try node(at: combined, followFinalSymlink: followFinalSymlink, symlinkDepth: symlinkDepth + 1)
            }

            current = child
            currentPath = currentPath.appending(component)
        }

        return current
    }

    private func resolvePath(path: WorkspacePath, followFinalSymlink: Bool, symlinkDepth: Int) throws -> WorkspacePath {
        if symlinkDepth > 64 {
            throw posixError(ELOOP)
        }

        if path.isRoot {
            return .root
        }

        let components = path.components
        var current = root
        var resolvedPath = WorkspacePath.root

        for (index, component) in components.enumerated() {
            guard case let .directory(children) = current.kind else {
                throw posixError(ENOTDIR)
            }

            guard let child = children[component] else {
                throw posixError(ENOENT)
            }

            let isFinal = index == components.count - 1
            if case let .symlink(target) = child.kind,
               (!isFinal || followFinalSymlink) {
                let targetPath = WorkspacePath(normalizing: target, relativeTo: resolvedPath)
                let remaining = components.suffix(from: index + 1).joined(separator: "/")
                let combined = remaining.isEmpty ? targetPath : targetPath.appending(remaining)
                return try resolvePath(path: combined, followFinalSymlink: followFinalSymlink, symlinkDepth: symlinkDepth + 1)
            }

            current = child
            resolvedPath = resolvedPath.appending(component)
        }

        return resolvedPath
    }

    private func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
