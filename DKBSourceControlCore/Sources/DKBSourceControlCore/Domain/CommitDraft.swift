import Foundation

/// What the commit composer holds (plan F4): an outline of details and
/// sub-details, or the raw text typed instead. Kept per repository until it
/// is committed, across repository switches and app launches.
///
/// The outline is a flat list with an indent flag rather than nested
/// `CommitMessage.Detail`s, so ⇥ / ⇧⇥ and drag-to-reorder are plain list
/// edits; `message` turns it into the git-rule text.
public struct CommitDraft: Sendable, Equatable, Codable {
    public struct Line: Sendable, Equatable, Codable, Identifiable {
        public var id: UUID
        /// "  + sub-detail" rather than " - detail".
        public var isSub: Bool
        public var text: String

        public init(id: UUID = UUID(), isSub: Bool = false, text: String = "") {
            self.id = id
            self.isSub = isSub
            self.text = text
        }
    }

    public var keyword: CommitKeyword
    public var lines: [Line]
    /// Set in raw mode: the message exactly as typed.
    public var rawText: String?
    public var pushAfterCommit: Bool

    public init(keyword: CommitKeyword = .update, lines: [Line] = [Line()], rawText: String? = nil,
                pushAfterCommit: Bool = false) {
        self.keyword = keyword
        self.lines = lines
        self.rawText = rawText
        self.pushAfterCommit = pushAfterCommit
    }

    /// An existing message as an outline (to reuse or amend it).
    public init(_ message: CommitMessage, pushAfterCommit: Bool = false) {
        let lines = message.details.flatMap { detail in
            [Line(text: detail.text)] + detail.subs.map { Line(isSub: true, text: $0) }
        }
        self.init(keyword: message.keyword, lines: lines.isEmpty ? [Line()] : lines, pushAfterCommit: pushAfterCommit)
    }

    /// The text git will get. Empty outline lines are left out (⏎ makes
    /// one before it is typed in); each item stays on one line, trimmed,
    /// as git-rule asks.
    public var message: String {
        if let rawText { return rawText }
        var rendered = ["+ \(keyword.rawValue) +"]
        for line in lines {
            let text = line.text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { rendered.append((line.isSub ? "  + " : " - ") + text) }
        }
        return rendered.joined(separator: "\n")
    }

    /// Nothing typed yet: no detail text and no raw text.
    public var isEmpty: Bool {
        if let rawText { return rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return lines.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Raw mode → outline. nil when the text doesn't follow the format, so
    /// switching back would lose what was typed. Empty text, or a header
    /// with no detail yet, gives an empty outline.
    public func outline() -> CommitDraft? {
        guard let rawText else { return self }
        if let message = CommitMessage.parse(rawText) { return CommitDraft(message, pushAfterCommit: pushAfterCommit) }
        let lines = CommitMessage.gitLines(rawText)
        guard lines.count == 1 else { return nil }
        if lines[0].isEmpty { return CommitDraft(keyword: keyword, pushAfterCommit: pushAfterCommit) }
        return CommitMessage.keyword(inHeader: lines[0]).map { CommitDraft(keyword: $0, pushAfterCommit: pushAfterCommit) }
    }
}
