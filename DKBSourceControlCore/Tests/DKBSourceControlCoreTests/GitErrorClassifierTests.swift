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
        ("fatal: 'origin' does not appear to be a git repository\nfatal: Could not read from remote repository.", .remoteNotFound),
        ("There is no tracking information for the current branch.\nPlease specify which branch you want to merge with.", .noUpstream),
        ("fatal: unable to access 'http://127.0.0.1:9/x.git/': Failed to connect to 127.0.0.1 port 9 after 0 ms: Couldn't connect to server",
         .networkUnreachable),
        ("fatal: unable to access 'https://nothing.invalid/x.git/': Could not resolve host: nothing.invalid", .networkUnreachable),
        ("ssh: Could not resolve hostname nothing.invalid: nodename nor servname provided, or not known\nfatal: Could not read from remote repository.",
         .networkUnreachable),
        ("You are not currently on a branch.\nPlease specify which branch you want to merge with.", .detachedHead),
        ("remote: Repository not found.\nfatal: repository 'https://github.com/o/missing.git/' not found", .repositoryNotFound),
        ("fatal: repository '/nonexistent/repo' does not exist", .repositoryNotFound),
        ("Host key verification failed.\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.",
         .hostKeyUnverified),
        ("error: pathspec 'x' did not match any file(s) known to git", .other),
    ])
    func classifies(output: String, kind: GitCommandError.Kind) {
        #expect(GitErrorClassifier.classify(output) == kind)
    }

    /// The address git asked an account for, from its three messages.
    @Test(arguments: [
        ("fatal: could not read Username for 'https://git.example.com:3000': terminal prompts disabled", "https://git.example.com:3000"),
        ("fatal: could not read Password for 'http://alice@127.0.0.1:55861': terminal prompts disabled", "http://alice@127.0.0.1:55861"),
        ("fatal: Authentication failed for 'http://127.0.0.1:55872/repo.git/'", "http://127.0.0.1:55872/repo.git/"),
        ("remote: Invalid username or token. Password authentication is not supported for Git operations.\nfatal: Authentication failed for 'https://github.com/o/r.git/'",
         "https://github.com/o/r.git/"),
    ])
    func credentialURL(output: String, url: String) {
        let error = GitCommandError(arguments: ["push"], result: GitResult(exitCode: 128, stdout: Data(), stderr: output))
        #expect(error.credentialURL == url)
        #expect(error.needsSignIn)
    }

    /// SSH has no account to type in; a URL in another message is not one git asked about.
    @Test(arguments: [
        "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.",
        "fatal: could not read Username for 'ssh://git@host/x.git': terminal prompts disabled",
        "fatal: unable to access 'https://nothing.invalid/x.git/': Could not resolve host: nothing.invalid",
    ])
    func noSignInWithoutAnHTTPAddress(output: String) {
        let error = GitCommandError(arguments: ["push"], result: GitResult(exitCode: 128, stdout: Data(), stderr: output))
        #expect(error.credentialURL == nil)
        #expect(!error.needsSignIn)
    }

    /// `git merge` prints CONFLICT on stdout, not stderr.
    @Test func stdoutIsPartOfTheOutput() {
        let result = GitResult(exitCode: 1, stdout: Data("CONFLICT (content): Merge conflict in f\n".utf8), stderr: "")
        let error = GitCommandError(arguments: ["merge", "x"], result: result)
        #expect(error.kind == .conflict)
        #expect(error.output == "CONFLICT (content): Merge conflict in f")
    }
}
