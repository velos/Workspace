import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A filesystem that composes a base filesystem with additional mounted filesystems.
///
/// Each mount is exposed at a virtual path, allowing callers to present a single workspace assembled
/// from multiple independent roots.
public final class MountableFilesystem: FileSystem, @unchecked Sendable {
    /// A mounted filesystem and the virtual path where it appears.
    public struct Mount: Sendable {
        /// The normalized virtual mount point.
        public var mountPoint: WorkspacePath
        /// The filesystem exposed at `mountPoint`.
        public var filesystem: any FileSystem

        /// Creates a mount description from a typed workspace path.
        public init(mountPoint: WorkspacePath, filesystem: any FileSystem) {
            self.mountPoint = mountPoint
            self.filesystem = filesystem
        }

        /// Convenience initializer that accepts a string mount point.
        public init(mountPoint: String, filesystem: any FileSystem) {
            self.init(mountPoint: WorkspacePath(normalizing: mountPoint), filesystem: filesystem)
        }
    }

    private let base: any FileSystem
    private let stateLock = NSLock()
    private var mounts: [Mount]

    private func withLock<R>(_ body: () throws -> R) rethrows -> R {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    private func mountsSnapshot() -> [Mount] {
        withLock { mounts }
    }

    /// Creates a mountable filesystem with an optional base filesystem and initial mounts.
    public init(
        base: any FileSystem = InMemoryFilesystem(),
        mounts: [Mount] = []
    ) {
        self.base = base
        self.mounts = mounts.sorted { $0.mountPoint.string.count > $1.mountPoint.string.count }
    }

    /// Adds a filesystem mount at `mountPoint`.
    public func mount(_ mountPoint: WorkspacePath, filesystem: any FileSystem) {
        withLock {
            let mount = Mount(mountPoint: mountPoint, filesystem: filesystem)
            mounts.append(mount)
            mounts.sort { $0.mountPoint.string.count > $1.mountPoint.string.count }
        }
    }

    /// Convenience overload that accepts a string mount point.
    public func mount(_ mountPoint: String, filesystem: any FileSystem) {
        mount(WorkspacePath(normalizing: mountPoint), filesystem: filesystem)
    }

    /// See ``FileSystem/configure(rootDirectory:)``.
    public func configure(rootDirectory: URL) async throws {
        try await base.configure(rootDirectory: rootDirectory)
    }

    /// See ``FileSystem/stat(path:)``.
    public func stat(path: WorkspacePath) async throws -> FileInfo {
        let mounts = mountsSnapshot()
        if let resolved = resolveMounted(path: path, mounts: mounts) {
            var info = try await resolved.filesystem.stat(path: resolved.relativePath)
            info.path = path
            return info
        }

        if hasSyntheticDirectory(at: path, mounts: mounts) {
            return FileInfo(
                path: path,
                kind: .directory,
                size: 0,
                permissions: .defaultDirectory,
                modificationDate: nil
            )
        }

        return try await base.stat(path: path)
    }

    /// See ``FileSystem/listDirectory(path:)``.
    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        let mounts = mountsSnapshot()
        if let resolved = resolveMounted(path: path, mounts: mounts) {
            let entries = try await resolved.filesystem.listDirectory(path: resolved.relativePath)
            return entries.map { entry in
                DirectoryEntry(
                    name: entry.name,
                    info: FileInfo(
                        path: path.appending(entry.name),
                        kind: entry.info.kind,
                        size: entry.info.size,
                        permissions: entry.info.permissions,
                        modificationDate: entry.info.modificationDate
                    )
                )
            }
        }

        var merged: [String: DirectoryEntry] = [:]
        let baseHasPath = path.isRoot ? true : await base.exists(path: path)
        if baseHasPath {
            if let baseEntries = try? await base.listDirectory(path: path) {
                for entry in baseEntries {
                    merged[entry.name] = entry
                }
            }
        }

        for syntheticName in syntheticChildMountNames(under: path, mounts: mounts) {
            merged[syntheticName] = DirectoryEntry(
                name: syntheticName,
                info: FileInfo(
                    path: path.appending(syntheticName),
                    kind: .directory,
                    size: 0,
                    permissions: .defaultDirectory,
                    modificationDate: nil
                )
            )
        }

        if merged.isEmpty, !hasSyntheticDirectory(at: path, mounts: mounts) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }

