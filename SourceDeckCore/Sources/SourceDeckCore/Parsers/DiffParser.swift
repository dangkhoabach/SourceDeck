import Foundation

/// Unified diff (`git diff`, `git show`, `diff --no-index`) → files and hunks
///. Lines are split on "\n" only, so a CRLF file keeps its "\r"
/// and a patch rebuilt from the parsed lines matches the file exactly.
enum DiffParser {
    /// Beyond this many hunk lines a file is reported as too large and its
    /// hunks are dropped: the viewer would not stay responsive.
    static let defaultMaxLines = 20_000

    static func parse(_ text: String, maxLines: Int = defaultMaxLines) -> [DiffFile] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        var files: [DiffFile] = []
        var current: FileBuilder?
        for line in lines {
            if line.hasPrefix("diff --git ") {
                if let current { files.append(current.build(maxLines: maxLines)) }
                current = FileBuilder(firstLine: line)
            } else {
                current?.add(line)
            }
        }
        if let current { files.append(current.build(maxLines: maxLines)) }
        return files
    }

    private struct FileBuilder {
        var headerLines: [String]
        var oldPath: String?
        var newPath: String?
        var change: DiffFile.Change = .modified
        var isBinary = false
        var sawMinusPlus = false
        var hunks: [HunkBuilder] = []
        var lineCount = 0

        init(firstLine: String) {
            headerLines = [firstLine]
            // Only trustworthy when both halves are the same path (no rename):
            // "diff --git a/P b/P" can't be split on " b/" when P has spaces.
            let rest = firstLine.dropFirst("diff --git ".count)
            let length = (rest.count - 5) / 2
            if rest.count >= 5, (rest.count - 5) % 2 == 0, rest.hasPrefix("a/") {
                let a = rest.dropFirst(2).prefix(length)
                let b = rest.suffix(length)
                if a == b, rest.dropFirst(2 + length).hasPrefix(" b/") {
                    oldPath = String(a)
                    newPath = String(b)
                }
            }
        }

        mutating func add(_ line: String) {
            if line.hasPrefix("@@") {
                if let hunk = HunkBuilder(header: line) { hunks.append(hunk) }
                return
            }
            if var hunk = hunks.popLast() {
                lineCount += 1
                hunk.add(line)
                hunks.append(hunk)
                return
            }
            headerLines.append(line)
            if line.hasPrefix("new file mode") {
                change = .added
            } else if line.hasPrefix("deleted file mode") {
                change = .deleted
            } else if line.hasPrefix("rename from ") {
                change = .renamed
                oldPath = String(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                newPath = String(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("copy from ") {
                change = .copied
                oldPath = String(line.dropFirst("copy from ".count))
            } else if line.hasPrefix("copy to ") {
                newPath = String(line.dropFirst("copy to ".count))
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                isBinary = true
            } else if line.hasPrefix("--- ") {
                sawMinusPlus = true
                oldPath = Self.path(line.dropFirst(4), prefix: "a/")
            } else if line.hasPrefix("+++ ") {
                newPath = Self.path(line.dropFirst(4), prefix: "b/")
            }
        }

        /// "a/name", "/dev/null", or "a/name with space\t" (git adds the TAB
        /// so a name with spaces has a visible end).
        static func path(_ raw: Substring, prefix: String) -> String? {
            var name = raw
            if name.hasSuffix("\t") { name = name.dropLast() }
            if name == "/dev/null" { return nil }
            return String(name.hasPrefix(prefix) ? name.dropFirst(prefix.count) : name)
        }

        func build(maxLines: Int) -> DiffFile {
            var change = change
            if sawMinusPlus {
                if oldPath == nil { change = .added } else if newPath == nil { change = .deleted }
            }
            let tooLarge = lineCount > maxLines
            return DiffFile(oldPath: change == .added ? nil : oldPath,
                            newPath: change == .deleted ? nil : newPath,
                            change: change, isBinary: isBinary, isTooLarge: tooLarge,
                            headerLines: headerLines,
                            hunks: tooLarge ? [] : hunks.map(\.hunk))
        }
    }

    private struct HunkBuilder {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        let section: String
        var oldLine: Int
        var newLine: Int
        var lines: [DiffLine] = []

        var hunk: DiffHunk {
            DiffHunk(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount,
                     section: section, lines: lines)
        }

        /// "@@ -oldStart[,oldCount] +newStart[,newCount] @@ section"; an
        /// omitted count means 1.
        init?(header: String) {
            let parts = header.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count >= 4, parts[0] == "@@", parts[3] == "@@",
                  let old = Self.range(parts[1], sign: "-"), let new = Self.range(parts[2], sign: "+") else { return nil }
            oldStart = old.start
            oldCount = old.count
            newStart = new.start
            newCount = new.count
            section = parts.count > 4 ? String(parts[4]) : ""
            oldLine = old.start
            newLine = new.start
        }

        static func range(_ text: Substring, sign: Character) -> (start: Int, count: Int)? {
            guard text.first == sign else { return nil }
            let numbers = text.dropFirst().split(separator: ",")
            guard let start = numbers.first.flatMap({ Int($0) }) else { return nil }
            let count = numbers.count > 1 ? Int(numbers[1]) : 1
            return count.map { (start, $0) }
        }

        mutating func add(_ line: String) {
            // An empty line is a blank context line printed without its
            // space (`diff.suppressBlankEmpty`); skipping it would break
            // the hunk's line count.
            let first = line.first ?? " "
            let text = String(line.dropFirst())
            switch first {
            case " ":
                lines.append(DiffLine(kind: .context, text: text, oldLine: oldLine, newLine: newLine))
                oldLine += 1
                newLine += 1
            case "-":
                lines.append(DiffLine(kind: .removed, text: text, oldLine: oldLine, newLine: nil))
                oldLine += 1
            case "+":
                lines.append(DiffLine(kind: .added, text: text, oldLine: nil, newLine: newLine))
                newLine += 1
            case "\\":
                lines.append(DiffLine(kind: .noNewlineMarker, text: text, oldLine: nil, newLine: nil))
            default:
                return
            }
        }
    }
}
