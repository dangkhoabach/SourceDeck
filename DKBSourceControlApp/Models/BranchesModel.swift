import DKBSourceControlCore
import Foundation
import Observation

/// Branches and stashes of one repository (plan F7, F8). Just enough to
/// never be stuck: switch, create from HEAD or a commit, rename, merge into
/// the current branch, delete merged (`-d`); stash, pop and drop; tags
/// made, deleted locally and pushed. No rebase or remote deletes.
@MainActor
@Observable
final class BranchesModel {
    unowned let model: RepositoryModel
    private(set) var branches: [Branch] = []
    private(set) var stashes: [Stash] = []
    private(set) var tags: [Tag] = []
    /// Until the first read, empty lists mean nothing yet, not none.
    private(set) var hasLoaded = false
    /// A switch waiting on uncommitted changes: stash them first, or cancel.
    var pendingSwitch: Branch?

    init(model: RepositoryModel) {
        self.model = model
    }

    var local: [Branch] { branches.filter { !$0.isRemote } }
    var remote: [Branch] { branches.filter(\.isRemote) }

    func load() async {
        async let branches = model.repository.branches()
        async let stashes = model.repository.stashes()
        async let tags = model.repository.tags()
        let loaded = (try? await branches, try? await stashes, try? await tags)
        guard !Task.isCancelled else { return }
        if let branches = loaded.0 { self.branches = branches }
        if let stashes = loaded.1 { self.stashes = stashes }
        if let tags = loaded.2 { self.tags = tags }
        hasLoaded = true
    }

    /// Staged or modified tracked files would travel along or block the
    /// switch, so the user is asked to stash them first (plan F7).
    func requestSwitch(to branch: Branch) async {
        guard !branch.isHead else { return }
        let status = model.status
        if (status?.stagedCount ?? 0) + (status?.unstagedCount ?? 0) > 0 {
            pendingSwitch = branch
            return
        }
        await switchTo(branch)
    }

    /// "origin/feature" checks out the local "feature", which git creates
    /// to track it when it doesn't exist yet.
    func switchTo(_ branch: Branch, stashingFirst: Bool = false) async {
        let name = Self.localName(of: branch)
        let repository = model.repository
        if stashingFirst {
            let stashed = await model.write("git stash push --include-untracked", logsSuccess: true) {
                // Stored in the repository, so in English like its commits.
                try await repository.stashPush(message: "Before switching to \(name)")
            }
            guard stashed else { return }
        }
        await model.write("git switch \(name)", logsSuccess: true) { try await repository.switchBranch(name) }
    }

    /// Created from HEAD, or from `commit`, and switched to.
    @discardableResult
    func create(_ name: String, at commit: Commit? = nil) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        return await model.write("git switch -c \(name)\(commit.map { " \($0.shortOID)" } ?? "")", logsSuccess: true) {
            [repository = model.repository] in
            try await repository.createBranch(name, at: commit?.oid)
        }
    }

    /// Annotated when it has a message.
    func createTag(_ name: String, message: String, at commit: Commit) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        await model.write("git tag\(message.isEmpty ? "" : " -a") \(name) \(commit.shortOID)", logsSuccess: true) {
            [repository = model.repository] in
            try await repository.createTag(name, at: commit.oid, message: message)
        }
    }

    /// Into the current branch (plan: history actions §3.6): a fast-forward
    /// when HEAD is behind it; otherwise staged with `MERGE_HEAD`, and the
    /// composer gets a git-rule message to commit it with.
    func merge(_ branch: Branch) async {
        let repository = model.repository
        let fastForward = (try? await repository.canFastForward(to: branch.name)) ?? false
        await model.write("git merge \(fastForward ? "--ff-only" : "--no-commit --no-ff") \(branch.name)", logsSuccess: true) {
            try await repository.merge(branch.name, fastForward: fastForward)
        }
        guard model.status?.state == .merging else { return }
        model.composer.use("+ Update +\n - Merge \(branch.name) into \(model.status?.head.branch ?? "HEAD")")
        model.tab = .workingCopy
    }

    func rename(_ branch: Branch, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != branch.name else { return }
        await model.write("git branch -m \(branch.name) \(name)", logsSuccess: true) { [repository = model.repository] in
            try await repository.renameBranch(branch.name, to: name)
        }
    }

    func deleteTag(_ tag: Tag) async {
        await model.write("git tag -d \(tag.name)", logsSuccess: true) { [repository = model.repository] in
            try await repository.deleteTag(tag.name)
        }
    }

    /// One tag, or all of them when nil.
    func pushTag(_ tag: Tag?) async {
        await model.write("git push origin \(tag.map { "refs/tags/\($0.name)" } ?? "--tags")", logsSuccess: true) {
            [repository = model.repository] in
            try await repository.pushTag(tag?.name)
        }
    }

    func delete(_ branch: Branch) async {
        await model.write("git branch -d \(branch.name)", logsSuccess: true) { [repository = model.repository] in
            try await repository.deleteBranch(branch.name)
        }
    }

    func stash(message: String) async {
        let message = message.trimmingCharacters(in: .whitespaces)
        await model.write("git stash push --include-untracked", logsSuccess: true) { [repository = model.repository] in
            try await repository.stashPush(message: message)
        }
    }

    /// Like pop, but the stash stays.
    func apply(_ stash: Stash) async {
        await model.write("git stash apply \(stash.ref)", logsSuccess: true) { [repository = model.repository] in
            try await repository.stashApply(stash)
        }
    }

    func pop(_ stash: Stash) async {
        await model.write("git stash pop \(stash.ref)", logsSuccess: true) { [repository = model.repository] in
            try await repository.stashPop(stash)
        }
    }

    func drop(_ stash: Stash) async {
        await model.write("git stash drop \(stash.ref)", logsSuccess: true) { [repository = model.repository] in
            try await repository.stashDrop(stash)
        }
    }

    /// The branch name without its remote: "origin/feature/x" → "feature/x".
    static func localName(of branch: Branch) -> String {
        guard branch.isRemote, let slash = branch.name.firstIndex(of: "/") else { return branch.name }
        return String(branch.name[branch.name.index(after: slash)...])
    }
}
