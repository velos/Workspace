#if os(macOS) || os(Linux)
import Foundation

enum Backend: String, CaseIterable, Codable, Sendable {
    case local, memory
}

enum Persistence: String, CaseIterable, Codable, Sendable {
    case memory, directory
}

enum Operation: String, CaseIterable, Codable, Sendable {
    case writeText, apply50, preview, transaction, transactionFirst
    case checkpointFirst, checkpointIncremental, diff, restore
    case readCheckpoint, readCheckpointWarm, readCurrent, search, glob
    case history1000, history1000Cached, write1001, limitedWrite, eventsInitial, eventsExternal

    var localOnly: Bool {
        switch self {
        case .history1000, .write1001, .limitedWrite, .eventsInitial, .eventsExternal: true
        case .writeText, .apply50, .preview, .transaction, .transactionFirst,
            .checkpointFirst, .checkpointIncremental, .diff, .restore,
            .readCheckpoint, .readCheckpointWarm, .readCurrent, .search, .glob, .history1000Cached:
            false
        }
    }

    var persistences: [Persistence] {
        switch self {
        case .writeText, .apply50, .transaction, .transactionFirst, .checkpointFirst,
            .checkpointIncremental, .diff, .restore, .readCheckpoint, .readCheckpointWarm:
            [.memory, .directory]
        case .history1000, .write1001: [.directory]
        case .preview, .readCurrent, .search, .glob, .history1000Cached,
            .limitedWrite, .eventsInitial, .eventsExternal:
            [.memory]
        }
    }

    var needsBaselineCheckpoint: Bool {
        switch self {
        case .transaction, .checkpointIncremental, .diff, .restore, .readCheckpoint,
            .readCheckpointWarm:
            true
        case .writeText, .apply50, .preview, .transactionFirst, .checkpointFirst,
            .readCurrent, .search, .glob, .history1000, .history1000Cached,
            .write1001, .limitedWrite, .eventsInitial, .eventsExternal:
            false
        }
    }

    var needsChangedFile: Bool {
        switch self {
        case .checkpointIncremental, .diff, .restore: true
        case .writeText, .apply50, .preview, .transaction, .transactionFirst, .checkpointFirst,
            .readCheckpoint, .readCheckpointWarm, .readCurrent, .search, .glob,
            .history1000, .history1000Cached, .write1001, .limitedWrite, .eventsInitial,
            .eventsExternal:
            false
        }
    }

    var needsHistory: Bool {
        switch self {
        case .history1000, .history1000Cached, .write1001: true
        case .writeText, .apply50, .preview, .transaction, .transactionFirst, .checkpointFirst,
            .checkpointIncremental, .diff, .restore, .readCheckpoint, .readCheckpointWarm,
            .readCurrent, .search, .glob, .limitedWrite, .eventsInitial, .eventsExternal:
            false
        }
    }

    var observes: Bool {
        switch self {
        case .eventsInitial, .eventsExternal: true
        case .writeText, .apply50, .preview, .transaction, .transactionFirst, .checkpointFirst,
            .checkpointIncremental, .diff, .restore, .readCheckpoint, .readCheckpointWarm,
            .readCurrent, .search, .glob, .history1000, .history1000Cached, .write1001, .limitedWrite:
            false
        }
    }

    var resetFileCount: Int { self == .apply50 ? 50 : 1 }

    // Read-only repetitions share the primed Workspace. Mutations get independent
    // prepared Workspace/store instances, so each write1001 really is the 1,001st.
    var repetitions: Int {
        switch self {
        case .readCurrent, .history1000Cached: 100
        case .readCheckpointWarm: 20
        case .writeText: 20
        case .write1001: 5
        case .apply50, .preview, .transaction, .transactionFirst, .checkpointFirst,
            .checkpointIncremental, .diff, .restore, .readCheckpoint, .search,
            .glob, .history1000, .limitedWrite, .eventsInitial, .eventsExternal:
            1
        }
    }

    var independentRepetitions: Bool { self == .writeText || self == .write1001 }
}

#endif
