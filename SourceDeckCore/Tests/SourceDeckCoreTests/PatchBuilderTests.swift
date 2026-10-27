import Foundation
import Testing
@testable import SourceDeckCore

@Suite struct PatchBuilderTests {
    private func hunk(_ oldStart: Int, _ oldCount: Int, _ newStart: Int, _ newCount: Int) -> DiffHunk {
        DiffHunk(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount, section: "",
                 lines: [DiffLine(kind: .context, text: "c", oldLine: oldStart, newLine: newStart)])
    }

    private func file(_ hunks: [DiffHunk], change: DiffFile.Change = .modified, newPath: String = "f") -> DiffFile {
        DiffFile(oldPath: "f", newPath: newPath, change: change, isBinary: false, isTooLarge: false,
                 headerLines: ["diff --git a/f b/f", "--- a/f", "+++ b/f"], hunks: hunks)
    }

    private func headers(_ patch: String) -> [String] {
        patch.split(separator: "\n").filter { $0.hasPrefix("@@") }.map(String.init)
    }

    /// Forward, the old side is the index as it is; the new side is shifted
    /// by the hunks left out before (hunk 1 added 3 lines, it isn't staged).
    @Test func forwardShiftsTheNewStartByHunksLeftOut() {
        let patch = PatchBuilder.patch(file([hunk(1, 4, 1, 7), hunk(15, 6, 18, 6)]), hunks: [1], reverse: false)
        #expect(headers(patch) == ["@@ -15,6 +15,6 @@"])
        #expect(patch.hasPrefix("diff --git a/f b/f\n--- a/f\n+++ b/f\n"))
        #expect(patch.hasSuffix("\n"))
    }

    /// Reversed, the new side is the file as it is; the old side keeps the
    /// hunks left out.
    @Test func reverseShiftsTheOldStartByHunksLeftOut() {
        let patch = PatchBuilder.patch(file([hunk(1, 4, 1, 7), hunk(15, 6, 18, 6)]), hunks: [1], reverse: true)
        #expect(headers(patch) == ["@@ -18,6 +18,6 @@"])
    }

    @Test func allHunksKeepTheirOwnNumbers() {
        let patch = PatchBuilder.patch(file([hunk(1, 4, 1, 7), hunk(15, 6, 18, 6)]), hunks: [0, 1], reverse: false)
        #expect(headers(patch) == ["@@ -1,4 +1,7 @@", "@@ -15,6 +18,6 @@"])
    }

    @Test func renameGetsAPlainHeaderForTheNewPath() {
        let renamed = file([hunk(1, 1, 1, 1)], change: .renamed, newPath: "new name.txt")
        let patch = PatchBuilder.patch(renamed, hunks: [0], reverse: true)
        #expect(patch.hasPrefix("diff --git a/new name.txt b/new name.txt\n--- a/new name.txt\t\n+++ b/new name.txt\t\n"))
    }
}

/// Round trips through the real `git apply`.
@Suite struct PatchRoundTripTests {
    private let numbers = (1...30).map(String.init).joined(separator: "\n") + "\n"

    /// Lines 2, 15 and 28 changed: three hunks with -U3.
    private func threeHunkRepository() async throws -> TempRepository {
        let repo = try await TempRepository()
        try repo.write("n.txt", numbers)
        try await repo.commitAll("init")
        try repo.write("n.txt", numbers.replacingOccurrences(of: "\n2\n", with: "\nTWO\n")
            .replacingOccurrences(of: "\n15\n", with: "\nFIFTEEN\n").replacingOccurrences(of: "\n28\n", with: "\nTWENTY-EIGHT\n"))
        return repo
    }

    @Test func stageOnlyTheMiddleHunk() async throws {
        let repo = try await threeHunkRepository()
        let diff = try #require(try await repo.repository.diff(path: "n.txt", area: .unstaged))
        #expect(diff.hunks.count == 3)
        _ = try await repo.repository.applyPatch(PatchBuilder.patch(diff, hunks: [1], reverse: false), mode: .stage)
        let staged = try await repo.stagedDiff()
        #expect(staged.contains("+FIFTEEN") && !staged.contains("TWO") && !staged.contains("TWENTY"))
        #expect(try repo.read("n.txt").contains("TWO"))
    }

