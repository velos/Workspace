import Foundation
import Testing
@testable import Workspace

@Suite("Checkpoint")
struct CheckpointTests {
    @Test
    func `Checkpoint inferredEventKind classifies created rollback and merge`() async throws {
        let workspaceId = UUID()
        let snapshotId = UUID()
        let summary = Checkpoint.Summary(changeCount: 0, touchedPaths: [], hasTextDiffs: false)

        let created = Checkpoint(
            workspaceId: workspaceId,
            label: nil,
            parentCheckpointId: nil,
            baseCheckpointId: nil,
            firstMutationSequence: nil,
            lastMutationSequence: nil,
            mutationCursor: 0,
            snapshotId: snapshotId,
            summary: summary
        )
        #expect(created.inferredEventKind == .created)

        let rolledBack = Checkpoint(
            workspaceId: workspaceId,
            label: nil,
            parentCheckpointId: nil,
            baseCheckpointId: nil,
            rollbackSourceCheckpointId: UUID(),
            firstMutationSequence: nil,
            lastMutationSequence: nil,
            mutationCursor: 0,
            snapshotId: snapshotId,
            summary: summary
        )
        #expect(rolledBack.inferredEventKind == .rolledBack)

        let merged = Checkpoint(
            workspaceId: workspaceId,
            label: nil,
            parentCheckpointId: nil,
            baseCheckpointId: nil,
            mergedFromWorkspaceId: UUID(),
            mergedFromCheckpointId: UUID(),
            firstMutationSequence: nil,
            lastMutationSequence: nil,
            mutationCursor: 0,
            snapshotId: snapshotId,
            summary: summary
        )
        #expect(merged.inferredEventKind == .merged)
    }

    @Test
    func `CheckpointEvent and MutationRecord roundtrip through Codable`() async throws {
        let workspaceId = UUID()
        let summary = Checkpoint.Summary(changeCount: 0, touchedPaths: [], hasTextDiffs: false)
        let checkpoint = Checkpoint(
            workspaceId: workspaceId,
            label: "x",
            parentCheckpointId: nil,
            baseCheckpointId: nil,
            firstMutationSequence: nil,
            lastMutationSequence: nil,
            mutationCursor: 0,
            snapshotId: UUID(),
            summary: summary
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let event = CheckpointEvent(kind: .created, checkpoint: checkpoint)
        #expect(try decoder.decode(CheckpointEvent.self, from: encoder.encode(event)) == event)

        let kinds: [MutationRecord.Kind] = [
            .writeFile,
            .appendFile,
            .writeData,
            .writeJSON,
            .createDirectory,
            .removeItem,
            .copyItem,
            .moveItem,
            .applyEdits,
            .applyReplacement,
            .restoreSnapshot,
            .mergeWorkspace,
        ]

        for kind in kinds {
            let mutation = MutationRecord(
                sequence: 1,
                workspaceId: workspaceId,
                kind: kind,
                touchedPaths: ["/a.txt"],
                fileChanges: []
            )
            let decoded = try decoder.decode(MutationRecord.self, from: encoder.encode(mutation))
            #expect(decoded == mutation)
        }
    }

    @Test
    func `WorkspaceError descriptions are stable and include identifiers`() async throws {
        let checkpointId = UUID()
        let snapshotId = UUID()
        let workspaceId = UUID()
        let headId = UUID()

        let cases: [(WorkspaceError, String)] = [
            (.checkpointNotFound(checkpointId), checkpointId.uuidString),
            (.snapshotNotFound(snapshotId), snapshotId.uuidString),
            (.mergeConflict(parentWorkspaceId: workspaceId, expectedBase: nil, actualHead: headId), workspaceId.uuidString),
            (.mergeConflict(parentWorkspaceId: workspaceId, expectedBase: nil, actualHead: headId), headId.uuidString),
            (.mutationFailed("boom"), "boom"),
        ]

        for (error, needle) in cases {
            let description = String(describing: error)
            #expect(description.contains(needle), "missing '\(needle)' in: \(description)")
        }
    }
}
