import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import Workspace

@Suite("Transactions")
struct TransactionTests {
    @Test
    func `transaction previews and commits as one parent mutation`() async throws {
        let workspace = Workspace()
        try await workspace.writeText("/a.txt", "base\n")
        let transaction = try await workspace.beginTransaction(label: "draft")
        try await transaction.writeText("/a.txt", "draft\n")
        try await transaction.writeText("/b.txt", "new\n")

        let preview = try await transaction.preview()
        #expect(preview.statistics.changedFileCount == 2)
        #expect(try await workspace.readText("/a.txt") == "base\n")

        let commit = try await transaction.commit()
        #expect(commit.applied)
        #expect(commit.preview == preview)
        #expect(commit.checkpoint?.origin == .transaction(base: nil))
        #expect(try await workspace.readText("/a.txt") == "draft\n")
        #expect(try await workspace.history().last?.operation == .transaction)
    }

    @Test
    func `discard and no-op commit create no parent artifacts`() async throws {
        let workspace = Workspace()
        let discarded = try await workspace.beginTransaction()
        try await discarded.writeText("/x", "x")
        try await discarded.discard()
        #expect(!(await workspace.exists("/x")))

        let noOp = try await workspace.beginTransaction()
        let commit = try await noOp.commit()
        #expect(commit.applied)
        #expect(commit.checkpoint == nil)
        #expect(try await workspace.checkpoints().isEmpty)
    }

    @Test
    func `three-way commit merges non-overlapping parent changes`() async throws {
        let workspace = Workspace()
        _ = try await workspace.apply([.writeText("/a", "a0"), .writeText("/b", "b0")])
        let transaction = try await workspace.beginTransaction()
        try await transaction.writeText("/a", "a1")
        try await workspace.writeText("/b", "b1")

        let commit = try await transaction.commit(strategy: .threeWay)
        #expect(commit.applied)
        #expect(try await workspace.readText("/a") == "a1")
        #expect(try await workspace.readText("/b") == "b1")
    }

    @Test
    func `conflicted transaction remains active for preview and discard`() async throws {
        let workspace = Workspace()
        try await workspace.writeText("/a", "base")
        let transaction = try await workspace.beginTransaction()
        try await transaction.writeText("/a", "draft")
        try await workspace.writeText("/a", "parent")

        let commit = try await transaction.commit()
        #expect(!commit.applied)
        #expect(commit.conflicts.map(\.path) == ["/a"])
        #expect(try await transaction.preview().changes.first?.path == "/a")
        try await transaction.discard()
        #expect(try await workspace.readText("/a") == "parent")
    }

    @Test
    func `strict commit rejects any parent change`() async throws {
        let workspace = Workspace()
        _ = try await workspace.apply([.writeText("/a", "a"), .writeText("/b", "b")])
        let transaction = try await workspace.beginTransaction()
        try await transaction.writeText("/a", "draft")
        try await workspace.writeText("/b", "parent")
        let commit = try await transaction.commit(strategy: .strict)
        #expect(commit.conflicts.contains { $0.kind == .parentChanged && $0.path == "/b" })
    }

    @Test
    func `scoped transaction returns value and commit`() async throws {
        let workspace = Workspace()
        let result = try await workspace.transaction { transaction in
            try await transaction.writeText("/value", "42")
            return 42
        }
        #expect(result.value == 42)
        #expect(result.commit.applied)
        #expect(try await workspace.readText("/value") == "42")
    }

    enum NodeShape: String, CaseIterable, Sendable {
        case missing, file, directory, symlink

        var create: [Edit] {
            switch self {
            case .missing: []
            case .file: [.writeText("/d", "file")]
            case .directory: [.createDirectory("/d")]
            case .symlink: [.createSymbolicLink("/d", target: "target")]
            }
        }

        func replacing(_ base: NodeShape) -> [Edit] {
            if self == base { return [] }
            return (base == .missing ? [] : [.remove("/d")]) + create
        }
    }

