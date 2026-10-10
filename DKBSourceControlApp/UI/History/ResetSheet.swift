import DKBSourceControlCore
import SwiftUI

/// Reset the branch to a commit (plan: history actions §3.2): how many
/// commits leave it and whether some were pushed; Soft, Mixed or Hard. Hard
/// is asked about once more, and stashes every change before it runs.
struct ResetSheet: View {
    let history: HistoryModel
    let commit: Commit
    @State private var mode = ResetMode.mixed
    @State private var counts: (total: Int, notOnRemote: Int)?
    @State private var confirmingHard = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if let branch = history.model.status?.head.branch {
                    Text("Reset “\(branch)” to \(commit.shortOID)?")
                } else {
                    Text("Reset HEAD to \(commit.shortOID)?")
                }
            }
            .font(.headline)
            Text(verbatim: commit.title).foregroundStyle(.secondary).lineLimit(2)
            if let counts {
                Text("Commits that leave the branch: \(counts.total)")
                if counts.notOnRemote < counts.total {
                    Label("Already pushed: \(counts.total - counts.notOnRemote). The branch will be behind the remote: Push will be refused, and Pull brings them back.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Picker("Mode", selection: $mode) {
                option("Soft", detail: "Keep their changes, staged.").tag(ResetMode.soft)
                option("Mixed", detail: "Keep their changes, not staged.").tag(ResetMode.mixed)
                option("Hard", detail: "Discard their changes and every uncommitted change. Uncommitted changes and untracked files are stashed first.")
                    .tag(ResetMode.hard)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Reset") {
                    if mode == .hard {
                        confirmingHard = true
                    } else {
                        run()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { counts = try? await history.model.repository.commitsAfter(commit.oid) }
        .confirmationDialog("Discard the commits and every uncommitted change?", isPresented: $confirmingHard) {
            Button("Reset", role: .destructive, action: run)
            // Spelled out: the one SwiftUI adds is in the system's language, not the app's.
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Uncommitted changes go to a stash first (Branches › Stashes). The commits can still be found with git reflog.")
        }
    }

    private func option(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    private func run() {
        let mode = mode
        dismiss()
        Task { await history.reset(to: commit, mode: mode) }
    }
}
