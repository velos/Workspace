# Workspace

`Workspace` is a shell-agnostic Swift package for building agent and tool runtimes around a controlled filesystem model.

It gives you:
- virtual filesystem abstractions
- rooted and jailed disk access
- in-memory filesystems
- copy-on-write overlays
- mounted multi-root workspaces
- explicit permission checks for file operations
- one `Workspace` actor for reads, tracked writes, tree summaries, snapshots, checkpoints, rollback, branching, and merge

`Workspace` is beta software and should be used at your own risk. It is useful for app and agent workflows, but it is not a hardened sandbox or a security boundary by itself.

## Why

Many agent and tooling flows need more than plain disk I/O:
- one isolated workspace per task
- a shared scratch or memory area
- the ability to read a real project without writing back to it
- explicit approvals before reads or writes
- tree summaries, JSON helpers, batched edits, and checkpoints without shell parsing

`Workspace` provides one model for those cases. You can back it with memory, a rooted directory on disk, an overlay snapshot, or a mounted combination of several filesystems.

## What It Provides

- `Workspace`: high-level actor API for file operations, mutation tracking, snapshots, checkpoints, rollback, branch, and merge
- `Checkpoint` and `CheckpointEvent`: public checkpoint metadata and event stream values
- `Snapshot`: durable capture/restore of a subtree
- `ChangeEvent`: structured change notifications emitted by `Workspace.watchChanges(at:recursive:)`
- `FileSystem`: low-level protocol for custom filesystem backends
- `ReadWriteFilesystem`: real disk access rooted to a configured directory
- `InMemoryFilesystem`: fully in-memory filesystem for isolated workspaces and tests
- `OverlayFilesystem`: snapshot a disk root and keep writes in memory
- `MountableFilesystem`: compose multiple filesystems under one virtual tree
- `PermissionedFileSystem`: wrap any filesystem with operation-level approvals
- `SandboxFilesystem`: convenience wrapper for app sandbox roots
- `SecurityScopedFilesystem`: security-scoped URL and bookmark-backed access
- `WorkspacePath`: path normalization and joining helpers

## Installation

Until this package is published to a remote, use it as a local SwiftPM dependency:

```swift
.dependencies: [
    .package(path: "../Workspace")
],
.targets: [
    .target(
        name: "YourTarget",
        dependencies: ["Workspace"]
    )
]
```

## Workspace

Create an ephemeral workspace with the default initializer:

```swift
import Workspace

let workspace = Workspace()
try await workspace.writeFile("/notes/todo.txt", content: "ship it")

let text = try await workspace.readFile("/notes/todo.txt")
print(text) // ship it
```

Use a custom filesystem when the files should come from memory, disk, an overlay, a mount table, or a permission wrapper:

```swift
let filesystem = InMemoryFilesystem()
let workspace = Workspace(filesystem: filesystem)
```

Persist checkpoint artifacts with file-backed storage:

```swift
let root = URL(fileURLWithPath: "/tmp/workspace-checkpoints", isDirectory: true)
let workspace = Workspace(
    filesystem: InMemoryFilesystem(),
    storage: .directory(at: root)
)
```

`Storage.directory(at:)` writes checkpoint and snapshot JSON plus a `mutations.jsonl` append log (one JSON record per line) under `<url>/<workspaceId>/`. A legacy `mutations.json` array is migrated to JSONL on first access. The store assigns monotonic `sequence` numbers while holding `mutations.lock` (advisory `flock` where the OS supports it), so multiple `Workspace` instances that share a `workspaceId` and store do not collide on mutation sequence. The current checkpoint head is derived from the parent-id graph (unparented tips), not only from `createdAt` ordering, which reduces surprises when wall clocks differ between processes. Listing or loading mutations still reads the full log; very long histories may need application-level rotation. Coordinating multiple hosts or network disks that do not honor `flock` may still require extra synchronization.

### Reads

