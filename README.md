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

Edit previews use an isolated copy-on-write layer and the same affected-root journal as `apply`.
Their ChangeSets describe the edited paths, including link and permission changes. Preview does not
simulate external races or guarantee that later writes pass filesystem permissions or quota checks.

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

New directory stores use format version 2. Preparing an existing v1 store upgrades
`format.json` under the format, lifecycle, and mutation locks before publishing any new-format
checkpoint. Existing recursive manifests and loose blobs remain readable; migration does not
rewrite checkpoint history. The first new checkpoint over a v1 parent creates its directory
objects; historical v1 reads keep their original full-manifest decoding cost. New v1 operations
reject the v2 format marker. Schema-3 roots use the required `treeRoot` key instead of legacy
`root`, so an old operation admitted before migration fails decoding a new root: it cannot read
it as an empty tree, capture against it, or sweep its blobs during compaction. An admitted old
operation that only accesses legacy roots (or appends mutations) can still complete; migration
cannot cancel old code already running. Stop old processes before upgrading to avoid mixed-version
operation failures.
Do not downgrade the format marker.

New snapshots use manifest schema 3: a small snapshot root points to SHA-256-addressed directory
objects in `trees/`. Each object contains byte-sorted immediate child names (never absolute paths), with child directories
referenced by hash. An incremental capture writes only changed directories and their ancestors;
unchanged objects remain shared. File reads decode only directories on the requested path.
Decoded trees and the write catalog share a **32 MiB estimated decoded-storage budget** per
store (24 MiB for trees, 8 MiB for the catalog). Both refresh recency on hits and normally use
O(1) LRU eviction. Capture-time tree inserts evict the most recent entry instead, so repeated
whole-tree scans retain a resident set when the trees exceed the budget. Estimates include entry,
string-buffer and bookkeeping costs; this is not a process-RSS cap.
File metadata and directory listings also use path-only lookup. Full revision indexes are still materialized
when a whole-tree operation requests them. Metadata capture still walks the filesystem.

Blobs retain their SHA-256 identities. Small captures use loose `blobs/<hash>` files; after the
first 32 new unique blobs in a capture, remaining blobs go into immutable `packs/<uuid>.pack`
files with adjacent JSON hash/range indexes. Packs target 16 MiB and use a 1 MiB write buffer;
a single larger file may exceed the target. Tree file entries carry their pack/range, so reads
need no global pack-index decode. Full snapshot materialization maps at most four packs at a
time and copies only the required file ranges; those mappings do not escape the locked load.
The bounded write-side pack catalog is cached for one workspace. A constant-size `packs.generation`
token invalidates other writers' catalogs before compaction removes packs, without depending on
directory mtimes or enumerating historical pack files on warm writes. Hashes captured with in-memory
checkpoints are reused by revision indexes and unchanged files in subsequent checkpoints.

Publication orders durable blob/pack writes and directory objects before the snapshot root,
and the snapshot root before checkpoint metadata. Files are synchronized before atomic rename,
and containing directories are synchronized before advancing publication. Tree-directory syncs
are batched at capture completion; compaction synchronizes each relocated tree before replacing
roots. On Darwin, snapshot-root and checkpoint-metadata publication additionally use `F_FULLFSYNC`
after syncing the containing directory, flushing the drive cache including preceding writes.
A successfully published checkpoint therefore survives process crashes and power loss on storage
that honors these synchronization requests. If `F_FULLFSYNC` fails other than interruption,
publication retains the completed file and directory `fsync`; power-loss protection is best-effort
on such volumes. Other POSIX platforms use file and directory `fsync`.
Failed captures can leave unreachable objects, but publish no checkpoint referencing incomplete content. Compaction
sweeps both formats, rewrites partially live packs, durably replaces affected snapshot roots,
and only then removes old objects. Interrupted compaction can be resumed; dry-run blob counts
and byte totals include reclaimable pack entries and incomplete orphan packs.

All writers preserve the mutation sequence high-water mark and retraction epoch in
`mutations.sequence.json`; legacy bare-integer sidecars remain readable. Retractions and failed
append reservations can leave sequence gaps. History refreshes invalidate cached records when
another instance retracts or prunes mutations.

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

