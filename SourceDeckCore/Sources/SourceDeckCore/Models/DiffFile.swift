import Foundation

/// One file of a unified diff.
public struct DiffFile: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case modified, added, deleted, renamed, copied
    }

    /// nil when the file is new.
    public let oldPath: String?
    /// nil when the file was deleted.
    public let newPath: String?
    public let change: Change
    public let isBinary: Bool
    /// More lines than the viewer shows: `hunks` is empty.
    public let isTooLarge: Bool
    /// Every line from `diff --git` up to the first hunk, verbatim, so a
    /// patch built from some of the hunks applies exactly like git's own.
    public let headerLines: [String]
    public let hunks: [DiffHunk]

    public var path: String { newPath ?? oldPath ?? "" }
}

public struct DiffHunk: Sendable, Equatable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    /// The text after the second `@@`, usually the enclosing function.
    public let section: String
    public let lines: [DiffLine]
}

public struct DiffLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case context, added, removed
        /// `\ No newline at end of file`, about the line before it.
        case noNewlineMarker
    }

    public let kind: Kind
    /// Without the leading ' ', '+' or '-'. A CRLF file keeps its "\r", so a
    /// patch rebuilt from these lines still matches the file byte for byte.
    public let text: String
    public let oldLine: Int?
    public let newLine: Int?

    public var displayText: String { text.hasSuffix("\r") ? String(text.dropLast()) : text }
}
