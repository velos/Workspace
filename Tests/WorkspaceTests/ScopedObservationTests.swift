import Foundation
import Testing
#if os(macOS)
import CoreServices
#endif
@testable import Workspace

@Suite("Scoped filesystem observation")
struct ScopedObservationTests {
    @Test func `shallow parent plus entry signals leave unrelated subtrees and contents alone`() async throws {
        let fs = SignallingFileSystem()
        try await fs.base.createDirectory(path: "/unrelated/deep", recursive: true)
        try await fs.base.writeFile(path: "/unrelated/deep/a", data: Data("keep".utf8), append: false)
        try await fs.base.writeFile(path: "/sibling", data: Data("keep".utf8), append: false)
        try await fs.base.writeFile(path: "/x", data: Data("before".utf8), append: false)
        let ws = Workspace(fileSystem: fs)
        let events = await ws.events(.init(includeCheckpoints: false))
        let lists = await fs.base.listings.count
        let reads = await fs.base.reads.count
        try await fs.base.writeFile(path: "/x", data: Data("after".utf8), append: false)
        // Separate signals exercise Workspace's burst coalescing as well as refresh.
        fs.signal(.paths([.root: .shallow]))
        fs.signal(.paths(["/x": .entry]))
        guard case let .changes(change)? = await first(events) else { Issue.record("missing external event"); return }
        #expect(change.touchedPaths == ["/x"])
        #expect(await fs.base.listings.dropFirst(lists).allSatisfy { $0 == .root })
        #expect(await fs.base.reads.dropFirst(reads).allSatisfy { $0 == "/x" })
        // The untouched descendants must remain in the observation index.
        try await fs.base.remove(path: "/unrelated", recursive: true)
        fs.signal(.paths([.root: .shallow]))
        guard case let .changes(deleted)? = await first(events) else { Issue.record("missing deletion event"); return }
        #expect(deleted.touchedPaths == ["/unrelated", "/unrelated/deep", "/unrelated/deep/a"])
    }

