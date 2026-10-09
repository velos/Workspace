import Foundation

/// Adapter envelopes retain the original ChangeSet/EditResult keys. Statistics
/// cover the whole selected operation; the nested ChangeSet describes this page.
struct ToolChangesOutput: Encodable {
    var changes = ChangeSet()
    var statistics: ChangeSet.Statistics
    var totalChanges: Int
    var changeOffset: Int
    var nextChangeOffset: Int?
    var omittedFiles: Int
    var omittedTextDiffs = 0
    var truncated = false
    var unifiedPatch: String?
    // Apply runs atomically: failures throw before this success envelope is built,
    // so successful apply responses always carry []; diff omits this field.
    var failures: [EditFailure]?
}

/// This boundary cannot throw after an atomic apply has committed. Even an
/// unexpected encoder error or accounting failure returns a successful, truncated
/// envelope, so a caller never mistakes omitted detail for a failed operation.
func boundedApplyOutput(
    _ source: ChangeSet, maxBytes: Int, maxFileBytes: Int, encoder: JSONEncoder
) -> Data {
    do {
        return try boundedChangesOutput(source, offset: 0, maxBytes: maxBytes, maxFileBytes: maxFileBytes,
                                        patch: false, applying: true, encoder: encoder)
    } catch {
        return minimalApplyOutput(source)
    }
}

private func minimalApplyOutput(_ source: ChangeSet) -> Data {
    let statistics = source.statistics
    // Integer interpolation needs no escaping and cannot fail. Even Int.max in
    // every field keeps this fixed shape below the 1,024-byte minimum budget.
    return Data("""
    {"changes":{"changes":[],"textDiffOmissions":[]},"failures":[],"statistics":{"changedPathCount":\(statistics.changedPathCount),"changedFileCount":\(statistics.changedFileCount),"additions":\(statistics.additions),"deletions":\(statistics.deletions)},"totalChanges":\(source.changes.count),"changeOffset":0,"omittedFiles":\(source.changes.count),"omittedTextDiffs":0,"truncated":true}
    """.utf8)
}

func boundedChangesOutput(
    _ source: ChangeSet, offset: Int, maxBytes: Int, maxFileBytes: Int,
    patch: Bool, applying: Bool, encoder: JSONEncoder
) throws -> Data {
    let start = min(offset, source.changes.count)
    var output = ToolChangesOutput(statistics: source.statistics, totalChanges: source.changes.count,
                                   changeOffset: offset, omittedFiles: source.changes.count - start,
                                   unifiedPatch: patch ? "" : nil, failures: applying ? [] : nil)
    let largestEnvelope = ToolChangesOutput(
        statistics: .init(changedPathCount: Int.max, changedFileCount: Int.max, additions: Int.max, deletions: Int.max),
        totalChanges: Int.max, changeOffset: Int.max, nextChangeOffset: applying ? nil : Int.max,
        omittedFiles: Int.max, omittedTextDiffs: Int.max, truncated: false,
        unifiedPatch: patch ? "" : nil, failures: applying ? [] : nil)
    var remaining = maxBytes - (try encoder.encode(largestEnvelope).count)
    let omissions = Dictionary(grouping: source.textDiffOmissions, by: \.path)
    var patchSections: [String] = []
    var cursor = start
    for original in source.changes[start...] {
        var change = original
        change.diff = nil
        // Encode metadata and diff once each. Adding the optional diff property
        // costs its JSON key plus its value; no growing prefix is re-encoded.
        let metadataCost = try encoder.encode(change).count + 1 // Array separator.
        var diffCost = 0
        var section: String?
        var sectionCost = 0
        if let diff = original.diff {
            diffCost = try encoder.encode(diff).count
            if patch {
                section = ChangeSet(changes: [original]).unifiedPatch()
                // The envelope owns the outer JSON quotes; separators between
                // patch sections are encoded as two bytes (backslash and n).
                sectionCost = try encoder.encode(section!).count - 2 + (patchSections.isEmpty ? 0 : 2)
            }
        }
        var fileOmissions = omissions[change.path] ?? []
        var omissionCost = 0
        for omission in fileOmissions {
            omissionCost += try encoder.encode(omission).count + 1
        }
        let textCost = diffCost + sectionCost
        let diffPropertyCost = original.diff == nil ? 0 : ",\"diff\":".utf8.count + diffCost
        var cost = metadataCost + omissionCost + diffPropertyCost + sectionCost
        var omittedText = false
        if original.diff != nil, textCost > maxFileBytes || cost > remaining {
            omittedText = true
            fileOmissions.append(.init(path: change.path, reason: .outputBudgetExceeded))
            omissionCost += try encoder.encode(fileOmissions.last!).count + 1
            section = nil
            cost = metadataCost + omissionCost
        } else {
            change.diff = original.diff
        }
        guard cost <= remaining else {
            if !output.changes.changes.isEmpty { break }
            // Oversized path metadata is counted as omitted, but consumes its
            // offset so paging cannot get stuck on a single unreturnable entry.
            cursor += 1
            continue
        }
        remaining -= cost
        cursor += 1
        output.changes.changes.append(change)
        output.changes.textDiffOmissions += fileOmissions
        output.omittedTextDiffs += omittedText ? 1 : 0
        if let section { patchSections.append(section) }
    }
    output.omittedFiles = source.changes.count - start - output.changes.changes.count
    output.nextChangeOffset = !applying && cursor < source.changes.count ? cursor : nil
    output.truncated = output.omittedFiles > 0 || output.omittedTextDiffs > 0 ||
        output.changes.textDiffOmissions.contains { $0.reason != .binary }
    if patch { output.unifiedPatch = patchSections.joined(separator: "\n") }
    let data = try encoder.encode(output)
    guard data.count <= maxBytes else {
        throw WorkspaceToolError.invalidArguments("max_bytes cannot fit result metadata")
    }
    return data
}

struct ToolGlobOutput: Encodable {
    var matches: [WorkspacePath] = []
    var totalMatches: Int
    var matchOffset: Int
    var nextMatchOffset: Int?
    var omittedMatches = 0
    var truncated = false
}

func boundedGlobOutput(
    _ matches: [WorkspacePath], offset: Int, maxMatches: Int, maxBytes: Int, encoder: JSONEncoder
) throws -> Data {
    var cursor = min(offset, matches.count)
    var output = ToolGlobOutput(totalMatches: matches.count, matchOffset: offset)
    let largestEnvelope = ToolGlobOutput(totalMatches: Int.max, matchOffset: Int.max,
                                        nextMatchOffset: Int.max, omittedMatches: Int.max, truncated: false)
    var remaining = maxBytes - (try encoder.encode(largestEnvelope).count)
    while cursor < matches.count, output.matches.count < maxMatches {
        let cost = try encoder.encode(matches[cursor]).count + 1
        if cost > remaining {
            if !output.matches.isEmpty { break }
            output.omittedMatches += 1
        } else {
            remaining -= cost
            output.matches.append(matches[cursor])
        }
        cursor += 1
    }
    output.nextMatchOffset = cursor < matches.count ? cursor : nil
    output.truncated = cursor < matches.count || output.omittedMatches > 0
    let data = try encoder.encode(output)
    guard data.count <= maxBytes else {
        throw WorkspaceToolError.invalidArguments("max_bytes cannot fit result metadata")
    }
    return data
}
