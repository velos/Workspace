import Foundation

/// A disk-backed filesystem rooted at a concrete directory on the host filesystem.
///
/// Paths are resolved relative to the configured root and constrained so callers cannot escape that root
/// through traversal or symlink resolution.
public final class ReadWriteFilesystem: FileSystem, @unchecked Sendable {
    private let fileManager: FileManager
    private let stateLock = NSLock()
    private var rootURL: URL?
    private var resolvedRootPath: String?

    private struct ConfigurationSnapshot {
        var rootURL: URL
        var resolvedRootPath: String
    }

    /// Creates an unconfigured disk-backed filesystem.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Creates and configures a disk-backed filesystem rooted at `rootDirectory`.
    public convenience init(rootDirectory: URL, fileManager: FileManager = .default) throws {
        self.init(fileManager: fileManager)
        try applyConfiguration(rootDirectory: rootDirectory)
    }

    /// See ``FileSystem/configure(rootDirectory:)``.
    public func configure(rootDirectory: URL) async throws {
        try applyConfiguration(rootDirectory: rootDirectory)
    }

    /// Applies configuration synchronously; also used by adapters that cannot use `async` initializers.
    internal func applyConfiguration(rootDirectory: URL) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        let standardized = rootDirectory.standardizedFileURL
        try fileManager.createDirectory(at: standardized, withIntermediateDirectories: true)
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        rootURL = standardized
        resolvedRootPath = resolved.path
    }

    /// See ``FileSystem/stat(path:)``.
    public func stat(path: WorkspacePath) async throws -> FileInfo {
        let configuration = try requireConfiguration()
        let url = try existingURL(for: path, configuration: configuration)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)

        let fileType = attributes[.type] as? FileAttributeType
        let isDirectory = fileType == .typeDirectory
        let isSymbolicLink = fileType == .typeSymbolicLink
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let permissionBits = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let modificationDate = attributes[.modificationDate] as? Date

        let kind: FileTree.Kind
        if isSymbolicLink {
            kind = .symlink
        } else if isDirectory {
            kind = .directory
        } else {
            kind = .file
        }

        return FileInfo(
            path: path,
            kind: kind,
            size: size,
            permissions: POSIXPermissions(permissionBits),
            modificationDate: modificationDate
        )
    }

    /// See ``FileSystem/listDirectory(path:)``.
    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        let configuration = try requireConfiguration()
        let url = try existingURL(for: path, configuration: configuration)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))
        }

        let names = try fileManager.contentsOfDirectory(atPath: url.path).sorted()
        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(names.count)
        for name in names {
            let childPath = path.appending(name)
            let info = try stat(path: childPath, configuration: configuration)
            entries.append(DirectoryEntry(name: name, info: info))
        }
        return entries
    }

    /// See ``FileSystem/readFile(path:)``.
    public func readFile(path: WorkspacePath) async throws -> Data {
        let configuration = try requireConfiguration()
        let url = try existingURL(for: path, configuration: configuration)
        return try Data(contentsOf: url)
    }

    /// See ``FileSystem/writeFile(path:data:append:)``.
    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        let configuration = try requireConfiguration()
        let url = try creationURL(for: path, configuration: configuration)

        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        if append, fileManager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    /// See ``FileSystem/createDirectory(path:recursive:)``.
    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        let configuration = try requireConfiguration()
        let url = try creationURL(for: path, configuration: configuration)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: recursive)
    }

    /// See ``FileSystem/remove(path:recursive:)``.
    public func remove(path: WorkspacePath, recursive: Bool) async throws {
        let configuration = try requireConfiguration()
        let url = try existingURL(for: path, configuration: configuration)

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists else { return }

        if isDirectory.boolValue, !recursive {
            let contents = try fileManager.contentsOfDirectory(atPath: url.path)
            if !contents.isEmpty {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTEMPTY))
            }
        }

        try fileManager.removeItem(at: url)
    }

    /// See ``FileSystem/move(from:to:)``.
    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        let configuration = try requireConfiguration()
        let source = try existingURL(for: sourcePath, configuration: configuration)
        let destination = try creationURL(for: destinationPath, configuration: configuration)
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: destination)
    }

    /// See ``FileSystem/copy(from:to:recursive:)``.
    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool)
        async throws
    {
        let configuration = try requireConfiguration()
        let source = try existingURL(for: sourcePath, configuration: configuration)
        let destination = try creationURL(for: destinationPath, configuration: configuration)

        let sourceInfo = try stat(path: sourcePath, configuration: configuration)
        if sourceInfo.kind == .directory, !recursive {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EISDIR))
        }

        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        if sourceInfo.kind == .directory {
            try fileManager.copyItem(at: source, to: destination)
        } else {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    /// See ``FileSystem/createSymlink(path:target:)``.
    public func createSymlink(path: WorkspacePath, target: String) async throws {
        _ = try WorkspacePath(validating: target, relativeTo: path.dirname)
        let configuration = try requireConfiguration()
        let url = try creationURL(for: path, configuration: configuration)
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    /// See ``FileSystem/createHardLink(path:target:)``.
    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        let configuration = try requireConfiguration()
        let linkURL = try creationURL(for: path, configuration: configuration)
        let targetURL = try existingURL(for: target, configuration: configuration)

        let parent = linkURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.linkItem(at: targetURL, to: linkURL)
    }

    /// See ``FileSystem/readSymlink(path:)``.
    public func readSymlink(path: WorkspacePath) async throws -> String {
        let configuration = try requireConfiguration()
        let url = try existingURL(for: path, configuration: configuration)
        return try fileManager.destinationOfSymbolicLink(atPath: url.path)
    }

    /// See ``FileSystem/setPermissions(path:permissions:)``.
    public func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        let configuration = try requireConfiguration()
        let url = try existingURL(for: path, configuration: configuration)
        try fileManager.setAttributes([.posixPermissions: Int(permissions.rawValue)], ofItemAtPath: url.path)
    }

    /// See ``FileSystem/resolveRealPath(path:)``.
    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        let configuration = try requireConfiguration()
        let url = try existingURL(for: path, configuration: configuration)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        try ensureInsideRoot(resolved, configuration: configuration)
        return virtualPath(from: resolved, configuration: configuration)
    }

    /// See ``FileSystem/exists(path:)``.
    public func exists(path: WorkspacePath) async -> Bool {
        if path.string.contains("\u{0}") {
            return false
        }
        do {
            let configuration = try requireConfiguration()
            let url = try existingOrPotentialURL(for: path, configuration: configuration)
            return fileManager.fileExists(atPath: url.path)
        } catch {
            return false
        }
    }

    /// See ``FileSystem/glob(pattern:currentDirectory:)``.
    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        let normalizedPattern = try WorkspacePath(validating: pattern, relativeTo: currentDirectory)
        if !WorkspacePath.containsGlob(normalizedPattern.string) {
            return await exists(path: normalizedPattern) ? [normalizedPattern] : []
        }

        let regex = try NSRegularExpression(pattern: WorkspacePath.globToRegex(normalizedPattern.string))
        let allPaths = try allVirtualPaths()

        let matches = allPaths.filter { path in
            let range = NSRange(path.string.startIndex..<path.string.endIndex, in: path.string)
            return regex.firstMatch(in: path.string, range: range) != nil
        }

        return matches.sorted()
    }

    private func allVirtualPaths() throws -> [WorkspacePath] {
        let configuration = try requireConfiguration()
        let root = configuration.rootURL
        var paths: [WorkspacePath] = [.root]

        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return paths
        }

        for case let url as URL in enumerator {
            paths.append(virtualPath(from: url, configuration: configuration))
        }

        return paths
    }

    private func existingOrPotentialURL(
        for virtualPath: WorkspacePath,
        configuration: ConfigurationSnapshot
    ) throws -> URL {
        let root = configuration.rootURL
        if virtualPath.isRoot {
            return root
        }

        let relative = String(virtualPath.string.dropFirst())
        return root.appendingPathComponent(relative)
    }

    private func existingURL(
        for virtualPath: WorkspacePath,
        configuration: ConfigurationSnapshot
    ) throws -> URL {
        let url = try existingOrPotentialURL(for: virtualPath, configuration: configuration)
        try ensureInsideRoot(url, configuration: configuration)
        return url
    }

    private func creationURL(
        for virtualPath: WorkspacePath,
        configuration: ConfigurationSnapshot
    ) throws -> URL {
        let url = try existingOrPotentialURL(for: virtualPath, configuration: configuration)
        let parent = url.deletingLastPathComponent()
        try ensureInsideRoot(parent, configuration: configuration)
        return url
    }

    private func ensureInsideRoot(_ url: URL, configuration: ConfigurationSnapshot) throws {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let root = configuration.resolvedRootPath
        guard resolved == root || resolved.hasPrefix(root + "/") else {
            throw WorkspaceError.invalidPath(virtualPath(from: url, configuration: configuration).description)
        }
    }

    private func virtualPath(from physicalURL: URL, configuration: ConfigurationSnapshot) -> WorkspacePath {
        let rootPath = configuration.rootURL.path
        let path = physicalURL.standardizedFileURL.path

        if path == rootPath {
            return .root
        }

        guard path.hasPrefix(rootPath) else {
            return .root
        }

        let start = path.index(path.startIndex, offsetBy: rootPath.count)
        let suffix = String(path[start...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if suffix.isEmpty {
            return .root
        }
        return WorkspacePath(unchecked: "/" + suffix)
    }

    private func requireConfiguration() throws -> ConfigurationSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let rootURL, let resolvedRootPath else {
            throw WorkspaceError.notConfigured
        }
        return ConfigurationSnapshot(rootURL: rootURL, resolvedRootPath: resolvedRootPath)
    }

    private func stat(path: WorkspacePath, configuration: ConfigurationSnapshot) throws -> FileInfo {
        let url = try existingURL(for: path, configuration: configuration)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)

        let fileType = attributes[.type] as? FileAttributeType
        let isDirectory = fileType == .typeDirectory
        let isSymbolicLink = fileType == .typeSymbolicLink
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let permissionBits = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let modificationDate = attributes[.modificationDate] as? Date

        let kind: FileTree.Kind
        if isSymbolicLink {
            kind = .symlink
        } else if isDirectory {
            kind = .directory
        } else {
            kind = .file
        }

        return FileInfo(
            path: path,
            kind: kind,
            size: size,
            permissions: POSIXPermissions(permissionBits),
            modificationDate: modificationDate
        )
    }
}
