import Foundation
@testable import Workspace

enum TestSupport {
    static func temporaryDirectory(_ prefix: String = "WorkspaceTests") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

enum TestFileSystemError: Error { case injected }

actor HookableFileSystem: FileSystem, ExactTimestampFileSystem, TraversingFileSystem {
    var hasExactContentTimestamps: Bool { get async { await base.supportsExactContentTimestamps } }
    let base: any FileSystem
    var reads: [WorkspacePath] = []
    var statCount = 0
    var walks: [WorkspacePath] = []
    private let scopedWalk: Bool
    nonisolated var supportsScopedWalk: Bool { scopedWalk && base.supportsScopedWalk }
    nonisolated(nonsending) func walk(at path: WorkspacePath, skippingUnreadableDirectories: Bool, skippingVanishedEntries: Bool = false,
                                     visit: FileSystemWalkVisitor) async throws {
        guard supportsScopedWalk else {
            return try await walkUsingPaths(at: path, skippingUnreadableDirectories: skippingUnreadableDirectories,
                skippingVanishedEntries: skippingVanishedEntries, visit: visit)
        }
        await recordWalk(path)
        try await base.walk(at: path, skippingUnreadableDirectories: skippingUnreadableDirectories,
            skippingVanishedEntries: skippingVanishedEntries, visit: visit)
    }
    private func recordWalk(_ path: WorkspacePath) { walks.append(path) }
    func resetMetadataCounts() { walks = []; statCount = 0; listings = [] }
    var listings: [WorkspacePath] = []
    var writes: [WorkspacePath] = []
    var permissionWrites: [(path: WorkspacePath, permissions: POSIXPermissions)] = []
    private let forwardsPermissions: Bool
    private let transformRead: (@Sendable (Data) -> Data)?
    private var writeHook: (@Sendable (WorkspacePath) async throws -> Void)?
    private var readHook: (@Sendable (WorkspacePath) async throws -> Void)?
    private var readFailure = false
    private var statError: NSError?
    func failStat(_ error: NSError?) { statError = error }
    var unreadable: Set<WorkspacePath> = []
    func denyReads(at path: WorkspacePath) { unreadable.insert(path) }
    private var removeFailure = false
    func failRemovals() { removeFailure = true }

    init(base: any FileSystem = InMemoryFileSystem(), forwardsPermissions: Bool = false, scopedWalk: Bool = false,
         transformRead: (@Sendable (Data) -> Data)? = nil) {
        self.base = base
        self.forwardsPermissions = forwardsPermissions
        self.scopedWalk = scopedWalk
        self.transformRead = transformRead
    }
    func onWrite(_ hook: @escaping @Sendable (WorkspacePath) async throws -> Void) { writeHook = hook }
    func onRead(_ hook: @escaping @Sendable (WorkspacePath) async throws -> Void) { readHook = hook }
    func failNextRead() { readFailure = true }
    func stat(path: WorkspacePath) async throws -> FileInfo {
        statCount += 1
        if let statError { throw statError }
        return try await base.stat(path: path)
    }
    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        listings.append(path)
        return try await base.listDirectory(path: path)
    }
    func exists(path: WorkspacePath) async -> Bool { await base.exists(path: path) }
    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try await base.glob(pattern: pattern, currentDirectory: currentDirectory)
    }
    func readSymlink(path: WorkspacePath) async throws -> String { try await base.readSymlink(path: path) }
    func readFile(path: WorkspacePath) async throws -> Data {
        reads.append(path)
        if unreadable.contains(path) { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
        let hook = readHook
        readHook = nil
        try await hook?(path)
        if readFailure { readFailure = false; throw TestFileSystemError.injected }
        let data = try await base.readFile(path: path)
        return transformRead?(data) ?? data
    }
    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        writes.append(path)
        let hook = writeHook
        writeHook = nil
        try await hook?(path)
        if path == "/fail" { throw TestFileSystemError.injected }
        try await base.writeFile(path: path, data: data, append: append)
    }
    func createDirectory(path: WorkspacePath, recursive: Bool) async throws { try await base.createDirectory(path: path, recursive: recursive) }
    func remove(path: WorkspacePath, recursive: Bool) async throws {
        if removeFailure { throw TestFileSystemError.injected }
        try await base.remove(path: path, recursive: recursive)
    }
    func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        permissionWrites.append((path, permissions))
        guard forwardsPermissions else {
            throw WorkspaceError.unsupported("setting permissions is not supported by this filesystem")
        }
        try await base.setPermissions(path: path, permissions: permissions)
    }
    func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws { try await base.move(from: sourcePath, to: destinationPath) }
    func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool) async throws {
        try await base.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }
}

actor TestSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signaled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
