import Foundation
import Testing
@testable import DKBSourceControlCore

/// Messages recorded from git 2.54 (`LC_ALL=en_US.UTF-8`).
@Suite struct GitErrorClassifierTests {
    @Test(arguments: [
        ("fatal: could not read Username for 'https://github.com': terminal prompts disabled", GitCommandError.Kind.authenticationFailed),
        ("git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.", .authenticationFailed),
        ("fatal: Unable to create '/r/.git/index.lock': File exists.\n\nAnother git process seems to be running in this repository", .indexLocked),
        ("To /r/remote.git\n ! [rejected]        HEAD -> main (fetch first)\nerror: failed to push some refs to '/r/remote.git'\nhint: Updates were rejected because the remote contains work that you do not", .nonFastForward),
        ("To github.com:o/r.git\n!\tHEAD:refs/heads/main\t[rejected] (non-fast-forward)\nDone", .nonFastForward),
        ("To github.com:o/r.git\n ! [remote rejected] main -> main (protected branch hook declined)", .remoteRejected),
        ("hint: Diverging branches can't be fast-forwarded, you need to either:\nfatal: Not possible to fast-forward, aborting.", .diverged),
        ("error: Your local changes to the following files would be overwritten by checkout:\n\tf\nAborting", .localChangesWouldBeOverwritten),
        ("Auto-merging f\nCONFLICT (content): Merge conflict in f\nAutomatic merge failed; fix conflicts and then commit the result.", .conflict),
        ("error: patch failed: f:1\nerror: f: patch does not apply", .patchDoesNotApply),
        ("error: corrupt patch at <stdin>:13", .patchDoesNotApply),
        ("error: the branch 'topic' is not fully merged", .branchNotFullyMerged),
        ("fatal: not a git repository (or any of the parent directories): .git", .notARepository),
        ("fatal: There is no tracking information for the current branch.", .other),
    ])
    func classifies(output: String, kind: GitCommandError.Kind) {
        #expect(GitErrorClassifier.classify(output) == kind)
    }

    /// `git merge` prints CONFLICT on stdout, not stderr.
    @Test func stdoutIsPartOfTheOutput() {
        let result = GitResult(exitCode: 1, stdout: Data("CONFLICT (content): Merge conflict in f\n".utf8), stderr: "")
        let error = GitCommandError(arguments: ["merge", "x"], result: result)
        #expect(error.kind == .conflict)
        #expect(error.output == "CONFLICT (content): Merge conflict in f")
    }
}
