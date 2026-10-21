import Foundation
import Testing
@testable import Workspace

struct DeviceIdentityTests {
    @Test
    func `persisted equality distinguishes device renumbering from metadata reuse`() throws {
        let original = FileCheckpointStore.SnapshotManifest.Node(
            kind: .file, path: "/file", contentHash: "abc", contentSize: 3,
            identity: FileIdentity(device: 1, inode: 42))
        var renumbered = original
        renumbered.identity = FileIdentity(device: 2, inode: 42)
        #expect(original != renumbered)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(original) != encoder.encode(renumbered))
        #expect(original.isReusable(as: renumbered))
        #expect(renumbered.isReusable(as: original))
        #expect([original] != [renumbered])
        #expect([original].isReusable(as: [renumbered]))
        #expect(![original].isReusable(as: []))
        var replaced = renumbered
        replaced.identity = FileIdentity(device: 2, inode: 43)
        #expect(!original.isReusable(as: replaced))
        #expect(![original].isReusable(as: [replaced]))

        let metadata = MetadataIndex.Entry(info: FileInfo(
            path: "/file", kind: .file, size: 3, permissions: .defaultFile,
            modificationDate: nil, identity: original.identity), target: nil)
        var renumberedMetadata = metadata
        renumberedMetadata.info.identity = renumbered.identity
        #expect(metadata != renumberedMetadata)
        #expect(metadata.isReusable(as: renumberedMetadata))
    }

    @Test(arguments: ["unchanged", "size", "mtime", "racy", "verified", "replacement"])
    func `device renumbering preserves capture reuse without bypassing content guards`(change: String) async throws {
        let root = try TestSupport.temporaryDirectory("DeviceCapture")
        defer { TestSupport.remove(root) }
        let fs = RenumberedDeviceFileSystem(recent: change == "racy")
        try await fs.createDirectory(path: "/dir", recursive: true)
        try await fs.writeFile(path: "/dir/file", data: Data("old".utf8), append: false)
        try await fs.base.createSymlink(path: "/link", target: "dir/file")
        let policy: Workspace.CheckpointCapturePolicy = change == "verified" ? .verifyContents : .trustMetadata
        let id = UUID()
        let first = try await FileCheckpointStore(rootDirectory: root, checkpointCapture: policy).captureRevision(
            from: fs, draft: .init(workspaceID: id, label: nil, preferredParentID: nil, origin: .manual))
        let treesURL = root.appendingPathComponent(id.uuidString).appendingPathComponent("trees")
        let beforeTrees = try treeArtifacts(treesURL)
        await fs.renumber(replacingFile: change == "replacement")
        if change != "unchanged" {
            try await fs.writeFile(path: "/dir/file", data: Data((change == "size" ? "longer" : "new").utf8), append: false)
        }
        if change == "mtime" { await fs.advanceTimestamp() }
        await fs.resetReads()
        // Reopen so the comparison uses persisted identities, including nested trees.
        let reopened = FileCheckpointStore(rootDirectory: root, checkpointCapture: policy)
        let second = try await reopened.captureRevision(from: fs, draft: .init(
            workspaceID: id, label: nil, preferredParentID: first.id, origin: .manual))
        #expect(await fs.reads == (change == "unchanged" ? [] : ["/dir/file"]))
        #expect(second.summary.touchedPaths == (change == "unchanged" ? [] : ["/dir/file"]))
        let expected = change == "unchanged" ? "old" : change == "size" ? "longer" : "new"
        #expect(try await reopened.readSnapshotFile(id: second.snapshotId, workspaceId: id,
            path: "/dir/file", offset: 0, length: nil) == Data(expected.utf8))
        if change == "unchanged" { #expect(try treeArtifacts(treesURL) == beforeTrees) }
    }

    @Test(arguments: [false, true], [false, true])
    func `device renumbering retains diff and restore fast paths and the racy window`(disk: Bool, recent: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("DeviceComparison")
        defer { TestSupport.remove(root) }
        let fs = RenumberedDeviceFileSystem(recent: recent)
        try await fs.createDirectory(path: "/dir", recursive: true)
        try await fs.writeFile(path: "/dir/file", data: Data("old".utf8), append: false)
        var workspace = Workspace(fileSystem: fs, persistence: disk ? .directory(root) : .memory)
        let checkpoint = try await workspace.createCheckpoint()
        if disk {
            workspace = Workspace(workspaceID: workspace.workspaceID, fileSystem: fs, persistence: .directory(root))
        }
        await fs.renumber()
        await fs.resetReads()
        #expect(try await workspace.diff(from: .checkpoint(checkpoint.id), to: .current).isEmpty)
        #expect(await fs.reads == (recent ? ["/dir/file"] : []))
        await fs.resetReads()
        _ = try await workspace.restore(to: checkpoint)
        #expect(await fs.reads == (recent ? ["/dir/file"] : []))
        #expect(try await workspace.history().isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func `transactions tolerate device renumbering while verifying racy contents`(disk: Bool, recent: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("DeviceTransaction")
        defer { TestSupport.remove(root) }
        let fs = RenumberedDeviceFileSystem(recent: recent)
        try await fs.createDirectory(path: "/dir", recursive: true)
        try await fs.writeFile(path: "/dir/file", data: Data("old".utf8), append: false)
        let workspace = Workspace(fileSystem: fs, persistence: disk ? .directory(root) : .memory)
        // Keep the cold directory base alive so both storage modes have cached bytes.
        let first = try await workspace.beginTransaction()
        await fs.renumber()
        if recent {
            try await fs.writeFile(path: "/dir/file", data: Data("new".utf8), append: false)
        }
        await fs.resetReads()
        let second = try await workspace.beginTransaction()
        #expect(await fs.reads == (recent ? ["/dir/file"] : []))
        #expect(try await second.readText("/dir/file") == (recent ? "new" : "old"))
        try await second.discard()
        try await first.discard()
    }

    private func treeArtifacts(_ directory: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
}

