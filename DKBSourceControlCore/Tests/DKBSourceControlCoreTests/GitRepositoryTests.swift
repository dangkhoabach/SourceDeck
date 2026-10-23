import Foundation
import Testing
@testable import DKBSourceControlCore

@Suite struct GitRepositoryTests {
    @Test func openResolvesASubfolderToTheTopLevel() async throws {
        let repo = try await TempRepository()
        try repo.write("src/app/main.swift", "x")
        let opened = try await GitRepository.open(repo.url.appendingPathComponent("src/app"), git: repo.git)
        #expect(opened.root.path == repo.url.path)
    }

    @Test func openingAPlainFolderFailsAsNotARepository() async throws {
        let dir = TempRepository.tempRoot.appendingPathComponent("plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect { try await GitRepository.open(dir, git: GitProcess(environment: GitEnvironment())) } throws: { error in
            (error as? GitCommandError)?.kind == .notARepository
        }
    }

    @Test func unbornBranchStageUnstageAndEmptyLog() async throws {
        let repo = try await TempRepository()
        try repo.write("Cà Phê Tý Mập.txt", "xin chào\n")
        var status = try await repo.repository.status()
        #expect(status.head.isUnborn && status.head.branch == "main")
        #expect(status.entries.map(\.path) == ["Cà Phê Tý Mập.txt"] && status.entries[0].isUntracked)
        _ = try await repo.repository.stage(["Cà Phê Tý Mập.txt"])
        status = try await repo.repository.status()
        #expect(status.entries[0].index == .added)
        // No HEAD to restore from: unstage falls back to `rm --cached`.
        _ = try await repo.repository.unstage(["Cà Phê Tý Mập.txt"])
        #expect(try await repo.repository.status().entries[0].isUntracked)
        #expect(try await repo.repository.log().isEmpty)
    }

