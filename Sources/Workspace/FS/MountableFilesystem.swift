import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class MountableFilesystem: WorkspaceFilesystem, @unchecked Sendable {
    public struct Mount: Sendable {
        public var mountPoint: WorkspacePath
        public var filesystem: any WorkspaceFilesystem

        public init(mountPoint: WorkspacePath, filesystem: any WorkspaceFilesystem) {
            self.mountPoint = WorkspacePath(normalizing: mountPoint.string)
            self.filesystem = filesystem
        }

        public init(mountPoint: String, filesystem: any WorkspaceFilesystem) {
            self.init(mountPoint: WorkspacePath(normalizing: mountPoint), filesystem: filesystem)
        }
    }

    private let base: any WorkspaceFilesystem
    private var mounts: [Mount]

    public init(
        base: any WorkspaceFilesystem = InMemoryFilesystem(),
        mounts: [Mount] = []
    ) {
        self.base = base
        self.mounts = mounts.sorted { $0.mountPoint.string.count > $1.mountPoint.string.count }
    }

    public func mount(_ mountPoint: WorkspacePath, filesystem: any WorkspaceFilesystem) {
        let mount = Mount(mountPoint: mountPoint, filesystem: filesystem)
        mounts.append(mount)
        mounts.sort { $0.mountPoint.string.count > $1.mountPoint.string.count }
    }

    public func mount(_ mountPoint: String, filesystem: any WorkspaceFilesystem) {
        mount(WorkspacePath(normalizing: mountPoint), filesystem: filesystem)
    }

    public func configure(rootDirectory: URL) throws {
        try base.configure(rootDirectory: rootDirectory)
    }

    public func stat(path: WorkspacePath) async throws -> FileInfo {
        let normalized = WorkspacePath(normalizing: path.string)
        if let resolved = resolveMounted(path: normalized) {
            var info = try await resolved.filesystem.stat(path: resolved.relativePath)
            info.path = normalized
            return info
        }

        if hasSyntheticDirectory(at: normalized) {
            return FileInfo(
                path: normalized,
                isDirectory: true,
                isSymbolicLink: false,
                size: 0,
                permissions: 0o755,
                modificationDate: nil
            )
        }

        return try await base.stat(path: normalized)
    }

    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        let normalized = WorkspacePath(normalizing: path.string)
        if let resolved = resolveMounted(path: normalized) {
            let entries = try await resolved.filesystem.listDirectory(path: resolved.relativePath)
            return entries.map { entry in
                DirectoryEntry(
                    name: entry.name,
                    info: FileInfo(
                        path: normalized.appending(entry.name),
                        isDirectory: entry.info.isDirectory,
                        isSymbolicLink: entry.info.isSymbolicLink,
                        size: entry.info.size,
                        permissions: entry.info.permissions,
                        modificationDate: entry.info.modificationDate
                    )
                )
            }
        }

        var merged: [String: DirectoryEntry] = [:]
        let baseHasPath = normalized.isRoot ? true : await base.exists(path: normalized)
        if baseHasPath {
            if let baseEntries = try? await base.listDirectory(path: normalized) {
                for entry in baseEntries {
                    merged[entry.name] = entry
                }
            }
        }

        for syntheticName in syntheticChildMountNames(under: normalized) {
            merged[syntheticName] = DirectoryEntry(
                name: syntheticName,
                info: FileInfo(
                    path: normalized.appending(syntheticName),
                    isDirectory: true,
                    isSymbolicLink: false,
                    size: 0,
                    permissions: 0o755,
                    modificationDate: nil
                )
            )
        }

        if merged.isEmpty, !hasSyntheticDirectory(at: normalized) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }

        return merged.values.sorted { $0.name < $1.name }
    }

    public func readFile(path: WorkspacePath) async throws -> Data {
        let normalized = WorkspacePath(normalizing: path.string)
        if let resolved = resolveMounted(path: normalized) {
            return try await resolved.filesystem.readFile(path: resolved.relativePath)
        }
        return try await base.readFile(path: normalized)
    }

    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        let normalized = WorkspacePath(normalizing: path.string)
        let resolved = resolveWritable(path: normalized)
        try await resolved.filesystem.writeFile(path: resolved.relativePath, data: data, append: append)
    }

    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        let normalized = WorkspacePath(normalizing: path.string)
        let resolved = resolveWritable(path: normalized)
        try await resolved.filesystem.createDirectory(path: resolved.relativePath, recursive: recursive)
    }

    public func remove(path: WorkspacePath, recursive: Bool) async throws {
        let normalized = WorkspacePath(normalizing: path.string)
        let resolved = resolveWritable(path: normalized)
        try await resolved.filesystem.remove(path: resolved.relativePath, recursive: recursive)
    }

    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        let source = resolveWritable(path: WorkspacePath(normalizing: sourcePath.string))
        let destination = resolveWritable(path: WorkspacePath(normalizing: destinationPath.string))
        if source.mountPoint == destination.mountPoint {
            try await source.filesystem.move(from: source.relativePath, to: destination.relativePath)
            return
        }

        try await copyTree(
            from: source.filesystem,
            sourcePath: source.relativePath,
            to: destination.filesystem,
            destinationPath: destination.relativePath
        )
        try await source.filesystem.remove(path: source.relativePath, recursive: true)
    }

    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool)
        async throws
    {
        let source = resolveWritable(path: WorkspacePath(normalizing: sourcePath.string))
        let destination = resolveWritable(path: WorkspacePath(normalizing: destinationPath.string))
        if source.mountPoint == destination.mountPoint {
            try await source.filesystem.copy(
                from: source.relativePath,
                to: destination.relativePath,
                recursive: recursive
            )
            return
        }

        let info = try await source.filesystem.stat(path: source.relativePath)
        if info.isDirectory, !recursive {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EISDIR))
        }
        try await copyTree(
            from: source.filesystem,
            sourcePath: source.relativePath,
            to: destination.filesystem,
            destinationPath: destination.relativePath
        )
    }

    public func createSymlink(path: WorkspacePath, target: String) async throws {
        let resolved = resolveWritable(path: WorkspacePath(normalizing: path.string))
        try await resolved.filesystem.createSymlink(path: resolved.relativePath, target: target)
    }

    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        let link = resolveWritable(path: WorkspacePath(normalizing: path.string))
        let targetResolved = resolveWritable(path: WorkspacePath(normalizing: target.string))
        if link.mountPoint != targetResolved.mountPoint {
            throw ShellError.unsupported("hard links across mounts are not supported")
        }
        try await link.filesystem.createHardLink(path: link.relativePath, target: targetResolved.relativePath)
    }

    public func readSymlink(path: WorkspacePath) async throws -> String {
        let resolved = resolveWritable(path: WorkspacePath(normalizing: path.string))
        return try await resolved.filesystem.readSymlink(path: resolved.relativePath)
    }

    public func setPermissions(path: WorkspacePath, permissions: Int) async throws {
        let resolved = resolveWritable(path: WorkspacePath(normalizing: path.string))
        try await resolved.filesystem.setPermissions(path: resolved.relativePath, permissions: permissions)
    }

    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        let normalized = WorkspacePath(normalizing: path.string)
        let resolved = resolveWritable(path: normalized)
        let real = try await resolved.filesystem.resolveRealPath(path: resolved.relativePath)
        return resolved.mountPoint.isRoot ? real : WorkspacePath.join(resolved.mountPoint, String(real.string.dropFirst()))
    }

    public func exists(path: WorkspacePath) async -> Bool {
        let normalized = WorkspacePath(normalizing: path.string)
        if let resolved = resolveMounted(path: normalized) {
            return await resolved.filesystem.exists(path: resolved.relativePath)
        }
        if hasSyntheticDirectory(at: normalized) {
            return true
        }
        return await base.exists(path: normalized)
    }

    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        let normalizedPattern = PathUtils.normalize(path: pattern, currentDirectory: currentDirectory.string)
        if !PathUtils.containsGlob(normalizedPattern) {
            let normalizedPath = WorkspacePath(normalizing: normalizedPattern)
            return await exists(path: normalizedPath) ? [normalizedPath] : []
        }

        let regex = try NSRegularExpression(pattern: PathUtils.globToRegex(normalizedPattern))
        let paths = try await allPaths()
        return paths.filter { path in
            let range = NSRange(path.string.startIndex..<path.string.endIndex, in: path.string)
            return regex.firstMatch(in: path.string, range: range) != nil
        }.sorted()
    }

    private func copyTree(
        from sourceFS: any WorkspaceFilesystem,
        sourcePath: WorkspacePath,
        to destinationFS: any WorkspaceFilesystem,
        destinationPath: WorkspacePath
    ) async throws {
        let info = try await sourceFS.stat(path: sourcePath)
        if info.isDirectory {
            try await destinationFS.createDirectory(path: destinationPath, recursive: true)
            let children = try await sourceFS.listDirectory(path: sourcePath)
            for child in children {
                try await copyTree(
                    from: sourceFS,
                    sourcePath: sourcePath.appending(child.name),
                    to: destinationFS,
                    destinationPath: destinationPath.appending(child.name)
                )
            }
            return
        }

        if info.isSymbolicLink {
            let target = try await sourceFS.readSymlink(path: sourcePath)
            try await destinationFS.createSymlink(path: destinationPath, target: target)
            return
        }

        let data = try await sourceFS.readFile(path: sourcePath)
        try await destinationFS.writeFile(path: destinationPath, data: data, append: false)
    }

    private func allPaths() async throws -> [WorkspacePath] {
        var visited = Set<WorkspacePath>()
        var queue: [WorkspacePath] = [.root]
        var paths: [WorkspacePath] = [.root]

        while let current = queue.first {
            queue.removeFirst()
            if visited.contains(current) {
                continue
            }
            visited.insert(current)

            guard let entries = try? await listDirectory(path: current) else {
                continue
            }

            for entry in entries {
                let childPath = current.appending(entry.name)
                paths.append(childPath)
                if entry.info.isDirectory {
                    queue.append(childPath)
                }
            }
        }

        return Array(Set(paths))
    }

    private func hasSyntheticDirectory(at path: WorkspacePath) -> Bool {
        path.isRoot || mounts.contains { parentPath(of: $0.mountPoint) == path }
            || syntheticChildMountNames(under: path).isEmpty == false
    }

    private func syntheticChildMountNames(under path: WorkspacePath) -> [String] {
        var names = Set<String>()
        for mount in mounts where mount.mountPoint != path {
            guard isPath(mount.mountPoint, inside: path) else {
                continue
            }
            let remaining = mount.mountPoint.isRoot
                ? ""
                : String(mount.mountPoint.string.dropFirst(path.isRoot ? 1 : path.string.count + 1))
            guard !remaining.isEmpty else { continue }
            if let first = remaining.split(separator: "/").first {
                names.insert(String(first))
            }
        }
        return names.sorted()
    }

    private func parentPath(of path: WorkspacePath) -> WorkspacePath {
        path.dirname
    }

    private func isPath(_ candidate: WorkspacePath, inside parent: WorkspacePath) -> Bool {
        if parent.isRoot {
            return candidate.string.hasPrefix("/") && !candidate.isRoot
        }
        return candidate == parent || candidate.string.hasPrefix(parent.string + "/")
    }

    private func resolveWritable(path: WorkspacePath)
        -> (mountPoint: WorkspacePath, filesystem: any WorkspaceFilesystem, relativePath: WorkspacePath)
    {
        resolveMounted(path: path) ?? (.root, base, path)
    }

    private func resolveMounted(path: WorkspacePath)
        -> (mountPoint: WorkspacePath, filesystem: any WorkspaceFilesystem, relativePath: WorkspacePath)?
    {
        for mount in mounts {
            if mount.mountPoint == path {
                return (mount.mountPoint, mount.filesystem, .root)
            }

            if !mount.mountPoint.isRoot, path.string.hasPrefix(mount.mountPoint.string + "/") {
                let suffix = String(path.string.dropFirst(mount.mountPoint.string.count))
                return (
                    mount.mountPoint,
                    mount.filesystem,
                    WorkspacePath(normalizing: suffix.isEmpty ? "/" : suffix)
                )
            }
        }
        return nil
    }
}
