import Foundation
import Testing
@testable import Workspace

@Suite("HistoryTypes")
struct HistoryTypesTests {
    @Test
    func `Checkpoint inferredEventKind classifies created, rolledBack, and published`() async throws {
        let workspaceId = UUID()
        let snapshotId = UUID()
        let summary = History.Checkpoint.Summary(changeCount: 0, touchedPaths: [], hasTextDiffs: false)

        let created = History.Checkpoint(
            workspaceId: workspaceId,
            sessionId: nil,
            scope: .shared,
            label: nil,
            parentCheckpointId: nil,
            baseSharedCheckpointId: nil,
            firstMutationSequence: nil,
            lastMutationSequence: nil,
            mutationCursor: 0,
            originSessionId: nil,
            rollbackSourceCheckpointId: nil,
            snapshotId: snapshotId,
            summary: summary
        )
        #expect(created.inferredEventKind == .created)

        let rolledBack = History.Checkpoint(
            workspaceId: workspaceId,
            sessionId: nil,
            scope: .shared,
            label: nil,
            parentCheckpointId: nil,
            baseSharedCheckpointId: nil,
            firstMutationSequence: nil,
            lastMutationSequence: nil,
            mutationCursor: 0,
            originSessionId: nil,
            rollbackSourceCheckpointId: UUID(),
            snapshotId: snapshotId,
            summary: summary
        )
        #expect(rolledBack.inferredEventKind == .rolledBack)

        let published = History.Checkpoint(
            workspaceId: workspaceId,
            sessionId: UUID(),
            scope: .shared,
            label: nil,
            parentCheckpointId: nil,
            baseSharedCheckpointId: nil,
            firstMutationSequence: nil,
            lastMutationSequence: nil,
            mutationCursor: 0,
            originSessionId: UUID(),
            rollbackSourceCheckpointId: nil,
            snapshotId: snapshotId,
            summary: summary
        )
        #expect(published.inferredEventKind == .published)

        let sessionWithOrigin = History.Checkpoint(
            workspaceId: workspaceId,
            sessionId: UUID(),
            scope: .session,
            label: nil,
            parentCheckpointId: nil,
            baseSharedCheckpointId: UUID(),
            firstMutationSequence: nil,
            lastMutationSequence: nil,
            mutationCursor: 0,
            originSessionId: UUID(),
            rollbackSourceCheckpointId: nil,
            snapshotId: snapshotId,
            summary: summary
        )
        #expect(sessionWithOrigin.inferredEventKind == .created)
    }

    @Test
    func `CheckpointEvent scope mirrors checkpoint scope`() async throws {
        let workspaceId = UUID()
        let snapshotId = UUID()
        let summary = History.Checkpoint.Summary(changeCount: 0, touchedPaths: [], hasTextDiffs: false)
        let checkpoint = History.Checkpoint(
            workspaceId: workspaceId,
            sessionId: UUID(),
            scope: .session,
            label: "x",
            parentCheckpointId: nil,
            baseSharedCheckpointId: nil,
            firstMutationSequence: nil,
            lastMutationSequence: nil,
            mutationCursor: 0,
            snapshotId: snapshotId,
            summary: summary
        )
        let event = CheckpointEvent(kind: .created, checkpoint: checkpoint)
        #expect(event.scope == .session)
        #expect(event.checkpoint.scope == event.scope)
    }

    @Test
    func `HistoryError descriptions are stable and include identifiers`() async throws {
        let sessionId = UUID()
        let checkpointId = UUID()
        let snapshotId = UUID()
        let originSession = UUID()

        let cases: [(HistoryError, String)] = [
            (.sessionNotFound(sessionId), sessionId.uuidString),
            (.checkpointNotFound(checkpointId), checkpointId.uuidString),
            (.snapshotNotFound(snapshotId), snapshotId.uuidString),
            (.checkpointScopeMismatch(expected: .shared, actual: .session), "shared"),
            (.checkpointScopeMismatch(expected: .shared, actual: .session), "session"),
            (.checkpointSessionMismatch(checkpointId: checkpointId, expectedSessionId: sessionId, actualSessionId: originSession), checkpointId.uuidString),
            (.publishConflict(sessionId: sessionId, expectedBaseSharedCheckpointId: nil, actualSharedCheckpointId: checkpointId), sessionId.uuidString),
            (.mutationFailed("boom"), "boom"),
        ]

        for (error, needle) in cases {
            let description = String(describing: error)
            #expect(description.contains(needle), "missing '\(needle)' in: \(description)")
        }
    }

    @Test
    func `MutationRecord roundtrips through Codable for representative kinds`() async throws {
        let workspaceId = UUID()
        let sessionId = UUID()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

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
            .publishSessionHead,
        ]

        for kind in kinds {
            let original = MutationRecord(
                sequence: 1,
                workspaceId: workspaceId,
                sessionId: sessionId,
                scope: .shared,
                kind: kind,
                touchedPaths: ["/a.txt"],
                fileChanges: []
            )
            let decoded = try decoder.decode(MutationRecord.self, from: encoder.encode(original))
            #expect(decoded == original)
            #expect(decoded.kind == kind)
        }
    }
}