    @Test func commitStoresTheGitRuleMessageByteForByte() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "a\n")
        _ = try await repo.repository.stage(["a.txt"])
        let message = CommitMessageTests.gitRuleExample
        _ = try await repo.repository.commit(message)
        #expect(try await repo.run("log", "-1", "--format=%B") == message + "\n\n")
        let log = try await repo.repository.log()
        #expect(log.count == 1)
        #expect(log[0].message == message)
        #expect(log[0].summary == "+ Fix Bug +")
        #expect(log[0].refs == ["HEAD -> refs/heads/main"])
        #expect(log[0].decorations == [CommitRef(kind: .head, name: "main")])
        #expect(try await repo.repository.commitFiles(log[0].oid).map(\.path) == ["a.txt"])
        #expect(try await repo.repository.status().isClean)
    }

    @Test func amendRewritesTheLastCommit() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "a\n")
        try await repo.commitAll("first")
        try repo.write("b.txt", "b\n")
        _ = try await repo.repository.stage(["b.txt"])
        _ = try await repo.repository.commit("+ Update +\n - amended", amend: true)
        let log = try await repo.repository.log()
        #expect(log.count == 1)
        #expect(log[0].message == "+ Update +\n - amended")
        #expect(Set(try await repo.repository.commitFiles(log[0].oid).map(\.path)) == ["a.txt", "b.txt"])
    }

    /// GIT_LITERAL_PATHSPECS: a file named like a glob or pathspec magic
    /// means only itself.
    @Test func pathsAreLiteralNotPatterns() async throws {
        let repo = try await TempRepository()
        for name in ["*.txt", "a.txt", ":(exclude)b.txt", "b.txt"] { try repo.write(name, name) }
        _ = try await repo.repository.stage(["*.txt", ":(exclude)b.txt"])
        let staged = try await repo.repository.status().entries.filter(\.hasStagedChange).map(\.path).sorted()
        #expect(staged == ["*.txt", ":(exclude)b.txt"])
    }

    @Test func diffForEveryArea() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.commitAll("init")
        try repo.write("a.txt", "one\nTWO\n")
        try repo.write("new file.txt", "new\n")

        let unstaged = try #require(try await repo.repository.diff(path: "a.txt", area: .unstaged))
        #expect(unstaged.hunks[0].lines.map(\.kind) == [.context, .removed, .added])
        #expect(try await repo.repository.diff(path: "a.txt", area: .staged) == nil)

        let untracked = try #require(try await repo.repository.diff(path: "new file.txt", area: .untracked))
        #expect(untracked.change == .added && untracked.newPath == "new file.txt")

        _ = try await repo.repository.stage(["a.txt"])
        #expect(try await repo.repository.diff(path: "a.txt", area: .staged)?.hunks.count == 1)
        _ = try await repo.repository.commit("+ Update +\n - two")
        let head = try await repo.repository.log()[0].oid
        let shown = try #require(try await repo.repository.diff(path: "a.txt", area: .commit(head)))
        #expect(shown.hunks[0].lines.contains { $0.kind == .added && $0.text == "TWO" })
    }

    @Test func diffContextAndWhitespaceOptions() async throws {
        let repo = try await TempRepository()
        try repo.write("n.txt", (1...40).map { "line \($0)\n" }.joined())
        try await repo.commitAll("init")
        try repo.write("n.txt", (1...40).map { $0 == 20 ? "changed\n" : $0 == 30 ? "line  30\n" : "line \($0)\n" }.joined())

        let three = try #require(try await repo.repository.diff(path: "n.txt", area: .unstaged))
        #expect(three.hunks.count == 2 && three.hunks[0].lines.count == 8)
        let ten = try #require(try await repo.repository.diff(path: "n.txt", area: .unstaged, options: DiffOptions(context: 10)))
        #expect(ten.hunks.count == 1)
        let whole = try #require(try await repo.repository.diff(path: "n.txt", area: .unstaged,
                                                                options: DiffOptions(context: DiffOptions.wholeFile)))
        #expect(whole.hunks.count == 1 && whole.hunks[0].oldCount == 40)
        // Only the change to line 20 is left once spacing is ignored.
        let noSpace = try #require(try await repo.repository.diff(path: "n.txt", area: .unstaged,
                                                                  options: DiffOptions(ignoresWhitespace: true)))
        #expect(noSpace.hunks.count == 1 && noSpace.hunks[0].lines.filter { $0.kind == .added }.map(\.text) == ["changed"])
    }

    /// The sensitive check reads every staged line, even past the viewer's limit.
    @Test func stagedDiffHasEveryFileUnlimited() async throws {
        let repo = try await TempRepository()
        try repo.write("big.txt", (1...25_000).map { "\($0)\n" }.joined())
        try repo.write("small.txt", "x\n")
        _ = try await repo.repository.stage(["big.txt", "small.txt"])
        // Before the first commit too: compared with the empty tree.
        let diffs = try await repo.repository.stagedDiff()
        #expect(diffs.map(\.path) == ["big.txt", "small.txt"])
        #expect(!diffs[0].isTooLarge && diffs[0].hunks[0].lines.count == 25_000)
    }

    @Test func unstagingARenameNeedsBothPaths() async throws {
        let repo = try await TempRepository()
        try repo.write("old name.txt", "a\n")
        try await repo.commitAll("init")
        try await repo.run("mv", "old name.txt", "new name.txt")
        let entry = try #require(try await repo.repository.status().entries.first)
        #expect(entry.index == .renamed && entry.originalPath == "old name.txt")
        _ = try await repo.repository.unstage([entry.originalPath, entry.path].compactMap { $0 })
        let status = try await repo.repository.status()
        #expect(status.stagedCount == 0)
        #expect(Set(status.entries.map(\.path)) == ["old name.txt", "new name.txt"])
    }

    @Test func discardKeepsOrDropsTheStagedPart() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "v1\n")
        try await repo.commitAll("init")
        try repo.write("a.txt", "v2\n")
        _ = try await repo.repository.stage(["a.txt"])
        try repo.write("a.txt", "v3\n")
        _ = try await repo.repository.discard(["a.txt"], includingStaged: false)
        #expect(try repo.read("a.txt") == "v2\n")
        _ = try await repo.repository.discard(["a.txt"], includingStaged: true)
        #expect(try repo.read("a.txt") == "v1\n")
        #expect(try await repo.repository.status().isClean)
    }

    @Test func unstageAllEmptiesTheIndex() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "a\n")
        try await repo.commitAll("init")
        try repo.write("a.txt", "b\n")
        try repo.write("c.txt", "c\n")
        _ = try await repo.repository.stage(["a.txt", "c.txt"])
        _ = try await repo.repository.unstageAll()
        #expect(try await repo.repository.status().stagedCount == 0)
    }

    @Test func logFiltersAndPages() async throws {
        let repo = try await TempRepository()
        for i in 1...5 {
            try repo.write("f\(i % 2).txt", "\(i)\n")
            try await repo.commitAll("+ Update +\n - change number \(i)")
        }
        #expect(try await repo.repository.log(limit: 2).count == 2)
        #expect(try await repo.repository.log(limit: 2, skip: 4).count == 1)
        #expect(try await repo.repository.log(grep: "NUMBER 3").map(\.body) == [" - change number 3"])
        #expect(try await repo.repository.log(path: "f0.txt").count == 2)
        #expect(try await repo.repository.log(author: "test").count == 5)
        // A regex character in the search is just a character.
        #expect(try await repo.repository.log(grep: "number .").isEmpty)
    }

    @Test func branchCreateSwitchAndDelete() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "a\n")
        try await repo.commitAll("init")
        _ = try await repo.repository.createBranch("feature")
        #expect(try await repo.repository.status().head.branch == "feature")
        try repo.write("f.txt", "f\n")
        try await repo.commitAll("feature work")
        _ = try await repo.repository.switchBranch("main")
        let branches = try await repo.repository.branches()
        #expect(branches.map(\.name) == ["feature", "main"])
        #expect(branches.first { $0.isHead }?.name == "main")

        await #expect { try await repo.repository.deleteBranch("feature") } throws: { error in
            (error as? GitCommandError)?.kind == .branchNotFullyMerged
        }
        try await repo.run("merge", "-q", "--ff-only", "feature")
        _ = try await repo.repository.deleteBranch("feature")
        #expect(try await repo.repository.branches().map(\.name) == ["main"])
    }

    @Test func switchingWithConflictingLocalChangesIsRefused() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "a\n")
        try await repo.commitAll("init")
        _ = try await repo.repository.createBranch("other")
        try repo.write("a.txt", "other\n")
        try await repo.commitAll("other")
        _ = try await repo.repository.switchBranch("main")
        try repo.write("a.txt", "local\n")
        await #expect { try await repo.repository.switchBranch("other") } throws: { error in
            (error as? GitCommandError)?.kind == .localChangesWouldBeOverwritten
        }
        #expect(try repo.read("a.txt") == "local\n")
    }

    @Test func optionLikeNamesAreRefusedBeforeGitSeesThem() async throws {
        let repo = try await TempRepository()
        await #expect(throws: GitRepositoryError.invalidArgument("--orphan")) { try await repo.repository.createBranch("--orphan") }
        await #expect(throws: GitRepositoryError.invalidArgument("-D")) { try await repo.repository.deleteBranch("-D") }
        await #expect(throws: GitRepositoryError.invalidArgument("--all")) { try await repo.repository.log(revision: "--all") }
    }

    @Test func stashPushPopAndDropIncludeUntrackedFiles() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "a\n")
        try await repo.commitAll("init")
        try repo.write("a.txt", "changed\n")
        try repo.write("new.txt", "new\n")
        _ = try await repo.repository.stashPush(message: "-starts with a dash")
        #expect(try await repo.repository.status().isClean)
        var stashes = try await repo.repository.stashes()
        #expect(stashes.count == 1)
        #expect(stashes[0].message == "On main: -starts with a dash")
        _ = try await repo.repository.stashPop(stashes[0])
        #expect(try repo.read("new.txt") == "new\n")
        _ = try await repo.repository.stashPush(message: "")
        stashes = try await repo.repository.stashes()
        #expect(stashes[0].message.hasPrefix("WIP on main: "))
        _ = try await repo.repository.stashDrop(stashes[0])
        #expect(try await repo.repository.stashes().isEmpty)
    }

    @Test func mergeConflictIsDetectedAndAborted() async throws {
        let repo = try await TempRepository()
        try repo.write("c.txt", "base\n")
        try await repo.commitAll("init")
        _ = try await repo.repository.createBranch("feature")
        try repo.write("c.txt", "feature\n")
        try await repo.commitAll("feature")
        _ = try await repo.repository.switchBranch("main")
        try repo.write("c.txt", "main\n")
        try await repo.commitAll("main")
        _ = try await repo.git.run(["merge", "feature"], in: repo.url)

        let status = try await repo.repository.status()
        #expect(status.state == .merging)
        #expect(status.hasConflicts)
        #expect(status.entries.first?.isConflict == true)

        _ = try await repo.repository.abortInProgress()
        let after = try await repo.repository.status()
        #expect(after.state == .normal && after.isClean)
        #expect(try repo.read("c.txt") == "main\n")
    }

    @Test func mergeCommitFilesComeFromTheFirstParent() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "a\n")
        try await repo.commitAll("init")
        _ = try await repo.repository.createBranch("feature")
        try repo.write("f.txt", "f\n")
        try await repo.commitAll("feature")
        _ = try await repo.repository.switchBranch("main")
        try repo.write("m.txt", "m\n")
        try await repo.commitAll("main")
        try await repo.run("merge", "-q", "--no-edit", "feature")
        let merge = try await repo.repository.log()[0]
        #expect(merge.isMerge)
        #expect(try await repo.repository.commitFiles(merge.oid).map(\.path) == ["f.txt"])
        #expect(try await repo.repository.diff(path: "f.txt", area: .commit(merge.oid))?.change == .added)
    }

    /// Ten stage calls at once: without the write queue some would fail on
    /// `index.lock`.
    /// `.git` is a file pointing elsewhere (`init --separate-git-dir`, as
    /// submodules and linked work trees have): everything still works off
    /// the real git directory.
    @Test func gitDirectoryElsewhere() async throws {
        let base = TempRepository.tempRoot.appendingPathComponent("dkbsc-sep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let git = GitProcess(environment: GitEnvironment())
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        _ = try await git.run(["init", "-q", "-b", "main", "--separate-git-dir", base.appendingPathComponent("meta.git").path, "work"], in: base)
        let work = base.appendingPathComponent("work")
        let repository = try await GitRepository.open(work, git: git)
        #expect(repository.root.path == work.path)
        let gitDirectory = try await repository.gitDirectory()
        #expect(gitDirectory.path == base.appendingPathComponent("meta.git").path)
        try Data("a\n".utf8).write(to: work.appendingPathComponent("a.txt"))
        #expect(try await repository.status().entries.map(\.path) == ["a.txt"])
        try Data().write(to: gitDirectory.appendingPathComponent("MERGE_HEAD"))
        #expect(try await repository.status().state == .merging)
        let filter = WatchFilter(root: work.path, gitDirectory: gitDirectory.path, ignoredDirectories: [])
        #expect(!filter.isRelevant([gitDirectory.appendingPathComponent("objects/ab").path]))
        #expect(filter.isRelevant([gitDirectory.path]))
    }

    /// Plan R6: a lock released meanwhile is waited out; one that stays is reported.
    @Test func aLockedIndexIsTriedOnceMore() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "a\n")
        let lock = repo.url.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        Task {
            try await Task.sleep(for: .milliseconds(100))
            try FileManager.default.removeItem(at: lock)
        }
        _ = try await repo.repository.stage(["a.txt"])
        #expect(try await repo.repository.status().stagedCount == 1)

        try Data().write(to: lock)
        let started = ContinuousClock.now
        await #expect { try await repo.repository.unstage(["a.txt"]) } throws: { error in
            (error as? GitCommandError)?.kind == .indexLocked
        }
        #expect(ContinuousClock.now - started >= GitRepository.lockRetryDelay)
    }

    @Test func concurrentWritesRunOneAtATime() async throws {
        let repo = try await TempRepository()
        for i in 0..<10 { try repo.write("f\(i).txt", "\(i)\n") }
        let repository = repo.repository
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask { _ = try await repository.stage(["f\(i).txt"]) }
            }
            try await group.waitForAll()
        }
        #expect(try await repository.status().stagedCount == 10)
    }

    @Test func remoteURL() async throws {
        let repo = try await TempRepository()
        #expect(try await repo.repository.remoteURL() == nil)
        try await repo.run("remote", "add", "origin", "https://github.com/dangkhoabach/MyWebsite.git")
        #expect(try await repo.repository.remoteURL()?.gitHubWebURL?.absoluteString == "https://github.com/dangkhoabach/MyWebsite")
    }

    @Test func remoteURLsListEveryFetchAndPushAddressOnce() async throws {
        let repo = try await TempRepository()
        #expect(try await repo.repository.remoteURLs().isEmpty)
        try await repo.run("remote", "add", "origin", "https://github.com/o/r.git")
        try await repo.run("remote", "set-url", "--push", "origin", "https://push.example.test:3000/o/r.git")
        try await repo.run("remote", "add", "upstream", "git@github.com:o/r.git")
        try await repo.run("remote", "add", "local", "/Volumes/My Disk/r.git")
        #expect(try await repo.repository.remoteURLs() == [
            "/Volumes/My Disk/r.git", "https://github.com/o/r.git", "https://push.example.test:3000/o/r.git", "git@github.com:o/r.git",
        ])
    }
}

