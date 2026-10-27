import Foundation

/// `git for-each-ref` with NUL between fields and a newline after each ref
///. `%(HEAD)` is "*" for the checked-out branch, " " otherwise.
enum BranchParser {
    static let arguments = ["for-each-ref",
                            "--format=%(refname)%00%(objectname)%00%(upstream:short)%00%(upstream:track)%00%(HEAD)",
                            "refs/heads", "refs/remotes"]

    static func parse(_ data: Data) -> [Branch] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5 else { return nil }
            let ref = fields[0]
            let isRemote = ref.hasPrefix("refs/remotes/")
            let name = String(ref.dropFirst(isRemote ? "refs/remotes/".count : "refs/heads/".count))
            // origin/HEAD is a pointer to the default branch, not a branch.
            if isRemote, name.hasSuffix("/HEAD") { return nil }
            let track = parseTrack(fields[3])
            return Branch(name: name, isRemote: isRemote, oid: fields[1],
                          upstream: fields[2].isEmpty ? nil : fields[2],
                          ahead: track.ahead, behind: track.behind, upstreamGone: track.gone,
                          isHead: fields[4] == "*")
        }
    }

    /// "", "[ahead 1]", "[behind 2]", "[ahead 1, behind 2]", "[gone]".
    static func parseTrack(_ track: String) -> (ahead: Int, behind: Int, gone: Bool) {
        let inner = track.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if inner == "gone" { return (0, 0, true) }
        var ahead = 0
        var behind = 0
        for part in inner.components(separatedBy: ", ") {
            let words = part.split(separator: " ")
            guard words.count == 2, let n = Int(words[1]) else { continue }
            if words[0] == "ahead" { ahead = n } else if words[0] == "behind" { behind = n }
        }
        return (ahead, behind, false)
    }
}

/// `git stash list -z --format=%gd%x1f%s%x1f%cI`.
enum StashParser {
    static let arguments = ["stash", "list", "-z", "--format=%gd%x1f%s%x1f%cI"]

    static func parse(_ data: Data) -> [Stash] {
        data.nullSeparatedFields().compactMap { record in
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, let date = try? Date(fields[2], strategy: .iso8601) else { return nil }
            return Stash(ref: fields[0], message: fields[1], date: date)
        }
    }
}

/// `git for-each-ref refs/tags`, newest first, the same way as branches:
/// NUL between fields, a newline after each tag. `%(*objectname)` is the
/// commit an annotated tag points at; a lightweight one is the commit.
enum TagParser {
    static let arguments = ["for-each-ref", "--sort=-creatordate",
                            "--format=%(refname:strip=2)%00%(objectname)%00%(*objectname)%00%(creatordate:iso-strict)%00%(contents:subject)",
                            "refs/tags"]

    static func parse(_ data: Data) -> [Tag] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5 else { return nil }
            return Tag(name: fields[0], oid: fields[2].isEmpty ? fields[1] : fields[2],
                       date: try? Date(fields[3], strategy: .iso8601), subject: fields[4])
        }
    }
}
