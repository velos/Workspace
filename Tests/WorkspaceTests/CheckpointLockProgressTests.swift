import Foundation
import Testing
@testable import Workspace

@Suite("Checkpoint lock progress")
struct CheckpointLockProgressTests {
    // Only Linux reproduces the original deadlock: there Swift's pool and Dispatch's
    // global workers are shared, while on macOS this passes even with blocking flock.
    @Test
    func `contending stores allow an async lock holder to resume`() async throws {
        await #expect(processExitsWith: .success) {
            // A watchdog on its own thread still runs if Dispatch and Swift workers stall.
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: 30)
                exit(124)
            }
            let root = try TestSupport.temporaryDirectory("LockProgress")
            defer { TestSupport.remove(root) }
            let lock = root.appendingPathComponent("test.lock")
            let entered = TestSignal()
            let contenders = LockContenders()
            let holder = FileCheckpointStore(rootDirectory: root)
            let holding = Task {
                try await holder.withExclusiveLock(at: lock) {
                    await entered.signal()
                    await contenders.waitUntilStarted()
                    // Give contended OS waits time to occupy workers before resuming.
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
            await entered.wait()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<256 {
                    group.addTask {
                        let store = FileCheckpointStore(rootDirectory: root)
                        // Persistence must still complete after an accepted edit
                        // cancels its task; a cancelled sleep must not busy-spin.
                        if index.isMultiple(of: 2) { withUnsafeCurrentTask { $0?.cancel() } }
                        await contenders.started()
                        try await store.withExclusiveLock(at: lock) {
                            await contenders.enter()
                            await Task.yield()
                            await contenders.leave()
                        }
                    }
                }
                try await group.waitForAll()
            }
            try await holding.value
            #expect(await contenders.completed == 256)
        }
    }
}

private actor LockContenders {
    private var count = 0
    private var active = 0
    private var ready: CheckedContinuation<Void, Never>?
    private(set) var completed = 0

    func started() {
        count += 1
        if count == 256 { ready?.resume(); ready = nil }
    }
    func waitUntilStarted() async {
        if count == 256 { return }
        await withCheckedContinuation { ready = $0 }
    }
    func enter() {
        active += 1
        #expect(active == 1)
    }
    func leave() {
        active -= 1
        completed += 1
    }
}
