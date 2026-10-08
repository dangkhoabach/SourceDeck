import AppKit
import DKBSourceControlCore
import SwiftUI

/// Commits newest first, 200 at a time (plan F6), with search by message,
/// author or path; the selected commit on the right.
struct HistoryView: View {
    @Bindable var history: HistoryModel
    @FocusState private var searchFocused: Bool

    /// Anything that changes the list: a commit, a fetch, a new search.
    private struct ReloadKey: Equatable {
        let head: String?
        let upstream: String?
        let ahead: Int
        let behind: Int
        let search: String
        let scope: HistoryModel.SearchScope
    }

    var body: some View {
        let head = history.model.status?.head
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
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
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                list
            }
            .frame(minWidth: 320, idealWidth: 440, maxWidth: 700)
            CommitDetailView(history: history)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f")
                .hidden()
        }
        .task(id: ReloadKey(head: head?.oid, upstream: head?.upstream, ahead: head?.ahead ?? 0, behind: head?.behind ?? 0,
                            search: history.search, scope: history.scope)) {
            await history.reload()
        }
        .task(id: history.selection) { await history.loadFiles() }
    }

    private var list: some View {
        List(selection: $history.selection) {
            ForEach(history.commits) { commit in
                CommitRow(commit: commit)
                    .tag(commit.oid)
                    .contextMenu { CommitMenuItems(history: history, commit: commit) }
            }
            if !history.commits.isEmpty, !history.reachedEnd {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                // Reaching the end of the list reads the next 200.
                .onAppear { Task { await history.loadMore() } }
            }
        }
        .overlay {
            if let error = history.loadError {
                GitErrorBanner(error: error).padding(12).frame(maxHeight: .infinity, alignment: .top)
            } else if history.commits.isEmpty, !history.isLoading {
                if history.search.isEmpty {
                    ContentUnavailableView("No commits yet", systemImage: "clock",
                                           description: Text("The first commit will show up here."))
                } else {
                    ContentUnavailableView.search(text: history.search)
                }
            }
        }
    }
}

/// Title, refs, short SHA, author and when; a merge is marked.
private struct CommitRow: View {
    let commit: Commit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
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
                Text(verbatim: commit.shortOID).monospaced()
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

/// Copy SHA, copy message, open on GitHub, reuse the message.
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
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
