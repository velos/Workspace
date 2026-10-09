# Workspace

`Workspace` is a Swift package for agent and tool runtimes that need controlled filesystem access, structured edits, revision history, and isolated transactions without shell parsing.

The package is beta software. Its rooted filesystems, authorization rules, and limits are useful safety layers, but they are not a hardened process sandbox.

## Installation

```swift
.dependencies: [
    .package(path: "../Workspace")
]
```

The package contains one library product, `Workspace`, and has no external dependencies.

## The Model

The public API centers on a small set of concepts:

- `Workspace` owns current mutable state, history, checkpoints, and events.
- `Revision` addresses either the current state or a checkpoint.
- `Edit` describes a mutation.
- `ChangeSet` is the common result used by previews, edits, history, events, diffs, and transactions.
- `Workspace.Transaction` provides isolated preview, three-way commit, and discard.
- `FileSystem` is the low-level protocol for custom storage backends.

## Create a Workspace

An empty in-memory workspace needs no configuration:

```swift
import Workspace

let workspace = Workspace()
try await workspace.writeText("/notes/todo.txt", "ship it\n")
let text = try await workspace.readText("/notes/todo.txt")
```

Use a rooted local filesystem and persisted revision store when state should survive process exit:

```swift
let files = try LocalFileSystem(root: projectURL)
let workspace = Workspace(
    workspaceID: projectID,
    fileSystem: files,
    persistence: .directory(historyURL),
    recording: .full(maxTextBytes: 1_000_000)
)
```

The injected filesystem remains available as `workspace.fileSystem` so one `Workspace` can be
shared as the filesystem authority across shells, tool runtimes, and other adapters. Reads through
that reference are always fine. Mutations made directly through it bypass Workspace history,
checkpoints, and events, so integrations should either route mutations through the Workspace edit
pipeline or deliberately accept that those changes are unrecorded.

## Edits and Changes

Every mutation returns the same structured `ChangeSet`:

```swift
let preview = try await workspace.preview([
    .createDirectory("/Sources"),
    .writeText("/Sources/main.swift", "print(\"hello\")\n")
])

let result = try await workspace.apply([
    .createDirectory("/Sources"),
    .writeText("/Sources/main.swift", "print(\"hello\")\n")
])

print(result.changes.touchedPaths)
print(result.changes.statistics.additions)
```

`apply` is atomic by default. `.stopOnError` and `.continueAfterError` expose partial failures explicitly.
Atomic recovery does not track hard-link aliases outside captured roots or roll back permission changes to symlink entries.

Direct conveniences—`writeText`, `writeData`, `appendText`, `createDirectory`, `remove`, `copy`, `move`, link creation, and permission changes—use the same edit pipeline.

Text replacement is an edit and shares its file selection and pattern engine with search:

```swift
let swiftFiles = FileSelection(
    root: "/Sources",
    include: ["**/*.swift"],
    exclude: ["**/Generated/**"]
)

try await workspace.apply([
    .replace(files: swiftFiles, pattern: .literal("OldName"), with: "NewName")
])
```

## Search

```swift
let result = try await workspace.search(
    SearchRequest(
        pattern: .regularExpression(#"\bTODO\b"#),
        files: swiftFiles,
        contextLines: 2
    )
)

for match in result.matches {
    print("\(match.path):\(match.lineNumber): \(match.line)")
}
```

Search is deterministic, line-oriented, does not follow symlinks, and reports binary, oversized, or truncated work as structured result data.

## Checkpoints, Revisions, and Diffs

Checkpoints are persisted revisions; there is no second public snapshot representation.

```swift
let before = try await workspace.createCheckpoint(label: "before")
try await workspace.writeText("/README.md", "Updated\n")
let after = try await workspace.createCheckpoint(label: "after")

let oldText = try await workspace.readText(
    "/README.md",
    at: .checkpoint(before.id)
)

let changes = try await workspace.diff(
    from: .checkpoint(before.id),
    to: .checkpoint(after.id)
)
```

Checkpoint reads use cached in-memory indexes or persisted manifest metadata, resolve directory
symlinks inside the workspace namespace (at most 64 hops), and read selected byte ranges without
materializing whole blobs. `TextDiff` includes total line counts, addition/deletion statistics,
hunks, and UTF-16 intra-line ranges. Empty and identical inputs and unchanged prefixes/suffixes
avoid the general diff search. A Myers search preserves sparse edits; if its work or edit-distance
limit is reached, the unmatched interior uses a coarse replacement hunk. Its statistics describe
the emitted additions/deletions and may exceed a minimal edit script. The line search and each
intra-line pair have independent limits of 1,000 edits or 1,000,000 visited search steps.

Use `Workspace.Archive` only when a fully materialized, portable subtree is actually required:

