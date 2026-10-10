import AppKit
import DKBSourceControlCore
import SwiftUI

/// Commits newest first, 200 at a time (plan F6), with search by message,
/// author or path, or one file's history, of HEAD or another branch; the
/// selected commit on the right.
struct HistoryView: View {
    @Bindable var history: HistoryModel
    @FocusState private var searchFocused: Bool
    @State private var newName = ""
    @State private var tagMessage = ""

    /// Anything that changes the list: a commit, a fetch, a new search.
    private struct ReloadKey: Equatable {
        let head: String?
        let upstream: String?
        let ahead: Int
        let behind: Int
        let search: String
        let scope: HistoryModel.SearchScope
        let file: String?
        let revision: String?
    }

    var body: some View {
        let head = history.model.status?.head
        PaneSplit(size: 300...700, idealSize: 440, otherMinSize: 360) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    if let path = history.filePath {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                        Text("History of \(path)")
                            .lineLimit(1)
                            .truncationMode(.head)
                            .help(path)
                        Spacer(minLength: 0)
                        Button("Show All History", systemImage: "xmark.circle.fill") { history.showAllHistory() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Show All History")
                    } else {
                        branchPicker
                        NativeSearchField(text: $history.search, placeholder: String(localized: "Search history", bundle: AppLocale.bundle))
                            .focused($searchFocused)
                        Picker("Search in", selection: $history.scope) {
                            Text("Message").tag(HistoryModel.SearchScope.message)
                            Text("Author").tag(HistoryModel.SearchScope.author)
                            Text("Path").tag(HistoryModel.SearchScope.path)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help("Where to look: commit messages, author names and emails, or a file or folder path")
                        Button("File History…", systemImage: "clock.arrow.circlepath", action: chooseFile)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Choose a file to see every commit that changed it")
                    }
                }
                .frame(minHeight: 22)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                list
            }
        } second: {
            CommitDetailView(history: history)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f")
                .hidden()
        }
        .task(id: ReloadKey(head: head?.oid, upstream: head?.upstream, ahead: head?.ahead ?? 0, behind: head?.behind ?? 0,
                            search: history.search, scope: history.scope, file: history.filePath, revision: history.revision)) {
            await history.reload()
        }
        .task(id: history.selection) { await history.loadFiles() }
        .task(id: history.model.refreshCount) { await history.model.branches.load() }
        .sheet(item: $history.pendingReset) { commit in
            ResetSheet(history: history, commit: commit).environment(\.locale, AppLocale.current.locale)
        }
        .alert("Create Branch", isPresented: present(\.pendingBranch), presenting: history.pendingBranch) { commit in
            TextField("Name", text: $newName)
            Button("Create") { Task { await history.model.branches.create(newName, at: commit) } }
            Button("Cancel", role: .cancel) {}
        } message: { commit in
            Text("Created at \(commit.shortOID) and switched to. Your changes come along.")
        }
        .alert("Create Tag", isPresented: present(\.pendingTag), presenting: history.pendingTag) { commit in
            TextField("Name", text: $newName)
            TextField("Message (optional)", text: $tagMessage)
            Button("Create") { Task { await history.model.branches.createTag(newName, message: tagMessage, at: commit) } }
            Button("Cancel", role: .cancel) {}
        } message: { commit in
            Text("Tags \(commit.shortOID). With a message, the tag is annotated.")
        }
        .alert("You have uncommitted changes", isPresented: present(\.pendingCheckout), presenting: history.pendingCheckout) { commit in
            Button("Stash and Check Out") { Task { await history.checkout(commit, stashingFirst: true) } }
            Button("Cancel", role: .cancel) {}
        } message: { commit in
            Text("Stash them before checking out \(commit.shortOID), or commit them first.")
        }
        .onChange(of: [history.pendingBranch?.oid, history.pendingTag?.oid]) {
            newName = ""
            tagMessage = ""
        }
    }

    /// Whose history: HEAD's, or any local or remote branch's.
    private var branchPicker: some View {
        let branches = history.model.branches
        return Picker("Branch", selection: $history.revision) {
            Text(verbatim: history.model.status?.head.branch ?? "HEAD").tag(String?.none)
            Divider()
            ForEach(branches.local.filter { !$0.isHead }) { Text(verbatim: $0.name).tag(String?.some($0.name)) }
            Divider()
            ForEach(branches.remote) { Text(verbatim: $0.name).tag(String?.some($0.name)) }
        }
        .labelsHidden()
        .frame(maxWidth: 130)
        .help("Whose history: the current branch's or another branch's")
    }

    private func present(_ keyPath: ReferenceWritableKeyPath<HistoryModel, Commit?>) -> Binding<Bool> {
        Binding(get: { history[keyPath: keyPath] != nil }, set: { if !$0 { history[keyPath: keyPath] = nil } })
    }

    /// Any file of the repository, for its history.
    private func chooseFile() {
        let root = history.model.record.url.resolvingSymlinksInPath()
        let panel = NSOpenPanel()
        panel.directoryURL = root
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a file to see every commit that changed it", bundle: AppLocale.bundle)
        guard panel.runModal() == .OK, let url = panel.url?.resolvingSymlinksInPath() else { return }
        guard url.path.hasPrefix(root.path + "/") else { return NSSound.beep() }
        history.showHistory(of: String(url.path.dropFirst(root.path.count + 1)))
    }

    private var list: some View {
        List(selection: $history.selection) {
            ForEach(history.commits) { commit in
                CommitRow(commit: commit)
                    .tag(commit.oid)
                    .contextMenu { CommitMenuItems(history: history, commit: commit) }
            }
            if !history.commits.isEmpty, !history.reachedEnd {
                SkeletonRows(count: 2, icon: 52, secondLine: true, fills: false)
                    // Reaching the end of the list reads the next 200.
                    .onAppear { Task { await history.loadMore() } }
            }
        }
        .overlay {
            if let error = history.loadError {
                GitErrorBanner(error: error).padding(12).frame(maxHeight: .infinity, alignment: .top)
            } else if history.commits.isEmpty, history.isLoading {
                SkeletonRows(count: 12, icon: 52, secondLine: true)
            } else if history.commits.isEmpty, !history.isLoading {
                if history.filePath != nil {
                    ContentUnavailableView("No commits changed this file", systemImage: "clock",
                                           description: Text("It isn't in the history of this branch yet."))
                } else if history.search.isEmpty {
                    ContentUnavailableView("No commits yet", systemImage: "clock",
                                           description: Text("The first commit will show up here."))
                } else {
                    ContentUnavailableView.search(text: history.search)
                }
            }
        }
    }
}