    @Test func `shallow listings capture added and replaced directories recursively`() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(path: "/d", recursive: false)
        try await fs.writeFile(path: "/d/old", data: Data("old".utf8), append: false)
        var observation = try await FilesystemObservation.start(on: fs, budget: 1024)
        try await fs.remove(path: "/d", recursive: true)
        try await fs.createDirectory(path: "/d/nested", recursive: true)
        try await fs.writeFile(path: "/d/nested/new", data: Data("new".utf8), append: false)
        try await fs.createDirectory(path: "/added", recursive: false)
        try await fs.writeFile(path: "/added/file", data: Data("file".utf8), append: false)
        let changes = try await observation.refresh(on: fs, signal: .paths([.root: .shallow]))
        #expect(changes.touchedPaths == ["/added", "/added/file", "/d/nested", "/d/nested/new", "/d/old"])
        #expect(observation.metadata.entries["/d/old"] == nil)
        #expect(observation.metadata.entries["/d/nested/new"] != nil)
    }

    @Test func `atomic temporary names do not suppress similarly named user entries`() {
        let generated = LocalAtomicTemporaryName.make()
        #expect(LocalAtomicTemporaryName.matches(generated))
        for name in [".workspace-" + UUID().uuidString, ".workspace-atomic-" + UUID().uuidString + "-" + UUID().uuidString,
                     generated + ".txt", String(generated.dropLast()), generated.lowercased()] {
            #expect(!LocalAtomicTemporaryName.matches(name))
        }
    }

    @Test func `in-flight atomic temporaries are hidden from listings and walks`() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(root) }
        let temporary = LocalAtomicTemporaryName.make()
        let lookalike = ".workspace-atomic-" + UUID().uuidString + "-" + UUID().uuidString
        for name in [temporary, lookalike, "file"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        let fs = try LocalFileSystem(root: root)
        #expect(Set(try await fs.listDirectory(path: .root).map(\.name)) == [lookalike, "file"])
        var walked: [WorkspacePath] = []
        try await fs.walk(at: .root, skippingUnreadableDirectories: false) { info, _, _ in walked.append(info.path) }
        #expect(Set(walked) == [.root, WorkspacePath(normalizing: "/" + lookalike), "/file"])
        // A recursive copy must not duplicate the temporary as a stray user file.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: false)
        try Data("x".utf8).write(to: root.appendingPathComponent("src/" + temporary))
        try Data("y".utf8).write(to: root.appendingPathComponent("src/kept"))
        try await fs.copy(from: "/src", to: "/dst", recursive: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("dst").path) == ["kept"])
    }

    #if os(macOS)
    @Test func `FSEvents root item events are shallow only while the original directory remains`() throws {
        let container = try TestSupport.temporaryDirectory("RootItemIdentity").resolvingSymlinksInPath()
        defer { TestSupport.remove(container) }
        let root = container.appendingPathComponent("root")
        let moved = container.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let mapper = FSEventsChangeStream.EventMapper(root: root.path)
        let file = (path: root.path + "/x", flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile))
        for flag in [kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemRenamed,
                     kFSEventStreamEventFlagItemRemoved, kFSEventStreamEventFlagItemInodeMetaMod] {
            let flags = UInt32(flag | kFSEventStreamEventFlagItemIsDir)
            #expect(mapper.signal(for: [(root.path, flags), file]) == .paths([.root: .shallow, "/x": .entry]))
        }
        let createdDirectory = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir)
        #expect(mapper.signal(for: [(root.path + "/child", createdDirectory)]) == .paths(["/child": .recursive]))
        for flag in [kFSEventStreamEventFlagRootChanged, kFSEventStreamEventFlagMustScanSubDirs,
                     kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped] {
            #expect(mapper.signal(for: [(root.path, createdDirectory | UInt32(flag)), file]) == .rescan)
        }

        // Check the actual directory identity, even when only a child item arrives.
        try FileManager.default.moveItem(at: root, to: moved)
        #expect(mapper.signal(for: [file]) == .rescan)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        #expect(mapper.signal(for: [(root.path, createdDirectory), file]) == .rescan)
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: moved)
        #expect(mapper.signal(for: [file]) == .rescan)
    }

    @Test func `FSEvents distinguishes item metadata from structural and dropped notifications`() {
        let metadataFlags = [kFSEventStreamEventFlagItemModified, kFSEventStreamEventFlagItemInodeMetaMod,
            kFSEventStreamEventFlagItemXattrMod, kFSEventStreamEventFlagItemFinderInfoMod,
            kFSEventStreamEventFlagItemChangeOwner]
        for flag in metadataFlags {
            #expect(FSEventsChangeStream.scope(for: UInt32(flag | kFSEventStreamEventFlagItemIsDir)) == .shallow)
            #expect(FSEventsChangeStream.scope(for: UInt32(flag | kFSEventStreamEventFlagItemIsFile)) == .entry)
        }
        for flag in [kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemRemoved, kFSEventStreamEventFlagItemRenamed] {
            #expect(FSEventsChangeStream.scope(for: UInt32(flag | kFSEventStreamEventFlagItemIsDir)) == .recursive)
            #expect(FSEventsChangeStream.scope(for: UInt32(flag | kFSEventStreamEventFlagItemIsFile)) == .entry)
        }
        #expect(FSEventsChangeStream.scope(for: UInt32(kFSEventStreamEventFlagMustScanSubDirs)) == .recursive)
        for flag in [kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped,
                     kFSEventStreamEventFlagRootChanged, kFSEventStreamEventFlagEventIdsWrapped] {
            #expect(FSEventsChangeStream.scope(for: UInt32(flag | kFSEventStreamEventFlagItemIsDir)) == nil)
        }
        #expect(FSEventsChangeStream.scope(for: 0) == nil)
    }

    @Test func `one native write in a medium tree avoids a recursive metadata walk`() async throws {
        let root = try TestSupport.temporaryDirectory("ScopedMediumWatch")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        for directory in 0..<32 {
            try await local.createDirectory(path: WorkspacePath("/d\(directory)"), recursive: false)
            for file in 0..<100 {
                try await local.writeFile(path: WorkspacePath("/d\(directory)/f\(file)"), data: Data("keep".utf8), append: false)
            }
        }
        try await local.writeFile(path: "/x", data: Data("before".utf8), append: false)
        let fs = SignallingFileSystem(base: local, source: local)
        let ws = Workspace(fileSystem: fs)
        let events = await ws.events(.init(includeCheckpoints: false))
        // Drain fixture setup notifications before measuring the external write.
        try await Task.sleep(for: .milliseconds(250))
        let lists = await fs.base.listings.count
        let stats = await fs.base.statCount
        let reads = await fs.base.reads.count
        try await local.writeFile(path: "/x", data: Data("after".utf8), append: false)
        guard case let .changes(change)? = await first(events, timeout: .seconds(30)) else {
            Issue.record("missing native external event"); return
        }
        #expect(change.touchedPaths == ["/x"])
        // Include delayed batches for the same atomic replacement.
        try await Task.sleep(for: .milliseconds(200))
        let refreshed = await Array(fs.base.listings.dropFirst(lists))
        #expect(refreshed.allSatisfy { $0 == .root })
        #expect(refreshed.count <= 4)
        #expect(await fs.base.statCount - stats < 20)
        #expect(await fs.base.reads.dropFirst(reads).allSatisfy { $0 == "/x" })
    }
    #endif

    private func first(_ stream: AsyncStream<WorkspaceEvent>, timeout: Duration = .seconds(30)) async -> WorkspaceEvent? {
        await TestSupport.nextElement(in: stream, timeout: timeout)
    }
}
