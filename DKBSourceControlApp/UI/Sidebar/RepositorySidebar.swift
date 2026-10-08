import DKBSourceControlCore
import SwiftUI

/// Dashboard, then the repositories in the user's order (drag to reorder).
/// Dropping folders from Finder adds them.
struct RepositorySidebar: View {
    @Bindable var list: RepositoryList
    @State private var renaming: RepositoryModel?
    @State private var draftName = ""
    @State private var removing: RepositoryModel?

    var body: some View {
        List(selection: $list.selection) {
            Label("Dashboard", systemImage: "square.grid.2x2")
                .tag(RepositoryList.Selection.dashboard)
            Section("Repositories") {
                ForEach(list.models) { model in
                    RepositoryRow(model: model)
                        .tag(RepositoryList.Selection.repository(model.id))
                        .contextMenu {
                            OpenInMenuItems(model: model)
                            Divider()
                            Button("Rename…") {
                                draftName = model.record.name
                                renaming = model
                            }
                            Button("Remove from List…", role: .destructive) { removing = model }
                        }
                }
                .onMove { list.move(fromOffsets: $0, toOffset: $1) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await list.add(urls) }
            return !urls.isEmpty
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("Add Repository…") { list.chooseFoldersToAdd() }
                    Button("Scan Folder…") { list.isScanSheetPresented = true }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a repository or scan a folder for repositories")
                Spacer()
            }
            .padding(10)
        }
        .alert("Rename Repository", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draftName)
            Button("Rename") { if let renaming { list.rename(renaming, to: draftName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty to use the folder name.")
        }
        .confirmationDialog("Remove “\(removing?.record.name ?? "")” from the list?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let removing { list.remove(removing) } }
        } message: {
            Text("The folder and its files stay on disk.")
        }
    }
}

private struct RepositoryRow: View {
    let model: RepositoryModel

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.record.name).lineLimit(1)
                if let head = model.status?.head {
                    BranchLabel(head: head)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if model.runningOperation != nil {
                ProgressView().controlSize(.mini)
            } else if model.refreshError != nil || model.operationError != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if let status = model.status {
                SyncCounts(head: status.head)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !status.isClean {
                    Circle().fill(status.hasConflicts ? .red : .orange).frame(width: 7, height: 7)
                        .help("Uncommitted changes")
                }
            }
        }
    }
}
