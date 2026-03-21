import Foundation

public final class InMemoryFilesystem: SessionConfigurableFilesystem, @unchecked Sendable {
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

    public init() {
        root = Node(kind: .directory([:]), permissions: 0o755)
    }

    public func configure(rootDirectory: URL) throws {
        _ = rootDirectory
        reset()
    }

    public func configureForSession() throws {
        reset()
    }

    private func reset() {
        root = Node(kind: .directory([:]), permissions: 0o755)
    }

    public func stat(path: String) async throws -> FileInfo {
        try PathUtils.validate(path)
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        let node = try node(at: normalized, followFinalSymlink: false)
        return fileInfo(for: node, path: normalized)
    }

    public func listDirectory(path: String) async throws -> [DirectoryEntry] {
        try PathUtils.validate(path)
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        let node = try node(at: normalized, followFinalSymlink: true)

        guard case let .directory(children) = node.kind else {
            throw posixError(ENOTDIR)
        }

        return children.keys.sorted().compactMap { name in
            guard let child = children[name] else {
                return nil
            }
            let childPath = PathUtils.join(normalized, name)
            return DirectoryEntry(name: name, info: fileInfo(for: child, path: childPath))
        }
    }

    public func readFile(path: String) async throws -> Data {
        try PathUtils.validate(path)
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        let node = try node(at: normalized, followFinalSymlink: true)

        guard case let .file(data) = node.kind else {
            throw posixError(EISDIR)
        }

        return data
    }