        return merged.values.sorted { $0.name < $1.name }
    }

    /// See ``FileSystem/readFile(path:)``.
    public func readFile(path: WorkspacePath) async throws -> Data {
        if let resolved = resolveMounted(path: path, mounts: mountsSnapshot()) {
            return try await resolved.filesystem.readFile(path: resolved.relativePath)
        }
        return try await base.readFile(path: path)
    }

    /// See ``FileSystem/writeFile(path:data:append:)``.
    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        let resolved = resolveWritable(path: path, mounts: mountsSnapshot())
        try await resolved.filesystem.writeFile(path: resolved.relativePath, data: data, append: append)
    }

    /// See ``FileSystem/createDirectory(path:recursive:)``.
    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        let resolved = resolveWritable(path: path, mounts: mountsSnapshot())
        try await resolved.filesystem.createDirectory(path: resolved.relativePath, recursive: recursive)
    }

    /// See ``FileSystem/remove(path:recursive:)``.
    public func remove(path: WorkspacePath, recursive: Bool) async throws {
        let resolved = resolveWritable(path: path, mounts: mountsSnapshot())
        try await resolved.filesystem.remove(path: resolved.relativePath, recursive: recursive)
    }

    /// See ``FileSystem/move(from:to:)``.
    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        let mounts = mountsSnapshot()
        let source = resolveWritable(path: sourcePath, mounts: mounts)
        let destination = resolveWritable(path: destinationPath, mounts: mounts)
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

    /// See ``FileSystem/copy(from:to:recursive:)``.
    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool)
        async throws
    {
        let mounts = mountsSnapshot()
        let source = resolveWritable(path: sourcePath, mounts: mounts)
        let destination = resolveWritable(path: destinationPath, mounts: mounts)
        if source.mountPoint == destination.mountPoint {
            try await source.filesystem.copy(
                from: source.relativePath,
                to: destination.relativePath,
                recursive: recursive
            )
            return
        }

        let info = try await source.filesystem.stat(path: source.relativePath)
        if info.kind == .directory, !recursive {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EISDIR))
        }
        try await copyTree(
            from: source.filesystem,
            sourcePath: source.relativePath,
            to: destination.filesystem,
            destinationPath: destination.relativePath
        )
    }

    /// See ``FileSystem/createSymlink(path:target:)``.
    public func createSymlink(path: WorkspacePath, target: String) async throws {
        let resolved = resolveWritable(path: path, mounts: mountsSnapshot())
        try await resolved.filesystem.createSymlink(path: resolved.relativePath, target: target)
    }

    /// See ``FileSystem/createHardLink(path:target:)``.
    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        let mounts = mountsSnapshot()
        let link = resolveWritable(path: path, mounts: mounts)
        let targetResolved = resolveWritable(path: target, mounts: mounts)
        if link.mountPoint != targetResolved.mountPoint {
            throw WorkspaceError.unsupported("hard links across mounts are not supported")
        }
        try await link.filesystem.createHardLink(path: link.relativePath, target: targetResolved.relativePath)
    }

    /// See ``FileSystem/readSymlink(path:)``.
    public func readSymlink(path: WorkspacePath) async throws -> String {
        let resolved = resolveWritable(path: path, mounts: mountsSnapshot())
        return try await resolved.filesystem.readSymlink(path: resolved.relativePath)
    }

    /// See ``FileSystem/setPermissions(path:permissions:)``.
    public func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        let resolved = resolveWritable(path: path, mounts: mountsSnapshot())
        try await resolved.filesystem.setPermissions(path: resolved.relativePath, permissions: permissions)
    }

    /// See ``FileSystem/resolveRealPath(path:)``.
    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        let resolved = resolveWritable(path: path, mounts: mountsSnapshot())
        let real = try await resolved.filesystem.resolveRealPath(path: resolved.relativePath)
        return resolved.mountPoint.isRoot ? real : WorkspacePath.join(resolved.mountPoint, String(real.string.dropFirst()))
    }

    /// See ``FileSystem/exists(path:)``.
    public func exists(path: WorkspacePath) async -> Bool {
        let mounts = mountsSnapshot()
        if let resolved = resolveMounted(path: path, mounts: mounts) {
            return await resolved.filesystem.exists(path: resolved.relativePath)
        }
        if hasSyntheticDirectory(at: path, mounts: mounts) {
            return true
        }
        return await base.exists(path: path)
    }

    /// See ``FileSystem/glob(pattern:currentDirectory:)``.
    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        let normalizedPattern = try WorkspacePath(validating: pattern, relativeTo: currentDirectory)
        if !WorkspacePath.containsGlob(normalizedPattern.string) {
            return await exists(path: normalizedPattern) ? [normalizedPattern] : []
        }

        let regex = try NSRegularExpression(pattern: WorkspacePath.globToRegex(normalizedPattern.string))
        let paths = try await allPaths()
        return paths.filter { path in
            let range = NSRange(path.string.startIndex..<path.string.endIndex, in: path.string)
            return regex.firstMatch(in: path.string, range: range) != nil
        }.sorted()
    }

    private func copyTree(
        from sourceFS: any FileSystem,
        sourcePath: WorkspacePath,
        to destinationFS: any FileSystem,
        destinationPath: WorkspacePath
    ) async throws {
        let info = try await sourceFS.stat(path: sourcePath)
        if info.kind == .directory {
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

        if info.kind == .symlink {
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
                if entry.info.kind == .directory {
                    queue.append(childPath)
                }
            }
        }

        return Array(Set(paths))
    }

    private func hasSyntheticDirectory(at path: WorkspacePath, mounts: [Mount]) -> Bool {
        path.isRoot || mounts.contains { parentPath(of: $0.mountPoint) == path }
            || syntheticChildMountNames(under: path, mounts: mounts).isEmpty == false
    }

    private func syntheticChildMountNames(under path: WorkspacePath, mounts: [Mount]) -> [String] {
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

    private func resolveWritable(path: WorkspacePath, mounts: [Mount])
        -> (mountPoint: WorkspacePath, filesystem: any FileSystem, relativePath: WorkspacePath)
    {
        resolveMounted(path: path, mounts: mounts) ?? (.root, base, path)
    }

    private func resolveMounted(path: WorkspacePath, mounts: [Mount])
        -> (mountPoint: WorkspacePath, filesystem: any FileSystem, relativePath: WorkspacePath)?
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