Transactions use a copy-on-write draft over a frozen base. The first transaction on an instance
reads the tree, including after reopening a Workspace. Memory persistence retains the initial bytes.
A cold directory-backed base retains up to 256 MiB of file contents in memory; files that do not fit
use private temporary blobs until a checkpoint supplies immutable content. Live transaction handles
own the cold base. Discarding or releasing the last handle releases its bytes; successful commit
releases the completed handle's base and re-seeds the parent from the checkpoint. Other active handles
retain their frozen contents. A later begin without a live cold base or checkpoint base reads anew.
Beginning or discarding a transaction adds no public checkpoint. Subsequent begins and commits walk
metadata and read changed or unverifiable files; previews and merges materialize affected paths.
Metadata capture uses bulk traversal when available and per-path enumeration otherwise, including
scoped subtree refreshes. Mounted traversal preserves virtual paths and shadowing; authorized
traversal retains per-entry permission checks.
Snapshot capture likewise stats each entry on its per-path route. InMemoryFileSystem has a native
actor-owned traversal; after reentrant mutations it resolves pending paths and reads again.
Checkpoint persistence still requires the store's metadata and manifest work. Checkpoints prime a
transaction base only after that instance has begun a transaction. Directory commits replace the base
with the new revision index, without retaining changed-file contents or revision read caches.

With `checkpointCapture: .trustMetadata`, transactions reuse contents when size and mtime match
and the previous mtime is more than two seconds older than the start of the previous metadata
capture. Identity must also match when both entries provide it. Missing mtimes and recent timestamps
require reads; InMemoryFileSystem's exact timestamps skip this racy window. Writes that preserve
safely old metadata can evade the check. Use `.verifyContents` to read and compare every file during
transaction begin and commit, checkpoint-to-current diff and restore, and to read and hash every
file during directory checkpoint capture.

Checkpoint-to-current diffs and `restore(to:)` use one bulk metadata walk and compare against the
checkpoint's persisted capture hints and revision hashes. They read only suspect files (changed
metadata, missing hints, or timestamps inside the same two-second window). Identity is compared
when both captures provide it; exact-timestamp backends skip the window. Older revisions without
capture hints conservatively require content reads. Memory persistence retains hints for only the
four most recently captured or restored revisions; older revisions also fall back to content reads.
As with transactions, writes that preserve
safely old metadata can evade `.trustMetadata`; use `.verifyContents` when those writes must be
detected and restored.

Restore applies and recaptures only differing entries and necessary ancestor permissions. Its
failure recovery and recorded changes use the same sparse scope. The new checkpoint reuses existing
blobs and directory trees through the store's normal locked, durable publication path. Archive
restore continues to capture its selected subtree in full.

Transactions are logically atomic within cooperative workspace use. They are not crash-safe against
an external process racing the commit. In-process `Workspace.compact` protects revisions referenced
by transaction handles and other Workspace instances. This instance's reusable base does not override
retention: it survives dry runs and real compaction that retains its checkpoint, and is discarded
when that checkpoint is removed. Coordinate compaction across processes: the store protocol has no
cross-process revision lease.

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

Filesystem observation keeps a metadata index and a bounded least-recently-used content cache.
`observation: .init(contentCacheBytes: 32 * 1024 * 1024)` configures the cache on `Workspace`; 32 MiB is
the default, zero disables it, and negative budgets are treated as zero. Initial observation reads
at most that budget, excluding files above the text-diff size limit. A change whose old or new bytes
are uncached has no text diff and reports `.observationCacheMiss` in `textDiffOmissions`.
`.sizeLimitExceeded` identifies files above the text-diff limit. Failed content reads report the
metadata change with `.contentReadFailed`, without blocking other changes.

Full and recursive metadata rescans verify cached contents within the same two-second racy window
used by transactions, and whenever mtime is unavailable. Exact-timestamp backends skip that window.
Explicit path signals compare cached regular-file contents even when metadata matches. Rescans can
miss writes that preserve safely old metadata. Without cached contents, observation relies on
metadata and can report an identical rewrite as changed or miss a rewrite that preserves metadata.
Observation is not an atomic snapshot of external activity: a mutation between a Workspace write
and its metadata reconciliation can be absorbed into that write, particularly for uncached files
or structural changes. Coordinate concurrent writers when every intermediate change must be recorded.

