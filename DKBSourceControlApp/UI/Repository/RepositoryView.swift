import DKBSourceControlCore
import SwiftUI

/// One repository: where it stands against its remote, with Fetch, Pull
/// and Push (plan F5). The working copy fills the space below in Phase 4.
struct RepositoryView: View {
    let model: RepositoryModel
    @Binding var showsLog: Bool
    @State private var publishing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = model.operationError {
                GitErrorBanner(error: error, showLog: { showsLog = true }, dismiss: model.dismissOperationError)
            }
            if !model.folderExists {
                ContentUnavailableView {
                    Label("The folder was moved or deleted", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(model.record.path)
                }
            } else if let error = model.refreshError {
                GitErrorBanner(error: error)
            } else if let status = model.status {
                RepositorySummary(model: model, status: status)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(model.record.name)
        .navigationSubtitle(model.record.path)
        .toolbar { toolbar }
        .confirmationDialog("Publish “\(publishing ?? "")” to origin?",
                            isPresented: Binding(get: { publishing != nil }, set: { if !$0 { publishing = nil } })) {
            Button("Publish") { if let publishing { Task { await model.run(.push, setUpstream: publishing) } } }
        } message: {
            Text("The branch has no upstream yet. It will be pushed to origin and tracked from now on.")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
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

    private func operationButton(_ operation: RepositoryModel.RemoteOperation, title: LocalizedStringKey, icon: String,
                                 key: KeyEquivalent, help: LocalizedStringKey) -> some View {
        Button {
            perform(operation)
        } label: {
            if model.runningOperation == operation {
                ProgressView().controlSize(.small)
            } else {
                Label(title, systemImage: icon)
            }
        }
        .keyboardShortcut(key, modifiers: [.command, .shift])
        .disabled(model.runningOperation != nil || model.status == nil)
        .help(help)
    }

    /// A branch that was never published asks first (plan D14).
    private func perform(_ operation: RepositoryModel.RemoteOperation) {
        if operation == .push, let head = model.status?.head, head.upstream == nil, let branch = head.branch, !head.isUnborn {
            publishing = branch
            return
        }
        Task { await model.run(operation) }
    }
}

private struct RepositorySummary: View {
    let model: RepositoryModel
    let status: RepositoryStatus

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                Text("Branch").foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    BranchLabel(head: status.head).fontWeight(.medium)
                    if let upstream = status.head.upstream {
                        Text("→ \(upstream)").foregroundStyle(.secondary)
                    }
                    SyncCounts(head: status.head)
                    StateBadge(state: status.state)
                }
            }
            GridRow {
                Text("Changes").foregroundStyle(.secondary)
                ChangeCounts(status: status)
            }
            if let commit = model.lastCommit {
                GridRow {
                    Text("Last commit").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(commit.title).textSelection(.enabled)
                        HStack(spacing: 6) {
                            Text(commit.shortOID).monospaced()
                            Text("·")
                            Text(commit.authorName)
                            Text("·")
                            Text(commit.commitDate, format: .relative(presentation: .named))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
