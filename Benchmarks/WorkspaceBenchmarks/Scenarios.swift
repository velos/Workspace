#if os(macOS) || os(Linux)
import Foundation
import Workspace

struct ScenarioRunner {
    let fixture: Fixture
    let sourceTree: URL
    let scenario: Scenario
    let scratch: URL
    let watcherTimeout: Double

    func run(iterations: Int, warmups: Int) async -> ScenarioResult {
        var result = ScenarioResult(scenario: scenario, samples: [], peakRSSBytes: 0)
        do {
            let tree = scratch.appendingPathComponent("tree")
            let base: any FileSystem
            switch scenario.backend {
            case .local:
                try FileManager.default.copyItem(at: sourceTree, to: tree)
                // Foundation's Linux copy does not preserve mtimes. Stamp every
                // regular file, never symlinks, before a baseline can be captured.
                for i in 0..<fixture.fileCount {
                    try TemporaryCleanup.shared.checkInterrupt()
                    try stamp(tree.appendingPathComponent(Fixture.path(i, preset: fixture.preset)))
                }
                base = try LocalFileSystem(root: tree)
            case .memory:
                base = try await Fixture.loadMemory(from: sourceTree)
            }
            let counter =
                scenario.operation.observes
                ? ObservedCountingFileSystem(base) : CountingFileSystem(base)
            for iteration in 0..<(warmups + iterations) {
                try TemporaryCleanup.shared.checkInterrupt()
                let sample: Sample
                if scenario.operation.independentRepetitions {
                    var repetitions: [Sample] = []
                    for repetition in 0..<scenario.operation.repetitions {
                        repetitions.append(
                            try await measure(
                                base: base, counter: counter, tree: tree,
                                storeName: "store\(iteration)-\(repetition)"
                            ))
                    }
                    sample = try aggregate(repetitions)
                } else {
                    sample = try await measure(
                        base: base, counter: counter, tree: tree, storeName: "store\(iteration)"
                    )
                }
                if iteration < warmups {
                    result.warmupSamples.append(sample)
                } else {
                    result.samples.append(sample)
                }
            }
        } catch {
            result.error = String(describing: error)
        }
        result.peakRSSBytes = peakRSS()
        return result
    }

