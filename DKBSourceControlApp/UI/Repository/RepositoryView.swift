import DKBSourceControlCore
import SwiftUI

/// One repository: its working copy, diff and commit message (plan F2–F4),
/// with Fetch, Pull and Push on the toolbar (plan F5). Watches the folder
/// while it is on screen.
struct RepositoryView: View {
    let model: RepositoryModel
    @Binding var showsLog: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.operationError {
                GitErrorBanner(error: error, showLog: { showsLog = true }, dismiss: model.dismissOperationError)
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
                WorkingCopyView(model: model)
            } else if let error = model.refreshError {
                GitErrorBanner(error: error).padding(12)
                Spacer(minLength: 0)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .task(id: model.id) { await model.watchFileSystem() }
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
            Task { operation == .push ? await model.push() : await model.run(operation) }
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
}
