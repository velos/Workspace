import Foundation

extension ChangeSet {
    typealias RevisionLoader = @Sendable (WorkspacePath) async throws -> Data

    static func compare(
        before: RevisionIndex,
        after: RevisionIndex,
        maxTextBytes: Int?,
        loadBefore: @escaping RevisionLoader,
        loadAfter: @escaping RevisionLoader
    ) async throws -> ChangeSet {
        let result = try await compareIndexEntries(
            before.entry,
            after.entry,
            maxTextBytes: maxTextBytes,
            loadBefore: loadBefore,
            loadAfter: loadAfter
        )
        return ChangeSet(changes: result.changes, textDiffOmissions: result.omissions)
    }

    private static func compareIndexEntries(
        _ old: RevisionIndex.Entry,
        _ new: RevisionIndex.Entry,
        maxTextBytes: Int?,
        loadBefore: @escaping RevisionLoader,
        loadAfter: @escaping RevisionLoader
    ) async throws -> (changes: [FileChange], omissions: [TextDiffOmission]) {
        switch (old, new) {
        case (.missing, .missing):
            return ([], [])
        case (.missing, _):
            return try await collectIndex(
                new,
                effect: .created,
                maxTextBytes: maxTextBytes,
                loader: loadAfter
            )
        case (_, .missing):
            return try await collectIndex(
                old,
                effect: .deleted,
                maxTextBytes: maxTextBytes,
                loader: loadBefore
            )
        case let (.file(oldPath, oldSize, oldPermissions, oldID),
                  .file(newPath, newSize, newPermissions, newID)):
            guard oldID != newID || oldPermissions != newPermissions else { return ([], []) }
            guard oldID != newID else {
                return ([.init(path: newPath, kind: .file, effect: .modified)], [])
            }
            let result = try await indexedTextDiff(
                oldPath: oldPath,
                newPath: newPath,
                oldSize: oldSize,
                newSize: newSize,
                maxTextBytes: maxTextBytes,
                loadBefore: loadBefore,
                loadAfter: loadAfter
            )
            return ([.init(path: newPath, kind: .file, effect: .modified, diff: result.diff)], result.omission.map { [$0] } ?? [])
        case let (.symbolicLink(_, oldTarget, oldPermissions),
                  .symbolicLink(newPath, newTarget, newPermissions)):
            guard oldTarget != newTarget || oldPermissions != newPermissions else { return ([], []) }
            return ([.init(path: newPath, kind: .symlink, effect: .modified)], [])
        case let (.directory(oldPath, oldPermissions, oldChildren),
                  .directory(newPath, newPermissions, newChildren)):
            var changes: [FileChange] = []
            var omissions: [TextDiffOmission] = []
            if oldPermissions != newPermissions {
                changes.append(.init(path: newPath, kind: .directory, effect: .modified))
            }
            let oldByName = Dictionary(uniqueKeysWithValues: oldChildren.map { ($0.path.name, $0) })
            let newByName = Dictionary(uniqueKeysWithValues: newChildren.map { ($0.path.name, $0) })
            for name in Set(oldByName.keys).union(newByName.keys).sorted() {
                let result = try await compareIndexEntries(
                    oldByName[name] ?? .missing(path: oldPath.appending(name)),
                    newByName[name] ?? .missing(path: newPath.appending(name)),
                    maxTextBytes: maxTextBytes,
                    loadBefore: loadBefore,
                    loadAfter: loadAfter
                )
                changes += result.changes
                omissions += result.omissions
            }
            return (changes, omissions)
        default:
            let deleted = try await collectIndex(old, effect: .deleted, maxTextBytes: maxTextBytes, loader: loadBefore)
            let created = try await collectIndex(new, effect: .created, maxTextBytes: maxTextBytes, loader: loadAfter)
            return (deleted.changes + created.changes, deleted.omissions + created.omissions)
        }
    }

    private static func collectIndex(
        _ entry: RevisionIndex.Entry,
        effect: FileChange.Effect,
        maxTextBytes: Int?,
        loader: @escaping RevisionLoader
    ) async throws -> (changes: [FileChange], omissions: [TextDiffOmission]) {
        switch entry {
        case .missing:
            return ([], [])
        case let .file(path, size, _, _):
            if let maxTextBytes, size > UInt64(maxTextBytes) {
                return (
                    [.init(path: path, kind: .file, effect: effect)],
                    [.init(path: path, reason: .sizeLimitExceeded)]
                )
            }
            let data = try await loader(path)
            let old = effect == .created ? Data() : data
            let new = effect == .created ? data : Data()
            guard !old.contains(0), !new.contains(0),
                  let oldText = String(data: old, encoding: .utf8),
                  let newText = String(data: new, encoding: .utf8)
            else {
                return ([.init(path: path, kind: .file, effect: effect)], [.init(path: path, reason: .binary)])
            }
            let diff = TextDiff.lineBased(from: oldText, to: newText)
            return ([.init(path: path, kind: .file, effect: effect, diff: diff.hunks.isEmpty ? nil : diff)], [])
        case let .symbolicLink(path, _, _):
            return ([.init(path: path, kind: .symlink, effect: effect)], [])
        case let .directory(path, _, children):
            var changes = [FileChange(path: path, kind: .directory, effect: effect)]
            var omissions: [TextDiffOmission] = []
            for child in children {
                let result = try await collectIndex(child, effect: effect, maxTextBytes: maxTextBytes, loader: loader)
                changes += result.changes
                omissions += result.omissions
            }
            return (changes, omissions)
        }
    }

    private static func indexedTextDiff(
        oldPath: WorkspacePath,
        newPath: WorkspacePath,
        oldSize: UInt64,
        newSize: UInt64,
        maxTextBytes: Int?,
        loadBefore: @escaping RevisionLoader,
        loadAfter: @escaping RevisionLoader
    ) async throws -> (diff: TextDiff?, omission: TextDiffOmission?) {
        if let maxTextBytes, oldSize > UInt64(maxTextBytes) || newSize > UInt64(maxTextBytes) {
            return (nil, .init(path: newPath, reason: .sizeLimitExceeded))
        }
        async let old = loadBefore(oldPath)
        async let new = loadAfter(newPath)
        let (oldData, newData) = try await (old, new)
        guard !oldData.contains(0), !newData.contains(0),
              let oldText = String(data: oldData, encoding: .utf8),
              let newText = String(data: newData, encoding: .utf8)
        else {
            return (nil, .init(path: newPath, reason: .binary))
        }
        let diff = TextDiff.lineBased(from: oldText, to: newText)
        return (diff.hunks.isEmpty ? nil : diff, nil)
    }
}
