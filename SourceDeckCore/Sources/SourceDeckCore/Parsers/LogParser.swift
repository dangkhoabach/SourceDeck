import Foundation

/// `git log -z --format=…`. Fields are separated by US (0x1f) and
/// commits by NUL. The message is `%B`, the raw message, last because it is
/// the only field that can hold anything.
enum LogParser {
    static let format = "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%cI%x1f%D%x1f%B"

    static func parse(_ data: Data) -> [Commit] {
        data.nullSeparatedFields().compactMap(commit)
    }

    /// One commit's fields, as `format` prints them.
    static func commit(_ record: String) -> Commit? {
        let fields = record.split(separator: "\u{1f}", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 8,
              let authorDate = try? Date(fields[4], strategy: .iso8601),
              let commitDate = try? Date(fields[5], strategy: .iso8601) else { return nil }
        var message = fields[7]
        while message.hasSuffix("\n") { message.removeLast() }
        return Commit(
            oid: fields[0],
            parents: fields[1].split(separator: " ").map(String.init),
            authorName: fields[2],
            authorEmail: fields[3],
            authorDate: authorDate,
            commitDate: commitDate,
            refs: fields[6].isEmpty ? [] : fields[6].components(separatedBy: ", "),
            message: message)
    }
}

/// `git log -z --follow --name-status` with `format`: each commit is RS
/// (0x1e) and the `LogParser` fields, then "\n" and the status letter, then
/// the path, or the old and new paths of a rename. A commit git prints no
/// change for has no file.
enum FileHistoryParser {
    static let format = "--format=%x1e" + LogParser.format.dropFirst("--format=".count)

    static func parse(_ data: Data) -> [FileRevision] {
        let fields = data.nullSeparatedFields()
        var revisions: [FileRevision] = []
        var i = 0
        while i < fields.count {
            let field = fields[i]
            i += 1
            if field.hasPrefix("\u{1e}") {
                if let commit = LogParser.commit(String(field.dropFirst())) { revisions.append(FileRevision(commit: commit)) }
                continue
            }
            // A change belongs to the commit just read, and only its first counts.
            guard field.first == "\n", let letter = field.dropFirst().first, let change = FileChange(statusLetter: letter),
                  let last = revisions.indices.last, revisions[last].file == nil, i < fields.count else { continue }
            if change == .renamed || change == .copied, i + 1 < fields.count {
                revisions[last].file = CommitFileChange(path: fields[i + 1], originalPath: fields[i], change: change)
                i += 2
            } else {
                revisions[last].file = CommitFileChange(path: fields[i], originalPath: nil, change: change)
                i += 1
            }
        }
        return revisions
    }
}
