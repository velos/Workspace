import Foundation

extension TextDiff {
    /// Renders this text diff as a unified patch suitable for logs, prompts, and patch interop.
    public func unifiedPatch(oldPath: String, newPath: String) -> String {
        var output = "--- \(oldPath)\n+++ \(newPath)\n"
        for hunk in hunks {
            output += "@@ -\(rangeDescription(start: hunk.oldStartLine, count: hunk.oldLineCount))"
            output += " +\(rangeDescription(start: hunk.newStartLine, count: hunk.newLineCount)) @@\n"
            for line in hunk.lines {
                output.append(line.kind.patchPrefix)
                output += line.text
                output.append("\n")
                if !line.hasTrailingNewline {
                    output += "\\ No newline at end of file\n"
                }
            }
        }
        return output
    }

    private func rangeDescription(start: Int, count: Int) -> String {
        let normalizedStart = count == 0 ? max(0, start - 1) : start
        return count == 1 ? "\(normalizedStart)" : "\(normalizedStart),\(count)"
    }
}

extension ChangeSet {
    /// Renders every available textual file change as a git-style unified patch.
    ///
    /// Binary files, size-limited files, and metadata-only changes remain represented by
    /// ``changes`` and ``textDiffOmissions`` but do not produce patch sections.
    public func unifiedPatch() -> String {
        changes.compactMap { change in
            guard let diff = change.diff else { return nil }
            let oldPath: String
            let newPath: String
            switch change.effect {
            case .created:
                oldPath = "/dev/null"
                newPath = patchPath(change.path, prefix: "b")
            case .deleted:
                oldPath = patchPath(change.path, prefix: "a")
                newPath = "/dev/null"
            case .modified:
                oldPath = patchPath(change.path, prefix: "a")
                newPath = patchPath(change.path, prefix: "b")
            case .moved, .copied:
                oldPath = patchPath(change.sourcePath ?? change.path, prefix: "a")
                newPath = patchPath(change.path, prefix: "b")
            }
            return diff.unifiedPatch(oldPath: oldPath, newPath: newPath)
        }.joined(separator: "\n")
    }

    private func patchPath(_ path: WorkspacePath, prefix: String) -> String {
        let value = path.string == "/" ? "" : String(path.string.drop(while: { $0 == "/" }))
        return value.isEmpty ? prefix : "\(prefix)/\(value)"
    }
}

private extension TextDiff.Line.Kind {
    var patchPrefix: Character {
        switch self {
        case .context: " "
        case .added: "+"
        case .removed: "-"
        }
    }
}
