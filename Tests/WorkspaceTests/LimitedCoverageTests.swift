import Foundation
import Testing
@testable import Workspace

@Suite("Limited observation coverage", .serialized)
struct LimitedCoverageTests {
    @Test(arguments: ["memory base", "memory mount", "later memory mount"])
    func incompleteMountedCoverageSeesDirectWrites(configuration: String) async throws {
        let root = try TestSupport.temporaryDirectory("LimitedCoverage")
        defer { TestSupport.remove(root) }
        let memory = InMemoryFileSystem()
        let mounted = configuration == "memory base" ? MountedFileSystem(base: memory)
            : MountedFileSystem(base: try LocalFileSystem(root: root))
        if configuration == "memory mount" { mounted.mount("/memory", fileSystem: memory) }
        let fs = LimitedFileSystem(base: mounted, limits: .init(maxTotalBytes: 100))
        try await fs.writeFile(path: "/a", data: Data(count: 10), append: false)
        // Let the initial topology rescan settle, so it cannot mask missing coverage.
        try await Task.sleep(for: .milliseconds(300))
        if configuration == "later memory mount" { mounted.mount("/memory", fileSystem: memory) }
        try await memory.writeFile(path: "/external", data: Data(count: 85), append: false)
        try await Task.sleep(for: .milliseconds(1500))
        await #expect(throws: FileSystemLimitError.totalBytes(attempted: 105, limit: 100)) {
            try await fs.writeFile(path: "/b", data: Data(count: 10), append: false)
        }
        #expect(!(await mounted.exists(path: "/b")))
    }
}
