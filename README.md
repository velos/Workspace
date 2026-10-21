# Workspace

Workspace is a Swift package that gives agent and tool runtimes controlled access to a directory tree. It provides structured, atomic edits with a record of what changed, checkpoints you can diff and restore, isolated transactions with a three-way merge, change events, text search and an LLM tool adapter. Filesystem wrappers add root confinement, authorization rules, quotas, overlays and mounts.

The package hasn't been released, and its API can change.

## When to use it

Use Workspace when a program, such as a coding agent, edits files on someone's behalf and needs to preview edits, apply them all-or-nothing, show what changed and roll back.

It's the wrong tool when:

- **You need to contain untrusted code.** The wrappers constrain calls made through the `FileSystem` API, not processes. Use an OS sandbox or a container. See [Safety layer, not a sandbox](#safety-layer-not-a-sandbox).
- **You need to run commands.** There's no process execution or shell.
- **You want version control.** Checkpoints are local snapshots of one tree, with no branches or remotes.
- **Every operation must be cheap on a very large tree.** Checkpoints, transaction begin and commit, and checkpoint-to-current diffs each walk the whole tree's metadata.
- **Every writer must be recorded.** Changes made outside the Workspace can appear as events but never enter history.

## Requirements

Swift 6.2 or later on macOS 13, iOS 16, tvOS 16, watchOS 9 or Linux, with no dependencies. Events for external changes need macOS (FSEvents) or Linux (inotify).

```swift
dependencies: [
    .package(path: "../Workspace"),
],
targets: [
    .target(name: "MyTool", dependencies: [
        .product(name: "Workspace", package: "Workspace"),
    ]),
]
```

## Core model

- **`Workspace`** is an actor that owns one tree: its current state (a `FileSystem`), a mutation history, checkpoints and an event stream.
- **`WorkspacePath`** is a normalized absolute path. String literals convert to it.
- **`Edit`** describes one mutation: write, append, create a directory, remove, copy, move, link, set permissions, or find-and-replace.
- **`ChangeSet`** lists `FileChange` values (path, kind, effect, optional `TextDiff`) and `textDiffOmissions` for files without a text diff. Previews, edit results, history, events, diffs and commits all return it.
- **`Checkpoint`** is a stored revision of the whole tree. A **`Revision`** is `.current` or `.checkpoint(id)`.
- **`Workspace.Transaction`** is an isolated draft that commits back with a three-way merge.
- **`FileSystem`** is the storage protocol behind the current state.

`Workspace.init` parameters, all optional:

| Parameter | Default | Meaning |
| --- | --- | --- |
| `workspaceID` | `UUID()` | Identifies this workspace in a store. Pass the same value each time to reopen persisted history. |
| `fileSystem` | `InMemoryFileSystem()` | Holds the current state. |
| `persistence` | `.memory` | `.memory` keeps checkpoints and history in the process; `.directory(URL)` stores them on disk. |
| `recording` | `.full(maxTextBytes: 1_000_000)` | Detail kept in history: `.full` keeps text diffs up to the size limit, `.changesOnly` keeps paths and effects, `.off` keeps nothing. Returned results and events are unaffected. |
| `checkpointCapture` | `.trustMetadata` | See [Change detection](#change-detection). |
| `observation` | 32 MiB cache | See [External changes](#external-changes). |

## Getting started

```swift
import Workspace

let workspace = Workspace()
try await workspace.createDirectory("/notes")
try await workspace.writeText("/notes/todo.txt", "ship it\n")
let text = try await workspace.readText("/notes/todo.txt")
```

`InMemoryFileSystem` requires parent directories to exist before a write; `LocalFileSystem` creates them.

To work on a directory on disk and keep history across launches:

```swift
let workspace = Workspace(
    workspaceID: projectID,  // a UUID you store and reuse
    fileSystem: try LocalFileSystem(root: projectURL),
    persistence: .directory(historyURL)
)
```

`LocalFileSystem(root:)` creates the root if it's missing. A history directory holds one subdirectory per `workspaceID`. Keep it outside `projectURL`, or the store's files become part of the tree it records.

`workspace.fileSystem` returns the filesystem you passed in. Reading through it is fine, but writes through it bypass history and the [operation gate](#atomicity-and-the-operation-gate).

## Editing files

```swift
let edits: [Edit] = [
    .createDirectory("/Sources"),
    .writeText("/Sources/main.swift", "print(\"hello\")\n"),
]

let preview = try await workspace.preview(edits)   // nothing is written
let result = try await workspace.apply(edits)      // atomic by default

for change in result.changes.changes {
    print(change.effect, change.kind, change.path)
}
print(result.changes.statistics.additions)
```

`preview` runs the edits on a copy-on-write layer and returns the ChangeSet `apply` would produce. It can't predict concurrent writes or permission and quota failures.

`apply(_:policy:)` is `.atomic` by default: if any edit fails, the affected paths are restored and the error is rethrown. `.stopOnError` keeps earlier successes and stops at the first failure; `.continueAfterError` attempts every edit. Both report failures in `result.failures` and record what succeeded.

`writeText`, `writeData(_:to:)`, `writeJSON`, `appendText`, `appendData`, `createDirectory`, `remove`, `copy`, `move`, `createSymbolicLink`, `createHardLink` and `setPermissions` each apply one edit and return its ChangeSet.

Find-and-replace is an edit like any other:

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

Patterns are `.literal(_:caseSensitive:)` or `.regularExpression(_:)` (an `NSRegularExpression`; the replacement accepts `$1` templates). Every selected file must be UTF-8 text without NUL bytes, or the edit fails.

Selection patterns resolve against `root`; includes are combined and excludes removed. Globs support `*`, `?`, `[...]`, `[!...]` and `**`, and `*` matches names starting with a dot.

`readText`, `readData` (with an optional byte range), `readJSON`, `exists`, `info`, `list`, `glob` and `tree` all accept a `Revision`, so they read checkpoints too.

## Search

```swift
let request = SearchRequest(
    pattern: .regularExpression(#"\bTODO\b"#),
    files: swiftFiles,
    contextLines: 2
)
let result = try await workspace.search(request)

for match in result.matches {
    print("\(match.path):\(match.lineNumber): \(match.line)")
}
```

Search reads regular files in the current state, in path order, without following symbolic links. Binary and oversized files are listed in `skippedFiles`. Default limits are 1,000,000-byte files, 10,000 files and 1,000 matches; `maxOutputBytes` can also cap the encoded result. `truncation` names the limit that stopped a result. To page, pass `nextMatchOffset` back as `matchOffset`. Each page rescans every selected file.

## Checkpoints, diffs and restore

```swift
try await workspace.writeText("/README.md", "Original\n")
let before = try await workspace.createCheckpoint(label: "before")
try await workspace.writeText("/README.md", "Updated\n")

let oldText = try await workspace.readText("/README.md", at: .checkpoint(before.id))
let changes = try await workspace.diff(from: .checkpoint(before.id), to: .current)
print(changes.unifiedPatch())

let restored = try await workspace.restore(to: before)
```

A checkpoint records file contents, directories, symbolic links and permissions, storing identical contents once. Its `origin` is `.manual`, `.rollback(from:)` or `.transaction(base:)`, and its `summary` describes changes from its parent.

`restore(to:)` rewrites only the entries that differ, then records the result as a checkpoint with origin `.rollback(from:)`. Later checkpoints are kept.

`diff(from:to:options:)` compares any two revisions. Files larger than `DiffOptions.maxTextBytes` (default 1,000,000), binary files and metadata-only changes get no text diff and are listed in `textDiffOmissions`. `ChangeSet.unifiedPatch()` renders a git-style patch. The diff search gives up after 1,000 edits or 1,000,000 steps per file and emits one replacement hunk for the unmatched middle, so statistics can exceed a minimal diff.

To copy a subtree into another workspace, use an archive. Restoring one is recorded in history but creates no checkpoint.

```swift
let archive = try await workspace.archive(at: "/Sources")
try await anotherWorkspace.restore(archive, at: "/Imported")
```

### Compaction

```swift
let plan = try await workspace.compact(
    retaining: .latest(50, preservingLabeled: true, preserving: [release.id]),
    dryRun: true
)
print(plan.removedCheckpointCount, plan.reclaimedBytes)

let report = try await workspace.compact(retaining: .latest(50))
```

`.latest` keeps the newest checkpoints, labeled ones and any IDs you list. It also keeps the checkpoint each kept rollback or transaction checkpoint came from, and any checkpoint that an open transaction or another Workspace instance in the process depends on. `.all` keeps every checkpoint and removes only unreferenced data. Survivors are rebased onto their nearest kept ancestor. `storageStatistics()` reports usage. Nothing prunes mutation history, so use `recording` to bound it.

## Transactions

```swift
let transaction = try await workspace.beginTransaction(label: "agent draft")
try await transaction.writeText("/README.md", "Draft\n")

let draft = try await transaction.preview()   // base-to-draft ChangeSet
let commit = try await transaction.commit()   // .threeWay by default

if commit.applied {
    print("committed as checkpoint", commit.checkpoint?.id as Any)
} else {
    for conflict in commit.conflicts {
        print(conflict.path, conflict.kind)
    }
    try await transaction.discard()
}
```

A transaction starts from a frozen copy of the tree and edits a private draft, with the same read, search and edit methods as `Workspace`. The parent stays editable. A successful commit writes the merge to the parent, records it in history and as a checkpoint with origin `.transaction(base:)`, and emits an event. `commit.checkpoint` is `nil` when there was nothing to apply.

### Merge rules

The merge compares nodes path by path. A node is a path's kind, permissions and content (file bytes or symlink target), not a directory's children.

| Parent since begin | Transaction | Outcome |
| --- | --- | --- |
| Unchanged | Changed | Transaction's version |
| Changed | Unchanged | Parent's version |
| Same change | Same change | Converges |
| Modified | Modified differently | `bothModified` |
| Created | Created differently | `bothCreated` |
| Deleted | Modified, or the reverse | `modifiedAndDeleted` |
| Removed or replaced a directory | Changed something inside it, or the reverse | `structural`, once, at the outermost such directory |

So a permission change on a directory merges with edits inside it, and deleting files under a directory the other side removed converges. A move is a delete plus a create: if both sides move the same file to different paths, both copies survive. Node conflicts carry `parentDiff` and `transactionDiff` when both sides are text.

`commit(strategy: .strict)` instead rejects the commit if anything in the parent changed, including root metadata, reporting each changed path as `parentChanged`.

### Lifecycle

A conflicted commit applies nothing and leaves the transaction active, so you can edit the draft and commit again, or discard it. During a commit, edits, `discard()` and another `commit` throw `TransactionError.committing`; reads keep working. After a successful commit or a discard, calls throw `.inactive`. If a commit fails and the parent is restored, the transaction stays active; if the restore also fails, it throws `WorkspaceRollbackError` and the transaction closes.

The scoped form commits when the body returns and discards when it throws or conflicts. Conflicts throw `TransactionError.conflicts`.

```swift
let result = try await workspace.transaction(label: "agent run") { transaction in
    try await transaction.writeText("/result.txt", "done\n")
    return "agent result"
}
print(result.value, result.commit.appliedChanges.touchedPaths)
```

Begin and commit walk the parent's metadata, and the first transaction on a Workspace instance reads every file to build its base:

- With `.memory` persistence, the base stays in memory and later begins read only files whose metadata changed.
- With `.directory` persistence, up to 256 MiB stays in memory and the rest goes to temporary files. After a commit or checkpoint, later transactions start from that checkpoint. Otherwise, a begin after every handle has been discarded reads every file again.

## Events and history

```swift
let events = await workspace.events(.init(path: "/Sources"))
let watcher = Task {
    for await event in events {
        switch event {
        case let .changes(changes):
            print("changed:", changes.touchedPaths)
        case let .checkpoint(checkpoint):
            print("checkpoint:", checkpoint.id)
        }
    }
}

let mutations = try await workspace.history()
```

`.changes` events cover edits, restores, archive restores and commits made through this Workspace, plus external changes the filesystem reports. Events don't say which. `.checkpoint` events cover this instance's checkpoints and, with `.directory` persistence, those of other instances sharing the store. Cancel the consuming task to end a stream.

`history()` returns `Mutation` records for edits, rollbacks, transactions and archive restores from every Workspace sharing the store. It waits for this instance's in-flight mutations. External changes never enter history.

### External changes

`LocalFileSystem` reports external writes through FSEvents on macOS and inotify on Linux, and the wrappers over it forward those reports. `AuthorizedFileSystem` forwards only paths the authorizer lets you `stat`. `InMemoryFileSystem` and `OverlayFileSystem` report nothing. Custom backends can adopt `FileSystemChangeSource`.

On a filesystem that reports changes, the first `events` call walks the tree's metadata and fills a content cache. A text diff for an external change needs the file's previous contents from that cache. It's least-recently-used and sized by `ObservationPolicy(contentCacheBytes:)`: 32 MiB by default, 0 to disable. Files over 1,000,000 bytes are never cached. When the diff can't be computed, the change is still reported, with an omission reason: `.observationCacheMiss`, `.sizeLimitExceeded` or `.contentReadFailed`.

Without cached contents, observation relies on metadata: an identical rewrite can show as modified, and a rewrite that keeps size and an old modification time can be missed. An external write that races a Workspace edit can be folded into that edit's event, so coordinate writers if every intermediate change matters.

## Filesystems and safety wrappers

| Type | Role |
| --- | --- |
| `InMemoryFileSystem()` | Default backend for tests, previews and scratch trees. |
| `LocalFileSystem(root:)` | A host directory, confined to its root. Reports external changes on macOS and Linux. |
| `SandboxFileSystem(root:)` | A local filesystem at `.documents`, `.caches`, `.temporary`, `.appGroup(_:)` or `.url(_:)`. |
| `SecurityScopedFileSystem(url:mode:)` | A security-scoped URL, read-only or read-write, with bookmarks kept in a `BookmarkStore`. |
| `OverlayFileSystem(over:)` | Copy-on-write: reads pass through, writes stay in memory until `discardChanges()`. |
| `MountedFileSystem(base:mounts:)` | Several filesystems as one tree. A move between mounts copies, then removes. |
| `AuthorizedFileSystem(base:authorizer:)` | Checks every operation against a policy. |
| `LimitedFileSystem(base:limits:)` | Rejects mutations that would exceed byte, entry or per-write limits. |

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

let reads: Set<PermissionOperation> = [
    .stat, .exists, .listDirectory, .readFile, .readSymlink, .resolveRealPath, .glob,
]
let writes: Set<PermissionOperation> = [
    .writeFile, .createDirectory, .remove, .move, .copy,
    .createSymlink, .createHardLink, .setPermissions,
]
let authorizer = RuleBasedPermissionAuthorizer(rules: [
    PermissionRule(operations: reads, pathPrefix: "/", effect: .allow),
    PermissionRule(operations: writes, pathPrefix: "/Sources", effect: .allow),
])

let workspace = Workspace(
    fileSystem: AuthorizedFileSystem(base: limited, authorizer: authorizer)
)
```

Put `LimitedFileSystem` directly over the storage backend and `AuthorizedFileSystem` outside it. Over an `AuthorizedFileSystem` base, `LimitedFileSystem` can't reuse its accounting and walks the whole tree before every mutation.

### Authorization

Each call becomes a `PermissionRequest`. A path through a symbolic link is checked a second time at its resolved target, and both checks must pass. Denials throw `WorkspaceError.accessDenied`.

`RuleBasedPermissionAuthorizer` uses the first rule that names the operation and matches the paths, falling back to `defaultEffect`, which denies by default. Prefixes match whole components, so `/Src` doesn't match `/Sources`. An allow rule must cover every path in a request, including both ends of a copy or move; a deny rule applies if any path matches. Workspace edits also make `stat`, `exists`, `resolveRealPath`, `listDirectory` and `glob` calls, so allow those wherever edits are allowed.

For interactive approval, `PermissionAuthorizer` wraps a handler. It can return `.allow` for one request, `.allowForSession`, `.allowFor(_:)` a `Duration`, or `.deny(message:)`. Both authorizers keep a bounded audit log.

```swift
let approvals = PermissionAuthorizer { request in
    switch request.operation {
    case .stat, .exists, .listDirectory, .readFile, .glob, .resolveRealPath:
        return .allowForSession
    default:
        return .deny(message: "ask the user before \(request.operation)")
    }
}
```

### Limits

- `maxTotalBytes` caps the sum of regular-file sizes, counted per path, so each hard link counts.
- `maxEntryCount` caps entries other than the root, including dangling symbolic links.
- `maxWriteBytes` caps the data in one write or append.

Violations throw `FileSystemLimitError`. A tree already over a limit can shrink but not grow. Accounting reads metadata only. Mutations through one `LimitedFileSystem` run one at a time.

**Consistency rule.** A quota decision includes every change notification the `LimitedFileSystem` has processed before it finishes projecting the mutation. Notifications still in flight can arrive later, so external writes can leave accounting briefly stale and push usage past a limit. `try await limited.revalidate()` re-walks the metadata without waiting for notifications, which closes that gap while external writers are quiet. Neither makes the check atomic with writes that bypass this instance.

Accounting is reused between mutations over `InMemoryFileSystem`, and over `LocalFileSystem` on macOS and Linux, including through `SandboxFileSystem`, `SecurityScopedFileSystem` or a `MountedFileSystem` whose parts all qualify. Otherwise each mutation walks the tree first. On Linux each instance holds its own recursive inotify watch and falls back to walks if the system's watch limit runs out.

Retained accounting is capped by `accountingCacheEntryLimit` on `LimitedFileSystem.init`. The default (`nil`) keeps up to 250,000 entries, or 25,000 on iOS and watchOS; `0` keeps nothing between mutations, so every mutation walks the tree. Larger trees still work, they just walk the tree before each mutation.

## LLM tool adapter

```swift
let adapter = WorkspaceToolAdapter(workspace: workspace)
let definitions = WorkspaceToolAdapter.definitions  // name, description, inputSchema

let output: Data = try await adapter.call(
    name: "workspace_read",
    arguments: Data(#"{"path":"/README.md"}"#.utf8)
)
```

Each definition's `inputSchema` is a `JSONValue` holding a plain JSON Schema object, ready to translate into a provider's tool format. Arguments are snake_case JSON; results are camelCase JSON. Mutating calls go through the Workspace, so history, events, authorization and limits apply.

| Tool | Purpose | Paging and size arguments |
| --- | --- | --- |
| `workspace_read` | Read UTF-8 text, current or from a checkpoint | `offset`; `max_bytes` of content (default 65,536, minimum 4, clamped to 262,144). Continue at `nextOffset`. |
| `workspace_glob` | List matching paths | `match_offset`; `max_matches` (default 1,000, clamped to 10,000); `max_bytes`. Continue at `nextMatchOffset`. |
| `workspace_search` | Literal or regex search | `match_offset`; `context_lines` (clamped to 100); `max_bytes`. Continue at `nextMatchOffset`. |
| `workspace_apply` | Apply `write_text`, `append_text`, `create_directory`, `remove`, `copy` and `move` edits atomically | `max_bytes`; `max_file_bytes` |
| `workspace_diff` | Compare checkpoints or the current state, optionally with a unified patch | `change_offset`; `paths`; `max_text_bytes`; `max_bytes`; `max_file_bytes`. Continue at `nextChangeOffset`. |
| `workspace_checkpoint` | Create a checkpoint | None |

- `max_bytes` bounds the encoded JSON result of glob, search, diff and apply, including escaping: default 65,536, minimum 1,024, clamped to 262,144.
- `max_file_bytes` bounds each file's diff and patch text: default 8,192, clamped to 65,536; 0 omits all text. Omitted text has reason `outputBudgetExceeded` and is counted in `omittedTextDiffs`. `statistics` always describe the full change.
- `max_text_bytes` (default and maximum 1,000,000) skips text diffs for larger files.

`workspace_apply` finishes the whole edit before trimming its response, so never repeat an apply to recover detail; read the files, or diff from a checkpoint taken first. Diff between checkpoints for stable paging while the tree changes.

`call` throws `WorkspaceToolError` for an unknown tool or invalid arguments. Workspace and filesystem errors, such as a missing file or a denial, propagate unchanged. Turn both into tool-error results for the model.

## Guarantees and limits

### Atomicity and the operation gate

An atomic `apply` snapshots every path an edit touches, including parents it creates, and restores them if an edit or the history write fails. If the restore also fails, it throws `WorkspaceRollbackError` carrying both errors. Commits and `restore(to:)` recover the same way. Recovery doesn't cover hard links to an edited file outside those paths, permission changes on symbolic links themselves, or a crash: recovery runs in the process.

Operations that mutate or capture the tree run one at a time per Workspace instance, in arrival order. This operation gate covers `apply` and its conveniences, `preview`, `createCheckpoint`, `restore`, `beginTransaction`, commits, `compact`, `history()` and diffs against `.current`. In practice:

- An edit never interleaves with another edit, checkpoint or commit on the same instance.
- A slow operation, such as the first checkpoint of a large tree, delays everything queued behind it.
- Reads of the current state aren't queued and can see an edit partly applied.
- Other instances, writes through `workspace.fileSystem` and other processes aren't serialized. A failed atomic apply restores its paths over any concurrent change to them.

### Path identity

A `WorkspacePath` is absolute and normalized: `.` is dropped, and `..` removes a component but can't climb above the root. Its identity is the exact UTF-8 bytes of its components. Equality, hashing, ordering, permission rules and quotas don't fold case or Unicode normalization, so precomposed and decomposed `/café` are different paths.

`LocalFileSystem` requires the spelling you use to match the stored name byte for byte, even on volumes that treat other spellings as the same file. On case-insensitive APFS with `/Readme.md` stored:

- reading `/readme.md` fails with `ENOENT`;
- writing or creating `/readme.md`, or renaming `/Readme.md` to `/README.md`, fails with `EEXIST` (rename through a temporary name instead);
- removing `/readme.md` does nothing.

HFS+ and macOS's exFAT driver store names in decomposed form (NFD). Creating a precomposed (NFC) name that the volume would decompose fails with `EILSEQ`, and the entry is removed. Use the spelling a directory listing reports. Linux case-folding directories and case-insensitive XFS follow the same alias rules. Listing a directory that contains a name that isn't valid UTF-8 throws `WorkspaceError.invalidPath`.

### Safety layer, not a sandbox

What the wrappers do:

- `LocalFileSystem` holds a descriptor for its root, opens each component without following links, and resolves links itself, up to 40 hops. An access that would leave the root fails with `WorkspaceError.invalidPath`. A link pointing outside can exist and be read with `readSymlink`, but not followed.
- `AuthorizedFileSystem` checks the path you named and the path it resolves to.
- `LimitedFileSystem` rejects a mutation before it runs.

What they don't do:

- Confine your process. Code in it, and anything it launches, can reach any file the user can.
- Stop other processes. A host process can move an open directory out of the root, change a file through a hard link from outside, or rename entries between an authorization check and the operation.
- Enforce quotas against writers that bypass the `LimitedFileSystem`.

Run untrusted code in an OS sandbox or container, and use these wrappers inside it for policy and bookkeeping.

### History store and durability

`.memory` persistence keeps checkpoints, including file contents, and history in process memory until the process exits.

`.directory(url)` keeps each workspace in `url/<workspaceID>/`, in a single on-disk format marked by `format.json`. An existing directory whose marker is missing or different fails with `WorkspaceError.storageCorrupted`, and the message names the history directory to delete. There's no migration; deleting it discards that workspace's checkpoints and history, not its files.

Several instances and processes can share a store. Compaction only protects checkpoints in use within its own process, so coordinate compaction across processes.

A checkpoint becomes visible only after its files and directories are synced with `fsync`. On Apple platforms the snapshot root and checkpoint record also use `F_FULLFSYNC` to flush the drive cache; volumes that don't support it keep the `fsync` guarantee. A published checkpoint survives a crash or power loss on storage that honors these requests, and a failed capture never publishes a checkpoint with missing content. Mutation history is appended without `fsync`, so its latest records can be lost on power failure.

### Change detection

With the default `checkpointCapture: .trustMetadata`, a file whose size, modification time and identity (when known) match the previous capture isn't re-read. This applies to directory-store checkpoints, transactions, and checkpoint-to-current diffs and restores.

Reuse also requires the modification time to be more than two seconds older than the start of the previous capture, because coarse timestamps can hide a second write in the same tick. Files modified inside that window, and files without a modification time, are re-read. The cost is an extra read of recently written files, not a correctness risk. `InMemoryFileSystem` has exact timestamps and skips the window.

The check can't see a write that keeps the size and restores an old modification time, as some sync and archive tools do, or clock skew on a network filesystem. Use `.verifyContents` to read every file instead.

## Testing

```bash
swift build
swift test --disable-xctest --enable-swift-testing
```

CI runs the tests with Swift 6.2 on macOS and Linux.

## Benchmarks

`WorkspaceBenchmarks` is a separate executable for macOS and Linux, not part of `swift test`. Run it in release mode and compare later runs against a saved report:

```sh
swift run -c release WorkspaceBenchmarks --preset small --json Benchmarks/Results/before.json
swift run -c release WorkspaceBenchmarks --preset small --json Benchmarks/Results/after.json \
  --compare Benchmarks/Results/before.json
```

Compare the same preset on the same machine. `--compare` prints timing ratios and exact I/O count differences, `--filter` selects scenarios, and `--help` lists the options. `Benchmarks/Results/` is git-ignored. See [Benchmarks/README.md](Benchmarks/README.md) for presets, scenarios and counters.