```swift
let archive = try await workspace.archive(at: "/Sources")
try await anotherWorkspace.restore(archive, at: "/Imported")
```

## Storage Lifecycle

Inspect checkpoint-store usage and preview retention before deleting anything:

```swift
let usage = try await workspace.storageStatistics()

let preview = try await workspace.compact(
    retaining: .latest(
        50,
        preservingLabeled: true,
        preserving: [releaseCheckpoint.id]
    ),
    dryRun: true
)

print(preview.removedCheckpointCount)
print(preview.reclaimedBytes)
```

Apply the same policy by omitting `dryRun`:

```swift
let report = try await workspace.compact(retaining: .latest(50))
```

Compaction rebases retained checkpoints to their nearest retained ancestor and recomputes their summaries. Retained rollback and transaction checkpoints also retain an existing checkpoint they reference as provenance. `.all` keeps every checkpoint while sweeping orphaned manifests and blobs.

Directory-backed stores serialize checkpoint commits, revision reads, and compaction with a persistent lifecycle lock. Mutation history is independent and is not pruned by checkpoint retention.

Store format version 1 is retained so existing stores remain readable. Once a store contains `mutations.sequence.json`, do not use older library versions that ignore this file to write to that store, including through concurrent instances or after a downgrade: those writers can reuse retracted mutation sequence numbers. All writers must preserve the sequence high-water mark and retraction epoch. The sidecar now stores both fields; legacy bare-integer sidecars remain readable. Retractions and failed append reservations can leave sequence gaps. History refreshes invalidate cached records when another instance retracts or prunes mutations.

Directory-backed checkpoint capture also reuses existing CAS blobs when a file's size and available
modification timestamp are unchanged and the timestamp is more than two seconds older than the
previous capture's start. Entries within that timestamp-granularity window are rehashed. It still
walks directory metadata for correctness. Filesystems without modification timestamps, and older
manifests without a capture timestamp, safely fall back to reading those files.

For tools that preserve older timestamps while changing content, pass
`checkpointCapture: .verifyContents` to `Workspace` to read and hash every file at each checkpoint.
The default `.trustMetadata` policy compares the local wall clock with filesystem modification
timestamps. Clock skew can make a recent change appear safely old; use `.verifyContents` for
network filesystems whose clock may differ. This policy affects only `.directory` persistence.

## Transactions

Transactions replace separate branch and merge APIs:

```swift
let transaction = try await workspace.beginTransaction(label: "agent draft")
try await transaction.writeText("/README.md", "Draft\n")

let preview = try await transaction.preview()
let commit = try await transaction.commit(strategy: .threeWay)

if !commit.applied {
    for conflict in commit.conflicts {
        print(conflict.path, conflict.kind)
    }
    try await transaction.discard()
}
```

Transaction commits follow these rules:

- Three-way merging accepts a change made by only one side, coalesces identical changes, and reports divergent changes to the same node as conflicts.
- A directory removed or replaced on one side while the other creates or modifies something beneath it is a `.structural` conflict at the outermost removed or replaced directory. Descendant deletions converge with ancestor removal. Directory mode changes and child edits merge.
- Strict mode rejects any parent change, including root-directory metadata.
- Moves are delete-plus-create operations. Moving the same source to different destinations keeps both copies.
- During `commit()`, edits and `discard()` throw `TransactionError.committing`; read-only draft calls remain available. Another commit also throws `.committing`.
- A rollback failure permanently closes the transaction. Failures that leave the parent unchanged allow retry.

Manual conflicted transactions remain active. The scoped convenience commits on success and discards on failure or conflict:

```swift
let result = try await workspace.transaction { transaction in
    try await transaction.writeText("/result.txt", "done\n")
    return "agent result"
}
```

Transactions are logically atomic within cooperative workspace use. They are not crash-safe against an external process racing the commit.

## Events and History

```swift
let events = await workspace.events()
Task {
    for await event in events {
        print(event)
    }
}

let mutations = try await workspace.history()
```

Change events, returned edit results, and mutation history all carry the same `ChangeSet` representation. Checkpoint events share the same stream.

`LocalFileSystem` also pushes out-of-band filesystem invalidations through FSEvents on macOS and
inotify on Linux. `events()` and the path-focused `watchChanges(at:recursive:)` turn those
invalidations into structured `ChangeSet` values. External changes remain unrecorded in mutation
history, matching the direct-filesystem contract above. Directory-backed checkpoint stores use the
same push model for cross-instance checkpoint events; there is no periodic polling loop.

## Filesystems and Safety Layers

Built-in filesystems use consistent names and constructor-driven configuration:

- `InMemoryFileSystem`
- `LocalFileSystem`
- `OverlayFileSystem`
- `MountedFileSystem`
- `SandboxFileSystem`
- `SecurityScopedFileSystem`
- `AuthorizedFileSystem`
- `LimitedFileSystem`