`FileSystemChangeSource.changeSignals()` emits `.paths([WorkspacePath: Scope])` in the source's
filesystem namespace. `.entry` checks one entry's contents and metadata; `.shallow` also checks a
directory's immediate listing without traversing existing child directories; `.recursive` checks
the whole subtree. Added, removed or replaced directories include their current or former descendants.
Sources must name deleted or replaced ancestors, use recursive scopes for directory renames, and emit
`.rescan` when coverage is uncertain. Coalescing keeps the strongest scope at each path without letting
a shallow ancestor suppress descendant signals. The default maps `changes()` Void signals to `.rescan`;
wrappers should forward richer signals when available. FSEvents and inotify provide scoped signals,
coalesced over 40 ms, with full metadata rescans for dropped or unknown events. Native watchers exclude
LocalFileSystem's atomic-replace temporary names in this process's private random namespace; similarly
named user files and temporary files from other processes remain visible.
Metadata failures retain their invalidations and retry with exponential backoff for at most three
attempts. After that, observation waits for a new native signal before resuming the pending work.

## Path Identity

A `WorkspacePath` is a normalized absolute path whose identity is the exact UTF-8
bytes of each component. Equality, hashing, ordering, containment, permission
rules, and quota accounting do not fold case or Unicode normalization. For example,
`/café` (NFC) and `/cafe\u{301}` (NFD) are different paths. This deliberately changes
previous releases' use of Swift canonical-equivalence equality. Names and symlink
targets must be valid UTF-8; undecodable host entries are rejected, not repaired
into a different name. In-memory storage
and byte-exact host filesystems can hold both names.

`LocalFileSystem` requires the requested spelling to match the stored directory
entry. On APFS, including case-sensitive APFS, case or normalization aliases are
rejected: lookups and reads report `ENOENT`; creates, writes, and rename/copy
destinations report `EEXIST` when an equivalent entry exists. Renaming an entry
to an equivalent spelling is rejected too; move through a distinct temporary
name if a spelling change is needed. Case-only renames remain possible on
case-sensitive filesystems. Removing a missing/aliased spelling remains
a no-op. Symlink targets must use the stored spelling, and `resolveRealPath`
returns that spelling. Directory listings and bulk traversal use names
emitted by `readdir`, so they already carry the stored identity.

On Darwin, volume policy is cached by device. APFS and HFS+ use
`getattrlistat(ATTR_CMN_NAME, FSOPT_NOFOLLOW)` to verify stored names. For APFS,
an `F_GETPATH` check on the held parent **directory** can verify its components
together, against the root descriptor's own path plus the resolved physical
components; the final name still uses `getattrlistat` so hard links remain valid.
Unavailable, overlong, or mismatched directory paths fall back to per-component
checks, so relocating the pinned root or an ancestor remains supported.
No final file descriptor is checked with `F_GETPATH`.

HFS+ and macOS's exFAT driver store Unicode names in decomposed form (NFD).
Creating a precomposed (NFC) name that decomposes there fails with `EILSEQ` and
the new entry is removed; use the NFD spelling reported by directory listings.
New entries are checked before use on rewriting volumes. A rewritten rename is
rolled back to preserve its source. Other Darwin
filesystems (including exFAT/FSKit, network and unknown types) verify spelling by
an exact byte match in the parent directory's `readdir` listing instead of trusting
name-cache-sensitive attribute APIs. Their new entries are also checked for name
rewriting. Listings are never cached, including on filesystems with coarse mtimes.

On Linux, ext4/f2fs/bcachefs/overlayfs/tmpfs directory flags are inspected with
`FS_IOC_GETFLAGS`. Directories with `FS_CASEFOLD_FL` use listing verification;
others skip spelling verification. Flags are cached per `(device, inode)` in a
bounded 4,096-entry cache under the existing exclusion of external host namespace
and flag changes. A full cache is cleared before adding a new entry. Workspace
creation/removal invalidates directory entries to prevent stale flags on inode
reuse. Changing casefold requires ownership and an empty directory and is not
exposed by the workspace API. Inspecting flags requires read permission;
unavailable inspection falls back to listing verification, which also requires
read access. While its policy remains cached, a byte-exact directory can still
be traversed with search-only access.

