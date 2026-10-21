import Foundation

/// Index bytes once; materialize only the lines that reach the output page.
struct SearchText {
    let text: String
    private let data: Data
    private let starts: [Int]
    private let ascii: Bool
    var lineCount: Int { starts.count }

    init?(data: Data) {
        guard !data.withUnsafeBytes({ bytes in
            bytes.count > 0 && memchr(bytes.baseAddress!, 0, bytes.count) != nil
        }), let text = String(data: data, encoding: .utf8) else { return nil }
        // Foundation can strip the leading UTF-8 BOM during decoding. Index the
        // decoded bytes so matching, line text and output byte counts agree.
        let data = data.starts(with: [0xef, 0xbb, 0xbf]) && text.utf8.count == data.count - 3
            ? Data(data.dropFirst(3)) : data
        self.data = data
        self.text = text
        var starts = [0]
        var ascii = true
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for index in bytes.indices {
                let byte = bytes[index]
                if byte == 10 { starts.append(index + 1) }
                if byte >= 128 { ascii = false }
            }
        }
        self.starts = starts
        self.ascii = ascii
    }

    private func end(_ index: Int) -> Int {
        index + 1 < starts.count ? starts[index + 1] - 1 : data.count
    }
    func line(_ index: Int) -> String {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            String(decoding: bytes[starts[index]..<end(index)], as: UTF8.self)
        }
    }
    func byteCount(_ range: Range<Int>) -> UInt64 {
        UInt64(end(range.upperBound - 1) - starts[range.lowerBound] - (range.count - 1))
    }

    func matchingLines(_ matcher: SearchMatcher) -> [Int] {
        switch matcher.pattern {
        case let .literal(value, caseSensitive):
            // Foundation literal matching includes canonical Unicode equivalence. Byte
            // matching is equivalent on ASCII; retain Foundation for Unicode text/patterns.
            guard ascii, matcher.asciiNeedle else {
                return starts.indices.filter {
                    line($0).range(of: value, options: caseSensitive ? [] : [.caseInsensitive]) != nil
                }
            }
            guard !matcher.needle.contains(10) else { return [] }
            return literalLines(matcher.needle, caseSensitive: caseSensitive)
        case .regularExpression:
            guard let regex = matcher.regex else { return [] }
            let offsets: [Int]
            if ascii { offsets = starts }
            else {
                var result = [0]
                for (offset, value) in text.utf16.enumerated() where value == 10 { result.append(offset + 1) }
                offsets = result
            }
            if matcher.lineLocalRegex {
                var result: [Int] = []
                var line = 0
                var start = 0
                let length = text.utf16.count
                while let hit = regex.firstMatch(in: text, range: NSRange(location: start, length: length - start)) {
                    while line + 1 < offsets.count, offsets[line + 1] <= hit.range.location { line += 1 }
                    result.append(line)
                    // Only one hit per line is observable. Jump over its remaining
                    // positions, especially for expressions that match empty strings.
                    guard line + 1 < offsets.count else { break }
                    line += 1
                    start = offsets[line]
                }
                return result
            }
            // Anchors, lookarounds, flags and expressions that can consume LF need the
            // original independent-line bounds. Reuse the whole String without allocating
            // a String per line; opaque matching bounds preserve that contract.
            let length = text.utf16.count
            return offsets.indices.filter { index in
                let end = index + 1 < offsets.count ? offsets[index + 1] - 1 : length
                return regex.firstMatch(in: text, range: NSRange(location: offsets[index], length: end - offsets[index])) != nil
            }
        }
    }

    private func literalLines(_ needle: [UInt8], caseSensitive: Bool) -> [Int] {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            needle.withUnsafeBytes { target in
                guard bytes.count >= target.count, !target.isEmpty else { return [] }
                var result: [Int] = []
                var offset = 0
                var line = 0
                let last = bytes.count - target.count
                while offset <= last {
                    if caseSensitive {
                        guard let found = memchr(bytes.baseAddress!.advanced(by: offset), Int32(needle[0]), last - offset + 1) else { break }
                        offset = bytes.baseAddress!.distance(to: found)
                    } else if SearchMatcher.fold(bytes[offset]) != needle[0] {
                        offset += 1
                        continue
                    }
                    let matched: Bool
                    if caseSensitive {
                        matched = memcmp(bytes.baseAddress!.advanced(by: offset), target.baseAddress!, target.count) == 0
                    } else {
                        matched = needle.indices.allSatisfy { SearchMatcher.fold(bytes[offset + $0]) == needle[$0] }
                    }
                    if matched {
                        while line + 1 < starts.count, starts[line + 1] <= offset { line += 1 }
                        result.append(line)
                        // Search reports one match per line, including overlapping occurrences.
                        offset = end(line) + 1
                    } else { offset += 1 }
                }
                return result
            }
        }
    }
}

struct SearchMatcher {
    let pattern: TextPattern
    let needle: [UInt8]
    let asciiNeedle: Bool
    let regex: NSRegularExpression?
    let lineLocalRegex: Bool

    init(_ pattern: TextPattern) throws {
        self.pattern = pattern
        switch pattern {
        case let .literal(value, caseSensitive):
            needle = caseSensitive ? Array(value.utf8) : value.utf8.map(Self.fold)
            asciiNeedle = needle.allSatisfy { $0 < 128 }
            regex = nil
            lineLocalRegex = false
        case let .regularExpression(value):
            needle = []
            asciiNeedle = false
            regex = try NSRegularExpression(pattern: value)
            lineLocalRegex = Self.isLineLocal(value)
        }
    }

    static func fold(_ byte: UInt8) -> UInt8 { (65...90).contains(byte) ? byte + 32 : byte }

    /// Conservatively certify expressions whose matches cannot cross LF or inspect
    /// beyond a line. Everything else uses bounded, per-line regex matching above.
    private static func isLineLocal(_ pattern: String) -> Bool {
        let bytes = Array(pattern.utf8)
        var index = 0
        var inClass = false
        while index < bytes.count {
            let byte = bytes[index]
            guard byte >= 32, byte < 127, byte != 94, byte != 36 else { return false }
            if byte == 40, index + 1 < bytes.count, bytes[index + 1] == 63 { return false }
            if byte == 91 {
                // ICU POSIX classes (e.g. [[:space:]]) may include LF.
                if index + 1 < bytes.count, [UInt8(58), 46, 61].contains(bytes[index + 1]) { return false }
                inClass = true
            }
            if byte == 93 { inClass = false }
            if byte == 92 {
                index += 1
                guard index < bytes.count else { return false }
                // Positive ASCII/Unicode word and digit classes cannot consume LF.
                let escaped = bytes[index]
                guard escaped == 100 || escaped == 119 || (escaped == 116 && !inClass)
                    || Array("\\.*+?()[]{}|-/$^".utf8).contains(escaped) else { return false }
            }
            index += 1
        }
        return true
    }
}