```swift
let data = try await workspace.readData(from: "/blob.bin")
let text = try await workspace.readFile("/notes/todo.txt")
let exists = await workspace.exists("/notes/todo.txt")
let info = try await workspace.fileInfo(at: "/notes/todo.txt")
let entries = try await workspace.listDirectory(at: "/notes")
let matches = try await workspace.glob("/notes/*.txt", currentDirectory: "/")
let tree = try await workspace.walkTree("/")
let summary = try await workspace.summarizeTree("/")
```

JSON helpers encode and decode through `Codable`:

```swift
struct Config: Codable {
    var name: String
    var enabled: Bool
}

try await workspace.writeJSON(Config(name: "demo", enabled: true), to: "/config.json")
let config: Config = try await workspace.readJSON(from: "/config.json")
print(config.enabled) // true
```

### Tracked Writes

Every public write records an internal mutation:

```swift
try await workspace.writeFile("/notes/todo.txt", content: "one")
try await workspace.appendFile("/notes/todo.txt", content: " two")
try await workspace.writeData(Data([0xDE, 0xAD]), to: "/blob.bin")
try await workspace.createDirectory(at: "/docs")
try await workspace.copyItem(from: "/notes/todo.txt", to: "/docs/todo.txt")
try await workspace.moveItem(from: "/docs/todo.txt", to: "/docs/done.txt")
try await workspace.removeItem(at: "/docs/done.txt")
```

Batched edits and replacements can be previewed before execution:

```swift
let preview = try await workspace.previewEdits([
    .createDirectory(path: "/src"),
    .writeFile(path: "/src/a.txt", content: "one"),
])

let result = try await workspace.applyEdits([
    .appendFile(path: "/src/a.txt", content: " two"),
])

let replacement = try await workspace.applyReplacement(
    ReplacementRequest(pattern: "/src/*.txt", search: "one", replacement: "1")
)

print(preview.mode)       // preview
print(result.mode)        // execution
print(replacement.mode)   // execution
```

`applyEdits` and `applyReplacement` use logical rollback when `failurePolicy` is `.rollback`. Other policies may leave partial changes in place.

### Watchers

```swift
let changes = await workspace.watchChanges(at: "/notes")

Task {
    for await change in changes {
        print(change.kind, change.path)
    }
}

try await workspace.writeFile("/notes/todo.txt", content: "ship it")
```

Checkpoint events are separate from file change events:

```swift
let checkpoints = try await workspace.watchCheckpointEvents()

Task {
    for await event in checkpoints {
        print(event.kind, event.checkpoint.label ?? "")
    }
}
```

### Snapshots And Checkpoints

Snapshots capture filesystem contents. Checkpoints persist a snapshot plus lineage and summary metadata.

```swift
try await workspace.writeFile("/readme.txt", content: "v1")
let checkpoint = try await workspace.createCheckpoint(label: "before edits")

try await workspace.writeFile("/readme.txt", content: "v2")
let rollback = try await workspace.rollback(to: checkpoint.id, label: "restore v1")

let all = try await workspace.listCheckpoints()
let snapshot = try await workspace.snapshot(for: checkpoint)

print(rollback.rollbackSourceCheckpointId == checkpoint.id) // true
print(all.count)
print(snapshot.rootPath)
```

Public `restoreSnapshot(_:)` is also tracked as a workspace mutation. Checkpoint rollback uses an internal untracked restore so the rollback is represented by the rollback checkpoint, not by a second restore mutation.

### Branch And Merge

Branches are isolated `Workspace` actors cloned from the parent's current snapshot. They share the checkpoint store but not the filesystem, watchers, or mutation sequence. By default `branch()` materializes the snapshot into a new `InMemoryFilesystem`; pass `filesystem:` to use another implementation (for example a `ReadWriteFilesystem` if the branch should live on disk).

