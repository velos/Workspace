import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class MountableFilesystem: SessionConfigurableFilesystem, @unchecked Sendable {
    public struct Mount: Sendable {
        public var mountPoint: String
        public var filesystem: any WorkspaceFilesystem

        public init(mountPoint: String, filesystem: any WorkspaceFilesystem) {
            self.mountPoint = PathUtils.normalize(path: mountPoint, currentDirectory: "/")
            self.filesystem = filesystem
        }
    }

    private let base: any WorkspaceFilesystem
    private var mounts: [Mount]

    public init(
        base: any WorkspaceFilesystem = InMemoryFilesystem(),
        mounts: [Mount] = []
    ) {
        self.base = base
        self.mounts = mounts.sorted { $0.mountPoint.count > $1.mountPoint.count }
    }

    public func mount(_ mountPoint: String, filesystem: any WorkspaceFilesystem) {
        let mount = Mount(mountPoint: mountPoint, filesystem: filesystem)
        mounts.append(mount)
        mounts.sort { $0.mountPoint.count > $1.mountPoint.count }
    }

    public func configure(rootDirectory: URL) throws {
        try base.configure(rootDirectory: rootDirectory)
        for mount in mounts {
            if let configurable = mount.filesystem as? any SessionConfigurableFilesystem {
                try configurable.configureForSession()
            }
        }
    }

    public func configureForSession() throws {
        guard let configurableBase = base as? any SessionConfigurableFilesystem else {
            throw ShellError.unsupported("filesystem requires rootDirectory initializer")
        }
        try configurableBase.configureForSession()
        for mount in mounts {
            if let configurable = mount.filesystem as? any SessionConfigurableFilesystem {
                try configurable.configureForSession()
            }
        }
    }

    public func stat(path: String) async throws -> FileInfo {
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
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

    public func listDirectory(path: String) async throws -> [DirectoryEntry] {
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        if let resolved = resolveMounted(path: normalized) {
            let entries = try await resolved.filesystem.listDirectory(path: resolved.relativePath)
            return entries.map { entry in
                DirectoryEntry(
                    name: entry.name,
                    info: FileInfo(
                        path: PathUtils.join(normalized, entry.name),
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
        let baseHasPath = normalized == "/" ? true : await base.exists(path: normalized)
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
                    path: PathUtils.join(normalized, syntheticName),
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

    public func readFile(path: String) async throws -> Data {
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        if let resolved = resolveMounted(path: normalized) {
            return try await resolved.filesystem.readFile(path: resolved.relativePath)
        }
        return try await base.readFile(path: normalized)
    }

    public func writeFile(path: String, data: Data, append: Bool) async throws {
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        let resolved = resolveWritable(path: normalized)
        try await resolved.filesystem.writeFile(path: resolved.relativePath, data: data, append: append)
    }

    public func createDirectory(path: String, recursive: Bool) async throws {
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        let resolved = resolveWritable(path: normalized)
        try await resolved.filesystem.createDirectory(path: resolved.relativePath, recursive: recursive)
    }

    public func remove(path: String, recursive: Bool) async throws {
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        let resolved = resolveWritable(path: normalized)
        try await resolved.filesystem.remove(path: resolved.relativePath, recursive: recursive)
    }

    public func move(from sourcePath: String, to destinationPath: String) async throws {
        let source = resolveWritable(path: PathUtils.normalize(path: sourcePath, currentDirectory: "/"))
        let destination = resolveWritable(path: PathUtils.normalize(path: destinationPath, currentDirectory: "/"))
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

    public func copy(from sourcePath: String, to destinationPath: String, recursive: Bool) async throws {
        let source = resolveWritable(path: PathUtils.normalize(path: sourcePath, currentDirectory: "/"))
        let destination = resolveWritable(path: PathUtils.normalize(path: destinationPath, currentDirectory: "/"))
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

    public func createSymlink(path: String, target: String) async throws {
        let resolved = resolveWritable(path: PathUtils.normalize(path: path, currentDirectory: "/"))
        try await resolved.filesystem.createSymlink(path: resolved.relativePath, target: target)
    }

    public func createHardLink(path: String, target: String) async throws {
        let link = resolveWritable(path: PathUtils.normalize(path: path, currentDirectory: "/"))
        let targetResolved = resolveWritable(path: PathUtils.normalize(path: target, currentDirectory: "/"))
        if link.mountPoint != targetResolved.mountPoint {
            throw ShellError.unsupported("hard links across mounts are not supported")
        }
        try await link.filesystem.createHardLink(path: link.relativePath, target: targetResolved.relativePath)
    }

    public func readSymlink(path: String) async throws -> String {
        let resolved = resolveWritable(path: PathUtils.normalize(path: path, currentDirectory: "/"))
        return try await resolved.filesystem.readSymlink(path: resolved.relativePath)
    }

    public func setPermissions(path: String, permissions: Int) async throws {
        let resolved = resolveWritable(path: PathUtils.normalize(path: path, currentDirectory: "/"))
        try await resolved.filesystem.setPermissions(path: resolved.relativePath, permissions: permissions)
    }

    public func resolveRealPath(path: String) async throws -> String {
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        let resolved = resolveWritable(path: normalized)
        let real = try await resolved.filesystem.resolveRealPath(path: resolved.relativePath)
        return resolved.mountPoint == "/" ? real : PathUtils.join(resolved.mountPoint, String(real.dropFirst()))
    }

    public func exists(path: String) async -> Bool {
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        if let resolved = resolveMounted(path: normalized) {
            return await resolved.filesystem.exists(path: resolved.relativePath)
        }
        if hasSyntheticDirectory(at: normalized) {
            return true
        }
        return await base.exists(path: normalized)
    }

    public func glob(pattern: String, currentDirectory: String) async throws -> [String] {
        let normalizedPattern = PathUtils.normalize(path: pattern, currentDirectory: currentDirectory)
        if !PathUtils.containsGlob(normalizedPattern) {
            return await exists(path: normalizedPattern) ? [normalizedPattern] : []
        }

        let regex = try NSRegularExpression(pattern: PathUtils.globToRegex(normalizedPattern))
        let paths = try await allPaths()
        return paths.filter { path in
            let range = NSRange(path.startIndex..<path.endIndex, in: path)
            return regex.firstMatch(in: path, range: range) != nil
        }.sorted()
    }

    private func copyTree(
        from sourceFS: any WorkspaceFilesystem,
        sourcePath: String,
        to destinationFS: any WorkspaceFilesystem,
        destinationPath: String
    ) async throws {
        let info = try await sourceFS.stat(path: sourcePath)
        if info.isDirectory {
            try await destinationFS.createDirectory(path: destinationPath, recursive: true)
            let children = try await sourceFS.listDirectory(path: sourcePath)
            for child in children {
                try await copyTree(
                    from: sourceFS,
                    sourcePath: PathUtils.join(sourcePath, child.name),
                    to: destinationFS,
                    destinationPath: PathUtils.join(destinationPath, child.name)
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

    private func allPaths() async throws -> [String] {
        var visited = Set<String>()
        var queue = ["/"]
        var paths = ["/"]

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
                let childPath = PathUtils.join(current, entry.name)
                paths.append(childPath)
                if entry.info.isDirectory {
                    queue.append(childPath)
                }
            }
        }

        return Array(Set(paths))
    }

    private func hasSyntheticDirectory(at path: String) -> Bool {
        path == "/" || mounts.contains { parentPath(of: $0.mountPoint) == path } || syntheticChildMountNames(under: path).isEmpty == false
    }

    private func syntheticChildMountNames(under path: String) -> [String] {
        var names = Set<String>()
        for mount in mounts where mount.mountPoint != path {
            guard isPath(mount.mountPoint, inside: path) else {
                continue
            }
            let remaining = mount.mountPoint == "/" ? "" : String(mount.mountPoint.dropFirst(path == "/" ? 1 : path.count + 1))
            guard !remaining.isEmpty else { continue }
            if let first = remaining.split(separator: "/").first {
                names.insert(String(first))
            }
        }
        return names.sorted()
    }

    private func parentPath(of path: String) -> String {
        PathUtils.dirname(path)
    }

    private func isPath(_ candidate: String, inside parent: String) -> Bool {
        if parent == "/" {
            return candidate.hasPrefix("/") && candidate != "/"
        }
        return candidate == parent || candidate.hasPrefix(parent + "/")
    }

    private func resolveWritable(path: String) -> (mountPoint: String, filesystem: any WorkspaceFilesystem, relativePath: String) {
        resolveMounted(path: path) ?? ("/", base, path)
    }

    private func resolveMounted(path: String) -> (mountPoint: String, filesystem: any WorkspaceFilesystem, relativePath: String)? {
        for mount in mounts {
            if mount.mountPoint == path {
                return (mount.mountPoint, mount.filesystem, "/")
            }

            if mount.mountPoint != "/", path.hasPrefix(mount.mountPoint + "/") {
                let suffix = String(path.dropFirst(mount.mountPoint.count))
                return (mount.mountPoint, mount.filesystem, suffix.isEmpty ? "/" : suffix)
            }
        }
        return nil
    }
}
