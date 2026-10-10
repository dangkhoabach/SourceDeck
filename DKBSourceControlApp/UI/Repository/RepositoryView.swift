import DKBSourceControlCore
import SwiftUI

/// One repository: its working copy, history or branches (plan F2–F8),
/// with Fetch, Pull and Push on the toolbar (plan F5). Watches the folder
/// while it is on screen, whichever tab is shown.
struct RepositoryView: View {
    let model: RepositoryModel
    @Binding var showsLog: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.operationError {
                GitErrorBanner(error: error, signIn: { Task { await model.askToSignIn() } },
                               showLog: { showsLog = true }, dismiss: model.dismissOperationError)
                    .padding([.horizontal, .top], 12)
            }
            if !model.folderExists {
                ContentUnavailableView {
                    Label("The folder was moved or deleted", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(model.record.path)
                }
            } else if let status = model.status {
                if status.state != .normal {
                    InProgressBanner(model: model, status: status)
                        .padding([.horizontal, .top], 12)
                }
                switch model.tab {
                case .workingCopy: WorkingCopyView(model: model)
                case .history: HistoryView(history: model.history)
                case .branches: BranchesView(branches: model.branches)
                }
            } else if let error = model.refreshError {
                GitErrorBanner(error: error).padding(12)
                Spacer(minLength: 0)
            } else {
                RepositorySkeleton(tab: model.tab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(model.record.name)
        .navigationSubtitle(model.record.path)
        .toolbar { toolbar }
        .confirmationDialog("Publish “\(model.pendingPublish ?? "")” to origin?",
                            isPresented: Binding(get: { model.pendingPublish != nil }, set: { if !$0 { model.pendingPublish = nil } })) {
            Button("Publish") {
                if let branch = model.pendingPublish { Task { await model.run(.push, setUpstream: branch) } }
            }
        } message: {
            Text("The branch has no upstream yet. It will be pushed to origin and tracked from now on.")
        }
        .sheet(item: Bindable(model).inspection) { inspection in
            Group {
                switch inspection {
                case .blame(let path, let commit):
                    BlameSheet(model: model, path: path, commit: commit)
                case .stash(let stash):
                    ChangesSheet(model: model, title: Text(verbatim: stash.message)) { [repository = model.repository] in
                        let files = try await repository.stashFiles(stash)
                        let untracked = GitRepository.untrackedRevision(of: stash)
                        return files.tracked.map { .init(file: $0, area: .commit(stash.ref)) }
                            + files.untracked.map { .init(file: $0, area: .commit(untracked)) }
                    }
                case .compare(let file, let commit):
                    ChangesSheet(model: model, title: Text("\(file.path): \(commit.shortOID) → Working Copy")) {
                        [.init(file: file, area: .workingCopy(since: commit.oid))]
                    }
                }
            }
            .environment(\.locale, AppLocale.current.locale)
        }
        .sheet(item: Bindable(model).pendingSignIn) { request in
            if let signIn = model.signIn {
                SignInSheet(request: request, signIn: signIn).environment(\.locale, AppLocale.current.locale)
            }
        }
        .task(id: model.id) { await model.watchFileSystem() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: Bindable(model).tab) {
                Text("Working Copy").tag(RepositoryModel.Tab.workingCopy)
                Text("History").tag(RepositoryModel.Tab.history)
                Text("Branches").tag(RepositoryModel.Tab.branches)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Working Copy (⌘1), History (⌘2), Branches (⌘3)")
        }
        ToolbarItemGroup {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .help("Read the repository's status again (⌘R)")
            operationButton(.fetch, title: "Fetch", icon: "arrow.down.circle", key: "f",
                            help: "Download new commits from the remote without changing your files (⇧⌘F)")
            operationButton(.pull, title: "Pull", icon: "arrow.down.to.line", key: "l",
                            help: "Bring the remote's new commits into this branch (⇧⌘L)")
            operationButton(.push, title: "Push", icon: "arrow.up.circle", key: "p",
                            help: "Send this branch's new commits to the remote (⇧⌘P)")
            Menu {
                OpenInMenuItems(model: model)
            } label: {
                Label("Open In", systemImage: "arrow.up.forward.app")
            }
            .help("Open the repository in Finder, a terminal, an editor or on GitHub")
        }
    }

    /// The first status read, shaped like the tab it opens on: a list, and
    /// the diff beside it for Working Copy and History.
    private struct RepositorySkeleton: View {
        let tab: RepositoryModel.Tab

        var body: some View {
            HStack(spacing: 0) {
                SkeletonRows(count: 10, icon: tab == .history ? 52 : 14, secondLine: tab == .history)
                    .frame(width: tab == .branches ? nil : 420)
                if tab != .branches {
                    Divider()
                    SkeletonCode()
                }
            }
        }
    }

    private func operationButton(_ operation: RepositoryModel.RemoteOperation, title: LocalizedStringKey, icon: String,
                                 key: KeyEquivalent, help: LocalizedStringKey) -> some View {
        Button {
            Task { operation == .push ? await model.push() : await model.run(operation) }
        } label: {
            if model.runningOperation == operation {
                ProgressView().controlSize(.small)
            } else {
                Label(title, systemImage: icon)
            }
        }
        .keyboardShortcut(key, modifiers: [.command, .shift])
        // Pull and push need a branch; git's own message for a detached HEAD says little.
        .disabled(model.runningOperation != nil || model.status == nil
                  || (operation != .fetch && model.status?.head.isDetached == true))
        .help(operation != .fetch && model.status?.head.isDetached == true
              ? "HEAD isn't on a branch. Switch to a branch in Branches first." : help)
    }
}
