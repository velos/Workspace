import Foundation
import Testing
@testable import Workspace

private enum WorkspaceTestSupport {
    static func makeTempDirectory(prefix: String = "WorkspaceTests") throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class FailOnceFilesystem: FileSystem, @unchecked Sendable {
    private let base: any FileSystem
    private let failingWritePaths: Set<WorkspacePath>
    private var failedWritePaths: Set<WorkspacePath> = []

    init(base: any FileSystem, failingWritePaths: Set<WorkspacePath>) {
        self.base = base
        self.failingWritePaths = failingWritePaths
    }

    func configure(rootDirectory: URL) async throws {
        try await base.configure(rootDirectory: rootDirectory)
    }

    func stat(path: WorkspacePath) async throws -> FileInfo {
        try await base.stat(path: path)
    }

    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await base.listDirectory(path: path)
    }

    func readFile(path: WorkspacePath) async throws -> Data {
        try await base.readFile(path: path)
    }

    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        if failingWritePaths.contains(path), !failedWritePaths.contains(path) {
            failedWritePaths.insert(path)
            throw WorkspaceError.unsupported("forced write failure")
        }
        try await base.writeFile(path: path, data: data, append: append)
    }

    func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        try await base.createDirectory(path: path, recursive: recursive)
    }

    func remove(path: WorkspacePath, recursive: Bool) async throws {
        try await base.remove(path: path, recursive: recursive)
    }

    func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        try await base.move(from: sourcePath, to: destinationPath)
    }

    func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool) async throws {
        try await base.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }

    func createSymlink(path: WorkspacePath, target: String) async throws {
        try await base.createSymlink(path: path, target: target)
    }

    func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        try await base.createHardLink(path: path, target: target)
    }

    func readSymlink(path: WorkspacePath) async throws -> String {
        try await base.readSymlink(path: path)
    }

    func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        try await base.setPermissions(path: path, permissions: permissions)
    }

    func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        try await base.resolveRealPath(path: path)
    }

    func exists(path: WorkspacePath) async -> Bool {
        await base.exists(path: path)
    }

    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try await base.glob(pattern: pattern, currentDirectory: currentDirectory)
    }
}

private final class NSErrorFailOnceFilesystem: FileSystem, @unchecked Sendable {
    private let base: any FileSystem
    private let failingWritePaths: Set<WorkspacePath>
    private var failedWritePaths: Set<WorkspacePath> = []

    init(base: any FileSystem, failingWritePaths: Set<WorkspacePath>) {
        self.base = base
        self.failingWritePaths = failingWritePaths
    }

    func configure(rootDirectory: URL) async throws {
        try await base.configure(rootDirectory: rootDirectory)
    }

    func stat(path: WorkspacePath) async throws -> FileInfo {
        try await base.stat(path: path)
    }

    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await base.listDirectory(path: path)
    }

    func readFile(path: WorkspacePath) async throws -> Data {
        try await base.readFile(path: path)
    }

    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        if failingWritePaths.contains(path), !failedWritePaths.contains(path) {
            failedWritePaths.insert(path)
            throw NSError(domain: "WorkspaceTests", code: 42, userInfo: [NSLocalizedDescriptionKey: "forced NSError write failure"])
        }
        try await base.writeFile(path: path, data: data, append: append)
    }

    func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        try await base.createDirectory(path: path, recursive: recursive)
    }

    func remove(path: WorkspacePath, recursive: Bool) async throws {
        try await base.remove(path: path, recursive: recursive)
    }

    func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        try await base.move(from: sourcePath, to: destinationPath)
    }

    func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool) async throws {
        try await base.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }

    func createSymlink(path: WorkspacePath, target: String) async throws {
        try await base.createSymlink(path: path, target: target)
    }

    func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        try await base.createHardLink(path: path, target: target)
    }

    func readSymlink(path: WorkspacePath) async throws -> String {
        try await base.readSymlink(path: path)
    }

    func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        try await base.setPermissions(path: path, permissions: permissions)
    }

    func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        try await base.resolveRealPath(path: path)
    }

    func exists(path: WorkspacePath) async -> Bool {
        await base.exists(path: path)
    }

    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try await base.glob(pattern: pattern, currentDirectory: currentDirectory)
    }
}

private final class MinimalFilesystem: FileSystem, @unchecked Sendable {
    private let base = InMemoryFilesystem()

    func stat(path: WorkspacePath) async throws -> FileInfo {
        try await base.stat(path: path)
    }

    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await base.listDirectory(path: path)
    }

    func readFile(path: WorkspacePath) async throws -> Data {
        try await base.readFile(path: path)
    }

    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        try await base.writeFile(path: path, data: data, append: append)
    }

    func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        try await base.createDirectory(path: path, recursive: recursive)
    }

    func remove(path: WorkspacePath, recursive: Bool) async throws {
        try await base.remove(path: path, recursive: recursive)
    }

    func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        try await base.move(from: sourcePath, to: destinationPath)
    }

    func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool) async throws {
        try await base.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }

    func exists(path: WorkspacePath) async -> Bool {
        await base.exists(path: path)
    }

    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try await base.glob(pattern: pattern, currentDirectory: currentDirectory)
    }
}

private actor ChangeEventRecorder {
    private var events: [ChangeEvent] = []

    func append(_ event: ChangeEvent) {
        events.append(event)
    }

    func snapshot() -> [ChangeEvent] {
        events
    }
}

private enum ChangeWatchTestError: Error {
    case timeout(expected: Int, actual: Int)
}

private func startRecording(
    _ stream: AsyncStream<ChangeEvent>,
    into recorder: ChangeEventRecorder
) -> Task<Void, Never> {
    Task {
        for await event in stream {
            await recorder.append(event)
        }
    }
}