    // All ordered type combinations, including identical replacements and
    // unilateral changes. Expected outcomes are explicit tree shapes.
    @Test(arguments: NodeShape.allCases, NodeShape.allCases)
    func `type replacements merge identically or conflict without losing nodes`(
        base: NodeShape, replacement: NodeShape
    ) async throws {
        for parentShape in NodeShape.allCases {
            let workspace = Workspace()
            try await workspace.apply(base.create)
            let transaction = try await workspace.beginTransaction()
            try await transaction.apply(replacement.replacing(base))
            try await workspace.apply(parentShape.replacing(base))
            let before = try await workspace.revisionSnapshot(.current).entry
            let history = try await workspace.history()
            let commit = try await transaction.commit()
            let shouldConflict = replacement != base && parentShape != base && replacement != parentShape
            #expect(commit.applied == !shouldConflict,
                    "base=\(base), draft=\(replacement), parent=\(parentShape)")
            if shouldConflict {
                let expectedKind: Workspace.Transaction.Conflict.Kind = if base == .missing {
                    .bothCreated
                } else if parentShape == .missing || replacement == .missing {
                    .modifiedAndDeleted
                } else {
                    .bothModified
                }
                #expect(commit.conflicts.map(\.path) == ["/d"])
                #expect(commit.conflicts.map(\.kind) == [expectedKind])
                #expect(try await workspace.revisionSnapshot(.current).entry == before)
                #expect(try await workspace.history() == history)
                #expect(commit.checkpoint == nil)
            } else {
                let expected = Workspace()
                try await expected.apply((replacement == base ? parentShape : replacement).create)
                #expect(try await workspace.revisionSnapshot(.current).entry == expected.revisionSnapshot(.current).entry)
            }
        }
    }

    enum DescendantChange: String, CaseIterable, Sendable {
        case create, modify, permissions, typeChange, remove, move, moveOut
        var base: [Edit] {
            self == .create ? [.createDirectory("/d")] : [.createDirectory("/d/nested"), .writeText("/d/nested/a", "base")]
        }
        var edits: [Edit] {
            switch self {
            case .create: [.writeText("/d/new.txt", "new")]
            case .modify: [.writeText("/d/nested/a", "changed")]
            case .permissions: [.setPermissions("/d/nested/a", POSIXPermissions(0o600))]
            case .typeChange: [.remove("/d/nested/a"), .createDirectory("/d/nested/a")]
            case .remove: [.remove("/d/nested/a")]
            case .moveOut: [.move(from: "/d/nested/a", to: "/out")]
            case .move: [.move(from: "/d/nested/a", to: "/d/moved")]
            }
        }
    }

    @Test(arguments: [NodeShape.missing, .file, .symlink], DescendantChange.allCases)
    func `ancestor replacement and descendant edits never silently lose work`(
        replacement: NodeShape, descendant: DescendantChange
    ) async throws {
        for reverse in [false, true] {
            let workspace = Workspace()
            try await workspace.apply(descendant.base)
            let transaction = try await workspace.beginTransaction()
            let ancestorEdits = replacement.replacing(.directory)
            try await transaction.apply(reverse ? descendant.edits : ancestorEdits)
            try await workspace.apply(reverse ? ancestorEdits : descendant.edits)
            let before = try await workspace.revisionSnapshot(.current).entry
            let history = try await workspace.history()
            let commit = try await transaction.commit()
            if descendant == .remove || descendant == .moveOut {
                #expect(commit.applied)
                let expected = Workspace()
                try await expected.apply(replacement.create)
                if descendant == .moveOut { try await expected.writeText("/out", "base") }
                #expect(try await workspace.revisionSnapshot(.current).entry == expected.revisionSnapshot(.current).entry)
            } else {
                // In particular, modifying /d/nested/a reports only the outer /d,
                // without nested structural or modifiedAndDeleted duplicates.
                #expect(commit.conflicts == [.init(path: "/d", kind: .structural)])
                #expect(try await workspace.revisionSnapshot(.current).entry == before)
                #expect(try await workspace.history() == history)
                #expect(commit.checkpoint == nil)
                try await transaction.discard()
            }
        }
    }

    @Test(arguments: [WorkspacePath.root, "/d", "/d/a"])
    func `permissions use three-way rules including root metadata`(path: WorkspacePath) async throws {
        // nil leaves that side unchanged; equal and differing edits are separate cases.
        let pairs: [(Int?, Int?, Bool)] = [
            (0o700, nil, true), (nil, 0o700, true),
            (0o700, 0o700, true), (0o700, 0o711, false)
        ]
        for (draftMode, parentMode, clean) in pairs {
            let workspace = Workspace()
            try await workspace.createDirectory("/d")
            try await workspace.writeText("/d/a", "content")
            let transaction = try await workspace.beginTransaction()
            if let draftMode { try await transaction.setPermissions(POSIXPermissions(draftMode), at: path) }
            if let parentMode { try await workspace.setPermissions(POSIXPermissions(parentMode), at: path) }
            let before = try await workspace.revisionSnapshot(.current).entry
            let commit = try await transaction.commit()
            #expect(commit.applied == clean)
            if clean {
                #expect(try await workspace.info(path).permissions == POSIXPermissions(draftMode ?? parentMode!))
                #expect(try await workspace.readText("/d/a") == "content")
                if draftMode != nil && parentMode == nil {
                    #expect(commit.appliedChanges.touchedPaths == [path])
                    #expect(commit.checkpoint != nil)
                }
            } else {
                #expect(commit.conflicts.map(\.path) == [path])
                #expect(try await workspace.revisionSnapshot(.current).entry == before)
            }
        }
    }

    @Test
    func `strict commits include root permissions in comparison and application`() async throws {
        let workspace = Workspace()
        let transaction = try await workspace.beginTransaction()
        try await workspace.setPermissions(POSIXPermissions(0o700), at: .root)
        let rejected = try await transaction.commit(strategy: .strict)
        #expect(rejected.conflicts == [.init(path: .root, kind: .parentChanged)])
        try await workspace.setPermissions(.defaultDirectory, at: .root)
        try await transaction.setPermissions(POSIXPermissions(0o711), at: .root)
        #expect(try await transaction.commit(strategy: .strict).applied)
        #expect(try await workspace.info(.root).permissions == POSIXPermissions(0o711))
    }

    @Test
    func `commit excludes late edits discard and duplicate commits while suspended`() async throws {
        let fs = HookableFileSystem()
        let workspace = Workspace(fileSystem: fs)
        let transaction = try await workspace.beginTransaction()
        try await transaction.writeText("/a", "42")
        let entered = TestSignal()
        let resume = TestSignal()
        await fs.onWrite { _ in
            await entered.signal()
            await resume.wait()
        }
        let committing = Task { try await transaction.commit() }
        await entered.wait()
        await #expect { try await transaction.writeText("/late", "lost") } throws: { error in
            guard case Workspace.Transaction.TransactionError.committing = error else { return false }
            return true
        }
        await #expect { try await transaction.discard() } throws: { error in
            guard case Workspace.Transaction.TransactionError.committing = error else { return false }
            return true
        }
        await #expect {
            try await transaction.commit()
        } throws: { error in
            guard case Workspace.Transaction.TransactionError.committing = error else { return false }
            return true
        }
        #expect(try await transaction.exists("/a"))
        #expect(try await transaction.readText("/a") == "42")
        #expect(try await transaction.readData(from: "/a") == Data("42".utf8))
        #expect(try await transaction.readJSON(Int.self, from: "/a") == 42)
        #expect(try await transaction.search(.init(pattern: .literal("42"))).matches.map(\.path) == ["/a"])
        #expect(try await transaction.info("/a").kind == .file)
        #expect(try await transaction.list(.root).map(\.name) == ["a"])
        #expect(try await transaction.tree().children?.map(\.path) == ["/a"])
        #expect(try await transaction.glob("/a*") == ["/a"])
        #expect(try await transaction.preview().touchedPaths == ["/a"])
        #expect(try await transaction.preview([.writeText("/preview", "scratch")]).touchedPaths == ["/preview"])
        #expect(!(try await transaction.exists("/preview")))
        await resume.signal()
        #expect(try await committing.value.applied)
        #expect(try await workspace.readText("/a") == "42")
        #expect(!(await workspace.exists("/late")))
        await #expect { try await transaction.commit() } throws: { error in
            guard case Workspace.Transaction.TransactionError.inactive = error else { return false }
            return true
        }
    }

    struct MergePair: Sendable {
        let name: String
        let base: [Edit]
        let draft: [Edit]
        let parent: [Edit]
        // nil means conflict; otherwise these edits create the complete expected tree.
        let expected: [Edit]?
        var conflict: Workspace.Transaction.Conflict? = nil

        static let cases: [MergePair] = [
            .init(name: "identical file edits", base: [.writeText("/a", "old")],
                  draft: [.writeText("/a", "same")], parent: [.writeText("/a", "same")],
                  expected: [.writeText("/a", "same")]),
            .init(name: "different file edits", base: [.writeText("/a", "old")],
                  draft: [.writeText("/a", "draft")], parent: [.writeText("/a", "parent")], expected: nil,
                  conflict: .init(path: "/a", kind: .bothModified)),
            .init(name: "identical link targets", base: [.createSymbolicLink("/a", target: "old")],
                  draft: [.remove("/a"), .createSymbolicLink("/a", target: "same")],
                  parent: [.remove("/a"), .createSymbolicLink("/a", target: "same")],
                  expected: [.createSymbolicLink("/a", target: "same")]),
            .init(name: "different link targets", base: [.createSymbolicLink("/a", target: "old")],
                  draft: [.remove("/a"), .createSymbolicLink("/a", target: "draft")],
                  parent: [.remove("/a"), .createSymbolicLink("/a", target: "parent")], expected: nil,
                  conflict: .init(path: "/a", kind: .bothModified)),
            .init(name: "content versus mode is a node conflict", base: [.writeText("/a", "old")],
                  draft: [.writeText("/a", "new")], parent: [.setPermissions("/a", POSIXPermissions(0o600))], expected: nil,
                  conflict: .init(path: "/a", kind: .bothModified)),
            .init(name: "directory mode and child content merge", base: [.createDirectory("/d"), .writeText("/d/a", "old")],
                  draft: [.writeText("/d/a", "new")], parent: [.setPermissions("/d", POSIXPermissions(0o700))],
                  expected: [.createDirectory("/d"), .writeText("/d/a", "new"), .setPermissions("/d", POSIXPermissions(0o700))]),
            .init(name: "concurrent directory creation keeps both children", base: [],
                  draft: [.createDirectory("/d"), .writeText("/d/a", "a")],
                  parent: [.createDirectory("/d"), .writeText("/d/b", "b")],
                  expected: [.createDirectory("/d"), .writeText("/d/a", "a"), .writeText("/d/b", "b")]),
            .init(name: "identical populated directory deletions", base: [.createDirectory("/d"), .writeText("/d/a", "a")],
                  draft: [.remove("/d")], parent: [.remove("/d")], expected: []),
            .init(name: "move directory versus new source child", base: [.createDirectory("/d")],
                  draft: [.move(from: "/d", to: "/moved")], parent: [.writeText("/d/new", "new")], expected: nil,
                  conflict: .init(path: "/d", kind: .structural)),
            .init(name: "move file versus source edit", base: [.writeText("/a", "old")],
                  draft: [.move(from: "/a", to: "/moved")], parent: [.writeText("/a", "new")], expected: nil,
                  conflict: .init(path: "/a", kind: .modifiedAndDeleted)),
            .init(name: "move child outside a removed ancestor", base: [.createDirectory("/d"), .writeText("/d/a", "a")],
                  draft: [.move(from: "/d/a", to: "/out")], parent: [.remove("/d")],
                  expected: [.writeText("/out", "a")]),
            .init(name: "identical directory moves", base: [.createDirectory("/d"), .writeText("/d/a", "a")],
                  draft: [.move(from: "/d", to: "/moved")], parent: [.move(from: "/d", to: "/moved")],
                  expected: [.createDirectory("/moved"), .writeText("/moved/a", "a")]),
            .init(name: "different move destinations preserve both creations", base: [.writeText("/a", "a")],
                  draft: [.move(from: "/a", to: "/one")], parent: [.move(from: "/a", to: "/two")],
                  expected: [.writeText("/one", "a"), .writeText("/two", "a")])
        ]
    }

    @Test(arguments: MergePair.cases)
    func `concurrent changes merge to the expected complete tree or leave parent intact`(pair: MergePair) async throws {
        for reverse in [false, true] {
            let workspace = Workspace()
            try await workspace.apply(pair.base)
            let transaction = try await workspace.beginTransaction()
            try await transaction.apply(reverse ? pair.parent : pair.draft)
            try await workspace.apply(reverse ? pair.draft : pair.parent)
            let before = try await workspace.revisionSnapshot(.current).entry
            let history = try await workspace.history()
            let checkpoints = try await workspace.checkpoints()
            let commit = try await transaction.commit()
            if let expectedEdits = pair.expected {
                #expect(commit.applied, "\(pair.name)")
                let expected = Workspace()
                try await expected.apply(expectedEdits)
                #expect(try await workspace.revisionSnapshot(.current).entry == expected.revisionSnapshot(.current).entry)
            } else {
                let conflict = try #require(pair.conflict)
                #expect(commit.conflicts.map(\.path) == [conflict.path], "\(pair.name)")
                #expect(commit.conflicts.map(\.kind) == [conflict.kind], "\(pair.name)")
                #expect(try await workspace.revisionSnapshot(.current).entry == before)
                #expect(try await workspace.history() == history)
                #expect(try await workspace.checkpoints() == checkpoints)
            }
        }
    }

    @Test(arguments: [false, true])
    func `commit can retry after read failure or successful rollback`(duringWrite: Bool) async throws {
        let fs = HookableFileSystem()
        let workspace = Workspace(fileSystem: fs)
        try await workspace.writeText("/a", "base")
        let transaction = try await workspace.beginTransaction()
        try await transaction.writeText("/a", "draft")
        let before = try await workspace.revisionSnapshot(.current).entry
        let history = try await workspace.history()
        if duringWrite {
            await fs.onWrite { _ in
                // Fail after touching the parent, so this exercises compensation.
                try await fs.base.writeFile(path: "/a", data: Data("partial".utf8), append: false)
                throw TestFileSystemError.injected
            }
        } else {
            await fs.onRead { _ in throw TestFileSystemError.injected }
        }
        await #expect(throws: TestFileSystemError.self) { try await transaction.commit() }
        #expect(try await workspace.revisionSnapshot(.current).entry == before)
        #expect(try await workspace.history() == history)
        #expect(try await workspace.checkpoints().isEmpty)
        try await transaction.appendText("/a", "-retry")
        #expect(try await transaction.commit().applied)
        #expect(try await workspace.readText("/a") == "draft-retry")
    }

    @Test
    func `failed rollback closes transaction against unsafe retries`() async throws {
        let fs = HookableFileSystem()
        let workspace = Workspace(fileSystem: fs)
        let transaction = try await workspace.beginTransaction()
        try await transaction.writeText("/a", "draft")
        await fs.onWrite { _ in
            try await fs.base.writeFile(path: "/a", data: Data("partial".utf8), append: false)
            await fs.failRemovals()
            throw TestFileSystemError.injected
        }
        await #expect(throws: WorkspaceRollbackError.self) { try await transaction.commit() }
        #expect(try await workspace.readText("/a") == "partial")
        await #expect { try await transaction.writeText("/a", "retry") } throws: { error in
            guard case Workspace.Transaction.TransactionError.inactive = error else { return false }
            return true
        }
        await #expect { try await transaction.commit() } throws: { error in
            guard case Workspace.Transaction.TransactionError.inactive = error else { return false }
            return true
        }
        await #expect { try await transaction.discard() } throws: { error in
            guard case Workspace.Transaction.TransactionError.inactive = error else { return false }
            return true
        }
    }

    @Test
    func `merge validation rejects missing or non-directory ancestry`() throws {
        let root = Workspace.MergeNode(kind: .directory, permissions: .defaultDirectory)
        let file = Workspace.MergeNode(kind: .file, permissions: .defaultFile, fileData: Data("keep".utf8))
        let link = Workspace.MergeNode(kind: .symlink, permissions: POSIXPermissions(0o777), symlinkTarget: "elsewhere")
        let invalid: [[WorkspacePath: Workspace.MergeNode]] = [
            [:], [.root: file], [.root: link],
            [.root: root, "/missing/child": file],
            [.root: root, "/d": file, "/d/child": file],
            [.root: root, "/d": link, "/d/child": file],
            [.root: root, "/missing/deep": root, "/missing/deep/child": file]
        ]
        for nodes in invalid {
            #expect(throws: WorkspaceError.self) { try Workspace.validateMergeNodes(nodes) }
        }
    }

    @Test
    func `commit waits for an already admitted draft edit before taking its snapshot`() async throws {
        let workspace = Workspace()
        let base = try await workspace.revisionSnapshot(.current)
        let draftFS = HookableFileSystem()
        let draft = Workspace(fileSystem: draftFS)
        // Use the existing initializer to supply a draft whose I/O can suspend.
        var nodes: [WorkspacePath: Workspace.MergeNode] = [:]
        Workspace.flattenMergeNodes(base.entry, into: &nodes)
        let tree = TransactionTree(nodes: nodes, load: { _ in throw WorkspaceError.readOnly })
        let transaction = Workspace.Transaction(parent: workspace, draft: draft, base: tree,
            metadata: try await MetadataIndex.capture(from: workspace.fileSystem), baseCheckpointID: nil, label: nil)
        let entered = TestSignal()
        let resume = TestSignal()
        await draftFS.onWrite { _ in
            await entered.signal()
            await resume.wait()
        }
        let editing = Task { try await transaction.apply([.writeText("/a", "first"), .writeText("/b", "second")]) }
        await entered.wait()
        let committing = Task {
            try await commitWithSuspensionHook(transaction) { _ in
                let entries = try await workspace.list(.root)
                #expect(entries.isEmpty)
                await resume.signal()
            }
        }
        _ = try await editing.value
        #expect(try await committing.value.applied)
        #expect(try await workspace.readText("/a") == "first")
        #expect(try await workspace.readText("/b") == "second")
    }

    @Test
    func `cancelled commit before parent mutation remains retryable`() async throws {
        let workspace = Workspace()
        let base = try await workspace.revisionSnapshot(.current)
        let draftFS = HookableFileSystem()
        let draft = Workspace(fileSystem: draftFS)
        var nodes: [WorkspacePath: Workspace.MergeNode] = [:]
        Workspace.flattenMergeNodes(base.entry, into: &nodes)
        let tree = TransactionTree(nodes: nodes, load: { _ in throw WorkspaceError.readOnly })
        let transaction = Workspace.Transaction(parent: workspace, draft: draft, base: tree,
            metadata: try await MetadataIndex.capture(from: workspace.fileSystem), baseCheckpointID: nil, label: nil)
        try await transaction.writeText("/a", "draft")
        let entered = TestSignal()
        let resume = TestSignal()
        await draftFS.onRead { _ in
            await entered.signal()
            await resume.wait()
        }
        await workspace.acquireOperation()
        let committing = Task { try await transaction.commit() }
        await entered.wait()
        committing.cancel()
        await resume.signal()
        await workspace.releaseOperation()
        await #expect(throws: CancellationError.self) { try await committing.value }
        #expect(try await workspace.list(.root).isEmpty)
        #expect(try await workspace.history().isEmpty)
        try await transaction.appendText("/a", "-retry")
        #expect(try await transaction.commit().applied)
        #expect(try await workspace.readText("/a") == "draft-retry")
    }

    @Test(arguments: [false, true])
    func `restrictive in-memory directories need no chmod for commit or rollback`(atomicFailure: Bool) async throws {
        let fs = HookableFileSystem()
        try await fs.base.createDirectory(path: "/d", recursive: true)
        try await fs.base.writeFile(path: "/d/a", data: Data("old".utf8), append: false)
        try await fs.base.setPermissions(path: "/d", permissions: POSIXPermissions(0o555))
        let workspace = Workspace(fileSystem: fs)
        try await workspace.writeText("/d/plain", "plain")
        if atomicFailure {
            // The no-op mkdir expands the rollback journal to /d, whose mode
            // already matches the snapshot and needs no optional chmod support.
            await #expect(throws: TestFileSystemError.self) {
                try await workspace.apply([
                    .writeText("/d/a", "temporary"), .createDirectory("/d"), .writeText("/fail", "fail")
                ])
            }
            #expect(try await workspace.readText("/d/a") == "old")
        } else {
            let transaction = try await workspace.beginTransaction()
            try await transaction.writeText("/d/a", "committed")
            #expect(try await transaction.commit().applied)
            #expect(try await workspace.readText("/d/a") == "committed")
        }
        #expect(try await workspace.readText("/d/plain") == "plain")
        #expect(try await workspace.info("/d").permissions == POSIXPermissions(0o555))
        #expect(await fs.permissionWrites.isEmpty)
    }

    @Test
    func `unchanged restrictive subdirectories are not chmodded during restore`() async throws {
        let fs = HookableFileSystem(forwardsPermissions: true)
        try await fs.base.createDirectory(path: "/d/kept", recursive: true)
        try await fs.base.writeFile(path: "/d/kept/a", data: Data("kept".utf8), append: false)
        try await fs.base.setPermissions(path: "/d/kept", permissions: POSIXPermissions(0o555))
        let workspace = Workspace(fileSystem: fs)
        let transaction = try await workspace.beginTransaction()
        try await transaction.setPermissions(POSIXPermissions(0o750), at: "/d")
        #expect(try await transaction.commit().applied)
        // Only the explicitly requested parent mode change reaches the backend.
        #expect(await fs.permissionWrites.map(\.path) == ["/d"])
        #expect(await fs.permissionWrites.map(\.permissions) == [POSIXPermissions(0o750)])
        #expect(try await workspace.info("/d/kept").permissions == POSIXPermissions(0o555))
        #expect(try await workspace.readText("/d/kept/a") == "kept")
    }

    @Test(.enabled(if: geteuid() != 0, "Root bypasses directory write permissions"))
    func `local child failure restores temporary access and leaves transaction retryable`() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("d").path)
            TestSupport.remove(root)
        }
        let local = try LocalFileSystem(root: root)
        try await local.createDirectory(path: "/d", recursive: true)
        try await local.writeFile(path: "/d/a", data: Data("old".utf8), append: false)
        try await local.setPermissions(path: "/d", permissions: POSIXPermissions(0o500))
        let fs = HookableFileSystem(base: local, forwardsPermissions: true)
        let workspace = Workspace(fileSystem: fs)
        let transaction = try await workspace.beginTransaction()
        try await transaction.writeText("/d/a", "new")
        await fs.onWrite { _ in
            if try await local.stat(path: "/d").permissions == POSIXPermissions(0o500) {
                // Let the actual local write fail with EACCES first. The retry
                // after granting access must fail with the injected error.
                await fs.onWrite { _ in throw TestFileSystemError.injected }
            } else {
                throw TestFileSystemError.injected
            }
        }
        await #expect(throws: TestFileSystemError.self) { try await transaction.commit() }
        #expect(try await workspace.info("/d").permissions == POSIXPermissions(0o500))
        #expect(try await workspace.readText("/d/a") == "old")
        #expect(await fs.permissionWrites.map(\.permissions) == [POSIXPermissions(0o700), POSIXPermissions(0o500)])
        #expect(try await workspace.history().isEmpty)
        #expect(try await transaction.commit().applied)
        #expect(try await workspace.readText("/d/a") == "new")
        #expect(try await workspace.info("/d").permissions == POSIXPermissions(0o500))
    }

    enum RestrictiveRemoval: CaseIterable, Sendable {
        case directory, child, replaceWithFile
    }

    @Test(.enabled(if: geteuid() != 0, "Root bypasses directory write permissions"),
          arguments: RestrictiveRemoval.allCases)
    func `local restore removes directories with restrictive descendants`(scenario: RestrictiveRemoval) async throws {
        let root = try TestSupport.temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("d").path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("d/nested").path)
            TestSupport.remove(root)
        }
        let local = try LocalFileSystem(root: root)
        try await local.createDirectory(path: "/d/nested", recursive: true)
        try await local.writeFile(path: "/d/nested/a", data: Data("remove".utf8), append: false)
        try await local.setPermissions(path: "/d/nested", permissions: POSIXPermissions(0o500))
        try await local.setPermissions(path: "/d", permissions: POSIXPermissions(0o500))
        let workspace = Workspace(fileSystem: local)
        let transaction = try await workspace.beginTransaction()
        try await transaction.remove(scenario == .child ? "/d/nested" : "/d")
        if scenario == .replaceWithFile { try await transaction.writeText("/d", "replacement") }
        #expect(try await transaction.commit().applied)
        switch scenario {
        case .directory: #expect(!(await workspace.exists("/d")))
        case .child:
            #expect(try await workspace.list("/d").isEmpty)
            #expect(try await workspace.info("/d").permissions == POSIXPermissions(0o500))
        case .replaceWithFile: #expect(try await workspace.readText("/d") == "replacement")
        }
    }

    enum RestrictiveDirectory: CaseIterable, Sendable {
        case parentMode, draftMode, existingMode, newDirectory
    }

    @Test(.enabled(if: geteuid() != 0, "Root bypasses directory write permissions"),
          arguments: RestrictiveDirectory.allCases)
    func `local commits restore children before restrictive directory modes`(scenario: RestrictiveDirectory) async throws {
        let root = try TestSupport.temporaryDirectory()
        defer {
            // Restore traversal/write permissions before cleaning up, including
            // when an assertion or commit fails.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("d").path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("d/nested").path)
            TestSupport.remove(root)
        }
        let workspace = Workspace(fileSystem: try LocalFileSystem(root: root))
        if scenario != .newDirectory {
            try await workspace.createDirectory("/d")
            try await workspace.writeText("/d/kept", "kept")
        }
        if scenario == .existingMode { try await workspace.setPermissions(POSIXPermissions(0o500), at: "/d") }
        let transaction = try await workspace.beginTransaction()
        if scenario == .parentMode { try await workspace.setPermissions(POSIXPermissions(0o500), at: "/d") }
        if scenario == .draftMode {
            try await workspace.createDirectory("/d/nested")
            try await workspace.writeText("/d/nested/new", "new")
        } else {
            try await transaction.createDirectory("/d/nested")
            try await transaction.writeText("/d/nested/new", "new")
        }
        if scenario == .draftMode || scenario == .newDirectory {
            try await transaction.setPermissions(POSIXPermissions(0o500), at: "/d")
        }
        // A new restrictive child directory must also be populated before chmod.
        if scenario == .newDirectory { try await transaction.setPermissions(POSIXPermissions(0o500), at: "/d/nested") }
        #expect(try await transaction.commit().applied)
        #expect(try await workspace.info("/d").permissions == POSIXPermissions(0o500))
        #expect(try await workspace.readText("/d/nested/new") == "new")
        if scenario == .newDirectory {
            #expect(try await workspace.info("/d/nested").permissions == POSIXPermissions(0o500))
        } else {
            #expect(try await workspace.readText("/d/kept") == "kept")
        }
    }
}

// Enqueue the hook on the same actor before entering commit synchronously. It
// cannot run until commit suspends, so a paused draft write is released only
// after commit has entered its drain. This adds no production observation seam.
private func commitWithSuspensionHook(
    _ transaction: isolated Workspace.Transaction,
    hook: @escaping @Sendable (isolated Workspace.Transaction) async throws -> Void
) async throws -> Workspace.Transaction.Commit {
    let observer = Task { try await hook(transaction) }
    let result = try await transaction.commit()
    try await observer.value
    return result
}