    @Test func unstageOneOfTwoStagedHunks() async throws {
        let repo = try await threeHunkRepository()
        try await repo.run("add", "n.txt")
        let staged = try #require(try await repo.repository.diff(path: "n.txt", area: .staged))
        _ = try await repo.repository.applyPatch(PatchBuilder.patch(staged, hunks: [0], reverse: true), mode: .unstage)
        let remaining = try await repo.stagedDiff()
        #expect(!remaining.contains("TWO") && remaining.contains("+FIFTEEN") && remaining.contains("+TWENTY-EIGHT"))
    }

    @Test func discardOneHunkFromTheWorkTree() async throws {
        let repo = try await threeHunkRepository()
        let diff = try #require(try await repo.repository.diff(path: "n.txt", area: .unstaged))
        _ = try await repo.repository.applyPatch(PatchBuilder.patch(diff, hunks: [2], reverse: true), mode: .discard)
        let content = try repo.read("n.txt")
        #expect(content.contains("TWO") && content.contains("FIFTEEN") && !content.contains("TWENTY-EIGHT") && content.contains("\n28\n"))
    }

    /// A later hunk after one that added lines: the case where a wrong
    /// header would put the change in the wrong place.
    @Test func stageAHunkAfterOneThatAddedLines() async throws {
        let repo = try await TempRepository()
        try repo.write("n.txt", numbers)
        try await repo.commitAll("init")
        try repo.write("n.txt", numbers.replacingOccurrences(of: "\n2\n", with: "\n2\nA\nB\nC\n").replacingOccurrences(of: "\n25\n", with: "\nX25\n"))
        let diff = try #require(try await repo.repository.diff(path: "n.txt", area: .unstaged))
        _ = try await repo.repository.applyPatch(PatchBuilder.patch(diff, hunks: [1], reverse: false), mode: .stage)
        let index = try await repo.run("show", ":n.txt")
        #expect(index == numbers.replacingOccurrences(of: "\n25\n", with: "\nX25\n"))
    }

    @Test func crlfFileWithoutFinalNewline() async throws {
        let repo = try await TempRepository()
        let original = (1...12).map { "l\($0)" }.joined(separator: "\r\n")
        try repo.write("crlf.txt", original)
        try await repo.commitAll("init")
        try repo.write("crlf.txt", original.replacingOccurrences(of: "l2\r\n", with: "L2\r\n").replacingOccurrences(of: "l12", with: "l12 changed"))
        let diff = try #require(try await repo.repository.diff(path: "crlf.txt", area: .unstaged))
        #expect(diff.hunks.count == 2)
        _ = try await repo.repository.applyPatch(PatchBuilder.patch(diff, hunks: [1], reverse: false), mode: .stage)
        let index = try await repo.run("show", ":crlf.txt")
        #expect(index == original.replacingOccurrences(of: "l12", with: "l12 changed"))
    }

    /// Unstaging part of a staged rename keeps the rename staged.
    @Test func unstageAHunkOfARenamedFile() async throws {
        let repo = try await TempRepository()
        try repo.write("old name.txt", numbers)
        try await repo.commitAll("init")
        try await repo.run("mv", "old name.txt", "new name.txt")
        try repo.write("new name.txt", numbers.replacingOccurrences(of: "\n2\n", with: "\nTWO\n").replacingOccurrences(of: "\n28\n", with: "\nTWENTY-EIGHT\n"))
        try await repo.run("add", "new name.txt")
        let staged = try #require(try await repo.repository.diff(path: "new name.txt", originalPath: "old name.txt", area: .staged))
        #expect(staged.change == .renamed)
        _ = try await repo.repository.applyPatch(PatchBuilder.patch(staged, hunks: [0], reverse: true), mode: .unstage)
        let status = try await repo.repository.status()
        #expect(status.entries.first { $0.path == "new name.txt" }?.index == .renamed)
        let index = try await repo.run("show", ":new name.txt")
        #expect(index == numbers.replacingOccurrences(of: "\n28\n", with: "\nTWENTY-EIGHT\n"))
    }
}