private func waitForRecordedEvents(
    _ expectedCount: Int,
    recorder: ChangeEventRecorder,
    timeout: Duration = .seconds(1)
) async throws -> [ChangeEvent] {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while clock.now < deadline {
        let snapshot = await recorder.snapshot()
        if snapshot.count >= expectedCount {
            return Array(snapshot.prefix(expectedCount))
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    let snapshot = await recorder.snapshot()
    throw ChangeWatchTestError.timeout(expected: expectedCount, actual: snapshot.count)
}

private func waitForSettledEvents(
    recorder: ChangeEventRecorder,
    settling: Duration = .milliseconds(50)
) async throws -> [ChangeEvent] {
    try await Task.sleep(for: settling)
    return await recorder.snapshot()
}

private struct DemoConfig: Codable, Equatable, Sendable {
    var name: String
    var enabled: Bool
}

private func diffLines(_ diff: TextDiff?) -> [TextDiff.Line] {
    diff?.hunks.flatMap(\.lines) ?? []
}

private func addedLineTexts(_ diff: TextDiff?) -> [String] {
    diffLines(diff).filter { $0.kind == .added }.map(\.text)
}

private func removedLineTexts(_ diff: TextDiff?) -> [String] {
    diffLines(diff).filter { $0.kind == .removed }.map(\.text)
}

private func assertBasicWatchSemantics(
    workspace: Workspace,
    watchedPath: WorkspacePath
) async throws {
    let recorder = ChangeEventRecorder()
    let stream = await workspace.watchChanges(at: watchedPath, recursive: false)
    let task = startRecording(stream, into: recorder)
    defer { task.cancel() }

    try await workspace.writeFile(watchedPath, content: "one")
    try await workspace.writeFile(watchedPath, content: "two")
    try await workspace.removeItem(at: watchedPath)

    let events = try await waitForRecordedEvents(3, recorder: recorder)
    #expect(
        events == [
            ChangeEvent(kind: .created, path: watchedPath, nodeKind: .file),
            ChangeEvent(kind: .modified, path: watchedPath, nodeKind: .file),
            ChangeEvent(kind: .deleted, path: watchedPath, nodeKind: .file),
        ]
    )
}

@Suite("Workspace")
struct WorkspaceTests {
    @Test
    func `workspace module reexports core filesystem primitives`() async throws {
        let workspaceFilesystem: any FileSystem = InMemoryFilesystem()
        let mount = MountableFilesystem.Mount(mountPoint: "/memory", filesystem: InMemoryFilesystem())
        let permission = PermissionRequest(operation: .readFile, path: "/memory/note.txt")
        let error = WorkspaceError.unsupported("workspace shim check")

        #expect(await workspaceFilesystem.exists(path: "/"))
        #expect(mount.mountPoint == "/memory")
        #expect(permission.path == "/memory/note.txt")
        #expect(error.description.contains("workspace shim check"))
    }

    @Test
    func `readJSON and writeJSON roundtrip`() async throws {
        let fs = InMemoryFilesystem()
        let state = Workspace(filesystem: fs)

        try await state.writeJSON(DemoConfig(name: "demo", enabled: true), to: "/config.json")
        let loaded: DemoConfig = try await state.readJSON(from: "/config.json")
        #expect(loaded == DemoConfig(name: "demo", enabled: true))
    }

    @Test
    func `workspace supports binary data appends directory listings and globbing`() async throws {
        let state = Workspace(filesystem: InMemoryFilesystem())

        try await state.createDirectory(at: "/", recursive: false)
        try await state.createDirectory(at: "/docs", recursive: false)
        try await state.writeData(Data([0xDE, 0xAD, 0xBE, 0xEF]), to: "/docs/blob.bin")
        try await state.writeFile("/docs/note.txt", content: "one")
        try await state.appendFile("/docs/note.txt", content: " two")

        #expect(try await state.readData(from: "/docs/blob.bin") == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(try await state.readFile("/docs/note.txt") == "one two")

        let info = try await state.fileInfo(at: "/docs/note.txt")
        #expect(info.kind == .file)
        #expect(info.size == 7)

        let entries = try await state.listDirectory(at: "/docs")
        #expect(entries.map(\.name) == ["blob.bin", "note.txt"])

        let globbed = try await state.glob("/docs/*", currentDirectory: "/")
        #expect(globbed == ["/docs/blob.bin", "/docs/note.txt"])
        #expect(await state.exists("/docs/blob.bin"))

        do {
            _ = try await state.readFile("/docs/blob.bin")
            Issue.record("expected invalid UTF-8 error")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("not valid UTF-8"))
        }
    }

    @Test(.tags(.watching))
    func `watchChanges emits create modify and delete for a file`() async throws {
        let state = Workspace(filesystem: InMemoryFilesystem())
        let recorder = ChangeEventRecorder()
        let stream = await state.watchChanges(at: "/note.txt", recursive: false)
        let task = startRecording(stream, into: recorder)
        defer { task.cancel() }

        try await state.writeFile("/note.txt", content: "one")
        try await state.writeFile("/note.txt", content: "one")
        try await state.writeFile("/note.txt", content: "two")
        try await state.removeItem(at: "/note.txt")

        let events = try await waitForRecordedEvents(3, recorder: recorder)
        #expect(
            events == [
                ChangeEvent(kind: .created, path: "/note.txt", nodeKind: .file),
                ChangeEvent(kind: .modified, path: "/note.txt", nodeKind: .file),
                ChangeEvent(kind: .deleted, path: "/note.txt", nodeKind: .file),
            ]
        )
    }

    @Test(.tags(.watching))
    func `watchChanges recursively emits directory file and symlink copy events`() async throws {
        let fs = InMemoryFilesystem()
        try await fs.createDirectory(path: "/docs/archive", recursive: true)
        try await fs.writeFile(path: "/docs/archive/file.txt", data: Data("hello".utf8), append: false)
        try await fs.createSymlink(path: "/docs/archive/link.txt", target: "file.txt")
        let state = Workspace(filesystem: fs)

        let recorder = ChangeEventRecorder()
        let stream = await state.watchChanges(at: "/docs")
        let task = startRecording(stream, into: recorder)
        defer { task.cancel() }

        try await state.copyItem(from: "/docs/archive", to: "/docs/copy")

        let events = try await waitForRecordedEvents(3, recorder: recorder)
        #expect(
            events == [
                ChangeEvent(
                    kind: .copied,
                    path: "/docs/copy",
                    sourcePath: "/docs/archive",
                    nodeKind: .directory
                ),
                ChangeEvent(
                    kind: .copied,
                    path: "/docs/copy/file.txt",
                    sourcePath: "/docs/archive/file.txt",
                    nodeKind: .file
                ),
                ChangeEvent(
                    kind: .copied,
                    path: "/docs/copy/link.txt",
                    sourcePath: "/docs/archive/link.txt",
                    nodeKind: .symlink
                ),
            ]
        )
    }

    @Test(.tags(.watching))
    func `watchChanges emits missing directory creation and symlink deletion events`() async throws {
        let fs = InMemoryFilesystem()
        try await fs.writeFile(path: "/target.txt", data: Data("hello".utf8), append: false)
        try await fs.createSymlink(path: "/link.txt", target: "target.txt")
        let state = Workspace(filesystem: fs)

        let directoryRecorder = ChangeEventRecorder()
        let symlinkRecorder = ChangeEventRecorder()
        let directoryTask = startRecording(await state.watchChanges(at: "/folder", recursive: false), into: directoryRecorder)
        let symlinkTask = startRecording(await state.watchChanges(at: "/link.txt", recursive: false), into: symlinkRecorder)
        defer {
            directoryTask.cancel()
            symlinkTask.cancel()
        }

        try await state.createDirectory(at: "/folder", recursive: false)
        try await state.createDirectory(at: "/folder", recursive: true)
        try await state.removeItem(at: "/link.txt", recursive: false)

        let directoryEvents = try await waitForRecordedEvents(1, recorder: directoryRecorder)
        let symlinkEvents = try await waitForRecordedEvents(1, recorder: symlinkRecorder)
        #expect(directoryEvents == [ChangeEvent(kind: .created, path: "/folder", nodeKind: .directory)])
        #expect(symlinkEvents == [ChangeEvent(kind: .deleted, path: "/link.txt", nodeKind: .symlink)])

        let settledDirectoryEvents = try await waitForSettledEvents(recorder: directoryRecorder)
        #expect(settledDirectoryEvents == directoryEvents)
    }

    @Test(.tags(.watching))
    func `watchChanges matches move events by source and destination paths`() async throws {
        let fs = InMemoryFilesystem()
        try await fs.createDirectory(path: "/docs", recursive: true)
        try await fs.createDirectory(path: "/archive", recursive: true)
        try await fs.writeFile(path: "/docs/file.txt", data: Data("hello".utf8), append: false)
        let state = Workspace(filesystem: fs)

        let docsRecorder = ChangeEventRecorder()
        let archiveRecorder = ChangeEventRecorder()
        let docsTask = startRecording(await state.watchChanges(at: "/docs"), into: docsRecorder)
        let archiveTask = startRecording(await state.watchChanges(at: "/archive"), into: archiveRecorder)
        defer {
            docsTask.cancel()
            archiveTask.cancel()
        }

        try await state.moveItem(from: "/docs/file.txt", to: "/archive/file.txt")

        let expected = ChangeEvent(
            kind: .moved,
            path: "/archive/file.txt",
            sourcePath: "/docs/file.txt",
            nodeKind: .file
        )
        let docsEvents = try await waitForRecordedEvents(1, recorder: docsRecorder)
        let archiveEvents = try await waitForRecordedEvents(1, recorder: archiveRecorder)
        #expect(docsEvents == [expected])
        #expect(archiveEvents == [expected])
    }

    @Test(.tags(.edits, .watching))
    func `applyEdits rollback emits no watch events`() async throws {
        let state = Workspace(
            filesystem: FailOnceFilesystem(
                base: InMemoryFilesystem(),
                failingWritePaths: ["/b.txt"]
            )
        )
        let recorder = ChangeEventRecorder()
        let stream = await state.watchChanges(at: "/")
        let task = startRecording(stream, into: recorder)
        defer { task.cancel() }

        let result = try await state.applyEdits(
            [
                .writeFile(path: "/a.txt", content: "one"),
                .writeFile(path: "/b.txt", content: "two"),
            ],
            failurePolicy: .rollback
        )

        #expect(result.rolledBack)
        let events = try await waitForSettledEvents(recorder: recorder)
        #expect(events.isEmpty)
    }

    @Test(.tags(.edits, .watching))
    func `applyEdits fail-fast emits only persisted watch events`() async throws {
        let state = Workspace(
            filesystem: FailOnceFilesystem(
                base: InMemoryFilesystem(),
                failingWritePaths: ["/b.txt"]
            )
        )
        let recorder = ChangeEventRecorder()
        let stream = await state.watchChanges(at: "/")
        let task = startRecording(stream, into: recorder)
        defer { task.cancel() }

        let result = try await state.applyEdits(
            [
                .writeFile(path: "/a.txt", content: "one"),
                .writeFile(path: "/b.txt", content: "two"),
                .writeFile(path: "/c.txt", content: "three"),
            ],
            failurePolicy: .failFast
        )

        #expect(!result.rolledBack)
        let events = try await waitForRecordedEvents(1, recorder: recorder)
        #expect(events == [ChangeEvent(kind: .created, path: "/a.txt", nodeKind: .file)])
        let settled = try await waitForSettledEvents(recorder: recorder)
        #expect(settled == events)
    }

    @Test(.tags(.edits, .watching))
    func `applyEdits best-effort emits only applied watch events`() async throws {
        let state = Workspace(
            filesystem: FailOnceFilesystem(
                base: InMemoryFilesystem(),
                failingWritePaths: ["/b.txt"]
            )
        )
        let recorder = ChangeEventRecorder()
        let stream = await state.watchChanges(at: "/")
        let task = startRecording(stream, into: recorder)
        defer { task.cancel() }

        let result = try await state.applyEdits(
            [
                .writeFile(path: "/a.txt", content: "one"),
                .writeFile(path: "/b.txt", content: "two"),
                .writeFile(path: "/c.txt", content: "three"),
            ],
            failurePolicy: .bestEffort
        )

        #expect(!result.rolledBack)
        let events = try await waitForRecordedEvents(2, recorder: recorder)
        #expect(
            events == [
                ChangeEvent(kind: .created, path: "/a.txt", nodeKind: .file),
                ChangeEvent(kind: .created, path: "/c.txt", nodeKind: .file),
            ]
        )
    }

    @Test(.tags(.replacement, .watching))
    func `applyReplacement emits only persisted watch events`() async throws {
        let base = InMemoryFilesystem()
        try await base.createDirectory(path: "/src", recursive: true)
        try await base.writeFile(path: "/src/a.txt", data: Data("foo".utf8), append: false)
        try await base.writeFile(path: "/src/b.txt", data: Data("foo".utf8), append: false)
        let state = Workspace(
            filesystem: FailOnceFilesystem(
                base: base,
                failingWritePaths: ["/src/b.txt"]
            )
        )
        let recorder = ChangeEventRecorder()
        let stream = await state.watchChanges(at: "/src")
        let task = startRecording(stream, into: recorder)
        defer { task.cancel() }

        let result = try await state.applyReplacement(
            ReplacementRequest(pattern: "/src/*.txt", search: "foo", replacement: "bar"),
            failurePolicy: .bestEffort
        )

        #expect(!result.rolledBack)
        let events = try await waitForRecordedEvents(1, recorder: recorder)
        #expect(events == [ChangeEvent(kind: .modified, path: "/src/a.txt", nodeKind: .file)])
        let settled = try await waitForSettledEvents(recorder: recorder)
        #expect(settled == events)
    }

    @Test(.tags(.watching))
    func `watchChanges behaves consistently for in-memory overlay and mounted workspaces`() async throws {
        try await assertBasicWatchSemantics(
            workspace: Workspace(filesystem: InMemoryFilesystem()),
            watchedPath: "/note.txt"
        )

        let overlayRoot = try WorkspaceTestSupport.makeTempDirectory(prefix: "WorkspaceOverlayWatch")
        defer { WorkspaceTestSupport.removeDirectory(overlayRoot) }
        let overlayWorkspace = Workspace(filesystem: try await OverlayFilesystem(rootDirectory: overlayRoot))
        try await assertBasicWatchSemantics(
            workspace: overlayWorkspace,
            watchedPath: "/overlay.txt"
        )

        let mountedWorkspace = Workspace(
            filesystem: MountableFilesystem(
                base: InMemoryFilesystem(),
                mounts: [
                    .init(mountPoint: "/mounted", filesystem: InMemoryFilesystem()),
                ]
            )
        )
        try await assertBasicWatchSemantics(
            workspace: mountedWorkspace,
            watchedPath: "/mounted/note.txt"
        )
    }

    @Test(.tags(.watching))
    func `watchChanges unregisters cancelled streams`() async throws {
        let state = Workspace(filesystem: InMemoryFilesystem())
        let recorder = ChangeEventRecorder()

        do {
            let stream = await state.watchChanges(at: "/note.txt", recursive: false)
            let task = startRecording(stream, into: recorder)

            try await state.writeFile("/note.txt", content: "one")
            _ = try await waitForRecordedEvents(1, recorder: recorder)

            task.cancel()
        }

        try await Task.sleep(for: .milliseconds(50))
        try await state.writeFile("/note.txt", content: "two")

        let settled = try await waitForSettledEvents(recorder: recorder)
        #expect(settled == [ChangeEvent(kind: .created, path: "/note.txt", nodeKind: .file)])
    }

    @Test
    func `nested Codable mutation metadata roundtrips`() throws {
        let original = MutationMode.execution
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MutationMode.self, from: data)
        #expect(decoded == original)
    }

    @Test(.tags(.replacement))
    func `replacement request and result roundtrip through Codable`() throws {
        let request = ReplacementRequest(
            scope: "/Sources",
            include: ["**/*.swift"],
            exclude: ["**/*Tests.swift"],
            search: .literal("workspace", caseSensitive: false),
            replacement: "Workspace"
        )
        let requestData = try JSONEncoder().encode(request)
        let decodedRequest = try JSONDecoder().decode(ReplacementRequest.self, from: requestData)
        #expect(decodedRequest == request)

        let diff = TextDiff(
            hunks: [
                .init(
                    oldStartLine: 1,
                    oldLineCount: 1,
                    newStartLine: 1,
                    newLineCount: 1,
                    lines: [
                        .init(
                            kind: .added,
                            text: "Workspace",
                            hasTrailingNewline: true,
                            oldLineNumber: nil,
                            newLineNumber: 1
                        )
                    ]
                )
            ]
        )
        let result = ReplacementResult(
            mode: .preview,
            touchedPaths: ["/Sources/Workspace.swift"],
            changes: [
                .init(
                    path: "/Sources/Workspace.swift",
                    replacements: 1,
                    status: .planned,
                    diff: diff
                )
            ],
            failures: [.init(path: "/Sources/Broken.swift", message: "decode failed")],
            rolledBack: false
        )

        let resultData = try JSONEncoder().encode(result)
        let decodedResult = try JSONDecoder().decode(ReplacementResult.self, from: resultData)
        #expect(decodedResult.mode == result.mode)
        #expect(decodedResult.touchedPaths == result.touchedPaths)
        #expect(decodedResult.changes.count == 1)
        #expect(decodedResult.changes[0].path == result.changes[0].path)
        #expect(decodedResult.changes[0].replacements == result.changes[0].replacements)
        #expect(decodedResult.changes[0].status == result.changes[0].status)
        #expect(decodedResult.changes[0].diff == result.changes[0].diff)
        #expect(decodedResult.failures.count == 1)
        #expect(decodedResult.failures[0].path == result.failures[0].path)
        #expect(decodedResult.failures[0].message == result.failures[0].message)
        #expect(decodedResult.rolledBack == result.rolledBack)
    }

    @Test
    func `default filesystem extensions throw unsupported advanced operations`() async throws {
        let filesystem = MinimalFilesystem()
        try await filesystem.writeFile(path: "/note.txt", data: Data("hello".utf8), append: false)

        do {
            try await filesystem.configure(rootDirectory: URL(fileURLWithPath: "/ignored"))
            Issue.record("expected default configure error")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("not configured"))
        }

        do {
            try await filesystem.createSymlink(path: "/alias.txt", target: "note.txt")
            Issue.record("expected unsupported createSymlink error")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("symbolic links are not supported"))
        }

        do {
            try await filesystem.createHardLink(path: "/hard.txt", target: "/note.txt")
            Issue.record("expected unsupported createHardLink error")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("hard links are not supported"))
        }

        do {
            _ = try await filesystem.readSymlink(path: "/note.txt")
            Issue.record("expected unsupported readSymlink error")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("symbolic links are not supported"))
        }

        do {
            try await filesystem.setPermissions(path: "/note.txt", permissions: .defaultFile)
            Issue.record("expected unsupported setPermissions error")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("setting permissions is not supported"))
        }

        do {
            _ = try await filesystem.resolveRealPath(path: "/note.txt")
            Issue.record("expected unsupported resolveRealPath error")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("real path resolution is not supported"))
        }
    }

    @Test
    func `readJSON rejects invalid JSON`() async throws {
        let fs = InMemoryFilesystem()
        try await fs.writeFile(path: "/broken.json", data: Data("{ nope".utf8), append: false)
        let state = Workspace(filesystem: fs)

        do {
            _ = try await state.readJSON(DemoConfig.self, from: "/broken.json")
            Issue.record("expected invalid JSON error")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("invalid JSON"))
        }
    }

    @Test(.tags(.tree))
    func `walkTree and summarizeTree preserve stable ordering`() async throws {
        let fs = InMemoryFilesystem()
        try await fs.createDirectory(path: "/src", recursive: true)
        try await fs.writeFile(path: "/src/b.txt", data: Data("b".utf8), append: false)
        try await fs.writeFile(path: "/src/a.txt", data: Data("aa".utf8), append: false)
        try await fs.createDirectory(path: "/src/nested", recursive: true)
        let state = Workspace(filesystem: fs)

        let tree = try await state.walkTree("/src", maxDepth: 1)
        #expect(tree.children?.map(\.path) == ["/src/a.txt", "/src/b.txt", "/src/nested"])

        let summary = try await state.summarizeTree("/src", maxDepth: 1)
        #expect(summary.children.map(\.path) == ["/src/a.txt", "/src/b.txt", "/src/nested"])
        #expect(summary.fileCount == 2)
        #expect(summary.directoryCount == 2)
    }

    @Test(.tags(.tree))
    func `walkTree and summarizeTree report symlink kinds`() async throws {
        let fs = InMemoryFilesystem()
        try await fs.writeFile(path: "/note.txt", data: Data("hello".utf8), append: false)
        try await fs.createSymlink(path: "/alias.txt", target: "note.txt")
        let state = Workspace(filesystem: fs)

        let tree = try await state.walkTree("/")
        let alias = try #require(tree.children?.first(where: { $0.path == "/alias.txt" }))
        #expect(alias.kind == .symlink)

        let summary = try await state.summarizeTree("/")
        let aliasSummary = try #require(summary.children.first(where: { $0.path == "/alias.txt" }))
        #expect(aliasSummary.kind == .symlink)
        #expect(summary.symlinkCount == 1)
    }

    @Test(.tags(.replacement))
    func `previewReplacement previews without mutating files`() async throws {
        let fs = InMemoryFilesystem()
        try await fs.createDirectory(path: "/src", recursive: true)
        try await fs.writeFile(path: "/src/a.txt", data: Data("foo".utf8), append: false)
        try await fs.writeFile(path: "/src/b.txt", data: Data("foo bar".utf8), append: false)
        let state = Workspace(filesystem: fs)

        let result = try await state.previewReplacement(
            ReplacementRequest(pattern: "/src/*.txt", search: "foo", replacement: "baz")
        )
        #expect(result.mode == .preview)
        #expect(result.touchedPaths == ["/src/a.txt", "/src/b.txt"])
        #expect(result.changes.map(\.status) == [.planned, .planned])
        #expect(result.changes.map(\.replacements) == [1, 1])
        #expect(result.changes.map { addedLineTexts($0.diff) } == [["baz"], ["baz bar"]])
        #expect(try await state.readFile("/src/a.txt") == "foo")
    }

    @Test(.tags(.replacement))
    func `applyReplacement rolls back on write failure`() async throws {
        let base = InMemoryFilesystem()
        try await base.createDirectory(path: "/src", recursive: true)
        try await base.writeFile(path: "/src/a.txt", data: Data("foo".utf8), append: false)
        try await base.writeFile(path: "/src/b.txt", data: Data("foo".utf8), append: false)

        let state = Workspace(
            filesystem: FailOnceFilesystem(base: base, failingWritePaths: ["/src/b.txt"])
        )

        let result = try await state.applyReplacement(
            ReplacementRequest(pattern: "/src/*.txt", search: "foo", replacement: "bar"),
            failurePolicy: .rollback
        )
        #expect(result.rolledBack)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.path == "/src/b.txt")
        #expect(result.changes.map(\.status) == [.rolledBack, .failed])
        #expect(try await base.readFile(path: "/src/a.txt") == Data("foo".utf8))
        #expect(try await base.readFile(path: "/src/b.txt") == Data("foo".utf8))
    }

    @Test(.tags(.replacement))
    func `applyReplacement best effort reports failures without rollback`() async throws {
        let base = InMemoryFilesystem()
        try await base.createDirectory(path: "/src", recursive: true)
        try await base.writeFile(path: "/src/a.txt", data: Data("foo".utf8), append: false)
        try await base.writeFile(path: "/src/b.txt", data: Data("foo".utf8), append: false)

        let state = Workspace(
            filesystem: FailOnceFilesystem(base: base, failingWritePaths: ["/src/b.txt"])
        )

        let result = try await state.applyReplacement(
            ReplacementRequest(pattern: "/src/*.txt", search: .regularExpression("f.o"), replacement: "bar"),
            failurePolicy: .bestEffort
        )

        #expect(!result.rolledBack)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.path == "/src/b.txt")
        #expect(result.changes.map(\.status) == [.applied, .failed])
        #expect(try await base.readFile(path: "/src/a.txt") == Data("bar".utf8))
        #expect(try await base.readFile(path: "/src/b.txt") == Data("foo".utf8))
    }

    @Test(.tags(.replacement))
    func `applyReplacement fail-fast stops after the first failure`() async throws {
        let base = InMemoryFilesystem()
        try await base.createDirectory(path: "/src", recursive: true)
        try await base.writeFile(path: "/src/a.txt", data: Data("foo".utf8), append: false)
        try await base.writeFile(path: "/src/b.txt", data: Data("foo".utf8), append: false)
        try await base.writeFile(path: "/src/c.txt", data: Data("foo".utf8), append: false)

        let state = Workspace(
            filesystem: NSErrorFailOnceFilesystem(base: base, failingWritePaths: ["/src/b.txt"])
        )

        let result = try await state.applyReplacement(
            ReplacementRequest(pattern: "/src/*.txt", search: "foo", replacement: "bar"),
            failurePolicy: .failFast
        )

        #expect(!result.rolledBack)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.path == "/src/b.txt")
        #expect(result.failures.first?.message.contains("WorkspaceTests") == true)
        #expect(result.changes.map(\.status) == [.applied, .failed, .skipped])
        #expect(try await base.readFile(path: "/src/a.txt") == Data("bar".utf8))
        #expect(try await base.readFile(path: "/src/b.txt") == Data("foo".utf8))
        #expect(try await base.readFile(path: "/src/c.txt") == Data("foo".utf8))
    }

    @Test(.tags(.replacement))
    func `applyReplacement returns an empty execution result when nothing matches`() async throws {
        let state = Workspace(filesystem: InMemoryFilesystem())

        let result = try await state.applyReplacement(
            ReplacementRequest(pattern: "/missing/*.txt", search: "foo", replacement: "bar")
        )

        #expect(result.mode == .execution)
        #expect(result.touchedPaths.isEmpty)
        #expect(result.changes.isEmpty)
        #expect(result.failures.isEmpty)
        #expect(!result.rolledBack)
    }

    @Test(.tags(.replacement))
    func `previewReplacement respects scope excludes and case-insensitive matching`() async throws {
        let fs = InMemoryFilesystem()
        try await fs.createDirectory(path: "/src/dir", recursive: true)
        try await fs.writeFile(path: "/src/keep.txt", data: Data("FoO".utf8), append: false)
        try await fs.writeFile(path: "/src/skip.txt", data: Data("foo".utf8), append: false)
        let state = Workspace(filesystem: fs)

        let result = try await state.previewReplacement(
            ReplacementRequest(
                scope: "/src",
                include: ["*.txt", "dir"],
                exclude: ["skip.txt"],
                search: .literal("foo", caseSensitive: false),
                replacement: "bar"
            )
        )

        #expect(result.touchedPaths == ["/src/keep.txt"])
        #expect(result.changes.count == 1)
        #expect(result.changes.first?.status == .planned)
        #expect(removedLineTexts(result.changes.first?.diff) == ["FoO"])
        #expect(addedLineTexts(result.changes.first?.diff) == ["bar"])
    }

    @Test(.tags(.replacement))
    func `previewReplacement rejects invalid UTF-8 and empty search patterns`() async throws {
        let fs = InMemoryFilesystem()
        try await fs.writeFile(path: "/binary.bin", data: Data([0xFF]), append: false)
        try await fs.writeFile(path: "/note.txt", data: Data("hello".utf8), append: false)
        let state = Workspace(filesystem: fs)

        do {
            _ = try await state.previewReplacement(
                ReplacementRequest(
                    include: ["/binary.bin"],
                    search: .literal("x"),
                    replacement: "y"
                )
            )
            Issue.record("expected invalid UTF-8 error")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("not valid UTF-8"))
        }

        do {
            _ = try await state.previewReplacement(
                ReplacementRequest(
                    include: ["/note.txt"],
                    search: .literal("", caseSensitive: false),
                    replacement: "y"
                )
            )
            Issue.record("expected empty literal search rejection")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("must not be empty"))
        }

        do {
            _ = try await state.previewReplacement(
                ReplacementRequest(
                    include: ["/note.txt"],
                    search: .regularExpression(""),
                    replacement: "y"
                )
            )
            Issue.record("expected empty regex search rejection")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("must not be empty"))
        }
    }

    @Test(.tags(.edits))
    func `applyEdits succeeds across multiple files`() async throws {
        let fs = InMemoryFilesystem()
        let state = Workspace(filesystem: fs)

        let result = try await state.applyEdits([
            .createDirectory(path: "/src"),
            .writeFile(path: "/src/a.txt", content: "one"),
            .appendFile(path: "/src/a.txt", content: " two"),
            .copy(from: "/src/a.txt", to: "/src/b.txt"),
            .move(from: "/src/b.txt", to: "/src/c.txt"),
        ])

        #expect(!result.rolledBack)
        #expect(result.mode == .execution)
        #expect(result.touchedPaths == ["/src"])
        #expect(result.edits.map(\.status) == [.applied, .applied, .applied, .applied, .applied])
        #expect(addedLineTexts(result.edits[1].fileChanges.first?.diff) == ["one"])
        #expect(addedLineTexts(result.edits[2].fileChanges.first?.diff) == ["one two"])
        #expect(result.edits[3].fileChanges.first?.sourcePath == "/src/a.txt")
        #expect(result.edits[4].fileChanges.first?.sourcePath == "/src/b.txt")
        #expect(try await state.readFile("/src/a.txt") == "one two")
        #expect(try await state.readFile("/src/c.txt") == "one two")
    }

    @Test(.tags(.edits))
    func `applyEdits rolls back on failure`() async throws {
        let base = InMemoryFilesystem()
        try await base.writeFile(path: "/a.txt", data: Data("old".utf8), append: false)
        let state = Workspace(
            filesystem: FailOnceFilesystem(base: base, failingWritePaths: ["/b.txt"])
        )

        let result = try await state.applyEdits([
            .writeFile(path: "/a.txt", content: "new"),
            .writeFile(path: "/b.txt", content: "blocked"),
        ])

        #expect(result.rolledBack)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.index == 1)
        #expect(result.edits.map(\.status) == [.rolledBack, .failed])
        #expect(result.edits.first?.fileChanges.first?.status == .rolledBack)
        #expect(try await base.readFile(path: "/a.txt") == Data("old".utf8))
        let bExists = await base.exists(path: "/b.txt")
        #expect(!bExists)
    }

    @Test(.tags(.edits))
    func `previewEdits reports change states and delete diffs`() async throws {
        let fs = InMemoryFilesystem()
        try await fs.createDirectory(path: "/dir", recursive: true)
        try await fs.writeFile(path: "/same.txt", data: Data("same".utf8), append: false)
        try await fs.writeFile(path: "/delete.txt", data: Data("bye".utf8), append: false)
        let state = Workspace(filesystem: fs)

        let result = try await state.previewEdits([
            .writeFile(path: "/same.txt", content: "same"),
            .delete(path: "/delete.txt"),
            .delete(path: "/missing.txt"),
            .createDirectory(path: "/dir"),
            .move(from: "/same.txt", to: "/same.txt"),
        ])

        #expect(result.mode == .preview)
        #expect(result.edits.map(\.status) == [.planned, .planned, .planned, .planned, .planned])
        #expect(result.edits.map(\.changeState) == [.unchanged, .changed, .unchanged, .unchanged, .unchanged])
        #expect(result.edits[0].fileChanges.count == 1)
        #expect(result.edits[0].fileChanges[0].effect == .unchanged)
        #expect(result.edits[1].fileChanges[0].effect == .deleted)
        #expect(result.edits[0].fileChanges[0].diff?.hunks.isEmpty == true)
        #expect(removedLineTexts(result.edits[1].fileChanges.first?.diff) == ["bye"])
        #expect(result.edits[2].fileChanges.isEmpty)
    }

    @Test(.tags(.edits))
    func `applyEdits fail-fast keeps prior changes and reports non-workspace errors`() async throws {
        let base = InMemoryFilesystem()
        try await base.writeFile(path: "/old.txt", data: Data("gone".utf8), append: false)
        let state = Workspace(
            filesystem: NSErrorFailOnceFilesystem(base: base, failingWritePaths: ["/blocked.txt"])
        )

        let result = try await state.applyEdits([
            .delete(path: "/old.txt"),
            .writeFile(path: "/blocked.txt", content: "blocked"),
            .writeFile(path: "/after.txt", content: "after"),
        ], failurePolicy: .failFast)

        #expect(!result.rolledBack)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.index == 1)
        #expect(result.failures.first?.message.contains("WorkspaceTests") == true)
        #expect(result.edits.map(\.status) == [.applied, .failed, .skipped])
        #expect(!(await base.exists(path: "/old.txt")))
        #expect(!(await base.exists(path: "/blocked.txt")))
        #expect(!(await base.exists(path: "/after.txt")))
    }

    @Test(.tags(.edits))
    func `applyEdits returns an empty execution result when given no edits`() async throws {
        let state = Workspace(filesystem: InMemoryFilesystem())
        let result = try await state.applyEdits([])

        #expect(result.mode == .execution)
        #expect(result.touchedPaths.isEmpty)
        #expect(result.edits.isEmpty)
        #expect(result.failures.isEmpty)
        #expect(!result.rolledBack)
    }

    @Test(.tags(.edits))
    func `previewEdits plans sequential text diffs across earlier edits`() async throws {
        let state = Workspace(filesystem: InMemoryFilesystem())

        let result = try await state.previewEdits([
            .writeFile(path: "/note.txt", content: "one"),
            .appendFile(path: "/note.txt", content: " two"),
        ])

        #expect(result.edits.map(\.status) == [.planned, .planned])
        #expect(addedLineTexts(result.edits[0].fileChanges.first?.diff) == ["one"])
        #expect(removedLineTexts(result.edits[1].fileChanges.first?.diff) == ["one"])
        #expect(addedLineTexts(result.edits[1].fileChanges.first?.diff) == ["one two"])
    }

    @Test(.tags(.edits))
    func `previewEdits expands recursive file changes and omits binary diffs`() async throws {
        let fs = InMemoryFilesystem()
        try await fs.createDirectory(path: "/src/nested", recursive: true)
        try await fs.writeFile(path: "/src/a.txt", data: Data("alpha".utf8), append: false)
        try await fs.writeFile(path: "/src/nested/b.bin", data: Data([0xFF]), append: false)
        let state = Workspace(filesystem: fs)

        let copyPreview = try await state.previewEdits([
            .copy(from: "/src", to: "/dest")
        ])
        let deletePreview = try await state.previewEdits([
            .delete(path: "/src")
        ])

        #expect(copyPreview.edits[0].fileChanges.map(\.path) == ["/dest/a.txt", "/dest/nested/b.bin"])
        #expect(copyPreview.edits[0].fileChanges.map(\.sourcePath) == ["/src/a.txt", "/src/nested/b.bin"])
        #expect(copyPreview.edits[0].fileChanges.allSatisfy { $0.diff == nil })
        #expect(deletePreview.edits[0].fileChanges.map(\.path) == ["/src/a.txt", "/src/nested/b.bin"])
        #expect(deletePreview.edits[0].fileChanges.first?.diff != nil)
        #expect(deletePreview.edits[0].fileChanges.last?.diff == nil)
    }

    @Test(.tags(.edits))
    func `previewEdits preserves trailing newline metadata in diffs`() async throws {
        let state = Workspace(filesystem: InMemoryFilesystem())

        let result = try await state.previewEdits([
            .writeFile(path: "/multi.txt", content: "a\nb\n"),
        ])

        let lines = diffLines(result.edits[0].fileChanges.first?.diff)
        #expect(lines.map(\.text) == ["a", "b"])
        #expect(lines.allSatisfy { $0.hasTrailingNewline })
    }

    @Test
    func `workspace path and type helpers cover normalization and coding`() throws {
        #expect(WorkspacePath(normalizing: "", relativeTo: "/base") == "/base")
        #expect(WorkspacePath(normalizing: "./child", relativeTo: "/base") == "/base/child")
        #expect(WorkspacePath.basename("/") == "/")
        #expect(WorkspacePath.dirname("/") == .root)
        #expect(WorkspacePath.join("/base", "/override") == "/override")
        #expect(WorkspacePath.globToRegex("file?.[ch]") == "^file.\\.[ch]$")
        #expect(WorkspacePath.globToRegex("file[") == "^file\\[$")

        let encoded = try JSONEncoder().encode(WorkspacePath(normalizing: "/tmp/../file.txt"))
        #expect(try JSONDecoder().decode(WorkspacePath.self, from: encoded) == "/file.txt")

        let invalidPathError = WorkspaceError.invalidPath("/bad\u{0}path")
        #expect(invalidPathError.description == "path contains null byte")

        let fileInfo = FileInfo(
            path: "/tmp/../file.txt",
            kind: .file,
            size: 7,
            permissions: POSIXPermissions(0o644),
            modificationDate: nil
        )
        #expect(fileInfo.path == "/file.txt")
    }

    @Test(.tags(.edits))
    func `applyEdits works with overlay and mountable filesystems`() async throws {
        let workspaceRoot = try WorkspaceTestSupport.makeTempDirectory(prefix: "WorkspaceMountRoot")
        defer { WorkspaceTestSupport.removeDirectory(workspaceRoot) }

        let docsRoot = try WorkspaceTestSupport.makeTempDirectory(prefix: "WorkspaceDocsRoot")
        defer { WorkspaceTestSupport.removeDirectory(docsRoot) }
        try Data("guide".utf8).write(to: docsRoot.appendingPathComponent("guide.txt"))

        let mountable = MountableFilesystem(
            base: InMemoryFilesystem(),
            mounts: [
                .init(mountPoint: "/workspace", filesystem: try await OverlayFilesystem(rootDirectory: workspaceRoot)),
                .init(mountPoint: "/docs", filesystem: try await OverlayFilesystem(rootDirectory: docsRoot)),
            ]
        )

        let state = Workspace(filesystem: mountable)
        let result = try await state.applyEdits([
            .copy(from: "/docs/guide.txt", to: "/workspace/guide.txt"),
            .writeFile(path: "/workspace/note.txt", content: "hello"),
        ])

        #expect(!result.rolledBack)
        #expect(try await state.readFile("/workspace/guide.txt") == "guide")
        #expect(try await state.readFile("/workspace/note.txt") == "hello")
        #expect(!FileManager.default.fileExists(atPath: workspaceRoot.appendingPathComponent("guide.txt").path))
    }
}