```swift
try await workspace.writeFile("/readme.txt", content: "base")
let base = try await workspace.createCheckpoint(label: "base")

let branch = try await workspace.branch(label: "agent draft")
try await branch.writeFile("/readme.txt", content: "draft")
let branchHead = try await branch.createCheckpoint(label: "draft ready")

let merged = try await workspace.merge(branch, label: "merge draft")

print(merged.parentCheckpointId == base.id)                 // true
print(merged.mergedFromWorkspaceId == branch.workspaceId)   // true
print(merged.mergedFromCheckpointId == branchHead.id)       // true
```

`merge(_:)` is optimistic. If the parent workspace head changed after `branch()` was created, merge throws `WorkspaceError.mergeConflict(parentWorkspaceId:expectedBase:actualHead:)`.

## Common Filesystem Patterns

### Rooted Disk Workspace

```swift
let root = URL(fileURLWithPath: "/tmp/demo-workspace", isDirectory: true)
let filesystem = try ReadWriteFilesystem(rootDirectory: root)
let workspace = Workspace(filesystem: filesystem)

try await workspace.createDirectory(at: "/src", recursive: false)
try await workspace.writeFile("/src/main.swift", content: "print(\"hello\")\n")
```

### Overlay On Top Of A Real Project

```swift
let projectRoot = URL(fileURLWithPath: "/path/to/project", isDirectory: true)
let filesystem = try await OverlayFilesystem(rootDirectory: projectRoot)
let workspace = Workspace(filesystem: filesystem)

let preview = try await workspace.summarizeTree("/Sources", maxDepth: 2)
try await workspace.writeFile("/SCRATCH.md", content: "overlay-only change\n")
```

### Mounted Workspaces

```swift
let mounted = MountableFilesystem(
    base: InMemoryFilesystem(),
    mounts: [
        .init(mountPoint: "/workspace-a", filesystem: InMemoryFilesystem()),
        .init(mountPoint: "/workspace-b", filesystem: InMemoryFilesystem()),
        .init(mountPoint: "/memory", filesystem: InMemoryFilesystem()),
    ]
)

let workspace = Workspace(filesystem: mounted)
try await workspace.writeFile("/memory/plan.txt", content: "shared notes")
try await workspace.copyItem(from: "/memory/plan.txt", to: "/workspace-a/plan.txt")
```

### Operation-Level Permissions

```swift
let filesystem = PermissionedFileSystem(
    base: InMemoryFilesystem(),
    authorizer: PermissionAuthorizer { request in
        switch request.operation {
        case .readFile, .listDirectory, .stat:
            return .allowForSession
        default:
            return .deny(message: "write access denied")
        }
    }
)

let workspace = Workspace(filesystem: filesystem)
```

## Important Behavior

- Reads do not load checkpoint state. Writes, checkpoint calls, rollback, branch, and merge do.
- All checkpoint reads share the workspace actor barrier with file I/O, so they serialize behind in-flight writes.
- `writeJSON` ends the file with a single trailing newline; `readJSON` decodes the value as usual. Checkpoint event polling (when using `watchCheckpointEvents`) uses `Workspace.checkpointEventPollInterval` (500 ms by default; shorten in tests to reduce wait time).
- `.inMemory` storage still records one mutation per write in memory, including old-content capture for text diffs.
- Branches created with `.directory(at:)` share the same storage directory as the parent but are partitioned by `workspaceId`.
- `walkTree` and `summarizeTree` return stable path ordering, which is useful for deterministic tool output.

## Limitations

- `Workspace` is not a hardened sandbox.
- Logical rollback is not crash-safe and does not coordinate with external processes.
- `OverlayFilesystem` does not persist writes back to the original root.
- Hard links across mounts are not supported.
- Some filesystem types still use `@unchecked Sendable`; treat shared mutable class-based implementations carefully unless their synchronization guarantees are documented.

## Security Notes

- Jail and root enforcement belong to the underlying filesystem implementation.
- Permission checks are additive. They do not replace path normalization or jail enforcement.
- If you expose `Workspace` to model-driven or remote callers, the host still needs to define what roots, mounts, and permissions are acceptable.

## Testing

```bash
swift test
```
