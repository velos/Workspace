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

The injected filesystem is intentionally not exposed from `Workspace`; mutations through it would bypass workspace history and events.

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

Checkpoint reads use manifest metadata and load only selected blobs. `TextDiff` includes total line counts, addition/deletion statistics, hunks, and UTF-16 intra-line ranges.

Use `Workspace.Archive` only when a fully materialized, portable subtree is actually required:

```swift
let archive = try await workspace.archive(at: "/Sources")
try await anotherWorkspace.restore(archive, at: "/Imported")
```

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

## Testing

```bash
swift build
swift test --disable-xctest --enable-swift-testing
```

CI runs Swift 6.2 tests on macOS and Linux.
