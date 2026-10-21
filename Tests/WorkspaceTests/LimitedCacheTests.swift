import Foundation
import Testing
#if os(Linux)
import Glibc
#endif
@testable import Workspace

@Suite("Limited accounting cache", .serialized)
struct LimitedCacheTests {
    // Quota errors expose the projected totals at the public boundary. The independent
    // oracle enumerates the real backend after each mutation, without resetting the cache.
    private func checkTotals(_ limited: LimitedFileSystem, base: any FileSystem) async throws {
        var bytes: UInt64 = 0
        var entries = 0
        var pending: [WorkspacePath] = [.root]
        while let path = pending.popLast() {
            let info = try await base.stat(path: path)
            if !path.isRoot { entries += 1 }
            if info.kind == .file { bytes += info.size }
            if info.kind == .directory {
                pending.append(contentsOf: try await base.listDirectory(path: path).map { path.appending($0.name) })
            }
        }
        await #expect(throws: FileSystemLimitError.totalBytes(attempted: bytes + 101, limit: 100)) {
            try await limited.createFile(path: "/byte-probe", data: Data(count: 101))
        }
        let deep = WorkspacePath(normalizing: (0..<17).map { "entry-probe-\($0)" }.joined(separator: "/"))
        await #expect(throws: FileSystemLimitError.entryCount(attempted: entries + 17, limit: 16)) {
            try await limited.createDirectory(path: deep, recursive: true)
        }
    }

    @Test(arguments: ["memory", "signals", "opaque aliases"])
    func mutationSequencesMatchFreshMetadata(backend: String) async throws {
        let memory = InMemoryFileSystem()
        let base: any FileSystem = backend == "memory" ? memory
            : LimitedCacheBackend(memory: memory, opaqueAliases: backend == "opaque aliases")
        let fs = LimitedFileSystem(base: base, limits: .init(maxTotalBytes: 100, maxEntryCount: 16))
        try await checkTotals(fs, base: memory)
        try await fs.createDirectory(path: "/dir/sub", recursive: true)
        try await checkTotals(fs, base: memory)
        try await fs.createFile(path: "/dir/sub/file", data: Data(count: 3))
        try await checkTotals(fs, base: memory)
        try await fs.writeFile(path: "/dir/sub/file", data: Data(count: 2), append: true)
        try await checkTotals(fs, base: memory)
        try await fs.createHardLink(path: "/alias", target: "/dir/sub/file")
        try await checkTotals(fs, base: memory)
        try await fs.writeFile(path: "/alias", data: Data(count: 1), append: true)
        try await checkTotals(fs, base: memory)
        try await fs.writeFile(path: "/alias", data: Data(count: 2), append: false)
        try await checkTotals(fs, base: memory)
        try await fs.createSymlink(path: "/sym", target: "/dir/sub/file")
        try await checkTotals(fs, base: memory)
        try await fs.writeFile(path: "/sym", data: Data(count: 1), append: true)
        try await checkTotals(fs, base: memory)
        try await fs.createSymlink(path: "/dangling", target: "/missing")
        try await checkTotals(fs, base: memory)
        try await fs.writeFile(path: "/dangling", data: Data(count: 4), append: false)
        try await checkTotals(fs, base: memory)
        try await fs.copy(from: "/dir", to: "/copy", recursive: true)
        try await checkTotals(fs, base: memory)
        try await fs.move(from: "/copy", to: "/moved")
        try await checkTotals(fs, base: memory)
        try await fs.remove(path: "/dir", recursive: true)
        try await checkTotals(fs, base: memory)
        try await fs.createHardLink(path: "/other", target: "/missing")
        try await checkTotals(fs, base: memory)
        try await fs.writeFile(path: "/missing", data: Data(count: 1), append: false)
        try await checkTotals(fs, base: memory)
        try await fs.remove(path: "/moved", recursive: true)
        try await checkTotals(fs, base: memory)
        try await fs.remove(path: "/does-not-exist", recursive: true)
        try await checkTotals(fs, base: memory)
    }

    @Test(arguments: [false, true])
    func warmMutationsDoNotEnumerateUnchangedSubtrees(mountedAliases: Bool) async throws {
        let base = LimitedCacheBackend()
        for i in 0..<200 {
            try await base.memory.createDirectory(path: WorkspacePath("/dir-\(i)"), recursive: false)
            try await base.memory.createFile(path: WorkspacePath("/dir-\(i)/file"), data: Data(count: 2))
        }
        let wrapped: any FileSystem = mountedAliases ? MountedFileSystem(base: LimitedCacheBackend(), mounts: [
            .init(mountPoint: "/a", fileSystem: base), .init(mountPoint: "/b", fileSystem: base)
        ]) : base
        let fs = LimitedFileSystem(base: wrapped, limits: .init(maxTotalBytes: 10_000))
        let file: WorkspacePath = mountedAliases ? "/a/dir-0/file" : "/dir-0/file"
        let new: WorkspacePath = mountedAliases ? "/a/dir-0/new" : "/dir-0/new"
        try await fs.writeFile(path: file, data: Data(count: 3), append: false)
        await base.clearReads()
        try await fs.writeFile(path: file, data: Data(count: 1), append: true)
        try await fs.createFile(path: new, data: Data(count: 1))
        try await fs.remove(path: new, recursive: false)
        #expect(await base.listed.isEmpty)
    }

    @Test
    func externalScopesReconcileOnlyTheirCoverage() async throws {
        let base = LimitedCacheBackend()
        try await base.memory.createDirectory(path: "/untouched/deep", recursive: true)
        try await base.memory.writeFile(path: "/untouched/deep/file", data: Data(count: 2), append: false)
        try await base.memory.createDirectory(path: "/changed/old", recursive: true)
        try await base.memory.writeFile(path: "/changed/file", data: Data(count: 3), append: false)
        let fs = LimitedFileSystem(base: base, limits: .init(maxTotalBytes: 100, maxEntryCount: 16))
        try await checkTotals(fs, base: base.memory)
        await base.clearReads()
        try await base.memory.writeFile(path: "/changed/file", data: Data(count: 6), append: false)
        await base.signal(.paths(["/changed/file": .entry]))
        try await waitForBytes(8, fs: fs)
        #expect(await base.listed.isEmpty)
        try await checkTotals(fs, base: base.memory)

        await base.clearReads()
        try await base.memory.remove(path: "/changed/old", recursive: true)
        try await base.memory.createDirectory(path: "/changed/new/deep", recursive: true)
        try await base.memory.writeFile(path: "/changed/new/deep/file", data: Data(count: 4), append: false)
        await base.signal(.paths(["/changed": .shallow]))
        try await waitForBytes(12, fs: fs)
        #expect(await base.listed.contains("/changed/new/deep"))
        #expect(!(await base.listed.contains("/untouched")))
        try await checkTotals(fs, base: base.memory)

        await base.clearReads()
        try await base.memory.remove(path: "/changed", recursive: true)
        try await base.memory.createSymlink(path: "/changed", target: "/untouched/deep")
        await base.signal(.paths(["/changed": .entry]))
        try await waitForBytes(2, fs: fs)
        try await checkTotals(fs, base: base.memory)
        #expect(!(await base.listed.contains("/untouched")))
        // Delayed events for the former directory's children must not follow its
        // replacement symlink and charge the target file a second time.
        try await base.memory.writeFile(path: "/untouched/deep/file", data: Data(count: 3), append: false)
        await base.signal(.paths(["/changed/file": .entry, "/untouched/deep/file": .entry]))
        try await waitForBytes(3, fs: fs)
        try await checkTotals(fs, base: base.memory)

        try await base.memory.createDirectory(path: "/added/deep", recursive: true)
        try await base.memory.writeFile(path: "/added/deep/file", data: Data(count: 5), append: false)
        await base.signal(.paths(["/added": .recursive]))
        try await waitForBytes(8, fs: fs)
        try await checkTotals(fs, base: base.memory)
    }

    @Test(arguments: ["all", "root"])
    func opaqueDirectoryAliasesInvalidateUncertainMutationEffects(missingIdentities: String) async throws {
        let base = LimitedCacheBackend(opaqueAliases: missingIdentities == "all", opaqueRootIdentity: missingIdentities == "root")
        try await base.memory.createDirectory(path: "/dir", recursive: false)
        try await base.memory.createFile(path: "/dir/file", data: Data(count: 3))
        let mounted = missingIdentities == "root"
            ? MountedFileSystem(base: base, mounts: [.init(mountPoint: "/a", fileSystem: base.memory)])
            : MountedFileSystem(base: LimitedCacheBackend(), mounts: [
                .init(mountPoint: "/a", fileSystem: base), .init(mountPoint: "/b", fileSystem: base)
            ])
        let fs = LimitedFileSystem(base: mounted, limits: .init(maxTotalBytes: 100, maxEntryCount: 16))
        try await checkTotals(fs, base: mounted)
        try await fs.createFile(path: "/a/new", data: Data(count: 2))
        try await checkTotals(fs, base: mounted)
        try await fs.writeFile(path: "/a/dir/file", data: Data(count: 5), append: false)
        try await checkTotals(fs, base: mounted)
        try await fs.remove(path: "/a/new", recursive: false)
        try await checkTotals(fs, base: mounted)
    }

    @Test
    func directoryAliasRemovalClearsChildrenWithoutFileIdentities() async throws {
        let base = LimitedCacheBackend(opaqueFileIdentities: true)
        try await base.memory.createDirectory(path: "/dir", recursive: false)
        try await base.memory.createFile(path: "/dir/file", data: Data(count: 3))
        let mounted = MountedFileSystem(base: LimitedCacheBackend(), mounts: [
            .init(mountPoint: "/a", fileSystem: base), .init(mountPoint: "/b", fileSystem: base)
        ])
        let fs = LimitedFileSystem(base: mounted, limits: .init(maxTotalBytes: 100, maxEntryCount: 16))
        try await checkTotals(fs, base: mounted)
        try await base.memory.remove(path: "/dir", recursive: true)
        await base.signal(.paths(["/dir": .entry]))
        try await waitForBytes(0, fs: fs)
        try await checkTotals(fs, base: mounted)
    }

    @Test
    func rescanTerminationAndSubscriptionFailureDiscardCachedUsage() async throws {
        let base = LimitedCacheBackend()
        let fs = LimitedFileSystem(base: base, limits: .init(maxTotalBytes: 100, maxEntryCount: 16))
        try await checkTotals(fs, base: base.memory)
        try await base.memory.writeFile(path: "/external", data: Data(count: 8), append: false)
        await base.signal(.rescan)
        try await waitForBytes(8, fs: fs)
        #expect(await base.listed.filter { $0.isRoot }.count >= 2)
        await base.finish()
        try await base.memory.writeFile(path: "/external", data: Data(count: 10), append: false)
        try await waitForBytes(10, fs: fs)
        try await base.memory.writeFile(path: "/external", data: Data(count: 12), append: false)
        try await checkTotals(fs, base: base.memory)

        let unavailable = LimitedCacheBackend(subscriptionFails: true)
        let fallback = LimitedFileSystem(base: unavailable, limits: .init(maxTotalBytes: 100, maxEntryCount: 16))
        try await checkTotals(fallback, base: unavailable.memory)
        try await unavailable.memory.writeFile(path: "/external", data: Data(count: 7), append: false)
        try await checkTotals(fallback, base: unavailable.memory)
    }

    @Test
    func revalidationClosesUndeliveredSignalGap() async throws {
        let base = LimitedCacheBackend()
        let fs = LimitedFileSystem(base: base, limits: .init(maxTotalBytes: 100, maxEntryCount: 16))
        try await checkTotals(fs, base: base.memory)
        try await base.memory.writeFile(path: "/external", data: Data(count: 8), append: false)
        // No signal has been delivered. The cached snapshot is permitted to remain old.
        await #expect(throws: FileSystemLimitError.totalBytes(attempted: 101, limit: 100)) {
            try await fs.createFile(path: "/probe", data: Data(count: 101))
        }
        try await fs.revalidate()
        try await checkTotals(fs, base: base.memory)
    }

    @Test
    func partialMutationAndRefreshFailureRecoverOnNextPreflight() async throws {
        let base = LimitedCacheBackend()
        let fs = LimitedFileSystem(base: base, limits: .init(maxTotalBytes: 100, maxEntryCount: 16))
        try await checkTotals(fs, base: base.memory)
        await base.failNextMutation()
        await #expect(throws: CacheTestError.injected) {
            try await fs.copy(from: "/", to: "/partial", recursive: true)
        }
        try await checkTotals(fs, base: base.memory)
        await base.failNextRefresh()
        try await fs.createFile(path: "/successful", data: Data(count: 5))
        #expect(try await base.memory.stat(path: "/successful").size == 5)
        try await checkTotals(fs, base: base.memory)
    }

    @Test
    func signalDuringMutationSurvivesCacheCommitAndGateSerializesWriters() async throws {
        let base = LimitedCacheBackend()
        let fs = LimitedFileSystem(base: base, limits: .init(maxTotalBytes: 10))
        try await fs.revalidate()
        let latch = CacheMutationLatch()
        await base.pauseNextWrite(latch)
        let first = Task { try await fs.writeFile(path: "/first", data: Data(count: 4), append: false) }
        await latch.waitForEntry()
        try await base.memory.writeFile(path: "/external", data: Data(count: 3), append: false)
        await base.signal(.paths(["/external": .entry]))
        let others = Task {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                for i in 0..<20 {
                    group.addTask {
                        do {
                            try await fs.createFile(path: WorkspacePath("/other-\(i)"), data: Data(count: 4))
                            return true
                        } catch is FileSystemLimitError { return false }
                    }
                }
                var successes = 0
                for try await success in group where success { successes += 1 }
                return successes
            }
        }
        await latch.release()
        try await first.value
        #expect(try await others.value <= 1) // Delivery may lag a preflight; the gate never overspends its snapshot.
        // A delivered signal must survive the successful mutation's readback.
        try await waitForBytes(try await base.memory.listDirectory(path: .root).reduce(0) { $0 + $1.info.size }, fs: fs, limit: 10)
    }

    @Test
    func memoryGenerationDetectsExternalChangesIncludingPartialFailureAndReset() async throws {
        let memory = InMemoryFileSystem()
        let fs = LimitedFileSystem(base: memory, limits: .init(maxTotalBytes: 100, maxEntryCount: 16))
        try await checkTotals(fs, base: memory)
        try await memory.writeFile(path: "/new/deep/external", data: Data(count: 5), append: false)
        try await checkTotals(fs, base: memory)
        try await memory.createFile(path: "/dir/file", data: Data(count: 2))
        try await memory.createHardLink(path: "/alias", target: "/dir/file")
        try await checkTotals(fs, base: memory)
        try await memory.writeFile(path: "/alias", data: Data(count: 1), append: true)
        try await checkTotals(fs, base: memory)
        try await memory.move(from: "/new/deep/external", to: "/moved")
        try await memory.copy(from: "/dir", to: "/copy", recursive: true)
        try await memory.createSymlink(path: "/link", target: "/absent")
        try await checkTotals(fs, base: memory)
        try await memory.remove(path: "/copy", recursive: true)
        await memory.reset()
        try await checkTotals(fs, base: memory)
    }

    @Test(arguments: [0, 3, 4, 5])
    func accountingCacheCapIncludesRootAndIsInclusive(cap: Int) async throws {
        // Three files plus the root: only caps of at least four may retain this walk.
        let base = LimitedCacheBackend(fixedEntryCount: 3)
        let fs = LimitedFileSystem(base: base, limits: .init(maxTotalBytes: 100),
                                   accountingCacheEntryLimit: cap)
        try await fs.revalidate()
        await base.clearReads()
        for _ in 0..<2 {
            await #expect(throws: FileSystemLimitError.totalBytes(attempted: 101, limit: 100)) {
                try await fs.createFile(path: "/probe", data: Data(count: 101))
            }
        }
        #expect(await base.listed.filter { $0.isRoot }.count == (cap < 4 ? 2 : 0))
    }

    @Test(arguments: [0, 2])
    func successfulMutationsRespectAccountingCacheCap(cap: Int) async throws {
        let base = LimitedCacheBackend()
        let fs = LimitedFileSystem(base: base, limits: .init(maxTotalBytes: 100),
                                   accountingCacheEntryLimit: cap)
        try await fs.createFile(path: "/a", data: Data(count: 10))
        await base.clearReads()
        for _ in 0..<2 {
            await #expect(throws: FileSystemLimitError.totalBytes(attempted: 111, limit: 100)) {
                try await fs.createFile(path: "/probe", data: Data(count: 101))
            }
        }
        #expect(await base.listed.filter { $0.isRoot }.count == (cap == 0 ? 2 : 0))

        // Adding a second file takes the retained entry count from two to three.
        try await fs.createFile(path: "/b", data: Data(count: 20))
        await base.clearReads()
        await #expect(throws: FileSystemLimitError.totalBytes(attempted: 131, limit: 100)) {
            try await fs.createFile(path: "/probe", data: Data(count: 101))
        }
        #expect(await base.listed.filter { $0.isRoot }.count == 1)
    }

    @Test
    func permissionsRefreshOnlyTheirSubtreeAndShallowReusesListingMetadata() async throws {
        let base = LimitedCacheBackend()
        try await base.memory.createDirectory(path: "/changed/sub", recursive: true)
        try await base.memory.createDirectory(path: "/untouched", recursive: false)
        try await base.memory.writeFile(path: "/changed/sub/file", data: Data(count: 3), append: false)
        try await base.memory.writeFile(path: "/untouched/file", data: Data(count: 4), append: false)
        let fs = LimitedFileSystem(base: base, limits: .init(maxTotalBytes: 100, maxEntryCount: 16))
        try await checkTotals(fs, base: base.memory)
        await base.clearReads()
        try await fs.setPermissions(path: "/changed", permissions: .defaultDirectory)
        try await checkTotals(fs, base: base.memory)
        #expect(await base.listed.contains("/changed/sub"))
        #expect(!(await base.listed.contains(.root)))
        #expect(!(await base.listed.contains("/untouched")))
        await base.clearReads()
        try await base.memory.writeFile(path: "/changed/new", data: Data(count: 2), append: false)
        await base.signal(.paths(["/changed": .shallow]))
        try await waitForBytes(9, fs: fs)
        #expect(!(await base.statted.contains("/changed/new")))
        #expect(!(await base.statted.contains("/changed/sub")))
        try await checkTotals(fs, base: base.memory)
    }

    @Test
    func mountedSubscriptionFailureCannotRetainAccounting() async throws {
        let unavailable = LimitedCacheBackend(subscriptionFails: true)
        let mounted = MountedFileSystem(base: LimitedCacheBackend(), mounts: [
            .init(mountPoint: "/failed", fileSystem: unavailable)
        ])
        let fs = LimitedFileSystem(base: mounted, limits: .init(maxTotalBytes: 100, maxEntryCount: 16))
        try await fs.revalidate()
        try await unavailable.memory.writeFile(path: "/external", data: Data(count: 8), append: false)
        try await waitForBytes(8, fs: fs)
        try await unavailable.memory.writeFile(path: "/external", data: Data(count: 12), append: false)
        try await checkTotals(fs, base: mounted)
    }

    @Test
    func syntheticMountParentsKeepWarmAccounting() async throws {
        let base = LimitedCacheBackend()
        let mounted = MountedFileSystem(base: base, mounts: [
            .init(mountPoint: "/deep/m", fileSystem: LimitedCacheBackend())
        ])
        let fs = LimitedFileSystem(base: mounted, limits: .init(maxTotalBytes: 100, maxEntryCount: 16))
        try await fs.writeFile(path: "/deep/m/a", data: Data(count: 3), append: false)
        try await Task.sleep(for: .milliseconds(100)) // Initial topology rescan.
        try await checkTotals(fs, base: mounted)
        await base.clearReads()
        try await fs.writeFile(path: "/deep/m/a", data: Data(count: 1), append: true)
        #expect(await base.listed.isEmpty)
        try await checkTotals(fs, base: mounted)
    }

    #if os(macOS) || os(Linux)
    @Test
    func realLocalExternalSignalsConvergeToFreshWalk() async throws {
        let root = try TestSupport.temporaryDirectory("LimitedNativeSignals")
        defer { TestSupport.remove(root) }
        let base = try LocalFileSystem(root: root)
        // Require a working native watcher; a full-walk fallback would hide this regression.
        let control = try await base.changeSignals()
        let monitor = Task { for await _ in control {} }
        defer { monitor.cancel() }
        let fs = LimitedFileSystem(base: base, limits: .init(maxTotalBytes: 100, maxEntryCount: 16))
        try await fs.writeFile(path: "/a", data: Data(count: 3), append: false)
        try await base.writeFile(path: "/dir/file", data: Data(count: 5), append: false)
        try await waitForBytes(8, entries: 3, fs: fs)
        try await checkTotals(fs, base: base)
        try await base.createHardLink(path: "/alias", target: "/dir/file")
        try await base.writeFile(path: "/alias", data: Data(count: 2), append: true)
        try await waitForBytes(17, entries: 4, fs: fs)
        try await checkTotals(fs, base: base)
        try await base.move(from: "/dir", to: "/moved")
        try await base.createSymlink(path: "/dangling", target: "/absent")
        try await base.remove(path: "/a", recursive: false)
        try await waitForBytes(14, entries: 4, fs: fs)
        try await checkTotals(fs, base: base)
        try await base.remove(path: "/moved", recursive: true)
        try await waitForBytes(7, entries: 2, fs: fs)
        try await checkTotals(fs, base: base)
        #if os(Linux)
        if geteuid() != 0 {
            try await base.createDirectory(path: "/locked", recursive: false)
            try await base.setPermissions(path: "/locked", permissions: POSIXPermissions(0))
            // Wait until registration has encountered the unwatchable child.
            try await Task.sleep(for: .milliseconds(100))
            await #expect(throws: (any Error).self) { try await fs.revalidate() }
            try await base.setPermissions(path: "/locked", permissions: .defaultDirectory)
            try await base.writeFile(path: "/locked/file", data: Data(count: 2), append: false)
            try await waitForBytes(9, entries: 4, fs: fs)
            try await Task.sleep(for: .milliseconds(100))
            try await waitForBytes(9, entries: 4, fs: fs)
            // After the permission event has been consumed, a second child write must
            // have its own watch; a stale shallow invalidation cannot hide a gap.
            try await base.writeFile(path: "/locked/file", data: Data(count: 3), append: false)
            try await waitForBytes(10, entries: 4, fs: fs)
            try await checkTotals(fs, base: base)
        }
        #endif
    }
    #endif

    private func waitForBytes(_ bytes: UInt64, entries: Int? = nil, fs: LimitedFileSystem, limit: UInt64 = 100) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while true {
            do {
                try await fs.createFile(path: "/byte-probe", data: Data(count: Int(limit + 1)))
                Issue.record("quota probe unexpectedly succeeded")
                return
            } catch let error as FileSystemLimitError {
                if error == .totalBytes(attempted: bytes + limit + 1, limit: limit) {
                    guard let entries else { return }
                    // File removal and directory retirement can arrive separately.
                    // Correct bytes alone do not prove that all entries converged.
                    let deep = WorkspacePath(normalizing: (0..<17).map { "entry-probe-\($0)" }.joined(separator: "/"))
                    do {
                        try await fs.createDirectory(path: deep, recursive: true)
                        Issue.record("entry quota probe unexpectedly succeeded")
                        return
                    } catch let entryError as FileSystemLimitError {
                        if entryError == .entryCount(attempted: entries + 17, limit: 16) { return }
                        if ContinuousClock.now >= deadline {
                            Issue.record("unexpected entry usage: \(entryError), expected \(entries)"); return
                        }
                    }
                } else if ContinuousClock.now >= deadline {
                    Issue.record("unexpected usage: \(error), expected \(bytes)"); return
                }
            }
            await Task.yield()
        }
    }
}