/// Models remounts and in-place writes independently of the underlying memory backend.
private actor RenumberedDeviceFileSystem: FileSystem {
    let base = InMemoryFileSystem()
    private var device: UInt64 = 1
    private var fileInode: UInt64 = 3
    private var timestamp: Date
    var reads: [WorkspacePath] = []
    init(recent: Bool) { timestamp = recent ? .distantFuture : Date(timeIntervalSince1970: 1_000) }
    func renumber(replacingFile: Bool = false) {
        device += 1
        if replacingFile { fileInode += 1 }
    }
    func advanceTimestamp() { timestamp.addTimeInterval(10) }
    func resetReads() { reads = [] }
    private func metadata(_ info: FileInfo) -> FileInfo {
        var info = info
        let inode: UInt64 = info.path.isRoot ? 1 : info.kind == .directory ? 2 : info.kind == .file ? fileInode : 10
        info.identity = FileIdentity(device: device, inode: inode)
        info.modificationDate = timestamp
        return info
    }
    func stat(path: WorkspacePath) async throws -> FileInfo { metadata(try await base.stat(path: path)) }
    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await base.listDirectory(path: path).map { .init(name: $0.name, info: metadata($0.info)) }
    }
    func readFile(path: WorkspacePath) async throws -> Data {
        reads.append(path)
        return try await base.readFile(path: path)
    }
    func readSymlink(path: WorkspacePath) async throws -> String { try await base.readSymlink(path: path) }
    func exists(path: WorkspacePath) async -> Bool { await base.exists(path: path) }
    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try await base.glob(pattern: pattern, currentDirectory: currentDirectory)
    }
    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws { try await base.writeFile(path: path, data: data, append: append) }
    func createDirectory(path: WorkspacePath, recursive: Bool) async throws { try await base.createDirectory(path: path, recursive: recursive) }
    func remove(path: WorkspacePath, recursive: Bool) async throws { try await base.remove(path: path, recursive: recursive) }
    func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws { try await base.move(from: sourcePath, to: destinationPath) }
    func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool) async throws {
        try await base.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }
}
