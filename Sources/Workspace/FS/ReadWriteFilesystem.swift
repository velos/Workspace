import Foundation

/// A disk-backed filesystem rooted at a concrete directory on the host filesystem.
///
/// Paths are resolved relative to the configured root and constrained so callers cannot escape that root
/// through traversal or symlink resolution.
public final class ReadWriteFilesystem: WorkspaceFilesystem, @unchecked Sendable {
    private let fileManager: FileManager
    private var rootURL: URL?
    private var resolvedRootPath: String?

    /// Creates an unconfigured disk-backed filesystem.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Creates and configures a disk-backed filesystem rooted at `rootDirectory`.
    public convenience init(rootDirectory: URL, fileManager: FileManager = .default) throws {
        self.init(fileManager: fileManager)
        try configure(rootDirectory: rootDirectory)
    }

    /// See ``WorkspaceFilesystem/configure(rootDirectory:)``.
    public func configure(rootDirectory: URL) throws {
        let standardized = rootDirectory.standardizedFileURL
        try fileManager.createDirectory(at: standardized, withIntermediateDirectories: true)
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        rootURL = standardized
        resolvedRootPath = resolved.path
    }

    /// See ``WorkspaceFilesystem/stat(path:)``.
    public func stat(path: WorkspacePath) async throws -> FileInfo {
        let url = try existingURL(for: path)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)

        let fileType = attributes[.type] as? FileAttributeType
        let isDirectory = fileType == .typeDirectory
        let isSymbolicLink = fileType == .typeSymbolicLink
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let modificationDate = attributes[.modificationDate] as? Date

        return FileInfo(
            path: path,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            size: size,
            permissions: permissions,
            modificationDate: modificationDate
        )
    }

    /// See ``WorkspaceFilesystem/listDirectory(path:)``.
    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        let url = try existingURL(for: path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))
        }

        let names = try fileManager.contentsOfDirectory(atPath: url.path).sorted()
        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(names.count)
        for name in names {
            let childPath = path.appending(name)
            let info = try await stat(path: childPath)
            entries.append(DirectoryEntry(name: name, info: info))
        }
        return entries
    }

    /// See ``WorkspaceFilesystem/readFile(path:)``.
    public func readFile(path: WorkspacePath) async throws -> Data {
        let url = try existingURL(for: path)
        return try Data(contentsOf: url)
    }

    /// See ``WorkspaceFilesystem/writeFile(path:data:append:)``.
    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        let url = try creationURL(for: path)

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

    /// See ``WorkspaceFilesystem/createDirectory(path:recursive:)``.
    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        let url = try creationURL(for: path)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: recursive)
    }

    /// See ``WorkspaceFilesystem/remove(path:recursive:)``.
    public func remove(path: WorkspacePath, recursive: Bool) async throws {
        let url = try existingURL(for: path)

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

    /// See ``WorkspaceFilesystem/move(from:to:)``.
    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        let source = try existingURL(for: sourcePath)
        let destination = try creationURL(for: destinationPath)
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: destination)
    }

    /// See ``WorkspaceFilesystem/copy(from:to:recursive:)``.
    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool)
        async throws
    {
        let source = try existingURL(for: sourcePath)
        let destination = try creationURL(for: destinationPath)

        let sourceInfo = try await stat(path: sourcePath)
        if sourceInfo.isDirectory, !recursive {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EISDIR))
        }

        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        if sourceInfo.isDirectory {
            try fileManager.copyItem(at: source, to: destination)
        } else {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    /// See ``WorkspaceFilesystem/createSymlink(path:target:)``.
    public func createSymlink(path: WorkspacePath, target: String) async throws {
        _ = try WorkspacePath(validating: target, relativeTo: path.dirname)
        let url = try creationURL(for: path)
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    /// See ``WorkspaceFilesystem/createHardLink(path:target:)``.
    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        let linkURL = try creationURL(for: path)
        let targetURL = try existingURL(for: target)

        let parent = linkURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.linkItem(at: targetURL, to: linkURL)
    }

    /// See ``WorkspaceFilesystem/readSymlink(path:)``.
    public func readSymlink(path: WorkspacePath) async throws -> String {
        let url = try existingURL(for: path)
        return try fileManager.destinationOfSymbolicLink(atPath: url.path)
    }

    /// See ``WorkspaceFilesystem/setPermissions(path:permissions:)``.
    public func setPermissions(path: WorkspacePath, permissions: Int) async throws {
        let url = try existingURL(for: path)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    /// See ``WorkspaceFilesystem/resolveRealPath(path:)``.
    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        let url = try existingURL(for: path)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        try ensureInsideRoot(resolved)
        return virtualPath(from: resolved)
    }

    /// See ``WorkspaceFilesystem/exists(path:)``.
    public func exists(path: WorkspacePath) async -> Bool {
        do {
            let url = try existingOrPotentialURL(for: path)
            return fileManager.fileExists(atPath: url.path)
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
        let allPaths = try allVirtualPaths()

        let matches = allPaths.filter { path in
            let range = NSRange(path.string.startIndex..<path.string.endIndex, in: path.string)
            return regex.firstMatch(in: path.string, range: range) != nil
        }

        return matches.sorted()
    }

    private func allVirtualPaths() throws -> [WorkspacePath] {
        let root = try requireRoot()
        var paths: [WorkspacePath] = [.root]

        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return paths
        }

        for case let url as URL in enumerator {
            paths.append(virtualPath(from: url))
        }

        return paths
    }

    private func existingOrPotentialURL(for virtualPath: WorkspacePath) throws -> URL {
        let root = try requireRoot()
        if virtualPath.isRoot {
            return root
        }

        let relative = String(virtualPath.string.dropFirst())
        return root.appendingPathComponent(relative)
    }

    private func existingURL(for virtualPath: WorkspacePath) throws -> URL {
        let url = try existingOrPotentialURL(for: virtualPath)
        try ensureInsideRoot(url)
        return url
    }

    private func creationURL(for virtualPath: WorkspacePath) throws -> URL {
        let url = try existingOrPotentialURL(for: virtualPath)
        let parent = url.deletingLastPathComponent()
        try ensureInsideRoot(parent)
        return url
    }

    private func ensureInsideRoot(_ url: URL) throws {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard let root = resolvedRootPath else {
            throw ShellError.unsupported("filesystem is not configured")
        }
        guard resolved == root || resolved.hasPrefix(root + "/") else {
            throw ShellError.invalidPath(virtualPath(from: url).description)
        }
    }

    private func virtualPath(from physicalURL: URL) -> WorkspacePath {
        guard let root = try? requireRoot() else {
            return .root
        }

        let rootPath = root.path
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

    private func requireRoot() throws -> URL {
        guard let rootURL else {
            throw ShellError.unsupported("filesystem is not configured")
        }
        return rootURL
    }
}
