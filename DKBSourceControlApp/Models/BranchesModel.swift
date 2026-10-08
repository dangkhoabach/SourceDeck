import DKBSourceControlCore
import Foundation
import Observation

/// Branches and stashes of one repository (plan F7, F8). Just enough to
/// never be stuck: switch, create from HEAD, delete merged (`-d`), stash,
/// pop and drop. No merge, rebase or remote deletes.
@MainActor
@Observable
final class BranchesModel {
    unowned let model: RepositoryModel
    private(set) var branches: [Branch] = []
    private(set) var stashes: [Stash] = []
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
        let loaded = (try? await branches, try? await stashes)
        guard !Task.isCancelled else { return }
        if let branches = loaded.0 { self.branches = branches }
        if let stashes = loaded.1 { self.stashes = stashes }
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

    /// Created from HEAD and switched to.
    @discardableResult
    func create(_ name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        return await model.write("git switch -c \(name)", logsSuccess: true) { [repository = model.repository] in
            try await repository.createBranch(name)
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