private enum CacheTestError: Error { case injected }

// Own mutations do not emit events: cache correctness cannot depend on self-notifications.
// All content reads fail, so these tests also protect metadata-only accounting.
private actor LimitedCacheBackend: CompleteFileSystemChangeSource, PotentialPathResolvingFileSystem {
    var changeSignalsAreComplete: Bool { true }
    nonisolated let memory: InMemoryFileSystem
    private let stream: AsyncStream<FileSystemChangeSignal>
    private let continuation: AsyncStream<FileSystemChangeSignal>.Continuation
    private let subscriptionFails: Bool
    private let fixedEntryCount: Int
    private let opaqueAliases: Bool
    private let opaqueFileIdentities: Bool
    private let opaqueRootIdentity: Bool
    private var partialFailure = false
    private var refreshFailure = false
    private var failStat = false
    private var latch: CacheMutationLatch?
    private(set) var listed: [WorkspacePath] = []
    private(set) var statted: [WorkspacePath] = []
    init(memory: InMemoryFileSystem = InMemoryFileSystem(), fixedEntryCount: Int = 0, subscriptionFails: Bool = false, opaqueAliases: Bool = false, opaqueFileIdentities: Bool = false, opaqueRootIdentity: Bool = false) {
        self.memory = memory
        self.fixedEntryCount = fixedEntryCount
        self.subscriptionFails = subscriptionFails
        self.opaqueAliases = opaqueAliases
        self.opaqueFileIdentities = opaqueFileIdentities
        self.opaqueRootIdentity = opaqueRootIdentity
        (stream, continuation) = AsyncStream.makeStream()
    }
    func signal(_ signal: FileSystemChangeSignal) { continuation.yield(signal) }
    func finish() { continuation.finish() }
    func clearReads() { listed.removeAll(); statted.removeAll() }
    func failNextMutation() { partialFailure = true }
    func failNextRefresh() { refreshFailure = true }
    func pauseNextWrite(_ latch: CacheMutationLatch) { self.latch = latch }
    func changeSignals() async throws -> AsyncStream<FileSystemChangeSignal> {
        if subscriptionFails { throw CacheTestError.injected }
        return stream
    }
    func stat(path: WorkspacePath) async throws -> FileInfo {
        statted.append(path)
        if path.dirname.isRoot, path.basename.hasPrefix("fixed-"),
           let index = Int(path.basename.dropFirst(6)), (0..<fixedEntryCount).contains(index) {
            return fixedInfo(index)
        }
        if failStat { failStat = false; throw CacheTestError.injected }
        return metadata(try await memory.stat(path: path))
    }
    private func metadata(_ info: FileInfo) -> FileInfo {
        var info = info
        if opaqueAliases { info.identity = nil; info.linkCount = nil }
        if opaqueFileIdentities, info.kind == .file { info.identity = nil }
        if opaqueRootIdentity, info.path.isRoot { info.identity = nil }
        return info
    }
    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        listed.append(path)
        var entries = try await memory.listDirectory(path: path).map {
            DirectoryEntry(name: $0.name, info: metadata($0.info))
        }
        if path.isRoot {
            entries += (0..<fixedEntryCount).map { DirectoryEntry(name: "fixed-\($0)", info: fixedInfo($0)) }
        }
        return entries
    }
    private func fixedInfo(_ index: Int) -> FileInfo {
        FileInfo(path: WorkspacePath(normalizing: "/fixed-\(index)"), kind: .file, size: 0,
                 permissions: .defaultFile, modificationDate: nil,
                 identity: FileIdentity(device: 0, inode: UInt64(index)), linkCount: 1)
    }
    func readFile(path: WorkspacePath) async throws -> Data { throw CacheTestError.injected }
    func exists(path: WorkspacePath) async -> Bool { await memory.exists(path: path) }
    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try await memory.glob(pattern: pattern, currentDirectory: currentDirectory)
    }
    func createFile(path: WorkspacePath, data: Data) async throws {
        try await memory.createFile(path: path, data: data)
        if refreshFailure { refreshFailure = false; failStat = true }
    }
    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        if let latch { self.latch = nil; await latch.enter() }
        try await memory.writeFile(path: path, data: data, append: append)
    }
    func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        try await memory.createDirectory(path: path, recursive: recursive)
    }
    func remove(path: WorkspacePath, recursive: Bool) async throws { try await memory.remove(path: path, recursive: recursive) }
    func move(from: WorkspacePath, to: WorkspacePath) async throws { try await memory.move(from: from, to: to) }
    func copy(from: WorkspacePath, to: WorkspacePath, recursive: Bool) async throws {
        if partialFailure {
            partialFailure = false
            try await memory.createDirectory(path: to, recursive: true)
            try await memory.createFile(path: to.appending("written-before-failure"), data: Data(count: 7))
            throw CacheTestError.injected
        }
        try await memory.copy(from: from, to: to, recursive: recursive)
    }
    func createSymlink(path: WorkspacePath, target: String) async throws { try await memory.createSymlink(path: path, target: target) }
    func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws { try await memory.createHardLink(path: path, target: target) }
    func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        try await memory.setPermissions(path: path, permissions: permissions)
    }
    func readSymlink(path: WorkspacePath) async throws -> String { try await memory.readSymlink(path: path) }
    func capabilities() async -> FileSystemFeatures { await memory.capabilities() }
    func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath { try await memory.resolveRealPath(path: path) }
    func resolvePotentialPath(path: WorkspacePath) async throws -> WorkspacePath { try await memory.resolvePotentialPath(path: path) }
}

