import Foundation

/// Builds a patch holding only some hunks of a file, for `git apply`
/// (plan D8). Stage = `apply --cached`; unstage = `apply --cached --reverse`
/// on a staged diff; discard = `apply --reverse` on an unstaged diff.
public enum PatchBuilder {
    /// - Parameter reverse: the patch will be applied with `--reverse`.
    ///
    /// Line counts must be exact (`git apply` rejects a wrong count as a
    /// corrupt patch). Start lines are kept exact too: the side git reads
    /// is unchanged, and the other side is shifted by the hunks left out
    /// before it — forward, the target is the old side plus only the chosen
    /// hunks; reversed, it is the new side minus only the chosen hunks.
    public static func patch(_ file: DiffFile, hunks selection: Set<Int>, reverse: Bool) -> String {
        var lines = header(for: file)
        var skippedDelta = 0
        for (index, hunk) in file.hunks.enumerated() {
            let delta = hunk.newCount - hunk.oldCount
            guard selection.contains(index) else {
                skippedDelta += delta
                continue
            }
            let oldStart = reverse ? hunk.oldStart + skippedDelta : hunk.oldStart
            let newStart = reverse ? hunk.newStart : hunk.newStart - skippedDelta
            lines.append("@@ -\(oldStart),\(hunk.oldCount) +\(newStart),\(hunk.newCount) @@")
            for line in hunk.lines {
                switch line.kind {
                case .context: lines.append(" " + line.text)
                case .added: lines.append("+" + line.text)
                case .removed: lines.append("-" + line.text)
                case .noNewlineMarker: lines.append("\\" + line.text)
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Whether some lines of the hunk can be picked on their own. Not when
    /// the file is added or deleted as a whole (its header says so), nor
    /// next to "\ No newline at end of file": keeping half of such a pair
    /// would leave a line without its newline in the middle of the file.
    public static func supportsLineSelection(_ file: DiffFile, hunk index: Int) -> Bool {
        file.change != .added && file.change != .deleted && !file.hunks[index].lines.contains { $0.kind == .noNewlineMarker }
    }

    /// A patch with only the chosen added and removed lines of one hunk
    /// (plan D8, line mode). The lines left out keep the side `git apply`
    /// reads unchanged: forward (stage, onto the index) an unchosen "-"
    /// line stays as context and an unchosen "+" line is dropped; reversed
    /// (unstage, discard — git reads the new side) it is the other way round.
    ///
    /// Within a run of removed lines followed by added lines, the pairs are
    /// written side by side, so a chosen "+" line lands where its "-" line
    /// was rather than after every line left as context.
    /// - Parameter lines: indexes into the hunk's `lines`; context lines are ignored.
    public static func patch(_ file: DiffFile, hunk index: Int, lines selection: Set<Int>, reverse: Bool) -> String {
        let hunk = file.hunks[index]
        var body: [String] = []
        var oldCount = 0
        var newCount = 0
        func emit(_ position: Int) {
            let line = hunk.lines[position]
            let chosen = selection.contains(position)
            switch line.kind {
            case .context:
                body.append(" " + line.text)
            case .removed where chosen:
                body.append("-" + line.text)
                oldCount += 1
                return
            case .added where chosen:
                body.append("+" + line.text)
                newCount += 1
                return
            case .removed where !reverse, .added where reverse:
                // Stays as it is on the side git reads.
                body.append(" " + line.text)
            case .removed, .added, .noNewlineMarker:
                return
            }
            oldCount += 1
            newCount += 1
        }
        var removed: [Int] = []
        var added: [Int] = []
        func flush() {
            for pair in 0..<max(removed.count, added.count) {
                if pair < removed.count { emit(removed[pair]) }
                if pair < added.count { emit(added[pair]) }
            }
            removed = []
            added = []
        }
        for (position, line) in hunk.lines.enumerated() {
            switch line.kind {
            case .removed:
                if !added.isEmpty { flush() }
                removed.append(position)
            case .added:
                added.append(position)
            case .context, .noNewlineMarker:
                flush()
                emit(position)
            }
        }
        flush()
        // Nothing before this hunk is in the patch, so both sides start at
        // the first line of the side git reads. A side with no lines names
        // the line before instead, as git does.
        let (readStart, readCount) = reverse ? (hunk.newStart, hunk.newCount) : (hunk.oldStart, hunk.oldCount)
        let first = readCount == 0 ? readStart + 1 : readStart
        func start(_ count: Int) -> Int { count == 0 ? first - 1 : first }
        let header = "@@ -\(start(oldCount)),\(oldCount) +\(start(newCount)),\(newCount) @@"
        return (self.header(for: file) + [header] + body).joined(separator: "\n") + "\n"
    }

    /// git's own header, except for a rename or copy: applying that header
    /// in reverse would also undo the rename, when only the chosen lines
    /// should move. Those get a plain header for the new path.
    static func header(for file: DiffFile) -> [String] {
        guard file.change == .renamed || file.change == .copied, let path = file.newPath else { return file.headerLines }
        // git ends a name containing a space with a TAB so its end is visible.
        let end = path.contains(" ") ? "\t" : ""
        return ["diff --git a/\(path) b/\(path)", "--- a/\(path)\(end)", "+++ b/\(path)\(end)"]
    }
}