XFS volume geometry (`XFS_IOC_FSGEOMETRY`) is queried once per device: ascii-ci
volumes use listing verification and ordinary XFS skips it. Known byte-exact btrfs
and ramfs also skip it. Unknown filesystems, and unavailable sensitivity queries,
use listing verification rather than being refused. An existing kernel lookup
without an exact listing match is `ENOENT` for reads or `EEXIST` for creation;
missing creations use exclusive creation. Errors do not disclose the stored name.

These checks do not make metadata checks and later mutations atomic against an
external process renaming entries; the existing concurrent-host mutation
limitations still apply. Directory names emitted by `readdir` are already verified
spelling and are not looked up a second time solely to check their spelling.

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

`LimitedFileSystem` serializes its own preflight and mutation with a FIFO gate. Quotas
count logical regular-file bytes per visible path (including hard-link aliases), and
all non-root entries, including dangling symlinks. Appends charge aliases by identity
and link count; unknown aliases are charged conservatively. Already over-quota trees
may shrink or preserve usage, but cannot increase an exceeded quota. Accounting reads
metadata only and resolves symlinks in the backend's namespace, including mounts.

When the base declares complete change-signal coverage, Limited caches totals, compact
per-path accounting metadata (kind, size, identity and link count), children,
and alias indexes. Successful mutations refresh their affected metadata under the gate;
a failed or uncertain mutation discards the cache. File and directory identities are
needed to rule out unrecognized aliases through compositions (even for single-link
files); missing identities make the mutation uncertain and force a fresh walk on the
next preflight. External `.entry`, `.shallow`, and
`.recursive` signals invalidate those scopes for lazy reconciliation on the next
preflight. Removed/replaced directories invalidate their former descendants; hard-link
aliases are refreshed together. `.rescan` discards all cached accounting. A failed or
ended subscription falls back to a full metadata walk on every preflight, unless an
exact mutation generation is available. Coverage is checked at every preflight; Mounted
declares complete coverage only when its base and every mount do, including later mounts.
Incomplete or undeclared coverage uses full walks (or the exact generation capability).
Each Limited over Local registers its own recursive inotify watcher on Linux; large trees
can exhaust the watch limit (ENOSPC), at which point accounting safely falls back to walks.
The retained cache is capped at 250,000 entries (25,000 on iOS/watchOS); above that cap,
accounting is discarded after the operation and every preflight walks the tree.

**Consistency:** a quota decision incorporates signals processed by this Limited actor
before its projection finishes. Signals buffered in the backend or stream, or queued
for actor processing, may arrive after a decision, so external writes can temporarily make accounting stale and
can exceed quotas. `try await limited.revalidate()` forces a fresh metadata walk under
the gate without waiting for signals. With external writers quiescent, it closes the
notification-delivery gap. Neither revalidation nor the gate makes preflight atomic
with writers using another wrapper or the base directly. The package-level `changeSignalsAreComplete`
capability is an explicit guarantee of coverage for all visible children; sources that
only provide a partial stream cannot enable notification-based accounting reuse.

Without complete change signals, each preflight walks the whole tree. The package's optional
exact mutation-generation capability lets InMemoryFileSystem reuse accounting when
unchanged; direct mutations, reset, and partial failures change its generation and
force a new walk. Generation changes during a scan or this wrapper's mutation prevent
reuse of that potentially inconsistent snapshot.
Accounting retains strict bulk-walk semantics: a listed entry vanishing before metadata
lookup fails the preflight and invalidates partial accounting; the next preflight scans anew.

Authorization supports one-shot, duration-limited, and session approvals plus bounded audit records. Prefix rules use path-component boundaries and require both paths to match for copy and move.

Local scans record symlinks without descending into them and retain per-entry authorization
checks when using an authorized filesystem. Scans are live reads, not atomic snapshots:
concurrent changes can affect the result or cause an error. Snapshot capture fails when a
listed child disappears before it can be inspected or read. Directory-backed checkpoints omit
listed children that vanish before their metadata lookup (ENOENT/ENOTDIR); failures after metadata,
including content reads, still abort the checkpoint. Scoped no-follow opens reject
substituted symlinks even when they point inside the root. Deep scans bound open directory
handles by falling back to ordinary per-path operations; no handles are cached between calls.
As with other local operations, host processes can relocate open directories or mutate
hard-linked data.

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

