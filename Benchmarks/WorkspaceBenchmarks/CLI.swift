#if os(macOS) || os(Linux)
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct Options {
    var preset = "small"
    var fixtureDirectory: URL?
    var json: URL?
    var compare: URL?
    var filter: String?
    var iterations = 5
    var warmups = 1
    var watcherTimeout = 15.0
    var scenarioTimeout = 1800.0
    var keepFixture = false
    var scenarioID: String?
    var childResult: URL?
    var help = false

    init(_ arguments: [String]) throws {
        var index = 0
        func value(_ option: String) throws -> String {
            index += 1
            guard index < arguments.count else {
                throw BenchmarkError.message("missing value for \(option)")
            }
            return arguments[index]
        }
        func url(_ value: String) -> URL { URL(fileURLWithPath: value).standardizedFileURL }
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--preset": preset = try value(option)
            case "--fixture-dir": fixtureDirectory = try url(value(option))
            case "--json": json = try url(value(option))
            case "--compare": compare = try url(value(option))
            case "--filter": filter = try value(option)
            case "--iterations":
                guard let number = try Int(value(option)), number > 0 else {
                    throw BenchmarkError.message("iterations must be positive")
                }
                iterations = number
            case "--warmups":
                guard let number = try Int(value(option)), number >= 0 else {
                    throw BenchmarkError.message("warmups must be nonnegative")
                }
                warmups = number
            case "--watch-timeout":
                guard let seconds = try Double(value(option)), seconds.isFinite, seconds > 0 else {
                    throw BenchmarkError.message("watch timeout must be positive")
                }
                watcherTimeout = seconds
            case "--scenario-timeout":
                guard let seconds = try Double(value(option)), seconds.isFinite, seconds > 0 else {
                    throw BenchmarkError.message("scenario timeout must be positive")
                }
                scenarioTimeout = seconds
            case "--keep-fixture": keepFixture = true
            case "--scenario": scenarioID = try value(option)
            case "--child-result": childResult = try url(value(option))
            case "--help", "-h": help = true
            default: throw BenchmarkError.message("unknown option: \(option)")
            }
            index += 1
        }
        _ = try Fixture.count(preset)
    }
    static let usage = """
        Usage: swift run -c release WorkspaceBenchmarks [options]
          --preset small|medium|large    Deterministic 1k/10k/100k-file fixture (default small)
          --fixture-dir PATH            Generate or validate/reuse a preserved fixture
          --iterations N                Measured iterations per scenario (default 5)
          --warmups N                   Warmups excluded from summaries (default 1; raw samples retained)
          --filter TEXT[,TEXT...]        Match substrings of backend/persistence/operation
          --json PATH                   Write full report, updated after every scenario
          --compare BASELINE.json        Print exact I/O deltas and timing ratios
          --watch-timeout SECONDS        External event deadline (default 15)
          --scenario-timeout SECONDS     Child process deadline (default 1800)
          --keep-fixture                 Preserve an automatically generated fixture
        Every scenario is re-executed in a fresh child. Temporary scenario trees/stores are removed.
        """
}

