import Foundation
import Testing
@testable import Workspace

@Suite("Archive validation")
struct WorkspaceArchiveValidationTests {
    @Test
    func `malformed decoded archives are rejected before any mutation`() async throws {
        let workspace = Workspace()
        try await workspace.createDirectory("/keep")
        try await workspace.createDirectory("/Imported")
        try await workspace.writeText("/keep/important", "safe")
        try await workspace.writeText("/Imported/original", "original")
        let before = try await workspace.archive()
        let history = try await workspace.history()
        let file: Workspace.Archive.Entry = .file(path: "/source/good", data: Data("new".utf8), permissions: .defaultFile)
        let invalid: [Workspace.Archive] = [
            .init(root: "/source", entry: .missing("/")),
            .init(root: "/source", entry: .directory(path: "/source", permissions: .defaultDirectory, children: [file, .missing("/keep")])),
            .init(root: "/source", entry: .directory(path: "/source", permissions: .defaultDirectory, children: [.missing("/source/nested/child")])),
            .init(root: "/source", entry: .directory(path: "/source", permissions: .defaultDirectory, children: [file, file])),
            .init(root: "/", entry: .directory(path: "/", permissions: .defaultDirectory, children: [.missing("/")])),
            .init(root: "/source", entry: .directory(path: "/source", permissions: .defaultDirectory, children: [.directory(path: "/source/nested", permissions: .defaultDirectory, children: [.missing("/source/escape")])])),
        ]
        for archive in invalid {
            let decoded = try JSONDecoder().decode(Workspace.Archive.self, from: JSONEncoder().encode(archive))
            do {
                _ = try await workspace.restore(decoded, at: "/Imported")
                Issue.record("invalid archive was accepted")
            } catch let error as WorkspaceError {
                #expect(error.description.contains("invalid archive"))
            }
            #expect(try await workspace.archive() == before)
            #expect(try await workspace.history() == history)
        }
    }
}