private actor CacheMutationLatch {
    private var entered = false
    private var writer: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func enter() async {
        entered = true
        observer?.resume()
        observer = nil
        await withCheckedContinuation { writer = $0 }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { observer = $0 } } }
    func release() { writer?.resume(); writer = nil }
}

extension LimitedCacheTests {
    @Test
    func `authorization filtering disables cached coverage so hidden external growth is counted`() async throws {
        let root = try TestSupport.temporaryDirectory("LimitedAuthorizedCoverage")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        try await local.createDirectory(path: "/dir/sub", recursive: true)
        try await local.writeFile(path: "/dir/sub/secret", data: Data(count: 1), append: false)
        // A stat denial makes AuthorizedFileSystem drop that path's change signals.
        let authorized = AuthorizedFileSystem(base: local, authorizer: PermissionAuthorizer { request in
            request.operation == .stat && request.path == "/dir/sub/secret" ? .deny(message: nil) : .allow
        })
        #expect(await authorized.changeSignalsAreComplete == false)
        let limited = LimitedFileSystem(base: authorized, limits: .init(maxTotalBytes: 100))
        try await limited.writeFile(path: "/a", data: Data(count: 10), append: false)

        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("dir/sub/secret"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 84))
        try handle.close()

        await #expect(throws: (any Error).self) {
            try await limited.writeFile(path: "/b", data: Data(count: 10), append: false)
        }
    }
}