Compose wrappers explicitly:

```swift
let local = try LocalFileSystem(root: projectURL)
let limited = LimitedFileSystem(
    base: local,
    limits: FileSystemLimits(
        maxTotalBytes: 50_000_000,
        maxEntryCount: 10_000,
        maxWriteBytes: 1_000_000
    )
)

let rules = RuleBasedPermissionAuthorizer(
    rules: [
        PermissionRule(
            operations: [.readFile, .listDirectory, .stat],
            pathPrefix: "/Sources",
            effect: .allow
        )
    ]
)

let authorized = AuthorizedFileSystem(base: limited, authorizer: rules)
let workspace = Workspace(fileSystem: authorized)
```

Authorization supports one-shot, duration-limited, and session approvals plus bounded audit records. Prefix rules use path-component boundaries and require both paths to match for copy and move.

## LLM Tool Adapters

`WorkspaceToolAdapter` exposes dependency-free function definitions for read, glob, search, apply,
diff, and checkpoint operations. Each definition contains an ordinary JSON Schema object, so an
integration can translate it into its model provider's tool format without adding a provider SDK to
Workspace:

```swift
let adapter = WorkspaceToolAdapter(workspace: workspace)
let definitions = WorkspaceToolAdapter.definitions

let resultJSON = try await adapter.call(
    name: "workspace_diff",
    arguments: Data(#"{"from_checkpoint_id":"...","unified_patch":true}"#.utf8)
)
```

All mutating adapter calls use the Workspace edit/checkpoint APIs, so they retain the same history,
event, transaction, authorization, and limit behavior as direct callers. The diff result carries the
structured `ChangeSet` and can optionally include unified-patch text for prompt or CLI interop.

Tool arguments use snake_case and results use camelCase. Output budgets for glob, diff, and apply
count **encoded JSON bytes**, including escaping and metadata: `max_bytes` defaults to 65,536,
has a minimum of 1,024, and clamps to 262,144. Diff and apply also accept `max_file_bytes` for each
file's encoded text diff plus optional patch; it defaults to 8,192, clamps to 65,536, and accepts 0
to omit all text detail. Returned patch sections are complete; text that cannot fit is omitted
with `textDiffOmissions.reason = "outputBudgetExceeded"`.

| Tool | Additional arguments | Result |
| --- | --- | --- |
| `workspace_glob` | `match_offset` (default 0), `max_matches` (default 1,000, cap 10,000), `max_bytes` | `{matches, totalMatches, matchOffset, nextMatchOffset?, omittedMatches, truncated}` |
| `workspace_diff` | `change_offset` (default 0), `paths` (optional exact paths), `max_bytes`, `max_file_bytes` | `{changes, statistics, totalChanges, changeOffset, nextChangeOffset?, omittedFiles, omittedTextDiffs, truncated, unifiedPatch?}` |
| `workspace_apply` | `max_bytes`, `max_file_bytes` | `{changes, failures, statistics, totalChanges, changeOffset: 0, omittedFiles, omittedTextDiffs, truncated}` |

Continue glob/diff at the returned offset, keeping the same pattern/paths and revisions. Pin both
diff revisions to checkpoints for stable paging while the workspace changes. Narrow glob patterns
or diff `paths`, or raise `max_file_bytes`, to retrieve detail; use `workspace_read` for full text.
`max_text_bytes` skips text diffing for files larger than its source-byte limit (default and cap
1,000,000 bytes per input file); `max_file_bytes` bounds encoded diff bytes per file in the result.
The nested `changes` contains only returned detail; top-level `statistics` describes all selected
changes using available computed text diffs. `omittedFiles` counts change entries at/after the
requested offset that are absent from this response, including entries on subsequent pages.
`omittedTextDiffs` counts returned entries whose computed diff was removed by the output budget.
Glob skips a single path too large for a page and increments `omittedMatches`; diff similarly
counts oversized path metadata in `omittedFiles`. Offsets still advance past those entries.

Apply always completes the full atomic edit operation before bounding its response. Do not repeat
an apply call to retrieve omitted detail. Use `workspace_read` to inspect omitted files, or create
a checkpoint before applying and diff from it. If response encoding fails after commit, apply
returns a minimal success envelope with empty `changes`, full statistics, and `truncated: true`.

Beta compatibility: glob tool results now use an object instead of a bare array. Apply and diff
retain their existing keys and add budget/paging metadata; large results can contain less detail.
Direct Workspace method signatures are unchanged. Public adapter budget constants and
`TextDiffOmission.Reason.outputBudgetExceeded` are additive; exhaustive switches on the reason
must handle the new case.

## Testing

```bash
swift build
swift test --disable-xctest --enable-swift-testing
```

CI runs Swift 6.2 tests on macOS and Linux.
