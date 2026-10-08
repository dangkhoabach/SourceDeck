import Foundation
import Testing
@testable import DKBSourceControlCore

@Suite struct LogParserTests {
    @Test func recordedLogWithMergeAndDecorations() throws {
        let raw = "1bdcf16b0767931afec2562458d728eb324c5a33\u{1f}1c66a017260c9abdfe71a5e117c6cc894836ee17 1010c37406fac343f2b7f33449a20c8fc260a307\u{1f}PoC\u{1f}p@e\u{1f}2026-10-08T19:54:48+07:00\u{1f}2026-10-08T19:54:48+07:00\u{1f}HEAD -> main\u{1f}Merge branch 'feature'\n\0"
            + "1c66a017260c9abdfe71a5e117c6cc894836ee17\u{1f}1bace55aaf78f021f10560adba67be029ac07f7e\u{1f}PoC\u{1f}p@e\u{1f}2026-10-08T19:54:48+07:00\u{1f}2026-10-08T19:54:48+07:00\u{1f}\u{1f}main change\n\0"
            + "1010c37406fac343f2b7f33449a20c8fc260a307\u{1f}1bace55aaf78f021f10560adba67be029ac07f7e\u{1f}PoC\u{1f}p@e\u{1f}2026-10-08T19:54:48+07:00\u{1f}2026-10-08T19:54:48+07:00\u{1f}feature, origin/feature, tag: v1.0\u{1f}feature change\n\0"
        let commits = LogParser.parse(Data(raw.utf8))
        #expect(commits.count == 3)
        #expect(commits[0].isMerge)
        #expect(commits[0].parents.count == 2)
        #expect(commits[0].refs == ["HEAD -> main"])
        #expect(commits[0].message == "Merge branch 'feature'")
        #expect(commits[0].shortOID == "1bdcf16")
        #expect(commits[1].refs.isEmpty)
        #expect(!commits[1].isMerge)
        #expect(commits[2].refs == ["feature", "origin/feature", "tag: v1.0"])
        #expect(commits[0].authorDate == (try Date("2026-10-08T12:54:48Z", strategy: .iso8601)))
    }

    @Test func rootCommitHasNoParents() {
        let raw = "abc\u{1f}\u{1f}A\u{1f}a@e\u{1f}2026-01-01T00:00:00Z\u{1f}2026-01-01T00:00:00Z\u{1f}\u{1f}init\n\0"
        #expect(LogParser.parse(Data(raw.utf8)).first?.parents == [])
    }

    /// The git-rule format has no blank line after the header, so `%s` would
    /// have joined every line; the summary must be the header alone.
    @Test func gitRuleMessageSummaryIsTheHeaderLine() {
        let raw = "abc\u{1f}p\u{1f}A\u{1f}a@e\u{1f}2026-01-01T00:00:00Z\u{1f}2026-01-01T00:00:00Z\u{1f}\u{1f}+ Fix Bug +\n - README.md: the release date is 10/2024, not 09/2024\n\n\0"
        let commit = LogParser.parse(Data(raw.utf8))[0]
        #expect(commit.summary == "+ Fix Bug +")
        #expect(commit.body == " - README.md: the release date is 10/2024, not 09/2024")
        #expect(commit.message == "+ Fix Bug +\n - README.md: the release date is 10/2024, not 09/2024")
    }

    @Test func bodyAfterABlankLine() {
        let raw = "abc\u{1f}p\u{1f}A\u{1f}a@e\u{1f}2026-01-01T00:00:00Z\u{1f}2026-01-01T00:00:00Z\u{1f}\u{1f}second\n\nbody line 1\nbody line 2\n\0"
        let commit = LogParser.parse(Data(raw.utf8))[0]
        #expect(commit.summary == "second")
        #expect(commit.body == "body line 1\nbody line 2")
    }

    @Test func malformedRecordIsSkipped() {
        let raw = "only\u{1f}three\u{1f}fields\0abc\u{1f}\u{1f}A\u{1f}a@e\u{1f}not-a-date\u{1f}2026-01-01T00:00:00Z\u{1f}\u{1f}x\0"
        #expect(LogParser.parse(Data(raw.utf8)).isEmpty)
    }
}

@Suite struct BranchParserTests {
    @Test func recordedRefsWithUpstreamTrackAndHead() {
        let raw = "refs/heads/feature\01010c37406fac343f2b7f33449a20c8fc260a307\0\0\0 \n"
            + "refs/heads/main\01c66a017260c9abdfe71a5e117c6cc894836ee17\0origin/main\0[ahead 2]\0*\n"
            + "refs/remotes/origin/HEAD\050ea8d1c8b8fa75d047ea5b828c5a8782e8b5d38\0\0\0 \n"
            + "refs/remotes/origin/main\050ea8d1c8b8fa75d047ea5b828c5a8782e8b5d38\0\0\0 \n"
        let branches = BranchParser.parse(Data(raw.utf8))
        #expect(branches.map(\.name) == ["feature", "main", "origin/main"])
        #expect(branches[0].upstream == nil && !branches[0].isHead && !branches[0].isRemote)
        #expect(branches[1].isHead && branches[1].upstream == "origin/main" && branches[1].ahead == 2)
        #expect(branches[2].isRemote)
        #expect(branches[1].id == "refs/heads/main" && branches[2].id == "refs/remotes/origin/main")
    }

    @Test(arguments: [
        ("", 0, 0, false), ("[ahead 1]", 1, 0, false), ("[behind 2]", 0, 2, false),
        ("[ahead 1, behind 2]", 1, 2, false), ("[gone]", 0, 0, true),
    ])
    func upstreamTrack(text: String, ahead: Int, behind: Int, gone: Bool) {
        let track = BranchParser.parseTrack(text)
        #expect(track.ahead == ahead && track.behind == behind && track.gone == gone)
    }

    @Test func recordedStashList() {
        let raw = "stash@{0}\u{1f}WIP on main: 1bdcf16 Merge branch 'feature'\u{1f}2026-10-08T19:54:48+07:00\0stash@{1}\u{1f}On main: my stash\u{1f}2026-10-08T19:54:48+07:00\0"
        let stashes = StashParser.parse(Data(raw.utf8))
        #expect(stashes.map(\.ref) == ["stash@{0}", "stash@{1}"])
        #expect(stashes[1].message == "On main: my stash")
    }

    @Test(arguments: [
        ("https://github.com/dangkhoabach/MyWebsite.git", "https://github.com/dangkhoabach/MyWebsite"),
        ("https://github.com/dangkhoabach/MyWebsite", "https://github.com/dangkhoabach/MyWebsite"),
        ("git@github.com:dangkhoabach/DKB-Monitor.git", "https://github.com/dangkhoabach/DKB-Monitor"),
        ("ssh://git@github.com/dangkhoabach/AcmeGroup.git", "https://github.com/dangkhoabach/AcmeGroup"),
    ])
    func gitHubWebURL(raw: String, expected: String) {
        #expect(RemoteURL(raw: raw).gitHubWebURL?.absoluteString == expected)
    }

    @Test func nonGitHubRemoteHasNoWebURL() {
        #expect(RemoteURL(raw: "https://gitlab.com/a/b.git").gitHubWebURL == nil)
        #expect(RemoteURL(raw: "/Users/x/remote.git").gitHubWebURL == nil)
    }
}
