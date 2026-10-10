#if os(macOS) || os(Linux)
import Foundation
import Workspace
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct Fixture: Codable, Sendable {
    static let modificationDate = Date(timeIntervalSince1970: 1_600_000_000)
    static let version = 1
    var version: Int = Self.version
    var preset: String
    var fileCount: Int
    var bytes: Int64
    var symlinkCount: Int
    var directoryCount: Int

    static func count(_ preset: String) throws -> Int {
        switch preset {
        case "small": 1_000
        case "medium": 10_000
        case "large": 100_000
        default: throw BenchmarkError.message("unknown preset: \(preset)")
        }
    }
    static func path(_ i: Int, preset: String) -> String {
        if preset == "large" {
            return
                "node_modules/group\(i / 1000)/package\(i / 100)/node_modules/dependency/src/internal/generated/file\(i).swift"
        }
        return "Sources/module\(i / 100)/feature\(i / 20)/file\(i).\(i % 100 == 99 ? "bin" : "swift")"
    }
    static func data(_ i: Int, preset: String) -> Data {
        let size =
            preset == "large"
            ? (i < 50 ? 4_096 : 1_024) : (i % 100 == 99 ? 819_200 : (i % 100 >= 90 ? 102_400 : 4_096))
        if i % 100 == 99 {
            return Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &+ i) })
        }
        let header = "// deterministic fixture file \(i)\nfunc function\(i)() { }\n"
        let line = "// source padding with ordinary words and identifiers 0123456789\n"
        return Data(
            (header + String(repeating: line, count: size / line.utf8.count + 1)).utf8.prefix(size))
    }
    static func loadOrGenerate(at directory: URL, preset: String) throws -> Fixture {
        let manager = FileManager.default
        let manifest = directory.appendingPathComponent("fixture.json")
        if manager.fileExists(atPath: manifest.path) {
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: manifest))
            guard fixture.version == version, fixture.preset == preset,
                fixture.fileCount == (try count(preset)),
                fixture.symlinkCount == max(5, fixture.fileCount / 200),
                (try manager.attributesOfItem(atPath: directory.appendingPathComponent("tree").path))[
                    .type] as? FileAttributeType == .typeDirectory
            else {
                throw BenchmarkError.message(
                    "fixture version/preset mismatch or missing tree: \(directory.path)")
            }
            // Validate contents and the complete path set on reuse, outside measurement.
            // Never overwrite a user's tree or silently benchmark additional files.
            var expected: Set<String> = ["links"]
            for i in 0..<fixture.fileCount {
                try TemporaryCleanup.shared.checkInterrupt()
                let relative = path(i, preset: preset)
                expected.insert(relative)
                var parent = (relative as NSString).deletingLastPathComponent
                while !parent.isEmpty {
                    expected.insert(parent)
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
            for i in 0..<fixture.symlinkCount { expected.insert("links/link\(i)") }
            // Foundation canonicalizes /private/tmp to /tmp in resolvingSymlinksInPath,
            // while its enumerator returns /private/tmp URLs. POSIX realpath preserves
            // the physical prefix and does not resolve the final symlink of each entry.
            guard let physical = realpath(directory.appendingPathComponent("tree").path, nil) else {
                throw BenchmarkError.message("cannot resolve fixture tree")
            }
            defer { free(physical) }
            let tree = URL(fileURLWithPath: String(cString: physical))
            guard let enumerator = manager.enumerator(at: tree, includingPropertiesForKeys: nil) else {
                throw BenchmarkError.message("cannot enumerate fixture tree")
            }
            let actual = Set(
                enumerator.compactMap { item -> String? in
                    (item as? URL).map { String($0.path.dropFirst(tree.path.count + 1)) }
                })
            guard actual == expected,
                fixture.directoryCount == expected.count - fixture.fileCount - fixture.symlinkCount + 1
            else {
                throw BenchmarkError.message("fixture tree contains missing or unexpected entries")
            }
            var validatedBytes: Int64 = 0
            for i in 0..<fixture.fileCount {
                try TemporaryCleanup.shared.checkInterrupt()
                let url = directory.appendingPathComponent("tree").appendingPathComponent(
                    path(i, preset: preset))
                let expectedData = data(i, preset: preset)
                validatedBytes += Int64(expectedData.count)
                guard
                    (try manager.attributesOfItem(atPath: url.path))[.type] as? FileAttributeType
                        == .typeRegular,
                    try Data(contentsOf: url) == expectedData
                else {
                    throw BenchmarkError.message("fixture content mismatch: \(url.path)")
                }
            }
            for i in 0..<fixture.symlinkCount {
                try TemporaryCleanup.shared.checkInterrupt()
                let url = directory.appendingPathComponent("tree/links/link\(i)")
                guard
                    try manager.destinationOfSymbolicLink(atPath: url.path) == "../"
                        + path(i, preset: preset)
                else {
                    throw BenchmarkError.message("fixture symlink mismatch: \(url.path)")
                }
            }
            guard fixture.bytes == validatedBytes else {
                throw BenchmarkError.message("fixture byte count mismatch")
            }
            return fixture
        }
        if manager.fileExists(atPath: directory.path),
            !(try manager.contentsOfDirectory(atPath: directory.path)).isEmpty
        {
            throw BenchmarkError.message(
                "refusing to generate a fixture in a nonempty directory without fixture.json")
        }
        let tree = directory.appendingPathComponent("tree")
        try manager.createDirectory(at: tree, withIntermediateDirectories: true)
        var directories: Set<String> = ["", "links"]
        let count = try count(preset)
        var bytes: Int64 = 0
        for i in 0..<count {
            try TemporaryCleanup.shared.checkInterrupt()
            let relative = path(i, preset: preset)
            let url = tree.appendingPathComponent(relative)
            let parent = url.deletingLastPathComponent()
            try manager.createDirectory(at: parent, withIntermediateDirectories: true)
            var relativeParent = (relative as NSString).deletingLastPathComponent
            while !relativeParent.isEmpty {
                directories.insert(relativeParent)
                relativeParent = (relativeParent as NSString).deletingLastPathComponent
            }
            let data = data(i, preset: preset)
            try data.write(to: url)
            // Deliberately old mtimes make unchanged files eligible for trustMetadata reuse.
            try manager.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
            bytes += Int64(data.count)
        }
        let links = max(5, count / 200)
        try manager.createDirectory(
            at: tree.appendingPathComponent("links"), withIntermediateDirectories: true)
        for i in 0..<links {
            try TemporaryCleanup.shared.checkInterrupt()
            try manager.createSymbolicLink(
                atPath: tree.appendingPathComponent("links/link\(i)").path,
                withDestinationPath: "../" + path(i, preset: preset))
        }
        let fixture = Fixture(
            preset: preset, fileCount: count, bytes: bytes, symlinkCount: links,
            directoryCount: directories.count)
        try JSONEncoder().encode(fixture).write(to: manifest, options: .atomic)
        return fixture
    }
    static func loadMemory(from tree: URL) async throws -> InMemoryFileSystem {
        let local = try LocalFileSystem(root: tree)
        let memory = InMemoryFileSystem()
        func copy(_ path: WorkspacePath) async throws {
            for entry in try await local.listDirectory(path: path) {
                try TemporaryCleanup.shared.checkInterrupt()
                let path = entry.info.path
                switch entry.info.kind {
                case .directory:
                    try await memory.createDirectory(path: path, recursive: true)
                    try await copy(path)
                case .file:
                    try await memory.writeFile(path: path, data: local.readFile(path: path), append: false)
                case .symlink:
                    try await memory.createSymlink(path: path, target: local.readSymlink(path: path))
                }
            }
        }
        try await copy(.root)
        return memory
    }
}

#endif
