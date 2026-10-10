import DKBSourceControlCore
import SwiftUI

/// Local and remote branches, the stashes and the tags (plan F7, F8):
/// double-click a branch to switch to it; create from HEAD; merge, rename,
/// delete a merged branch; stash, pop and drop; tag, push and delete tags.
struct BranchesView: View {
    @Bindable var branches: BranchesModel
    @State private var selection: String?
    @State private var creating = false
    @State private var newName = ""
    @State private var stashing = false
    @State private var stashMessage = ""
    @State private var deleting: Branch?
    @State private var dropping: Stash?
    @State private var renaming: Branch?
    @State private var tagging = false
    @State private var tagMessage = ""
    @State private var deletingTag: Tag?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    newName = ""
                    creating = true
                } label: {
                    Label("New Branch…", systemImage: "plus")
                }
                .disabled(branches.model.status?.head.isUnborn != false)
                .help("Create a branch from HEAD and switch to it")
                Button {
                    stashMessage = ""
                    stashing = true
                } label: {
                    Label("Stash Changes…", systemImage: "tray.and.arrow.down")
                }
                // git can't stash before the first commit.
                .disabled(branches.model.status?.isClean != false || branches.model.status?.head.isUnborn == true)
                .help("Put every change, untracked files too, aside in a stash")
                Button {
                    newName = ""
                    tagMessage = ""
                    tagging = true
                } label: {
                    Label("New Tag…", systemImage: "tag")
                }
                .disabled(branches.model.lastCommit == nil)
                .help("Tag the last commit")
                Spacer()
                Button {
                    Task { await branches.pushTag(nil) }
                } label: {
                    Label("Push Tags", systemImage: "arrow.up.circle")
                }
                .disabled(branches.tags.isEmpty)
                .help("Send every tag to origin")
            }
            .padding(10)
            if branches.hasLoaded {
                list
            } else {
                SkeletonRows(count: 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: branches.model.refreshCount) { await branches.load() }
        .alert("New Branch", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Create") { Task { await branches.create(newName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Created from HEAD and switched to. Your changes come along.")
        }
        .alert("Stash Changes", isPresented: $stashing) {
            TextField("Message (optional)", text: $stashMessage)
            Button("Stash") { Task { await branches.stash(message: stashMessage) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every change, untracked files too, is put aside and the working copy goes back to the last commit.")
        }
        .alert("You have uncommitted changes", isPresented: Binding(get: { branches.pendingSwitch != nil },
                                                                    set: { if !$0 { branches.pendingSwitch = nil } }),
               presenting: branches.pendingSwitch) { branch in
            Button("Stash and Switch") { Task { await branches.switchTo(branch, stashingFirst: true) } }
            Button("Cancel", role: .cancel) {}
        } message: { branch in
            Text("Stash them before switching to “\(BranchesModel.localName(of: branch))”, or commit them first.")
        }
        .confirmationDialog("Delete the branch “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { branch in
            Button("Delete", role: .destructive) { Task { await branches.delete(branch) } }
        } message: { _ in
            Text("Only a branch whose commits are merged elsewhere is deleted; git keeps any other.")
        }
        .alert("Rename Branch", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { branch in
            TextField("Name", text: $newName)
            Button("Rename") { Task { await branches.rename(branch, to: newName) } }
            Button("Cancel", role: .cancel) {}
        } message: { branch in
            Text("A new name for “\(branch.name)”. Its upstream stays the same.")
        }
        .alert("New Tag", isPresented: $tagging) {
            TextField("Name", text: $newName)
            TextField("Message (optional)", text: $tagMessage)
            Button("Create") {
                if let head = branches.model.lastCommit { Task { await branches.createTag(newName, message: tagMessage, at: head) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tags the last commit. With a message, the tag is annotated.")
        }
        .confirmationDialog("Delete the tag “\(deletingTag?.name ?? "")”?",
                            isPresented: Binding(get: { deletingTag != nil }, set: { if !$0 { deletingTag = nil } }),
                            presenting: deletingTag) { tag in
            Button("Delete", role: .destructive) { Task { await branches.deleteTag(tag) } }
        } message: { _ in
            Text("Only here: a tag already pushed stays on the remote.")
        }
        .confirmationDialog("Drop “\(dropping?.message ?? "")”?",
                            isPresented: Binding(get: { dropping != nil }, set: { if !$0 { dropping = nil } }),
                            presenting: dropping) { stash in
            Button("Drop", role: .destructive) { Task { await branches.drop(stash) } }
        } message: { _ in
            Text("The stashed changes are thrown away. This can't be undone.")
        }
    }

    private var list: some View {
        List(selection: $selection) {
            Section("Local") {
                // A branch with no commit yet has no ref to list.
                if let head = branches.model.status?.head, head.isUnborn {
                    BranchLabel(head: head).foregroundStyle(.secondary)
                }
                ForEach(branches.local) { branch in
                    BranchRow(branch: branch)
                        .tag(branch.id)
                }
            }
            if !branches.remote.isEmpty {
                Section("Remote") {
                    ForEach(branches.remote) { branch in
                        BranchRow(branch: branch)
                            .tag(branch.id)
                    }
                }
            }
            Section("Stashes") {
                if branches.stashes.isEmpty {
                    Text("No stashes").foregroundStyle(.secondary)
                }
                ForEach(branches.stashes) { stash in
                    StashRow(stash: stash)
                        .tag(stash.id)
                }
            }
            Section("Tags") {
                if branches.tags.isEmpty {
                    Text("No tags").foregroundStyle(.secondary)
                }
                ForEach(branches.tags) { tag in
                    TagRow(tag: tag)
                        .tag(tag.id)
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first { menu(for: id) }
        } primaryAction: { ids in
            // Double-click switches to a branch; a stash isn't applied that easily, only shown.
            if let id = ids.first, let branch = branches.branches.first(where: { $0.id == id }) {
                Task { await branches.requestSwitch(to: branch) }
            } else if let id = ids.first, let stash = branches.stashes.first(where: { $0.id == id }) {
                branches.model.inspection = .stash(stash)
            }
        }
    }

    @ViewBuilder
    private func menu(for id: String) -> some View {
        if let branch = branches.branches.first(where: { $0.id == id }) {
            Button("Switch to “\(BranchesModel.localName(of: branch))”") { Task { await branches.requestSwitch(to: branch) } }
                .disabled(branch.isHead)
            Button("Show History") { branches.model.history.showHistory(of: branch) }
            if let status = branches.model.status, !branch.isHead {
                // Staged changes would end up in the merge's commit.
                Button("Merge into “\(status.head.branch ?? "HEAD")”") { Task { await branches.merge(branch) } }
                    .disabled(status.state != .normal || status.stagedCount > 0 || status.head.isUnborn)
                    .help(status.state != .normal ? "Finish or abort what is in progress first."
                          : status.stagedCount > 0 ? "Commit or unstage the staged changes first."
                          : "A fast-forward when possible; otherwise the merge is staged, to commit from Working Copy")
            }
            if !branch.isRemote {
                Divider()
                Button("Rename…") {
                    newName = branch.name
                    renaming = branch
                }
                Button("Delete…", role: .destructive) { deleting = branch }
                    .disabled(branch.isHead)
            }
        } else if let stash = branches.stashes.first(where: { $0.id == id }) {
            Button("Show Changes") { branches.model.inspection = .stash(stash) }
            Divider()
            Button("Apply") { Task { await branches.apply(stash) } }
                .help("Bring the changes back and keep the stash")
            Button("Pop") { Task { await branches.pop(stash) } }
                .help("Bring the changes back and drop the stash")
            Button("Drop…", role: .destructive) { dropping = stash }
        } else if let tag = branches.tags.first(where: { $0.id == id }) {
            Button("Push to origin") { Task { await branches.pushTag(tag) } }
            Button("Copy Name") { CommitMenuItems.copy(tag.name) }
            Divider()
            Button("Delete…", role: .destructive) { deletingTag = tag }
        }
    }
}

/// The checked-out branch in bold with a checkmark; ahead and behind its
/// upstream; an upstream deleted on the remote is said so.
private struct BranchRow: View {
    let branch: Branch

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: branch.isHead ? "checkmark.circle.fill" : branch.isRemote ? "cloud" : "arrow.triangle.branch")
                .foregroundStyle(branch.isHead ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(verbatim: branch.name)
                .fontWeight(branch.isHead ? .semibold : .regular)
                .lineLimit(1)
            if let upstream = branch.upstream {
                Text(verbatim: "→ \(upstream)").foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if branch.upstreamGone {
                Text("upstream deleted").font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 4) {
                if branch.ahead > 0 { Text("↑\(branch.ahead)") }
                if branch.behind > 0 { Text("↓\(branch.behind)") }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }
}

/// Name, its message (or its commit's) and when.
private struct TagRow: View {
    let tag: Tag

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tag").foregroundStyle(.orange).frame(width: 16)
            Text(verbatim: tag.name).lineLimit(1)
            Text(verbatim: tag.subject).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if let date = tag.date {
                Text(date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }
}

private struct StashRow: View {
    let stash: Stash

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full").foregroundStyle(.secondary).frame(width: 16)
            Text(verbatim: stash.message).lineLimit(1)
            Spacer(minLength: 0)
            Text(stash.date, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}
