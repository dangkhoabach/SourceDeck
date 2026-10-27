import Foundation
import Testing
@testable import SourceDeckCore

@Suite struct WordDiffTests {
    private func text(_ line: String, _ ranges: [Range<Int>]) -> [String] {
        let characters = Array(line)
        return ranges.map { String(characters[$0]) }
    }

    @Test func onlyTheChangedWordIsMarked() throws {
        let old = "let timeout = 30 // seconds"
        let new = "let timeout = 120 // seconds"
        let changes = try #require(WordDiff.changes(old: old, new: new))
        #expect(text(old, changes.old) == ["30"])
        #expect(text(new, changes.new) == ["120"])
    }

    @Test func insertedWordsAndPunctuation() throws {
        let old = "fetch(url)"
        let new = "fetch(url, timeout: 5)"
        let changes = try #require(WordDiff.changes(old: old, new: new))
        #expect(changes.old.isEmpty)
        #expect(text(new, changes.new) == [", timeout: 5"])
    }

    /// Offsets count characters, not bytes: Vietnamese text stays aligned.
    @Test func offsetsAreCharacters() throws {
        let old = "Cà Phê Tý Mập cũ"
        let new = "Cà Phê Tý Mập mới"
        let changes = try #require(WordDiff.changes(old: old, new: new))
        #expect(text(old, changes.old) == ["cũ"])
        #expect(text(new, changes.new) == ["mới"])
    }

    @Test func nothingInCommonIsNotHighlighted() {
        #expect(WordDiff.changes(old: "alpha beta", new: "gamma delta") == nil)
        // Shared spaces alone don't count.
        #expect(WordDiff.changes(old: "a b", new: "c d") == nil)
        #expect(WordDiff.changes(old: "", new: "x") == nil)
    }

    @Test func veryLongLinesAreSkipped() {
        let long = (0..<300).map { "w\($0)" }.joined(separator: " ")
        #expect(WordDiff.changes(old: long, new: long + " x") == nil)
    }

    @Test func runsOfRemovedThenAddedLinesPairUp() {
        func line(_ kind: DiffLine.Kind) -> DiffLine { DiffLine(kind: kind, text: "", oldLine: nil, newLine: nil) }
        let hunk = DiffHunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: 0, section: "", lines: [
            line(.context), line(.removed), line(.removed), line(.added), line(.context),
            line(.removed), line(.added), line(.added), line(.added), line(.noNewlineMarker),
        ])
        #expect(WordDiff.pairs(in: hunk) == [1: 3, 3: 1, 5: 6, 6: 5])
    }
}

/// Line mode against the real `git apply`.
@Suite struct PatchLineModeTests {
    private let numbers = (1...20).map(String.init).joined(separator: "\n") + "\n"

    /// Lines 5 to 9 replaced: one hunk of 5 removed and 5 added lines.
    private func tenLineHunk() async throws -> (TempRepository, DiffFile) {
        let repo = try await TempRepository()
        try repo.write("n.txt", numbers)
        try await repo.commitAll("init")
        var lines = numbers.split(separator: "\n").map(String.init)
        for index in 4...8 { lines[index] = "N\(lines[index])" }
        try repo.write("n.txt", lines.joined(separator: "\n") + "\n")
        let diff = try #require(try await repo.repository.diff(path: "n.txt", area: .unstaged))
        #expect(diff.hunks.count == 1 && diff.hunks[0].lines.filter { $0.kind != .context }.count == 10)
        return (repo, diff)
    }

    private func index(of text: String, _ kind: DiffLine.Kind, in file: DiffFile) -> Int {
        file.hunks[0].lines.firstIndex { $0.kind == kind && $0.text == text }!
    }

    private func changedLines(_ diff: String) -> [String] {
        diff.split(separator: "\n").filter { ($0.hasPrefix("+") || $0.hasPrefix("-")) && !$0.hasPrefix("+++") && !$0.hasPrefix("---") }
            .map(String.init)
    }

