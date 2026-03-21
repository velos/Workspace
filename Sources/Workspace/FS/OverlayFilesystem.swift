import Foundation

public final class OverlayFilesystem: WorkspaceFilesystem, @unchecked Sendable {
    private let fileManager: FileManager
    private let overlay: InMemoryFilesystem
    private var rootURL: URL?

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        overlay = InMemoryFilesystem()
    }

    public convenience init(rootDirectory: URL, fileManager: FileManager = .default) throws {
        self.init(fileManager: fileManager)
        try configure(rootDirectory: rootDirectory)
    }

    public func configure(rootDirectory: URL) throws {
        rootURL = rootDirectory.standardizedFileURL
        try reload()
    }

    public func reload() throws {
        guard rootURL != nil else {
            throw ShellError.unsupported("overlay filesystem requires rootDirectory")
        }
        try rebuildOverlay()
    }

    public func stat(path: WorkspacePath) async throws -> FileInfo {
        try await overlay.stat(path: path)
    }

    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await overlay.listDirectory(path: path)
    }

    public func readFile(path: WorkspacePath) async throws -> Data {
        try await overlay.readFile(path: path)
    }

    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        try await overlay.writeFile(path: path, data: data, append: append)
    }

    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        try await overlay.createDirectory(path: path, recursive: recursive)
    }

    public func remove(path: WorkspacePath, recursive: Bool) async throws {
        try await overlay.remove(path: path, recursive: recursive)
    }

    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        try await overlay.move(from: sourcePath, to: destinationPath)
    }

    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool)
        async throws
    {
        try await overlay.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }

    public func createSymlink(path: WorkspacePath, target: String) async throws {
        try await overlay.createSymlink(path: path, target: target)
    }

    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        try await overlay.createHardLink(path: path, target: target)
    }

    public func readSymlink(path: WorkspacePath) async throws -> String {
        try await overlay.readSymlink(path: path)
    }

    public func setPermissions(path: WorkspacePath, permissions: Int) async throws {
        try await overlay.setPermissions(path: path, permissions: permissions)
    }

    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        try await overlay.resolveRealPath(path: path)
    }

    public func exists(path: WorkspacePath) async -> Bool {
        await overlay.exists(path: path)
    }

    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try await overlay.glob(pattern: pattern, currentDirectory: currentDirectory)
    }

    private func rebuildOverlay() throws {
        overlay.reset()

        guard let rootURL else {
            return
        }

        guard fileManager.fileExists(atPath: rootURL.path) else {
            return
        }

        let names = try fileManager.contentsOfDirectory(atPath: rootURL.path).sorted()
        for name in names {
            let childURL = rootURL.appendingPathComponent(name, isDirectory: true)
            try importItem(at: childURL, virtualPath: WorkspacePath.root.appending(name))
        }
    }

    private func importItem(at url: URL, virtualPath: WorkspacePath) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue

        if values.isSymbolicLink == true {
            let target = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            try performAsync {
                try await self.overlay.createSymlink(path: virtualPath, target: target)
                if let permissions {
                    try await self.overlay.setPermissions(path: virtualPath, permissions: permissions)
                }
            }
            return
        }

        if values.isDirectory == true {
            try performAsync {
                try await self.overlay.createDirectory(path: virtualPath, recursive: true)
                if let permissions {
                    try await self.overlay.setPermissions(path: virtualPath, permissions: permissions)
                }
            }

            let children = try fileManager.contentsOfDirectory(atPath: url.path).sorted()
            for child in children {
                let childURL = url.appendingPathComponent(child, isDirectory: true)
                try importItem(at: childURL, virtualPath: virtualPath.appending(child))
            }
            return
        }

        let data = try Data(contentsOf: url)
        try performAsync {
            try await self.overlay.writeFile(path: virtualPath, data: data, append: false)
            if let permissions {
                try await self.overlay.setPermissions(path: virtualPath, permissions: permissions)
            }
        }
    }

    private func performAsync(
        _ operation: @escaping @Sendable () async throws -> Void
    ) throws {
        let semaphore = DispatchSemaphore(value: 0)
        final class ErrorBox: @unchecked Sendable {
            var error: Error?
        }
        let box = ErrorBox()

        Task {
            defer { semaphore.signal() }
            do {
                try await operation()
            } catch {
                box.error = error
            }
        }

        semaphore.wait()
        if let error = box.error {
            throw error
        }
    }
}
