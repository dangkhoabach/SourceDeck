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