    @Test func stageTwoLinesOfATenLineHunk() async throws {
        let (repo, diff) = try await tenLineHunk()
        let chosen: Set = [index(of: "6", .removed, in: diff), index(of: "N6", .added, in: diff)]
        _ = try await repo.repository.applyPatch(PatchBuilder.patch(diff, hunk: 0, lines: chosen, reverse: false), mode: .stage)
        #expect(changedLines(try await repo.stagedDiff()) == ["-6", "+N6"])
        #expect(try await repo.run("show", ":n.txt") == numbers.replacingOccurrences(of: "\n6\n", with: "\nN6\n"))
        // The work tree is untouched.
        #expect(try repo.read("n.txt").contains("N9"))
    }

    /// The diff is read again between the two, as the app does.
    @Test func stageOnlyAnAddedLineThenOnlyARemovedOne() async throws {
        let (repo, diff) = try await tenLineHunk()
        _ = try await repo.repository.applyPatch(
            PatchBuilder.patch(diff, hunk: 0, lines: [index(of: "N7", .added, in: diff)], reverse: false), mode: .stage)
        let again = try #require(try await repo.repository.diff(path: "n.txt", area: .unstaged))
        _ = try await repo.repository.applyPatch(
            PatchBuilder.patch(again, hunk: 0, lines: [index(of: "9", .removed, in: again)], reverse: false), mode: .stage)
        // Index: the original with N7 added next to 7 (both kept) and 9 gone.
        var expected = numbers.split(separator: "\n").map(String.init)
        expected.insert("N7", at: 7)
        expected.remove(at: 9)
        #expect(try await repo.run("show", ":n.txt") == expected.joined(separator: "\n") + "\n")
    }

    @Test func unstageSomeStagedLines() async throws {
        let (repo, _) = try await tenLineHunk()
        try await repo.run("add", "n.txt")
        let staged = try #require(try await repo.repository.diff(path: "n.txt", area: .staged))
        let chosen: Set = [index(of: "5", .removed, in: staged), index(of: "N5", .added, in: staged)]
        _ = try await repo.repository.applyPatch(PatchBuilder.patch(staged, hunk: 0, lines: chosen, reverse: true), mode: .unstage)
        let remaining = changedLines(try await repo.stagedDiff())
        #expect(!remaining.contains("-5") && !remaining.contains("+N5") && remaining.contains("+N6") && remaining.count == 8)
    }

    @Test func discardSomeLinesFromTheWorkTree() async throws {
        let (repo, diff) = try await tenLineHunk()
        let chosen: Set = [index(of: "8", .removed, in: diff), index(of: "N8", .added, in: diff)]
        _ = try await repo.repository.applyPatch(PatchBuilder.patch(diff, hunk: 0, lines: chosen, reverse: true), mode: .discard)
        let content = try repo.read("n.txt")
        #expect(content.contains("\n8\n") && !content.contains("N8") && content.contains("N7") && content.contains("N9"))
    }

    /// No context at all: the only line of the file replaced.
    @Test func singleLineFileStagesTheRemovalAlone() async throws {
        let repo = try await TempRepository()
        try repo.write("one.txt", "old\n")
        try await repo.commitAll("init")
        try repo.write("one.txt", "new\n")
        let diff = try #require(try await repo.repository.diff(path: "one.txt", area: .unstaged))
        _ = try await repo.repository.applyPatch(
            PatchBuilder.patch(diff, hunk: 0, lines: [index(of: "old", .removed, in: diff)], reverse: false), mode: .stage)
        #expect(try await repo.run("show", ":one.txt") == "")
        // Now an addition to an empty index: "@@ -0,0 +1,1 @@".
        let again = try #require(try await repo.repository.diff(path: "one.txt", area: .unstaged))
        _ = try await repo.repository.applyPatch(
            PatchBuilder.patch(again, hunk: 0, lines: [index(of: "new", .added, in: again)], reverse: false), mode: .stage)
        #expect(try await repo.run("show", ":one.txt") == "new\n")
    }

    @Test func lineSelectionIsOffForWholeFilesAndMissingNewlines() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "a\nb")
        try await repo.commitAll("init")
        try repo.write("a.txt", "a\nB")
        try repo.write("new.txt", "x\n")
        let noNewline = try #require(try await repo.repository.diff(path: "a.txt", area: .unstaged))
        #expect(!PatchBuilder.supportsLineSelection(noNewline, hunk: 0))
        let added = try #require(try await repo.repository.diff(path: "new.txt", area: .untracked))
        #expect(!PatchBuilder.supportsLineSelection(added, hunk: 0))
    }
}
