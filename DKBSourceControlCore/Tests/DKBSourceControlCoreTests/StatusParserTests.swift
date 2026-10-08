import Foundation
import Testing
@testable import DKBSourceControlCore

/// Inputs are git 2.54 output recorded from a scratch repository.
@Suite struct StatusParserTests {
    private func parse(_ text: String) -> (head: BranchHead, entries: [StatusEntry]) {
        StatusParser.parse(Data(text.utf8))
    }

    @Test func unbornBranch() {
        let (head, entries) = parse("# branch.oid (initial)\0# branch.head main\0")
        #expect(head.isUnborn)
        #expect(head.branch == "main")
        #expect(head.upstream == nil)
        #expect(entries.isEmpty)
    }

    @Test func cleanWithUpstream() {
        let (head, entries) = parse("# branch.oid 50ea8d1c8b8fa75d047ea5b828c5a8782e8b5d38\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +0 -0\0")
        #expect(head.oid == "50ea8d1c8b8fa75d047ea5b828c5a8782e8b5d38")
        #expect(head.upstream == "origin/main")
        #expect(head.ahead == 0 && head.behind == 0)
        #expect(entries.isEmpty)
    }

    @Test func aheadAndBehind() {
        let (head, _) = parse("# branch.oid 1bace55\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +3 -2\0")
        #expect(head.ahead == 3)
        #expect(head.behind == 2)
    }

    @Test func detachedHead() {
        let (head, _) = parse("# branch.oid 1bace55aaf78f021f10560adba67be029ac07f7e\0# branch.head (detached)\0")
        #expect(head.isDetached)
        #expect(!head.isUnborn)
    }

    @Test func mixedChangesRenameAndNamesWithSpaces() {
        let (_, entries) = parse(
            "# branch.oid 50ea8d1\0# branch.head main\0"
            + "1 D. N... 100644 000000 000000 abaddc0b9edd523c69166a2c9f3a9e31a4c873e3 0000000000000000000000000000000000000000 gone.txt\0"
            + "1 .M N... 100644 100644 100644 de980441c3ab03a8c07dda1ad27b8a11f39deb1e de980441c3ab03a8c07dda1ad27b8a11f39deb1e keep.txt\0"
            + "1 MM N... 100644 100644 100644 28ce6a8b26aa170e1de65536fe8abe1832bd3242 08bb2331e777f431177c40df6841c0034f89fb58 mod.txt\0"
            + "2 R. N... 100644 100644 100644 587be6b4c3f93f93c489c0111bba5596147a26cb 587be6b4c3f93f93c489c0111bba5596147a26cb R100 new name.txt\0old name.txt\0"
            + "? Cà Phê Tý Mập.txt\0? dir/new.txt\0")
        #expect(entries.map(\.path) == ["gone.txt", "keep.txt", "mod.txt", "new name.txt", "Cà Phê Tý Mập.txt", "dir/new.txt"])
        #expect(entries[0].index == .deleted && entries[0].hasStagedChange && !entries[0].hasUnstagedChange)
        #expect(entries[1].workTree == .modified && !entries[1].hasStagedChange && entries[1].hasUnstagedChange)
        #expect(entries[2].hasStagedChange && entries[2].hasUnstagedChange)
        #expect(entries[3].index == .renamed && entries[3].originalPath == "old name.txt")
        #expect(entries[4].isUntracked && entries[4].hasUnstagedChange && !entries[4].hasStagedChange)
        let status = RepositoryStatus(head: BranchHead(oid: "x", branch: "main", upstream: nil, ahead: 0, behind: 0),
                                      entries: entries, state: .normal)
        #expect(status.stagedCount == 3)
        #expect(status.unstagedCount == 2)
        #expect(status.untrackedCount == 2)
    }

    @Test func conflictEntry() {
        let (head, entries) = parse(
            "# branch.oid 1c66a01\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +2 -0\0"
            + "u UU N... 100644 100644 100644 100644 32814eeca5c53c405c14294dbc4be46f8e8c8b6e ba2906d0666cf726c7eaadd2cd3db615dedfdf3a a7453f07505c42ea8d6fdda75fa91710c81c53d6 c.txt\0")
        #expect(head.ahead == 2)
        #expect(entries.count == 1)
        #expect(entries[0].path == "c.txt")
        #expect(entries[0].isConflict)
        #expect(!entries[0].hasStagedChange && !entries[0].hasUnstagedChange)
    }

    @Test func pathWithMultipleSpacesStaysWhole() {
        let (_, entries) = parse("1 .M N... 100644 100644 100644 aaa bbb a  b   c.txt\0")
        #expect(entries.first?.path == "a  b   c.txt")
    }

    @Test func diffTreeRenameListsTheOldPathFirst() {
        let changes = NameStatusParser.parse(Data("A\0Cà Phê Tý Mập.txt\0D\0gone.txt\0M\0keep.txt\0R100\0old name.txt\0new name.txt\0".utf8))
        #expect(changes.map(\.change) == [.added, .deleted, .modified, .renamed])
        #expect(changes[3].path == "new name.txt")
        #expect(changes[3].originalPath == "old name.txt")
        #expect(changes[0].path == "Cà Phê Tý Mập.txt")
    }
}

@Suite struct RepositoryStateTests {
    @Test(arguments: [
        ("rebase-merge", RepositoryState.rebasing), ("rebase-apply", .rebasing), ("MERGE_HEAD", .merging),
        ("CHERRY_PICK_HEAD", .cherryPicking), ("REVERT_HEAD", .reverting), ("BISECT_LOG", .bisecting),
    ])
    func detectsFromTheGitDirectory(marker: String, expected: RepositoryState) throws {
        let dir = TempRepository.tempRoot.appendingPathComponent("state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(RepositoryState.detect(gitDirectory: dir) == .normal)
        FileManager.default.createFile(atPath: dir.appendingPathComponent(marker).path, contents: Data())
        #expect(RepositoryState.detect(gitDirectory: dir) == expected)
        #expect(expected.abortArguments != nil)
    }
}