    private func stamp(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Fixture.modificationDate], ofItemAtPath: url.path
        )
    }

    private func aggregate(_ samples: [Sample]) throws -> Sample {
        guard var result = samples.first, samples.allSatisfy({ $0.io == result.io }) else {
            throw BenchmarkError.message("independent repetition counts differ")
        }
        result.milliseconds = samples.map(\.milliseconds).reduce(0, +) / Double(samples.count)
        result.repetitions = samples.count
        result.innerSamples = samples
        // Keep the first operation's exact memory/store pair as the representative.
        // Summary maxima come from innerSamples, never mismatched before/after fields.
        return result
    }

    private func measure(
        base: any FileSystem, counter: CountingFileSystem, tree: URL, storeName: String
    ) async throws -> Sample {
        let operation = scenario.operation
        let path = try WorkspacePath(Fixture.path(0, preset: fixture.preset))
        let original = Fixture.data(0, preset: fixture.preset)
        let originalText = String(decoding: original, as: UTF8.self)
        var changed = original
        changed[changed.startIndex + 3] = UInt8(ascii: "X")
        let changedText = String(decoding: changed, as: UTF8.self)
        let edits = try (0..<50).map { i -> Edit in
            var data = Fixture.data(i, preset: fixture.preset)
            data[data.startIndex + 3] = UInt8(ascii: "X")
            return .writeText(
                try WorkspacePath(Fixture.path(i, preset: fixture.preset)),
                String(decoding: data, as: UTF8.self)
            )
        }
        for i in 0..<operation.resetFileCount {
            let relative = Fixture.path(i, preset: fixture.preset)
            try await base.writeFile(
                path: WorkspacePath(relative), data: Fixture.data(i, preset: fixture.preset),
                append: false
            )
            if scenario.backend == .local { try stamp(tree.appendingPathComponent(relative)) }
        }
        let filesystem: any FileSystem =
            operation == .limitedWrite
            ? LimitedFileSystem(
                base: counter,
                limits: FileSystemLimits(
                    maxTotalBytes: UInt64(fixture.bytes) * 2, maxEntryCount: fixture.fileCount * 3
                )
            ) : counter
        // limitedWrite measures a warm accounting cache. Workspace's no-op priming
        // does not reach the filesystem mutation boundary, so prime it explicitly.
        if operation == .limitedWrite {
            try await filesystem.writeFile(path: path, data: original, append: false)
        }
        let store = scratch.appendingPathComponent(storeName)
        defer { try? FileManager.default.removeItem(at: store) }
        let persistence: Workspace.Persistence =
            scenario.persistence == .directory ? .directory(store) : .memory
        let workspaceID = UUID()
        let workspace = Workspace(
            workspaceID: workspaceID, fileSystem: filesystem, persistence: persistence)
        defer { withExtendedLifetime(workspace) {} }
        // A no-op mutation loads AND prepares the store, without recording an edit.
        let priming = try await workspace.writeText(path, originalText)
        guard priming.isEmpty else { throw BenchmarkError.message("preparation recorded a mutation") }
        // The steady-state transaction scenario excludes first-use base freezing.
        // Ordinary checkpoints no longer opt an instance into transaction caching.
        // transactionFirst measures that cold capture independently.
        if operation == .transaction { try await workspace.beginTransaction().discard() }
        let checkpoint: Checkpoint? =
            operation.needsBaselineCheckpoint
            ? try await workspace.createCheckpoint() : nil
        if operation.needsChangedFile { try await workspace.writeText(path, changedText) }
        if operation == .readCheckpointWarm {
            guard let checkpoint else { throw BenchmarkError.message("missing baseline checkpoint") }
            _ = try await workspace.readText(path, at: .checkpoint(checkpoint.id))
        }
        if operation.needsHistory {
            for i in 0..<1000 {
                try await workspace.writeText(path, i.isMultiple(of: 2) ? changedText : originalText)
            }
        }
        // Cold history uses the same workspace ID/store but a fresh, unprimed
        // reader. Its load/decode is the operation, not mutation preparation.
        let historyReader =
            operation == .history1000
            ? Workspace(workspaceID: workspaceID, fileSystem: filesystem, persistence: persistence)
            : workspace
        defer { withExtendedLifetime(historyReader) {} }
        var externalStream: AsyncStream<WorkspaceEvent>?
        if operation == .eventsExternal {
            externalStream = await workspace.events(.init(includeCheckpoints: false))
            try assertObservation(counter)
            try await Task.sleep(for: .milliseconds(300))
        }
        let storeBefore = try StoreFootprint.capture(store)
        counter.reset()
        let rssBefore = currentRSS()
        let setupPeak = peakRSS()
        var rssHeld: Int64?
        var heldResult: Any?
        let repetitions = operation.independentRepetitions ? 1 : operation.repetitions
        let start = ContinuousClock.now
        for _ in 0..<repetitions {
            switch operation {
            case .writeText, .limitedWrite, .write1001:
                let result = try await workspace.writeText(path, changedText)
                guard !result.isEmpty else { throw BenchmarkError.message("write produced no change") }
                heldResult = result
            case .apply50:
                let result = try await workspace.apply(edits)
                guard result.failures.isEmpty, result.changes.touchedPaths.count == 50 else {
                    throw BenchmarkError.message("apply50 incomplete")
                }
                heldResult = result
            case .preview:
                let result = try await workspace.preview([.writeText(path, changedText)])
                guard !result.isEmpty else { throw BenchmarkError.message("preview produced no change") }
                heldResult = result
            case .transaction, .transactionFirst:
                let transaction = try await workspace.beginTransaction()
                try await transaction.writeText(path, changedText)
                rssHeld = currentRSS()
                let commit = try await transaction.commit()
                guard commit.conflicts.isEmpty else {
                    throw BenchmarkError.message("transaction conflict")
                }
                heldResult = commit
            case .checkpointFirst, .checkpointIncremental:
                heldResult = try await workspace.createCheckpoint()
            case .diff:
                guard let checkpoint else { throw BenchmarkError.message("missing baseline checkpoint") }
                let result = try await workspace.diff(from: .checkpoint(checkpoint.id), to: .current)
                guard result.touchedPaths.count == 1 else {
                    throw BenchmarkError.message("expected one changed path")
                }
                heldResult = result
            case .restore:
                guard let checkpoint else { throw BenchmarkError.message("missing baseline checkpoint") }
                heldResult = try await workspace.restore(to: checkpoint)
            case .readCheckpoint, .readCheckpointWarm:
                guard let checkpoint else { throw BenchmarkError.message("missing baseline checkpoint") }
                let text = try await workspace.readText(path, at: .checkpoint(checkpoint.id))
                guard text.utf8.count == original.count else {
                    throw BenchmarkError.message("revision read mismatch")
                }
                heldResult = text
            case .readCurrent:
                let text = try await workspace.readText(path, at: .current)
                guard text.utf8.count == original.count else {
                    throw BenchmarkError.message("current read mismatch")
                }
                heldResult = text
            case .search:
                let result = try await workspace.search(
                    SearchRequest(
                        pattern: .literal("__BENCHMARK_ABSENT_NEEDLE__"),
                        limits: .init(
                            maxFileBytes: 1_000_000, maxFiles: fixture.fileCount * 2, maxMatches: Int.max)
                    ))
                guard result.matches.isEmpty else {
                    throw BenchmarkError.message("unexpected search match")
                }
                heldResult = result
            case .glob:
                let paths = try await workspace.glob("**/*")
                guard paths.count >= fixture.fileCount else {
                    throw BenchmarkError.message("glob missed files")
                }
                heldResult = paths
            case .history1000, .history1000Cached:
                let mutations = try await historyReader.history()
                guard mutations.count == 1000 else {
                    throw BenchmarkError.message("expected 1000 mutations, got \(mutations.count)")
                }
                heldResult = mutations
            case .eventsInitial:
                let stream = await workspace.events(.init(includeCheckpoints: false))
                externalStream = stream
                heldResult = stream
                try assertObservation(counter)
            case .eventsExternal:
                guard let stream = externalStream else {
                    throw BenchmarkError.message("missing external stream")
                }
                try await base.writeFile(path: path, data: changed, append: false)
                try await waitForChange(stream, path: path)
                heldResult = stream
            }
        }
        let elapsed = milliseconds(since: start) / Double(repetitions)
        let operationPeak = peakRSS()
        withExtendedLifetime(heldResult) {
            if rssHeld == nil { rssHeld = currentRSS() }
        }
        let counts = try counter.snapshot().perOperation(repetitions)
        if operation == .checkpointIncremental, scenario.persistence == .directory,
            counts.filesRead != 1 || counts.bytesRead != Int64(changed.count)
        {
            throw BenchmarkError.message(
                "incremental checkpoint premise failed: \(counts.filesRead) reads")
        }
        let storeWritten = try StoreFootprint.capture(store).written(since: storeBefore)
        if let stream = externalStream { await cancel(stream) }
        switch operation {
        case .writeText, .apply50, .transaction, .transactionFirst, .limitedWrite, .write1001:
            guard try await base.readFile(path: path) == changed else {
                throw BenchmarkError.message("mutation result mismatch")
            }
        case .restore, .preview:
            guard try await base.readFile(path: path) == original else {
                throw BenchmarkError.message("restoration/preview mismatch")
            }
        case .checkpointFirst, .checkpointIncremental, .diff, .readCheckpoint, .readCheckpointWarm,
            .readCurrent, .search, .glob, .history1000, .history1000Cached, .eventsInitial,
            .eventsExternal:
            break
        }
        return Sample(
            milliseconds: elapsed, io: counts, repetitions: repetitions,
            heldRSSDeltaBytes: delta(rssBefore, rssHeld), rssBeforeBytes: rssBefore,
            rssHeldBytes: rssHeld,
            setupPeakRSSBytes: setupPeak, operationPeakRSSBytes: operationPeak,
            operationPeakIncreaseBytes: max(0, operationPeak - setupPeak),
            storeBytesWritten: storeWritten.bytes, storeFilesWritten: storeWritten.files
        )
    }

    private func assertObservation(_ counter: CountingFileSystem) throws {
        let calls = counter.snapshot().calls
        guard (calls["walk"] ?? 0) > 0 || (calls["listDirectory"] ?? 0) > 0 else {
            throw BenchmarkError.message(
                "notification setup unavailable: events() did not index the initial tree")
        }
    }

    private func delta(_ before: Int64?, _ after: Int64?) -> Int64? {
        guard let before, let after else { return nil }
        return after - before
    }

    private func cancel(_ stream: AsyncStream<WorkspaceEvent>) async {
        let consumer = Task {
            for await _ in stream { if Task.isCancelled { break } }
        }
        consumer.cancel()
        await consumer.value
        await Task.yield()
    }

    private func waitForChange(_ stream: AsyncStream<WorkspaceEvent>, path: WorkspacePath)
        async throws
    {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in stream {
                    if case .changes(let changes) = event, changes.touchedPaths.contains(path) { return }
                }
                throw BenchmarkError.message("notification stream ended before external change")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(watcherTimeout))
                throw BenchmarkError.message("external change event timed out after \(watcherTimeout)s")
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

extension IOCounts {
    func perOperation(_ repetitions: Int) throws -> IOCounts {
        let divisor = Int64(repetitions)
        let values = Array(calls.values) + [bytesRead, filesRead, directoryEntries, globMatches]
        guard values.allSatisfy({ $0.isMultiple(of: divisor) }) else {
            throw BenchmarkError.message("repetition counts cannot be normalized exactly")
        }
        return IOCounts(
            calls: calls.mapValues { $0 / divisor }, bytesRead: bytesRead / divisor,
            filesRead: filesRead / divisor, directoryEntries: directoryEntries / divisor,
            globMatches: globMatches / divisor
        )
    }
}

#endif
