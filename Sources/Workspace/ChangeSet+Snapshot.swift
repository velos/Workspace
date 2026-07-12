import Foundation

extension ChangeSet {
    static func compare(before: Snapshot, after: Snapshot, maxTextBytes: Int?) -> ChangeSet {
        var changes: [FileChange] = []
        var omissions: [TextDiffOmission] = []
        compareEntries(
            before.entry,
            after.entry,
            maxTextBytes: maxTextBytes,
            changes: &changes,
            omissions: &omissions
        )
        return ChangeSet(changes: changes, textDiffOmissions: omissions)
    }

    private static func compareEntries(
        _ old: Snapshot.Entry,
        _ new: Snapshot.Entry,
        maxTextBytes: Int?,
        changes: inout [FileChange],
        omissions: inout [TextDiffOmission]
    ) {
        switch (old, new) {
        case (.missing, .missing):
            return
        case (.missing, _):
            collect(new, effect: .created, maxTextBytes: maxTextBytes, changes: &changes, omissions: &omissions)
        case (_, .missing):
            collect(old, effect: .deleted, maxTextBytes: maxTextBytes, changes: &changes, omissions: &omissions)
        case let (.file(lhs), .file(rhs)):
            guard lhs.data != rhs.data || lhs.permissions != rhs.permissions else { return }
            let diffResult = textDiff(old: lhs.data, new: rhs.data, path: rhs.path, maxBytes: maxTextBytes)
            changes.append(.init(path: rhs.path, kind: .file, effect: .modified, diff: diffResult.diff))
            if let omission = diffResult.omission { omissions.append(omission) }
        case let (.symlink(lhs), .symlink(rhs)):
            guard lhs.target != rhs.target || lhs.permissions != rhs.permissions else { return }
            changes.append(.init(path: rhs.path, kind: .symlink, effect: .modified))
        case let (.directory(lhs), .directory(rhs)):
            if lhs.permissions != rhs.permissions {
                changes.append(.init(path: rhs.path, kind: .directory, effect: .modified))
            }
            let oldChildren = Dictionary(uniqueKeysWithValues: lhs.children.map { ($0.path.name, $0) })
            let newChildren = Dictionary(uniqueKeysWithValues: rhs.children.map { ($0.path.name, $0) })
            for name in Set(oldChildren.keys).union(newChildren.keys).sorted() {
                compareEntries(
                    oldChildren[name] ?? .missing(.init(path: lhs.path.appending(name))),
                    newChildren[name] ?? .missing(.init(path: rhs.path.appending(name))),
                    maxTextBytes: maxTextBytes,
                    changes: &changes,
                    omissions: &omissions
                )
            }
        default:
            collect(old, effect: .deleted, maxTextBytes: maxTextBytes, changes: &changes, omissions: &omissions)
            collect(new, effect: .created, maxTextBytes: maxTextBytes, changes: &changes, omissions: &omissions)
        }
    }

    private static func collect(
        _ entry: Snapshot.Entry,
        effect: FileChange.Effect,
        maxTextBytes: Int?,
        changes: inout [FileChange],
        omissions: inout [TextDiffOmission]
    ) {
        switch entry {
        case .missing:
            return
        case let .file(file):
            let dataPair = effect == .created ? (Data(), file.data) : (file.data, Data())
            let result = textDiff(old: dataPair.0, new: dataPair.1, path: file.path, maxBytes: maxTextBytes)
            changes.append(.init(path: file.path, kind: .file, effect: effect, diff: result.diff))
            if let omission = result.omission { omissions.append(omission) }
        case let .symlink(link):
            changes.append(.init(path: link.path, kind: .symlink, effect: effect))
        case let .directory(directory):
            changes.append(.init(path: directory.path, kind: .directory, effect: effect))
            for child in directory.children {
                collect(child, effect: effect, maxTextBytes: maxTextBytes, changes: &changes, omissions: &omissions)
            }
        }
    }

    private static func textDiff(
        old: Data,
        new: Data,
        path: WorkspacePath,
        maxBytes: Int?
    ) -> (diff: TextDiff?, omission: TextDiffOmission?) {
        if let maxBytes, old.count > maxBytes || new.count > maxBytes {
            return (nil, .init(path: path, reason: .sizeLimitExceeded))
        }
        guard !old.contains(0), !new.contains(0),
              let oldText = String(data: old, encoding: .utf8),
              let newText = String(data: new, encoding: .utf8)
        else {
            return (nil, .init(path: path, reason: .binary))
        }
        let diff = TextDiff.lineBased(from: oldText, to: newText)
        return (diff.hunks.isEmpty ? nil : diff, nil)
    }
}
