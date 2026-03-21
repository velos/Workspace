import Foundation

public final class ReadWriteFilesystem: WorkspaceFilesystem, @unchecked Sendable {
    private let fileManager: FileManager
    private var rootURL: URL?
    private var resolvedRootPath: String?

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public convenience init(rootDirectory: URL, fileManager: FileManager = .default) throws {
        self.init(fileManager: fileManager)
        try configure(rootDirectory: rootDirectory)
    }

    public func configure(rootDirectory: URL) throws {
        let standardized = rootDirectory.standardizedFileURL
        try fileManager.createDirectory(at: standardized, withIntermediateDirectories: true)
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        rootURL = standardized
        resolvedRootPath = resolved.path
    }

    public func stat(path: WorkspacePath) async throws -> FileInfo {
        let normalized = WorkspacePath(normalizing: path.string)
        let url = try existingURL(for: normalized)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)

        let fileType = attributes[.type] as? FileAttributeType
        let isDirectory = fileType == .typeDirectory
        let isSymbolicLink = fileType == .typeSymbolicLink
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let modificationDate = attributes[.modificationDate] as? Date

        return FileInfo(
            path: normalized,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            size: size,
            permissions: permissions,
            modificationDate: modificationDate
        )
    }

    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        let normalized = WorkspacePath(normalizing: path.string)
        let url = try existingURL(for: normalized)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))
        }

        let names = try fileManager.contentsOfDirectory(atPath: url.path).sorted()
        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(names.count)
        for name in names {
            let childPath = normalized.appending(name)
            let info = try await stat(path: childPath)
            entries.append(DirectoryEntry(name: name, info: info))
        }
        return entries
    }

    public func readFile(path: WorkspacePath) async throws -> Data {
        let normalized = WorkspacePath(normalizing: path.string)
        let url = try existingURL(for: normalized)
        return try Data(contentsOf: url)
    }

    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        let normalized = WorkspacePath(normalizing: path.string)
        let url = try creationURL(for: normalized)

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

    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        let normalized = WorkspacePath(normalizing: path.string)
        let url = try creationURL(for: normalized)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: recursive)
    }

    public func remove(path: WorkspacePath, recursive: Bool) async throws {
        let normalized = WorkspacePath(normalizing: path.string)
        let url = try existingURL(for: normalized)

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

    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        let sourcePath = WorkspacePath(normalizing: sourcePath.string)
        let destinationPath = WorkspacePath(normalizing: destinationPath.string)
        let source = try existingURL(for: sourcePath)
        let destination = try creationURL(for: destinationPath)
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: destination)
    }

    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool)
        async throws
    {
        let sourceVirtual = WorkspacePath(normalizing: sourcePath.string)
        let source = try existingURL(for: sourceVirtual)
        let destination = try creationURL(for: WorkspacePath(normalizing: destinationPath.string))

        let sourceInfo = try await stat(path: sourceVirtual)
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

    public func createSymlink(path: WorkspacePath, target: String) async throws {
        try WorkspacePath.validate(target)
        let normalized = WorkspacePath(normalizing: path.string)
        let url = try creationURL(for: normalized)
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        let normalizedLink = WorkspacePath(normalizing: path.string)
        let normalizedTarget = WorkspacePath(normalizing: target.string)
        let linkURL = try creationURL(for: normalizedLink)
        let targetURL = try existingURL(for: normalizedTarget)

        let parent = linkURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.linkItem(at: targetURL, to: linkURL)
    }

    public func readSymlink(path: WorkspacePath) async throws -> String {
        let normalized = WorkspacePath(normalizing: path.string)
        let url = try existingURL(for: normalized)
        return try fileManager.destinationOfSymbolicLink(atPath: url.path)
    }

    public func setPermissions(path: WorkspacePath, permissions: Int) async throws {
        let normalized = WorkspacePath(normalizing: path.string)
        let url = try existingURL(for: normalized)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        let normalized = WorkspacePath(normalizing: path.string)
        let url = try existingURL(for: normalized)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        try ensureInsideRoot(resolved)
        return virtualPath(from: resolved)
    }

    public func exists(path: WorkspacePath) async -> Bool {
        do {
            let normalized = WorkspacePath(normalizing: path.string)
            let url = try existingOrPotentialURL(for: normalized)
            return fileManager.fileExists(atPath: url.path)
        } catch {
            return false
        }
    }

    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try PathUtils.validate(pattern)
        let normalizedPattern = PathUtils.normalize(path: pattern, currentDirectory: currentDirectory.string)
        if !PathUtils.containsGlob(normalizedPattern) {
            let normalizedPath = WorkspacePath(normalizing: normalizedPattern)
            return await exists(path: normalizedPath) ? [normalizedPath] : []
        }

        let regex = try NSRegularExpression(pattern: PathUtils.globToRegex(normalizedPattern))
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
