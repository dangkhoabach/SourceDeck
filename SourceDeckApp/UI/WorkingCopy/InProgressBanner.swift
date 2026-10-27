import SourceDeckCore
import SwiftUI

/// A merge, rebase or other operation git left half done: what
/// it is, how many files still conflict, Abort, and the way to Sourcetree
/// to resolve it — this app has no conflict editor.
struct InProgressBanner: View {
    let model: RepositoryModel
    let status: RepositoryStatus
    @State private var confirmingAbort = false

    var body: some View {
        let conflicts = status.entries.count(where: \.isConflict)
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                if conflicts > 0 {
                    Text("Conflicted files: \(conflicts). Resolve them in an editor or Sourcetree, then stage them.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if [.merging, .cherryPicking, .reverting].contains(status.state) {
                    // A revert from History stops here on purpose.
                    Text("Commit to finish it, or abort to go back.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let sourcetree = ExternalApp.installed.first(where: { $0.bundleID == ExternalApp.sourcetree }) {
                Button("Open in Sourcetree") { sourcetree.open(model.record.url) }
            }
            if status.state.abortArguments != nil {
                Button("Abort…") { confirmingAbort = true }
            }
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .confirmationDialog(abortTitle, isPresented: $confirmingAbort) {
            Button("Abort", role: .destructive) {
                let command = "git " + (status.state.abortArguments ?? []).joined(separator: " ")
                Task {
                    await model.write(command, logsSuccess: true) { [repository = model.repository] in
                        try await repository.abortInProgress()
                    }
                }
            }
        } message: {
            Text("The repository goes back to how it was before it started. Conflict resolutions made so far are lost.")
        }
    }

    private var title: LocalizedStringKey {
        switch status.state {
        case .normal: ""
        case .merging: "A merge is in progress"
        case .rebasing: "A rebase is in progress"
        case .cherryPicking: "A cherry-pick is in progress"
        case .reverting: "A revert is in progress"
        case .bisecting: "A bisect is in progress"
        }
    }

    private var abortTitle: LocalizedStringKey {
        switch status.state {
        case .normal: ""
        case .merging: "Abort the merge?"
        case .rebasing: "Abort the rebase?"
        case .cherryPicking: "Abort the cherry-pick?"
        case .reverting: "Abort the revert?"
        case .bisecting: "End the bisect?"
        }
    }
}
