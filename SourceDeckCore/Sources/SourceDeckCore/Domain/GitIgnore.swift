import Foundation

/// "Add to .gitignore": one line in the root `.gitignore` that
/// matches exactly one untracked path. The file is only edited, never
/// committed on the user's behalf.
public enum GitIgnore {
    /// Anchored to the root with "/", which also keeps a leading "#" or "!"
    /// from reading as a comment or a negation. Wildcards are escaped, and so
    /// are trailing spaces, which git would otherwise drop.
    public static func pattern(for path: String) -> String {
        var escaped = ""
        for character in path {
            if "\\*?[".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        var trailingSpaces = 0
        while escaped.hasSuffix(" ") {
            escaped.removeLast()
            trailingSpaces += 1
        }
        return "/" + escaped + String(repeating: "\\ ", count: trailingSpaces)
    }

    /// Appends the pattern on its own line, creating the file if needed.
    public static func append(path: String, root: URL) throws {
        let file = root.appendingPathComponent(".gitignore")
        var content = (try? Data(contentsOf: file)) ?? Data()
        if let last = content.last, last != UInt8(ascii: "\n") { content.append(UInt8(ascii: "\n")) }
        content.append(Data((pattern(for: path) + "\n").utf8))
        try content.write(to: file, options: .atomic)
    }
}