/// SHA, title, refs, author and when; a merge is marked.
private struct CommitRow: View {
    let commit: Commit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                SHABadge(oid: commit.shortOID)
                if commit.isMerge {
                    Image(systemName: "arrow.triangle.merge")
                        .foregroundStyle(.purple)
                        .help("Merge commit")
                }
                Text(verbatim: commit.title).lineLimit(1)
            }
            // Refs on a line of their own: three of them would squeeze the rest.
            let decorations = commit.decorations
            if !decorations.isEmpty {
                HStack(spacing: 4) { ForEach(decorations, id: \.self) { RefChip(ref: $0) } }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
            }
            HStack(spacing: 6) {
                Text(verbatim: commit.authorName).lineLimit(1)
                Spacer(minLength: 0)
                Text(commit.commitDate, format: .relative(presentation: .named))
                    .fixedSize()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// The short SHA each commit is found by, first on its row. On a selected
/// row the tint would vanish into the highlight, so it turns white there.
private struct SHABadge: View {
    let oid: String
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let selected = prominence == .increased
        Text(verbatim: oid)
            .font(.system(.callout, design: .monospaced).weight(.semibold))
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(selected ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.tint.opacity(0.14)),
                        in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
    }
}

/// The checked-out branch with a checkmark, other local branches, remote
/// branches with a cloud, tags with a tag. Only the icon is coloured, so
/// the name stays readable on a selected row.
struct RefChip: View {
    let ref: CommitRef

    var body: some View {
        let (icon, color): (String, Color) = switch ref.kind {
        case .head: ("checkmark.circle.fill", .accentColor)
        case .detachedHead: ("smallcircle.filled.circle", .accentColor)
        case .local: ("arrow.triangle.branch", .green)
        case .remote: ("cloud", .secondary)
        case .tag: ("tag.fill", .orange)
        }
        Label { Text(verbatim: ref.name) } icon: { Image(systemName: icon).foregroundStyle(color) }
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// Copy SHA, copy message, open on GitHub, reuse the message; check it
/// out, branch or tag it; cherry-pick it from another branch, revert it,
/// reset the branch to it.
struct CommitMenuItems: View {
    let history: HistoryModel
    let commit: Commit

    var body: some View {
        Button("Copy SHA") { Self.copy(commit.oid) }
        Button("Copy Message") { Self.copy(commit.message) }
        if let url = history.webURL(of: commit) {
            Link("Open on GitHub", destination: url)
        }
        Divider()
        Button("Use This Message") {
            history.model.composer.use(commit.message)
            history.model.tab = .workingCopy
        }
        if let status = history.model.status {
            let busy = status.state != .normal
            let blocked = busy || status.stagedCount > 0
            let reason: LocalizedStringKey? = busy ? "Finish or abort what is in progress first."
                : status.stagedCount > 0 ? "Commit or unstage the staged changes first." : nil
            Divider()
            if status.head.oid != commit.oid {
                Button("Check Out This Commit") { Task { await history.requestCheckout(commit) } }
                    .disabled(busy)
                    .help("Move HEAD to this commit, on no branch")
            }
            Button("Create Branch Here…") { history.pendingBranch = commit }
                .disabled(busy)
            Button("Create Tag Here…") { history.pendingTag = commit }
            Divider()
            if history.revision != nil, let branch = status.head.branch {
                Button("Cherry-pick into “\(branch)”") { Task { await history.cherryPick(commit) } }
                    .disabled(blocked)
                    .help(reason ?? "Commit this commit's changes again on the current branch, with its message")
            }
            // Another branch's commit is picked, not reverted. Staged changes
            // would end up in the revert's commit.
            if history.revision == nil {
                Button("Revert Commit") { Task { await history.revert(commit) } }
                    .disabled(blocked)
                    .help(reason ?? "Stage the opposite of this commit's changes, to commit from Working Copy")
            }
            if status.head.oid != commit.oid {
                Group {
                    if let branch = status.head.branch {
                        Button("Reset “\(branch)” to Here…") { history.pendingReset = commit }
                    } else {
                        Button("Reset HEAD to Here…") { history.pendingReset = commit }
                    }
                }
                .disabled(busy)
            }
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