/// Push, fetch and pull against a bare repository on disk — no network.
@Suite struct GitRepositoryRemoteTests {
    @Test func publishPushFetchPullAndRejections() async throws {
        let remote = try await TempRepository(bare: true)
        let mine = try await TempRepository()
        try await mine.run("remote", "add", "origin", remote.url.path)
        try mine.write("a.txt", "1\n")
        try await mine.commitAll("one")

        // First push publishes the branch and sets its upstream.
        #expect(try await mine.repository.isHeadOnRemote() == false)
        _ = try await mine.repository.push(setUpstream: "main")
        #expect(try await mine.repository.isHeadOnRemote())
        var head = try await mine.repository.status().head
        #expect(head.upstream == "origin/main" && head.ahead == 0)

        try mine.write("a.txt", "2\n")
        try await mine.commitAll("two")
        #expect(try await mine.repository.status().head.ahead == 1)
        // A new commit can be amended until it is pushed.
        #expect(try await mine.repository.isHeadOnRemote() == false)
        _ = try await mine.repository.push()
        #expect(try await mine.repository.status().head.ahead == 0)

        // Someone else pushes.
        let theirs = try await TempRepository(cloning: remote)
        try theirs.write("b.txt", "b\n")
        try await theirs.commitAll("theirs")
        _ = try await theirs.repository.push()

        _ = try await mine.repository.fetch()
        head = try await mine.repository.status().head
        #expect(head.behind == 1)
        _ = try await mine.repository.pull(mode: .fastForwardOnly)
        #expect(try mine.read("b.txt") == "b\n")

        // Both sides commit: push is refused, ff-only pull is refused, rebase pull works.
        try theirs.write("b.txt", "theirs 2\n")
        try await theirs.commitAll("theirs 2")
        _ = try await theirs.repository.push()
        try mine.write("a.txt", "3\n")
        try await mine.commitAll("mine 3")
        await #expect { try await mine.repository.push() } throws: { error in
            (error as? GitCommandError)?.kind == .nonFastForward
        }
        await #expect { try await mine.repository.pull(mode: .fastForwardOnly) } throws: { error in
            (error as? GitCommandError)?.kind == .diverged
        }
        _ = try await mine.repository.pull(mode: .rebase)
        _ = try await mine.repository.push()
        head = try await mine.repository.status().head
        #expect(head.ahead == 0 && head.behind == 0)
        #expect(try await mine.repository.log().map(\.message).prefix(2) == ["mine 3", "theirs 2"])
    }

    @Test func cloneChecksOutTheDefaultBranchTrackingOrigin() async throws {
        let remote = try await TempRepository(bare: true)
        let mine = try await TempRepository()
        try await mine.run("remote", "add", "origin", remote.url.path)
        try mine.write("a.txt", "1\n")
        try await mine.commitAll("one")
        _ = try await mine.repository.push(setUpstream: "main")

        let destination = TempRepository.tempRoot.appendingPathComponent("dkbsc-clone-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try await GitRepository.clone(remote.url.path, into: destination, git: mine.git)
        let clone = try await GitRepository.open(destination, git: mine.git)
        #expect(clone.root.path == destination.path)
        let head = try await clone.status().head
        #expect(head.branch == "main" && head.upstream == "origin/main" && head.ahead == 0)
        #expect(try await clone.log().map(\.message) == ["one"])
    }

    @Test func aFetchTellsWhenAndWhatAPullWouldBring() async throws {
        let remote = try await TempRepository(bare: true)
        let mine = try await TempRepository()
        try await mine.run("remote", "add", "origin", remote.url.path)
        try mine.write("a.txt", "1\n")
        try await mine.commitAll("one")
        _ = try await mine.repository.push(setUpstream: "main")
        #expect(await mine.repository.lastFetchDate() == nil)

        let theirs = try await TempRepository(cloning: remote)
        try theirs.write("b.txt", "b\n")
        try await theirs.commitAll("theirs")
        _ = try await theirs.repository.push()
        // Nothing of it is known before a fetch.
        #expect(try await mine.repository.incomingCommits().isEmpty)

        let started = Date.now.addingTimeInterval(-1)
        _ = try await mine.repository.fetch()
        #expect(try #require(await mine.repository.lastFetchDate()) >= started)
        let theirsOID = try await theirs.run("rev-parse", "HEAD").trimmingCharacters(in: .newlines)
        #expect(try await mine.repository.incomingCommits() == [theirsOID])
        #expect(try await mine.repository.log().map(\.message) == ["one"])
        #expect(try await mine.repository.log(includingUpstream: true).map(\.message) == ["theirs", "one"])
    }

    @Test(arguments: [
        ("https://github.com/dangkhoabach/DKB-Source-Control.git", "DKB-Source-Control"),
        ("https://github.com/o/repo", "repo"),
        ("https://github.com/o/repo/", "repo"),
        ("git@github.com:o/repo.git", "repo"),
        ("git@host:repo.git", "repo"),
        ("ssh://git@host:22/o/repo.git/", "repo"),
        ("/Users/x/remote.git", "remote"),
        ("  https://github.com/o/repo.git\n", "repo"),
        ("", ""),
    ])
    func cloneFolderName(url: String, name: String) {
        #expect(GitRepository.cloneFolderName(for: url) == name)
    }

    @Test func failedCloneLeavesNothingBehind() async throws {
        let git = GitProcess(environment: GitEnvironment())
        let destination = TempRepository.tempRoot.appendingPathComponent("dkbsc-clone-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        await #expect { try await GitRepository.clone("/nonexistent/dkbsc-repo", into: destination, git: git) } throws: { error in
            (error as? GitCommandError)?.kind == .repositoryNotFound
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        // A URL that looks like an option is still only a URL.
        let marker = TempRepository.tempRoot.appendingPathComponent("dkbsc-marker-\(UUID().uuidString)")
        await #expect(throws: GitCommandError.self) {
            try await GitRepository.clone("--upload-pack=touch \(marker.path)", into: destination, git: git)
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        // A folder that already has files is refused, and keeps them.
        let remote = try await TempRepository(bare: true)
        let existing = try await TempRepository()
        try existing.write("keep.txt", "x")
        await #expect(throws: GitCommandError.self) {
            try await GitRepository.clone(remote.url.path, into: existing.url, git: git)
        }
        #expect(try existing.read("keep.txt") == "x")
    }
}