## Benchmarks

The separate executable does not run in `swift test`. Run in release mode:

```sh
swift run -c release WorkspaceBenchmarks --preset small --json Benchmarks/Results/small.json
swift run -c release WorkspaceBenchmarks --preset small --json Benchmarks/Results/after.json \
  --compare Benchmarks/Results/small.json
swift run -c release WorkspaceBenchmarks --preset medium --filter transaction,limitedWrite
```

Defaults: one warmup, five measured samples, a fresh child per scenario. Fast operations
use inner repetitions with per-operation times/counts; writes use independent prepared
stores (each `write1001` is exactly the 1,001st mutation). Fixtures have 1k/10k/100k
regular files: small ~20 MiB, medium ~200 MiB, large ~98 MiB with deep dependency nesting.
Allow roughly **2–5 minutes for small**, **10–30 minutes for medium**, and **well over
an hour for large** at defaults, depending on filesystem and watcher availability.
Fixture generation is excluded. `--fixture-dir PATH` generates/validates/reuses a
preserved fixture; otherwise temporary trees/stores are removed on completion or SIGINT.
`Benchmarks/Results/` is ignored. Use `--help` for filters, iteration counts and
deadlines (30 minutes per child by default).

| Scenario | What's timed | Setup excluded | Counter blind spots |
| --- | --- | --- | --- |
| `writeText`, `apply50`, `limitedWrite` | One recorded write, 50 edits, quota-limited write with warm accounting | No-op preparation, file reset, Limited accounting priming | Checkpoint store; Limited metadata traversal is visible |
| `transaction` / `transactionFirst` | Begin, one draft write, commit | Preparation; initial begin/discard and baseline checkpoint for steady-state `transaction` only | Draft filesystem, checkpoint store |
| `preview` | One edit preview | Preparation | Draft filesystem |
| `checkpointFirst` / `checkpointIncremental` | First capture / capture after one change | Preparation; baseline and change for incremental | Checkpoint store |
| `diff`, `restore` | Checkpoint-to-current diff / restore after one change | Preparation, baseline, change | Checkpoint store |
| `readCheckpoint` / `readCheckpointWarm`, `readCurrent` | Cold / primed checkpoint index read; direct current read | Baseline; first read for warm variant | Checkpoint store |
| `search`, `glob` | Full absent-literal search / `**/*` glob | Preparation | Glob internals; returned `globMatches` is visible |
| `history1000` / `history1000Cached` | Fresh directory Workspace log load/decode / cached memory history | Seed 1,000 mutations; new reader for cold variant | Checkpoint store |
| `write1001` | Exactly the 1,001st recorded directory write | Preparation and 1,000 mutations | Checkpoint store |
| `eventsInitial`, `eventsExternal` | Enable observation / direct external write until its event arrives | Preparation; initial observation and drain for external | External write bypasses counter; recaptures are visible |

The table shows median/p90 wall time, backend read bytes/calls, stat/list calls, entries,
glob matches, logical store bytes/files written, setup RSS high-water, operation increase
in that high-water, and held RSS delta. Held RSS is sampled with the result live. The
first-run column is the live-footprint figure: after the first run, allocator reuse hides
most of a result's memory, so the measured-sample summary (which excludes warmups) can be
near zero or slightly negative. Zero high-water growth can likewise mean allocator reuse.
Percentiles use linear interpolation between samples. Setup high-water includes preceding
samples in the same child; JSON retains each sample's values and process peak.
Darwin/Linux RSS units are normalized to bytes. Store write counts include newly created
empty lock files.

Counters observe the `FileSystem` boundary, not syscalls. Store writes are estimated
outside timing from directory metadata: append growth or final size of new/replaced
files; transient/deleted files, repeated overwrites and OS write amplification are
invisible. Compare identical presets for regressions: timing ratios and exact backend
count deltas are printed. Watcher errors produce a nonzero exit while retaining successful
results; run outside a restrictive macOS sandbox to measure FSEvents.

Scoped walks report `walk` and `walkEntry` counters; their content callbacks still count as
`readFile`, `readRange`, or `readSymlink`. `directoryEntries` includes visited descendants.
These are logical visits, not POSIX syscall counts; backend-internal glob walks remain opaque.