    public func writeFile(path: String, data: Data, append: Bool) async throws {
        try PathUtils.validate(path)
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        guard normalized != "/" else {
            throw posixError(EISDIR)
        }

        if let symlinkTarget = try symlinkTargetIfPresent(at: normalized) {
            let targetPath = PathUtils.normalize(path: symlinkTarget, currentDirectory: PathUtils.dirname(normalized))
            try await writeFile(path: targetPath, data: data, append: append)
            return
        }

        let (parent, name) = try parentDirectoryAndName(for: normalized)
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

    public func createDirectory(path: String, recursive: Bool) async throws {
        try PathUtils.validate(path)
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        if normalized == "/" {
            return
        }

        let components = PathUtils.splitComponents(normalized)
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

    public func remove(path: String, recursive: Bool) async throws {
        try PathUtils.validate(path)
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        if normalized == "/" {
            throw posixError(EPERM)
        }

        guard let (parent, name, entry) = try parentDirectoryEntryIfPresent(for: normalized) else {
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

    public func move(from sourcePath: String, to destinationPath: String) async throws {
        try PathUtils.validate(sourcePath)
        try PathUtils.validate(destinationPath)
        let source = PathUtils.normalize(path: sourcePath, currentDirectory: "/")
        let destination = PathUtils.normalize(path: destinationPath, currentDirectory: "/")

        if source == destination {
            return
        }

        guard let (sourceParent, sourceName, sourceNode) = try parentDirectoryEntryIfPresent(for: source) else {
            throw posixError(ENOENT)
        }

        if sourceNode.isDirectory,
           (destination == source || destination.hasPrefix(source + "/")) {
            throw posixError(EINVAL)
        }

        let (destinationParent, destinationName) = try parentDirectoryAndName(for: destination)
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

    public func copy(from sourcePath: String, to destinationPath: String, recursive: Bool) async throws {
        try PathUtils.validate(sourcePath)
        try PathUtils.validate(destinationPath)
        let source = PathUtils.normalize(path: sourcePath, currentDirectory: "/")
        let destination = PathUtils.normalize(path: destinationPath, currentDirectory: "/")

        let sourceNode = try node(at: source, followFinalSymlink: false)
        if sourceNode.isDirectory, !recursive {
            throw posixError(EISDIR)
        }

        let (destinationParent, destinationName) = try parentDirectoryAndName(for: destination)
        var destinationChildren = try directoryChildren(of: destinationParent)
        if destinationChildren[destinationName] != nil {
            throw posixError(EEXIST)
        }

        destinationChildren[destinationName] = sourceNode.clone()
        destinationParent.kind = .directory(destinationChildren)
        destinationParent.modificationDate = Date()
    }

    public func createSymlink(path: String, target: String) async throws {
        try PathUtils.validate(path)
        try PathUtils.validate(target)
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        guard normalized != "/" else {
            throw posixError(EEXIST)
        }

        let (parent, name) = try parentDirectoryAndName(for: normalized)
        var children = try directoryChildren(of: parent)
        if children[name] != nil {
            throw posixError(EEXIST)
        }

        children[name] = Node(kind: .symlink(target), permissions: 0o777)
        parent.kind = .directory(children)
        parent.modificationDate = Date()
    }

    public func createHardLink(path: String, target: String) async throws {
        try PathUtils.validate(path)
        try PathUtils.validate(target)
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        guard normalized != "/" else {
            throw posixError(EEXIST)
        }

        let source = PathUtils.normalize(path: target, currentDirectory: "/")
        let sourceNode = try node(at: source, followFinalSymlink: false)
        if sourceNode.isDirectory {
            throw posixError(EPERM)
        }

        let (parent, name) = try parentDirectoryAndName(for: normalized)
        var children = try directoryChildren(of: parent)
        if children[name] != nil {
            throw posixError(EEXIST)
        }

        children[name] = sourceNode
        parent.kind = .directory(children)
        parent.modificationDate = Date()
    }

    public func readSymlink(path: String) async throws -> String {
        try PathUtils.validate(path)
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        let node = try node(at: normalized, followFinalSymlink: false)

        guard case let .symlink(target) = node.kind else {
            throw posixError(EINVAL)
        }

        return target
    }

    public func setPermissions(path: String, permissions: Int) async throws {
        try PathUtils.validate(path)
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        let node = try node(at: normalized, followFinalSymlink: false)
        node.permissions = permissions
        node.modificationDate = Date()
    }

    public func resolveRealPath(path: String) async throws -> String {
        try PathUtils.validate(path)
        return try resolvePath(
            path: PathUtils.normalize(path: path, currentDirectory: "/"),
            followFinalSymlink: true,
            symlinkDepth: 0
        )
    }

    public func exists(path: String) async -> Bool {
        do {
            try PathUtils.validate(path)
            let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
            _ = try node(at: normalized, followFinalSymlink: true)
            return true
        } catch {
            return false
        }
    }

    public func glob(pattern: String, currentDirectory: String) async throws -> [String] {
        try PathUtils.validate(pattern)
        try PathUtils.validate(currentDirectory)
        let normalizedPattern = PathUtils.normalize(path: pattern, currentDirectory: currentDirectory)
        if !PathUtils.containsGlob(normalizedPattern) {
            return await exists(path: normalizedPattern) ? [normalizedPattern] : []
        }

        let regex = try NSRegularExpression(pattern: PathUtils.globToRegex(normalizedPattern))
        let paths = allVirtualPaths()

        let matches = paths.filter { path in
            let range = NSRange(path.startIndex..<path.endIndex, in: path)
            return regex.firstMatch(in: path, range: range) != nil
        }

        return matches.sorted()
    }

    private func allVirtualPaths() -> [String] {
        var paths = ["/"]
        collectPaths(node: root, currentPath: "/", into: &paths)
        return paths
    }

    private func collectPaths(node: Node, currentPath: String, into paths: inout [String]) {
        guard case let .directory(children) = node.kind else {
            return
        }

        for (name, child) in children.sorted(by: { $0.key < $1.key }) {
            let childPath = PathUtils.join(currentPath, name)
            paths.append(childPath)
            collectPaths(node: child, currentPath: childPath, into: &paths)
        }
    }

    private func fileInfo(for node: Node, path: String) -> FileInfo {
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

    private func parentDirectoryAndName(for path: String) throws -> (Node, String) {
        guard path != "/" else {
            throw posixError(EPERM)
        }

        let parentPath = PathUtils.dirname(path)
        let name = PathUtils.basename(path)
        let parent = try node(at: parentPath, followFinalSymlink: true)
        _ = try directoryChildren(of: parent)
        return (parent, name)
    }

    private func parentDirectoryEntryIfPresent(for path: String) throws -> (Node, String, Node)? {
        let (parent, name) = try parentDirectoryAndName(for: path)
        let children = try directoryChildren(of: parent)
        guard let entry = children[name] else {
            return nil
        }
        return (parent, name, entry)
    }

    private func symlinkTargetIfPresent(at path: String) throws -> String? {
        guard let (_, _, entry) = try parentDirectoryEntryIfPresent(for: path) else {
            return nil
        }

        if case let .symlink(target) = entry.kind {
            return target
        }

        return nil
    }

    private func node(at path: String, followFinalSymlink: Bool, symlinkDepth: Int = 0) throws -> Node {
        if symlinkDepth > 64 {
            throw posixError(ELOOP)
        }

        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        if normalized == "/" {
            return root
        }

        let components = PathUtils.splitComponents(normalized)
        var current = root
        var currentPath = "/"

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
                let targetPath = PathUtils.normalize(path: target, currentDirectory: base)
                let remaining = components.suffix(from: index + 1).joined(separator: "/")
                let combined = remaining.isEmpty ? targetPath : PathUtils.join(targetPath, remaining)
                return try node(at: combined, followFinalSymlink: followFinalSymlink, symlinkDepth: symlinkDepth + 1)
            }

            current = child
            currentPath = PathUtils.join(currentPath, component)
        }

        return current
    }

    private func resolvePath(path: String, followFinalSymlink: Bool, symlinkDepth: Int) throws -> String {
        if symlinkDepth > 64 {
            throw posixError(ELOOP)
        }

        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        if normalized == "/" {
            return "/"
        }

        let components = PathUtils.splitComponents(normalized)
        var current = root
        var resolvedPath = "/"

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
                let targetPath = PathUtils.normalize(path: target, currentDirectory: resolvedPath)
                let remaining = components.suffix(from: index + 1).joined(separator: "/")
                let combined = remaining.isEmpty ? targetPath : PathUtils.join(targetPath, remaining)
                return try resolvePath(path: combined, followFinalSymlink: followFinalSymlink, symlinkDepth: symlinkDepth + 1)
            }

            current = child
            resolvedPath = PathUtils.join(resolvedPath, component)
        }

        return resolvedPath
    }

    private func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
