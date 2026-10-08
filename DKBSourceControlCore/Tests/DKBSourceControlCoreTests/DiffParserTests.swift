import Foundation
import Testing
@testable import DKBSourceControlCore

@Suite struct DiffParserTests {
    private func parseOne(_ text: String, maxLines: Int = DiffParser.defaultMaxLines) throws -> DiffFile {
        let files = DiffParser.parse(text, maxLines: maxLines)
        #expect(files.count == 1)
        return try #require(files.first)
    }

    @Test func modifiedFileWithTwoHunksAndLineNumbers() throws {
        let file = try parseOne("""
            diff --git a/n.txt b/n.txt
            index 1234567..89abcde 100644
            --- a/n.txt
            +++ b/n.txt
            @@ -1,4 +1,7 @@ func top()
             1
            +A
            +B
            +C
             2
             3
             4
            @@ -15,6 +18,6 @@
             15
             16
             17
            -18
            +X18
             19
             20

            """)
        #expect(file.change == .modified)
        #expect(file.path == "n.txt")
        #expect(file.headerLines.count == 4)
        #expect(file.hunks.count == 2)
        let first = file.hunks[0]
        #expect((first.oldStart, first.oldCount, first.newStart, first.newCount) == (1, 4, 1, 7))
        #expect(first.section == "func top()")
        #expect(first.lines[1] == DiffLine(kind: .added, text: "A", oldLine: nil, newLine: 2))
        #expect(first.lines[4] == DiffLine(kind: .context, text: "2", oldLine: 2, newLine: 5))
        let second = file.hunks[1]
        #expect(second.lines[3] == DiffLine(kind: .removed, text: "18", oldLine: 18, newLine: nil))
        #expect(second.lines[4] == DiffLine(kind: .added, text: "X18", oldLine: nil, newLine: 21))
    }

    @Test func addedFileFromNoIndexWithSpaceInNameAndTrailingTab() throws {
        let file = try parseOne("diff --git a/Cà Phê.txt b/Cà Phê.txt\nnew file mode 100644\nindex 0000000..3e75765\n--- /dev/null\n+++ b/Cà Phê.txt\t\n@@ -0,0 +1 @@\n+new\n")
        #expect(file.change == .added)
        #expect(file.oldPath == nil)
        #expect(file.newPath == "Cà Phê.txt")
        #expect((file.hunks[0].oldStart, file.hunks[0].oldCount, file.hunks[0].newCount) == (0, 0, 1))
    }

    @Test func deletedFile() throws {
        let file = try parseOne("diff --git a/gone.txt b/gone.txt\ndeleted file mode 100644\nindex abaddc0..0000000\n--- a/gone.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-del\n")
        #expect(file.change == .deleted)
        #expect(file.newPath == nil)
        #expect(file.path == "gone.txt")
    }

    @Test func renameWithChanges() throws {
        let file = try parseOne("diff --git a/old name.txt b/new name.txt\nsimilarity index 80%\nrename from old name.txt\nrename to new name.txt\nindex 1..2 100644\n--- a/old name.txt\t\n+++ b/new name.txt\t\n@@ -1,2 +1,2 @@\n a\n-b\n+B\n")
        #expect(file.change == .renamed)
        #expect(file.oldPath == "old name.txt")
        #expect(file.newPath == "new name.txt")
        #expect(file.hunks.count == 1)
    }

    @Test func pureRenameHasNoHunks() throws {
        let file = try parseOne("diff --git a/a.txt b/b.txt\nsimilarity index 100%\nrename from a.txt\nrename to b.txt\n")
        #expect(file.change == .renamed)
        #expect((file.oldPath, file.newPath) == ("a.txt", "b.txt"))
        #expect(file.hunks.isEmpty)
    }

    @Test func binaryFileTakesItsPathFromTheDiffLine() throws {
        let file = try parseOne("diff --git a/icon with space.png b/icon with space.png\nindex 1..2 100644\nBinary files a/icon with space.png and b/icon with space.png differ\n")
        #expect(file.isBinary)
        #expect(file.path == "icon with space.png")
        #expect(file.hunks.isEmpty)
    }

    @Test func noNewlineMarkerAndCRLFAreKept() throws {
        let file = try parseOne("diff --git a/crlf.txt b/crlf.txt\nindex 5f46443..bfa6ab7 100644\n--- a/crlf.txt\n+++ b/crlf.txt\n@@ -9,4 +9,4 @@ l8\n l9\r\n l10\r\n l11\r\n-l12\n\\ No newline at end of file\n+l12 changed\n\\ No newline at end of file\n")
        let lines = file.hunks[0].lines
        #expect(lines[0].text == "l9\r")
        #expect(lines[0].displayText == "l9")
        #expect(lines[4].kind == .noNewlineMarker)
        #expect(lines[4].text == " No newline at end of file")
        #expect(lines.filter { $0.kind == .noNewlineMarker }.count == 2)
    }

    @Test func omittedCountsMeanOne() throws {
        let file = try parseOne("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n")
        #expect((file.hunks[0].oldCount, file.hunks[0].newCount) == (1, 1))
    }

    /// `diff.suppressBlankEmpty` prints a blank context line as "" — it is
    /// still a line of the hunk.
    @Test func emptyLineInsideAHunkIsBlankContext() throws {
        let file = try parseOne("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,3 +1,3 @@\n a\n\n-b\n+c\n")
        #expect(file.hunks[0].lines.map(\.kind) == [.context, .context, .removed, .added])
        #expect(file.hunks[0].lines[1].text == "")
    }

    @Test func tooLargeFileDropsItsHunks() throws {
        let body = (1...50).map { "+line \($0)" }.joined(separator: "\n")
        let file = try parseOne("diff --git a/big b/big\nnew file mode 100644\n--- /dev/null\n+++ b/big\n@@ -0,0 +1,50 @@\n\(body)\n", maxLines: 10)
        #expect(file.isTooLarge)
        #expect(file.hunks.isEmpty)
        #expect(file.path == "big")
    }

    @Test func severalFilesInOneDiff() {
        let files = DiffParser.parse("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-1\n+2\ndiff --git a/b b/b\nnew file mode 100644\n--- /dev/null\n+++ b/b\n@@ -0,0 +1 @@\n+x\n")
        #expect(files.map(\.path) == ["a", "b"])
        #expect(files.map(\.change) == [.modified, .added])
    }

    /// The viewer's limit (D20) must parse in well under a second; building
    /// each hunk once (not per line) is what keeps it linear.
    @Test func twentyThousandLinesParseQuickly() throws {
        let body = (1...20_000).map { "+line \($0)" }.joined(separator: "\n")
        let text = "diff --git a/big b/big\nnew file mode 100644\n--- /dev/null\n+++ b/big\n@@ -0,0 +1,20000 @@\n\(body)\n"
        let start = ContinuousClock.now
        let file = try parseOne(text)
        #expect(ContinuousClock.now - start < .milliseconds(500))
        #expect(file.hunks[0].lines.count == 20_000)
        #expect(!file.isTooLarge)
    }

    @Test func emptyInputHasNoFiles() {
        #expect(DiffParser.parse("").isEmpty)
    }
}
