#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import Workspace

@Suite("Native observation lifetime")
struct ObservationLifetimeTests {
    @Test
    func cancellationWhileCallbacksAreActive() async throws {
        let root = try TestSupport.temporaryDirectory("ObservationLifetime")
        defer { TestSupport.remove(root) }
        let fs = try LocalFileSystem(root: root)
        let events = try await withThrowingTaskGroup(of: Int.self) { group in
            for worker in 0..<4 {
                group.addTask {
                    var received = 0
                    for _ in 0..<32 {
                        let stream = try await fs.changeSignals()
                        let consumer = Task {
                            var count = 0
                            for await _ in stream { count += 1 }
                            return count
                        }
                        let producer = Task {
                            for i in 0..<32 {
                                try await fs.writeFile(path: WorkspacePath("/file-\(worker)-\(i)"),
                                                       data: Data(count: 32), append: false)
                                try await Task.sleep(for: .milliseconds(2))
                            }
                        }
                        defer { consumer.cancel(); producer.cancel() }
                        // FSEvents has 40ms latency. Cancel with callbacks and more writes
                        // still in flight, then await termination before reusing the root.
                        try await Task.sleep(for: .milliseconds(55))
                        consumer.cancel()
                        received += await consumer.value
                        try await producer.value
                    }
                    return received
                }
            }
            var total = 0
            for try await count in group { total += count }
            return total
        }
        // Exercise real callback delivery as well as 128 cancellation lifetimes.
        #expect(events > 0)
        #expect(try await fs.listDirectory(path: .root).count == 128)
    }
}
#endif
