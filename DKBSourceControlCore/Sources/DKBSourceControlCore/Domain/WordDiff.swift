import Foundation

/// Which words changed between a removed line and the added line that
/// replaced it, to highlight inside the lines (plan F3). Words are runs of
/// letters, digits and "_"; a run of spaces and every other character are
/// tokens of their own. Longest common subsequence over tokens.
public enum WordDiff {
    /// Character offsets of the changed parts of each line; nil when the
    /// lines share no word (all of it changed, a highlight would add
    /// nothing) or are too long to compare quickly.
    public static func changes(old: String, new: String) -> (old: [Range<Int>], new: [Range<Int>])? {
        let a = tokens(old)
        let b = tokens(new)
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= maxCells else { return nil }
        // lengths[i][j]: LCS of a[i...] and b[j...].
        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i].text == b[j].text ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var commonA = Set<Int>()
        var commonB = Set<Int>()
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i].text == b[j].text {
                commonA.insert(i)
                commonB.insert(j)
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        guard commonA.contains(where: { a[$0].isWord }) else { return nil }
        return (ranges(a, keeping: commonA), ranges(b, keeping: commonB))
    }

    /// A run of removed lines followed by a run of added lines pairs up
    /// line by line, as GitHub does. Indexes into `hunk.lines`, both ways.
    public static func pairs(in hunk: DiffHunk) -> [Int: Int] {
        var pairs: [Int: Int] = [:]
        var removed: [Int] = []
        var added: [Int] = []
        func flush() {
            for (old, new) in zip(removed, added) {
                pairs[old] = new
                pairs[new] = old
            }
            removed = []
            added = []
        }
        for (index, line) in hunk.lines.enumerated() {
            switch line.kind {
            case .removed:
                if !added.isEmpty { flush() }
                removed.append(index)
            case .added:
                added.append(index)
            case .context:
                flush()
            case .noNewlineMarker:
                continue
            }
        }
        flush()
        return pairs
    }

    /// 200 × 200 tokens: a few milliseconds, once per row on screen.
    static let maxCells = 40_000

    struct Token {
        let text: Substring
        let offset: Int
        let length: Int
        var isWord: Bool { text.first.map(isWordCharacter) ?? false }
    }

    static func tokens(_ line: String) -> [Token] {
        var tokens: [Token] = []
        var start = line.startIndex
        var offset = 0
        while start < line.endIndex {
            let first = line[start]
            var end = line.index(after: start)
            if isWordCharacter(first) {
                while end < line.endIndex, isWordCharacter(line[end]) { end = line.index(after: end) }
            } else if first.isWhitespace {
                while end < line.endIndex, line[end].isWhitespace { end = line.index(after: end) }
            }
            let length = line.distance(from: start, to: end)
            tokens.append(Token(text: line[start..<end], offset: offset, length: length))
            offset += length
            start = end
        }
        return tokens
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Adjacent changed tokens merge into one range.
    private static func ranges(_ tokens: [Token], keeping common: Set<Int>) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for (index, token) in tokens.enumerated() where !common.contains(index) {
            let range = token.offset..<(token.offset + token.length)
            if let last = ranges.last, last.upperBound == range.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
            } else {
                ranges.append(range)
            }
        }
        return ranges
    }
}
