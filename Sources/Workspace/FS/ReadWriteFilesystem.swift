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

    public func stat(path: String) async throws -> FileInfo {
        try PathUtils.validate(path)
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
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

    public func listDirectory(path: String) async throws -> [DirectoryEntry] {
        try PathUtils.validate(path)
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        let url = try existingURL(for: normalized)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))
        }

        let names = try fileManager.contentsOfDirectory(atPath: url.path).sorted()
        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(names.count)
        for name in names {
            let childPath = PathUtils.join(normalized, name)
            let info = try await stat(path: childPath)
            entries.append(DirectoryEntry(name: name, info: info))
        }
        return entries
    }

    public func readFile(path: String) async throws -> Data {
        try PathUtils.validate(path)
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        let url = try existingURL(for: normalized)
        return try Data(contentsOf: url)
    }

    public func writeFile(path: String, data: Data, append: Bool) async throws {
        try PathUtils.validate(path)
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
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

    public func createDirectory(path: String, recursive: Bool) async throws {
        try PathUtils.validate(path)
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        let url = try creationURL(for: normalized)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: recursive)
    }

    public func remove(path: String, recursive: Bool) async throws {
        try PathUtils.validate(path)
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
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

    public func move(from sourcePath: String, to destinationPath: String) async throws {
        try PathUtils.validate(sourcePath)
        try PathUtils.validate(destinationPath)
        let source = try existingURL(for: PathUtils.normalize(path: sourcePath, currentDirectory: "/"))
        let destination = try creationURL(for: PathUtils.normalize(path: destinationPath, currentDirectory: "/"))
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: destination)
    }

    public func copy(from sourcePath: String, to destinationPath: String, recursive: Bool) async throws {
        try PathUtils.validate(sourcePath)
        try PathUtils.validate(destinationPath)
        let sourceVirtual = PathUtils.normalize(path: sourcePath, currentDirectory: "/")
        let source = try existingURL(for: sourceVirtual)
        let destination = try creationURL(for: PathUtils.normalize(path: destinationPath, currentDirectory: "/"))

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

    public func createSymlink(path: String, target: String) async throws {
        try PathUtils.validate(path)
        try PathUtils.validate(target)
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        let url = try creationURL(for: normalized)
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    public func createHardLink(path: String, target: String) async throws {
        try PathUtils.validate(path)
        try PathUtils.validate(target)
        let normalizedLink = PathUtils.normalize(path: path, currentDirectory: "/")
        let normalizedTarget = PathUtils.normalize(path: target, currentDirectory: "/")
        let linkURL = try creationURL(for: normalizedLink)
        let targetURL = try existingURL(for: normalizedTarget)

        let parent = linkURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.linkItem(at: targetURL, to: linkURL)
    }

    public func readSymlink(path: String) async throws -> String {
        try PathUtils.validate(path)
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        let url = try existingURL(for: normalized)
        return try fileManager.destinationOfSymbolicLink(atPath: url.path)
    }

    public func setPermissions(path: String, permissions: Int) async throws {
        try PathUtils.validate(path)
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        let url = try existingURL(for: normalized)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    public func resolveRealPath(path: String) async throws -> String {
        try PathUtils.validate(path)
        let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
        let url = try existingURL(for: normalized)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        try ensureInsideRoot(resolved)
        return virtualPath(from: resolved)
    }

    public func exists(path: String) async -> Bool {
        do {
            try PathUtils.validate(path)
            let normalized = PathUtils.normalize(path: path, currentDirectory: "/")
            let url = try existingOrPotentialURL(for: normalized)
            return fileManager.fileExists(atPath: url.path)
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
        let allPaths = try allVirtualPaths()

        let matches = allPaths.filter { path in
            let range = NSRange(path.startIndex..<path.endIndex, in: path)
            return regex.firstMatch(in: path, range: range) != nil
        }

        return matches.sorted()
    }

    private func allVirtualPaths() throws -> [String] {
        let root = try requireRoot()
        var paths = ["/"]

        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return paths
        }

        for case let url as URL in enumerator {
            paths.append(virtualPath(from: url))
        }

        return paths
    }

    private func existingOrPotentialURL(for virtualPath: String) throws -> URL {
        let root = try requireRoot()
        let absolute = virtualPath.hasPrefix("/") ? virtualPath : "/\(virtualPath)"
        if absolute == "/" {
            return root
        }

        let relative = String(absolute.dropFirst())
        return root.appendingPathComponent(relative)
    }

    private func existingURL(for virtualPath: String) throws -> URL {
        let url = try existingOrPotentialURL(for: virtualPath)
        try ensureInsideRoot(url)
        return url
    }

    private func creationURL(for virtualPath: String) throws -> URL {
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
            throw ShellError.invalidPath(virtualPath(from: url))
        }
    }

    private func virtualPath(from physicalURL: URL) -> String {
        guard let root = try? requireRoot() else {
            return "/"
        }

        let rootPath = root.path
        let path = physicalURL.standardizedFileURL.path

        if path == rootPath {
            return "/"
        }

        guard path.hasPrefix(rootPath) else {
            return "/"
        }

        let start = path.index(path.startIndex, offsetBy: rootPath.count)
        let suffix = String(path[start...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if suffix.isEmpty {
            return "/"
        }
        return "/" + suffix
    }

    private func requireRoot() throws -> URL {
        guard let rootURL else {
            throw ShellError.unsupported("filesystem is not configured")
        }
        return rootURL
    }
}
