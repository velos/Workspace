# Workspace

`Workspace` is a shell-agnostic Swift package for building agent and tool runtimes around a controlled filesystem model.

It gives you:
- virtual filesystem abstractions
- rooted and jailed disk access
- in-memory filesystems
- copy-on-write overlays
- mounted multi-root workspaces
- explicit permission checks for file operations
- a typed `Workspace` actor for reading, writing, walking trees, and applying batched edits

`Workspace` is beta software and should be used at your own risk. It is useful for app and agent workflows, but it is not a hardened sandbox or a security boundary by itself.

## Why

Many agent and tooling flows need more than plain disk I/O:
- one isolated workspace per task
- a shared scratch or memory area
- the ability to read a real project without writing back to it
- explicit approvals before reads or writes
- tree summaries, JSON helpers, and batched edits without shell parsing

`Workspace` provides one model for those cases. You can back it with memory, a rooted directory on disk, an overlay snapshot, or a mounted combination of several filesystems.

## What It Provides

- `Workspace`: high-level actor API for common file operations and batch edits
- `ChangeEvent`: structured change notifications emitted by `Workspace.watchChanges(at:recursive:)`
- `FileSystem`: low-level protocol for custom filesystem backends (see also `ReadableFileSystem` / `WritableFileSystem`)
- `ReadWriteFilesystem`: real disk access rooted to a configured directory
- `InMemoryFilesystem`: fully in-memory filesystem for isolated sessions and tests
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

## Quick Start

```swift
import Workspace

let filesystem = InMemoryFilesystem()

let workspace = Workspace(filesystem: filesystem)
try await workspace.writeFile("/notes/todo.txt", content: "ship it")

let text = try await workspace.readFile("/notes/todo.txt")
print(text) // ship it
```

### Binary Data

```swift
import Workspace

let workspace = Workspace(filesystem: InMemoryFilesystem())
try await workspace.writeData(Data([0xDE, 0xAD, 0xBE, 0xEF]), to: "/blob.bin")

let blob = try await workspace.readData(from: "/blob.bin")
print(blob.count) // 4
```

### JSON Helpers

```swift
import Workspace

struct Config: Codable {
    var name: String
    var enabled: Bool
}

let filesystem = InMemoryFilesystem()

let workspace = Workspace(filesystem: filesystem)
try await workspace.writeJSON(Config(name: "demo", enabled: true), to: "/config.json")

let config = try await workspace.readJSON(Config.self, from: "/config.json")
print(config.enabled) // true
```

### Change Watching

```swift
import Workspace

let workspace = Workspace(filesystem: InMemoryFilesystem())
let changes = await workspace.watchChanges(at: "/notes")

Task {
    for await change in changes {
        print(change.kind, change.path)
    }
}

try await workspace.writeFile("/notes/todo.txt", content: "ship it")
```

## Common Patterns

### Rooted Disk Workspace

Use `ReadWriteFilesystem` when you want real file access under one root:

```swift
import Foundation
import Workspace

let root = URL(fileURLWithPath: "/tmp/demo-workspace", isDirectory: true)
let filesystem = try ReadWriteFilesystem(rootDirectory: root)
let workspace = Workspace(filesystem: filesystem)

try await workspace.createDirectory(at: "/src", recursive: false)
try await workspace.writeFile("/src/main.swift", content: "print(\"hello\")\n")
```

### Overlay On Top Of A Real Project

Use `OverlayFilesystem` when you want to read a real project but keep writes isolated in memory:

```swift
import Foundation
import Workspace

let projectRoot = URL(fileURLWithPath: "/path/to/project", isDirectory: true)
let filesystem = try await OverlayFilesystem(rootDirectory: projectRoot)
let workspace = Workspace(filesystem: filesystem)

let preview = try await workspace.summarizeTree("/Sources", maxDepth: 2)
try await workspace.writeFile("/SCRATCH.md", content: "overlay-only change\n")
```

### Multiple Workspaces Plus Shared Memory

Use `MountableFilesystem` to combine isolated roots and shared state in one virtual tree:

```swift
import Workspace

let workspaceA = InMemoryFilesystem()

let workspaceB = InMemoryFilesystem()

let sharedMemory = InMemoryFilesystem()

let mounted = MountableFilesystem(
    base: InMemoryFilesystem(),
    mounts: [
        .init(mountPoint: "/workspace-a", filesystem: workspaceA),
        .init(mountPoint: "/workspace-b", filesystem: workspaceB),
        .init(mountPoint: "/memory", filesystem: sharedMemory),
    ]
)

let workspace = Workspace(filesystem: mounted)
try await workspace.writeFile("/memory/plan.txt", content: "shared notes")
try await workspace.copyItem(from: "/memory/plan.txt", to: "/workspace-a/plan.txt", recursive: false)
```

### Operation-Level Permissions

Use `PermissionedFileSystem` when the host should decide which operations are allowed:

```swift
import Workspace

let base = InMemoryFilesystem()

let filesystem = PermissionedFileSystem(
    base: base,
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

## Batched Edits

`Workspace` includes explicit preview and apply APIs for tool-driven mutations:

```swift
let result = try await workspace.applyEdits([
    .createDirectory(path: "/src"),
    .writeFile(path: "/src/a.txt", content: "one"),
    .appendFile(path: "/src/a.txt", content: " two"),
    .copy(from: "/src/a.txt", to: "/src/b.txt"),
])

let writeChange = result.edits[1].fileChanges[0]
print(writeChange.status)              // applied
print(writeChange.diff?.hunks.count)   // Optional(1)
```

You can preview a batch before executing it:

```swift
let preview = try await workspace.previewEdits([
    .copy(from: "/docs/guide.txt", to: "/workspace/guide.txt"),
    .appendFile(path: "/workspace/notes.txt", content: "\nnext")
])

let appendPreview = preview.edits[1].fileChanges[0]
print(appendPreview.status)            // planned
print(appendPreview.diff?.hunks.count) // Optional(...)
```

Text replacements use a request type so scope, include, exclude, and matching strategy live in one value:

```swift
let preview = try await workspace.previewReplacement(
    ReplacementRequest(
        pattern: "/src/*.txt",
        search: .literal("foo"),
        replacement: "bar"
    )
)

let replacement = preview.changes[0]
print(replacement.status)         // planned
print(replacement.replacements)   // number of matched replacements
print(replacement.diff.hunks)     // structured line-based diff hunks
```

`ReplacementRequest`, `ReplacementResult`, edit metadata, tree metadata, and diffs are `Codable`, which makes previews and results easy to serialize for agent or tool workflows.

## Important Behavior

- `InMemoryFilesystem` is ready to use immediately after initialization. Call `await reset()` when you explicitly want to clear it. Actor isolation serializes access to the tree.
- `OverlayFilesystem` snapshots a real root into memory. Call `try await reload()` when you explicitly want to discard overlay edits and rebuild from disk.
- `ReadWriteFilesystem` and `OverlayFilesystem` normalize paths and enforce a rooted/jail model.
- `PermissionedFileSystem` sees normalized virtual paths, not raw user input paths.
- `FileSystem` provides default throwing implementations for advanced operations like symlinks, hard links, permission mutation, and real-path resolution, so minimal custom backends only need to implement the core read/write surface.
- `walkTree` and `summarizeTree` return stable path ordering, which is useful for deterministic tool output.

## Limitations

- `Workspace` is not a hardened sandbox.
- `applyEdits` and `applyReplacement` use logical rollback when `failurePolicy` is `.rollback`; other policies may leave partial changes in place.
- Rollback is not crash-safe and does not coordinate with external processes.
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
