import Foundation

/// `git status --porcelain=v2 -z --branch --untracked-files=all`.
///
/// Entry lines have a fixed number of space-separated fields before the
/// path, so splitting with `maxSplits` keeps paths with spaces whole. A
/// rename (`2`) carries its original path in the next NUL field.
enum StatusParser {
    static let arguments = ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"]

    static func parse(_ data: Data) -> (head: BranchHead, entries: [StatusEntry]) {
        var oid: String?
        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var entries: [StatusEntry] = []

        let fields = data.nullSeparatedFields()
        var i = 0
        while i < fields.count {
            let field = fields[i]
            i += 1
            switch field.first {
            case "#":
                let parts = field.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "branch.oid": oid = parts[2] == "(initial)" ? nil : parts[2]
                case "branch.head": branch = parts[2] == "(detached)" ? nil : parts[2]
                case "branch.upstream": upstream = parts[2]
                case "branch.ab":
                    let counts = parts[2].split(separator: " ")
                    ahead = counts.first.flatMap { Int($0.dropFirst()) } ?? 0
                    behind = counts.dropFirst().first.flatMap { Int($0.dropFirst()) } ?? 0
                default: break
                }
            case "1":
                if let entry = changed(field, pathIndex: 8, originalPath: nil) { entries.append(entry) }
            case "2":
                let original = i < fields.count ? fields[i] : nil
                i += 1
                if let entry = changed(field, pathIndex: 9, originalPath: original) { entries.append(entry) }
            case "u":
                if let entry = changed(field, pathIndex: 10, originalPath: nil, isConflict: true) { entries.append(entry) }
            case "?":
                entries.append(StatusEntry(path: String(field.dropFirst(2)), index: .untracked, workTree: .untracked))
            default:
                // "!" (ignored) is never requested.
                continue
            }
        }
        let head = BranchHead(oid: oid, branch: branch, upstream: upstream, ahead: ahead, behind: behind)
        return (head, entries)
    }

    private static func changed(_ field: String, pathIndex: Int, originalPath: String?, isConflict: Bool = false) -> StatusEntry? {
        let parts = field.split(separator: " ", maxSplits: pathIndex, omittingEmptySubsequences: false)
        guard parts.count == pathIndex + 1, parts[1].count == 2,
              let index = FileChange(statusLetter: parts[1].first!),
              let workTree = FileChange(statusLetter: parts[1].last!) else { return nil }
        return StatusEntry(path: String(parts[pathIndex]), originalPath: originalPath,
                           index: index, workTree: workTree, isConflict: isConflict)
    }
}

/// `git diff-tree -r -z --name-status`: a status letter (with a score for
/// R and C) then the path; renames and copies give the old path first.
enum NameStatusParser {
    static func parse(_ data: Data) -> [CommitFileChange] {
        let fields = data.nullSeparatedFields()
        var changes: [CommitFileChange] = []
        var i = 0
        while i + 1 < fields.count {
            let status = fields[i]
            guard let letter = status.first, let change = FileChange(statusLetter: letter) else { i += 1; continue }
            if change == .renamed || change == .copied, i + 2 < fields.count {
                changes.append(CommitFileChange(path: fields[i + 2], originalPath: fields[i + 1], change: change))
                i += 3
            } else {
                changes.append(CommitFileChange(path: fields[i + 1], originalPath: nil, change: change))
                i += 2
            }
        }
        return changes
    }
}
