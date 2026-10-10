#if os(macOS) || os(Linux)
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct Sample: Codable, Sendable {
    var milliseconds: Double
    var io: IOCounts
    var repetitions: Int = 1
    var heldRSSDeltaBytes: Int64?
    var rssBeforeBytes: Int64?
    var rssHeldBytes: Int64?
    var setupPeakRSSBytes: Int64
    var operationPeakRSSBytes: Int64
    var operationPeakIncreaseBytes: Int64
    var storeBytesWritten: Int64 = 0
    var storeFilesWritten: Int64 = 0
    var innerSamples: [Sample] = []
}

struct Scenario: Codable, Sendable {
    var operation: Operation
    var backend: Backend
    var persistence: Persistence
    var id: String { "\(backend.rawValue)/\(persistence.rawValue)/\(operation.rawValue)" }

    static func all(preset: String) -> [Scenario] {
        Backend.allCases.flatMap { backend in
            Operation.allCases.flatMap { operation -> [Scenario] in
                guard !(preset == "large" && backend == .memory),
                    !(operation.localOnly && backend == .memory)
                else { return [] }
                return operation.persistences.compactMap { persistence in
                    guard !(backend == .memory && persistence == .directory) else { return nil }
                    return Scenario(operation: operation, backend: backend, persistence: persistence)
                }
            }
        }
    }
}
struct ScenarioResult: Codable {
    var scenario: Scenario
    var samples: [Sample]
    var warmupSamples: [Sample] = []
    var peakRSSBytes: Int64
    var error: String?
    var medianMS: Double? { percentile(0.5) }
    var p90MS: Double? { percentile(0.9) }
    // Linear interpolation between ranked samples; retain all raw measurements.
    func percentile(_ fraction: Double) -> Double? {
        let sorted = samples.map(\.milliseconds).sorted()
        guard !sorted.isEmpty else { return nil }
        let rank = Double(sorted.count - 1) * fraction
        let lower = Int(floor(rank))
        let upper = Int(ceil(rank))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - Double(lower))
    }
    var measuredOperations: [Sample] {
        samples.flatMap { $0.innerSamples.isEmpty ? [$0] : $0.innerSamples }
    }
    var heldRSSDeltaBytes: Int64? { measuredOperations.compactMap(\.heldRSSDeltaBytes).max() }
    var firstRunHeldRSSDeltaBytes: Int64? {
        (warmupSamples.first ?? samples.first)?.heldRSSDeltaBytes
    }
    var deterministicIO: Bool { samples.dropFirst().allSatisfy { $0.io == samples.first?.io } }
}
struct Report: Codable {
    var schemaVersion = 2
    var createdAt: Date
    var machine: [String: String]
    var fixture: Fixture
    var iterations: Int
    var warmups: Int
    var results: [ScenarioResult]
    var measurementNotes: [String]
}

enum BenchmarkError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let message): message
        }
    }
}

func peakRSS() -> Int64 {
    var usage = rusage()
    #if canImport(Darwin)
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss)
    #else
    getrusage(Int32(RUSAGE_SELF.rawValue), &usage)
    return Int64(usage.ru_maxrss) * 1024
    #endif
}
func currentRSS() -> Int64? {
    #if canImport(Darwin)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? Int64(info.resident_size) : nil
    #else
    guard let contents = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8),
        let pages = contents.split(separator: " ").dropFirst().first.flatMap({ Int64($0) })
    else { return nil }
    return pages * Int64(sysconf(Int32(_SC_PAGESIZE)))
    #endif
}
func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let components = start.duration(to: ContinuousClock.now).components
    return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
}
func emit(_ message: String) { FileHandle.standardOutput.write(Data((message + "\n").utf8)) }

#endif