@main
struct WorkspaceBenchmarks {
    static func main() async {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            if options.help {
                print(Options.usage)
                return
            }
            try await run(options)
            await TemporaryCleanup.shared.finishInterruptIfNeeded()
        } catch {
            await TemporaryCleanup.shared.finishInterruptIfNeeded()
            FileHandle.standardError.write(Data("WorkspaceBenchmarks: \(error)\n".utf8))
            exit(1)
        }
    }
    static func run(_ options: Options) async throws {
        let manager = FileManager.default
        let temporary =
            (options.childResult?.deletingLastPathComponent() ?? manager.temporaryDirectory)
            .appendingPathComponent("WorkspaceBenchmarks-\(UUID().uuidString)")
        TemporaryCleanup.shared.register(temporary)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer {
            try? manager.removeItem(at: temporary)
            TemporaryCleanup.shared.unregister(temporary)
        }
        if let scenarioID = options.scenarioID {
            guard let directory = options.fixtureDirectory, let resultURL = options.childResult,
                let scenario = Scenario.all(preset: options.preset).first(where: { $0.id == scenarioID })
            else {
                throw BenchmarkError.message("invalid internal child arguments")
            }
            // Parent already validated the immutable fixture. Do not regenerate/validate every child.
            let fixture = try JSONDecoder().decode(
                Fixture.self, from: Data(contentsOf: directory.appendingPathComponent("fixture.json")))
            let runner = ScenarioRunner(
                fixture: fixture, sourceTree: directory.appendingPathComponent("tree"),
                scenario: scenario, scratch: temporary, watcherTimeout: options.watcherTimeout)
            let result = await runner.run(iterations: options.iterations, warmups: options.warmups)
            try encoder().encode(result).write(to: resultURL, options: .atomic)
            return
        }
        let directory =
            options.fixtureDirectory
            ?? manager.temporaryDirectory.appendingPathComponent(
                "WorkspaceBenchmarkFixture-\(UUID().uuidString)")
        if options.fixtureDirectory == nil, !options.keepFixture {
            TemporaryCleanup.shared.register(directory)
        }
        defer {
            if options.fixtureDirectory == nil, !options.keepFixture {
                try? manager.removeItem(at: directory)
                TemporaryCleanup.shared.unregister(directory)
            }
        }
        if let json = options.json {
            try manager.createDirectory(
                at: json.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        emit("Preparing \(options.preset) fixture at \(directory.path) (excluded from measurements)…")
        let fixture = try Fixture.loadOrGenerate(at: directory, preset: options.preset)
        let scenarios = Scenario.all(preset: options.preset).filter { scenario in
            options.filter.map { filter in
                filter.split(separator: ",").contains { scenario.id.contains($0) }
            } ?? true
        }
        guard !scenarios.isEmpty else { throw BenchmarkError.message("filter matched no scenarios") }
        var report = Report(
            createdAt: Date(), machine: machine(), fixture: fixture, iterations: options.iterations,
            warmups: options.warmups, results: [],
            measurementNotes: [
                """
                Each scenario uses a child process; fresh prepared stores per sample. Warmups/setup are excluded \
                from timing and counters. Percentiles use linear interpolation. Inner repetitions are averaged; counts are normalized exactly per \
                operation. Independent writes use fresh prepared stores; write1001 always times exactly the 1,001st \
                mutation.
                """,
                """
                Counters observe backend FileSystem calls, not OS syscalls, draft filesystem, checkpoint-store \
                reads/writes, or glob internals. globMatches reports returned traversal size.
                """,
                """
                Each sample records getrusage peak immediately before/after timing, normalized to bytes, and its \
                increase. Setup peak is cumulative process high-water, including preceding operations; zero increase \
                does not mean zero allocations. Held RSS is captured with the final result live. Summary uses \
                measured samples only; first-run held RSS is separate.
                """,
                """
                Store writes are logical estimates from directory metadata before/after, outside timing: append \
                growth or final size of new/replaced files. They exclude transient/deleted files, repeated \
                overwrites and OS write amplification.
                """,
                """
                Transactions have a baseline checkpoint; transactionFirst has none. Directory incremental capture \
                asserts exactly one changed-file read. Copied/reset regular files are stamped to the old fixture \
                epoch on both OSes.
                """,
                """
                readCheckpoint is cold index access; readCheckpointWarm primes that index. history1000 cold-loads a \
                fresh directory Workspace; history1000Cached reads the seeded memory Workspace. All mutation \
                scenarios prime preparation with a no-op write.
                """,
                """
                External event time includes backend write, notification latency/debounce and all recaptures until \
                the changed-path event arrives. Unsupported watchers report errors, not zero-cost successes.
                """,
            ])
        emit(
            """
            \(fixture.fileCount) regular files, \(fixture.bytes) bytes, \(fixture.directoryCount) directories, \
            \(fixture.symlinkCount) symlinks; \(options.warmups) warmup(s) + \(options.iterations) iterations
            """
        )
        emit(
            """
            scenario                                  median ms    p90 ms   read MiB    reads    stat   lists \
            entries     glob  store MiB  files  setup MiB  peak+ MiB  held MiB  first MiB
            """
        )
        for (index, scenario) in scenarios.enumerated() {
            try TemporaryCleanup.shared.checkInterrupt()
            do {
                try fixture.validateCounts(at: directory)
            } catch {
                try TemporaryCleanup.shared.checkInterrupt()
                let last = report.results.last?.scenario.id ?? "none (before first scenario)"
                throw BenchmarkError.message(
                    "fixture modified during run: \(error); last scenario: \(last); before scenario: \(scenario.id)")
            }
            let resultURL = temporary.appendingPathComponent("result\(index).json")
            let child = Process()
            guard let executable = Bundle.main.executableURL else {
                throw BenchmarkError.message("cannot find benchmark executable")
            }
            child.executableURL = executable
            child.arguments = [
                "--scenario", scenario.id, "--child-result", resultURL.path,
                "--fixture-dir", directory.path, "--preset", options.preset,
                "--iterations", String(options.iterations), "--warmups", String(options.warmups),
                "--watch-timeout", String(options.watcherTimeout),
            ]
            // Children emit only a JSON file; stderr remains visible for unexpected crashes.
            child.standardOutput = FileHandle.nullDevice
            try child.run()
            TemporaryCleanup.shared.register(child)
            let finished = await wait(child, timeout: options.scenarioTimeout)
            TemporaryCleanup.shared.unregister(child)
            try TemporaryCleanup.shared.checkInterrupt()
            let result: ScenarioResult
            if finished, child.terminationStatus == 0, manager.fileExists(atPath: resultURL.path) {
                do {
                    result = try JSONDecoder().decode(
                        ScenarioResult.self, from: Data(contentsOf: resultURL))
                } catch {
                    result = ScenarioResult(
                        scenario: scenario, samples: [], peakRSSBytes: 0,
                        error: "child result failed to decode: \(error)"
                    )
                }
            } else {
                result = ScenarioResult(
                    scenario: scenario, samples: [], peakRSSBytes: 0,
                    error: finished
                        ? "child exited \(child.terminationStatus)"
                        : "child exceeded \(options.scenarioTimeout)s deadline")
            }
            report.results.append(result)
            printRow(result)
            if let json = options.json {
                try encoder().encode(report).write(to: json, options: .atomic)
            }
        }
        if let baselineURL = options.compare {
            let baseline = try JSONDecoder().decode(Report.self, from: Data(contentsOf: baselineURL))
            compare(report, baseline)
        }
        emit(
            """
            Counts exclude persistence-store I/O and backend-internal glob traversal. Raw samples/all call \
            counts are in JSON. * = counts vary; ! = scenario failed.
            """
        )
        if options.keepFixture || options.fixtureDirectory != nil {
            emit("Fixture preserved: \(directory.path)")
        }
        if let json = options.json { emit("JSON: \(json.path)") }
        if report.results.contains(where: { $0.error != nil }) {
            throw BenchmarkError.message(
                "one or more scenarios failed; successful results were retained")
        }
    }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
    static func wait(_ process: Process, timeout: Double) async -> Bool {
        // Waiting on a subprocess must not block a Swift cooperative executor thread.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                let finished = !process.isRunning
                if !finished {
                    process.terminate()
                    Thread.sleep(forTimeInterval: 0.5)
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                // Do not wait a second time after Foundation reports child exit.
                continuation.resume(returning: finished)
            }
        }
    }
    static func machine() -> [String: String] {
        var name = utsname()
        uname(&name)
        let machineSize = MemoryLayout.size(ofValue: name.machine)
        let architecture = withUnsafePointer(to: &name.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: machineSize) { String(cString: $0) }
        }
        func command(_ executable: String, _ arguments: [String]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return String(decoding: data, as: UTF8.self).trimmingCharacters(
                    in: .whitespacesAndNewlines)
            } catch { return "unavailable" }
        }
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        return [
            "buildConfiguration": configuration,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "architecture": architecture,
            "logicalCPUs": String(ProcessInfo.processInfo.processorCount),
            "physicalMemoryBytes": String(ProcessInfo.processInfo.physicalMemory),
            "swift": command("/usr/bin/env", ["swift", "--version"]),
            "gitCommit": command("/usr/bin/env", ["git", "rev-parse", "HEAD"]),
            "gitBranch": command("/usr/bin/env", ["git", "branch", "--show-current"]),
            "gitStatus": command("/usr/bin/env", ["git", "status", "--short"]),
        ]
    }
    static func printRow(_ result: ScenarioResult) {
        let id = result.scenario.id.padding(toLength: 41, withPad: " ", startingAt: 0)
        guard let median = result.medianMS, let p90 = result.p90MS, let io = result.samples.first?.io
        else {
            emit("\(id) ! \(result.error ?? "no samples")")
            return
        }
        func mib(_ bytes: Int64?) -> String {
            bytes.map { String(format: "%10.2f", Double($0) / 1_048_576) } ?? "         -"
        }
        let sample = result.samples.first
        let setup = result.measuredOperations.map(\.setupPeakRSSBytes).max()
        let increase = result.measuredOperations.map(\.operationPeakIncreaseBytes).max()
        emit(
            id
                + String(
                    format: " %10.3f %9.3f %10.2f %8lld %7lld %7lld %8lld %8lld %10.3f %6lld",
                    median, p90, Double(io.bytesRead) / 1_048_576, io.filesRead,
                    io.calls["stat", default: 0], io.calls["listDirectory", default: 0],
                    io.directoryEntries, io.globMatches,
                    Double(sample?.storeBytesWritten ?? 0) / 1_048_576, sample?.storeFilesWritten ?? 0
                ) + mib(setup) + mib(increase) + mib(result.heldRSSDeltaBytes)
                + mib(result.firstRunHeldRSSDeltaBytes) + (result.deterministicIO ? "" : " *"))
        if let error = result.error { emit("  ! Partial samples: \(error)") }
    }
    static func compare(_ current: Report, _ baseline: Report) {
        emit(
            "\nComparison with \(baseline.fixture.preset) baseline (current/baseline time; exact current−baseline counts):"
        )
        if current.fixture.preset != baseline.fixture.preset
            || current.fixture.version != baseline.fixture.version
        {
            emit("Fixture differs; this comparison measures scaling, not a performance regression.")
        }
        for result in current.results {
            guard
                let previous = baseline.results.first(where: { $0.scenario.id == result.scenario.id }),
                let median = result.medianMS, let oldMedian = previous.medianMS,
                let p90 = result.p90MS, let oldP90 = previous.p90MS,
                let io = result.samples.first?.io, let oldIO = previous.samples.first?.io
            else { continue }
            let calls = Set(io.calls.keys).union(oldIO.calls.keys).sorted().map {
                "\($0)=\(io.calls[$0, default: 0] - oldIO.calls[$0, default: 0])"
            }.joined(separator: " ")
            emit(
                String(
                    format: "%@ median %.2fx p90 %.2fx", result.scenario.id, median / oldMedian,
                    p90 / oldP90)
                    + " bytes=\(io.bytesRead - oldIO.bytesRead) reads=\(io.filesRead - oldIO.filesRead)"
                    + " entries=\(io.directoryEntries - oldIO.directoryEntries)"
                    + " globMatches=\(io.globMatches - oldIO.globMatches) \(calls)"
                    + " storeBytes=\((result.samples.first?.storeBytesWritten ?? 0) - (previous.samples.first?.storeBytesWritten ?? 0))"
                    + " storeFiles=\((result.samples.first?.storeFilesWritten ?? 0) - (previous.samples.first?.storeFilesWritten ?? 0))"
                    + (result.deterministicIO && previous.deterministicIO
                        ? "" : " [counts vary; delta uses first sample]"))
        }
    }
}

#endif

#if !os(macOS) && !os(Linux)
@main
struct WorkspaceBenchmarks {
    static func main() {
        print("WorkspaceBenchmarks requires macOS or Linux.")
    }
}
#endif
