import DKBSourceControlCore
import SwiftUI

/// Local and remote branches and the stashes (plan F7, F8): double-click a
/// branch to switch to it; create from HEAD; delete a merged branch; stash,
/// pop and drop.
struct BranchesView: View {
    @Bindable var branches: BranchesModel
    @State private var selection: String?
    @State private var creating = false
    @State private var newName = ""
    @State private var stashing = false
    @State private var stashMessage = ""
    @State private var deleting: Branch?
    @State private var dropping: Stash?

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
                .disabled(branches.model.status?.isClean != false)
                .help("Put every change, untracked files too, aside in a stash")
                Spacer()
            }
            .padding(10)
            list
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
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first { menu(for: id) }
        } primaryAction: { ids in
            // Double-click switches to a branch; a stash isn't applied that easily.
            if let id = ids.first, let branch = branches.branches.first(where: { $0.id == id }) {
                Task { await branches.requestSwitch(to: branch) }
            }
        }
    }

    @ViewBuilder
    private func menu(for id: String) -> some View {
        if let branch = branches.branches.first(where: { $0.id == id }) {
            Button("Switch to “\(BranchesModel.localName(of: branch))”") { Task { await branches.requestSwitch(to: branch) } }
                .disabled(branch.isHead)
            if !branch.isRemote {
                Button("Delete…", role: .destructive) { deleting = branch }
                    .disabled(branch.isHead)
            }
        } else if let stash = branches.stashes.first(where: { $0.id == id }) {
            Button("Pop") { Task { await branches.pop(stash) } }
            Button("Drop…", role: .destructive) { dropping = stash }
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
