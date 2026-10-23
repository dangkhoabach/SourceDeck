import DKBSourceControlCore
import SwiftUI

/// Every repository on one screen (plan F1): what has changes, what is
/// ahead or behind, and one button to fetch them all.
struct DashboardView: View {
    let list: RepositoryList

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 520), spacing: 16)], spacing: 16) {
                ForEach(list.models) { model in
                    Button {
                        list.selection = .repository(model.id)
                    } label: {
                        RepositoryCard(model: model)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        OpenInMenuItems(model: model)
                        Divider()
                        AvatarMenuItems(list: list, model: model)
                    }
                }
            }
            .padding(20)
        }
        .overlay {
            if list.models.isEmpty {
                ContentUnavailableView {
                    Label("No repositories yet", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("Add a repository, scan a folder for them, or drop folders on the sidebar.")
                } actions: {
                    Button("Add Repository…") { list.chooseFoldersToAdd() }
                    Button("Scan Folder…") { list.isScanSheetPresented = true }
                }
            }
        }
        .navigationTitle(String(localized: "Dashboard", bundle: AppLocale.bundle))
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await list.refreshAll() }
                } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .help("Read the status of every repository again (⌘R)")
                Button {
                    Task { await list.fetchAll() }
                } label: {
                    if list.isFetchingAll {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Fetch All", systemImage: "arrow.down.circle")
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(list.isFetchingAll || list.models.isEmpty)
                .help("Fetch every repository from its remote (⇧⌘F)")
            }
        }
    }
}

private struct RepositoryCard: View {
    let model: RepositoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                RepositoryAvatar(model: model, size: 32)
                Text(model.record.name).font(.headline).lineLimit(1)
                Spacer()
                if model.runningOperation != nil || model.isRefreshing {
                    ProgressView().controlSize(.small)
                }
            }
            if let status = model.status {
                HStack(spacing: 8) {
                    Label { BranchLabel(head: status.head) } icon: { Image(systemName: "arrow.triangle.branch") }
                        .lineLimit(1)
                    SyncCounts(head: status.head)
                    Spacer()
                    StateBadge(state: status.state)
                    FetchDate(head: status.head, date: model.lastFetch)
                        .font(.caption)
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                ChangeCounts(status: status)
            }
            if model.status == nil, model.refreshError == nil {
                // Branch, counts and last commit, as they will sit.
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBlock(width: 150, height: 10)
                    SkeletonBlock(width: 90, height: 8)
                    SkeletonBlock(height: 10)
                }
                .padding(.top, 4)
                .skeleton()
            }
            if let commit = model.lastCommit {
                HStack(alignment: .firstTextBaseline) {
                    Text(commit.title).lineLimit(1)
                    Spacer()
                    Text(commit.commitDate, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .font(.callout)
            }
            if !model.folderExists {
                Label("The folder was moved or deleted", systemImage: "folder.badge.questionmark")
                    .font(.caption).foregroundStyle(.red)
            } else if let error = model.refreshError ?? model.operationError {
                Label { Text(GitErrorText.hint(for: error)) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(.caption).foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}
