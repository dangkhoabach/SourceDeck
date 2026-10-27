import SourceDeckCore
import SwiftUI

/// Read-only changes in a sheet: what a stash
/// holds, or a commit's version of a file against the working copy. The
/// file list is left out when there is one file.
struct ChangesSheet: View {
    /// A file and the diff that shows it.
    struct Entry: Identifiable {
        let file: CommitFileChange
        let area: DiffArea

        var id: String { file.path }
    }

    let model: RepositoryModel
    let title: Text
    let load: () async throws -> [Entry]
    @State private var entries: [Entry]?
    @State private var selection: String?
    @State private var diff: DiffFile?
    /// The entry `diff` was read for: another one selected is being read.
    @State private var diffFor: String?
    @State private var error: Error?
    @Environment(\.dismiss) private var dismiss

    private struct DiffKey: Equatable {
        let file: String?
        let options: DiffOptions
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                title.font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                DiffOptionsControls(options: Bindable(model.workingCopy).diffOptions).controlSize(.small)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            if let error {
                GitErrorBanner(error: error).padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if let entries {
                HStack(spacing: 0) {
                    if entries.count > 1 {
                        List(entries, selection: $selection) { entry in
                            HStack(spacing: 6) {
                                StatusLetter(change: entry.file.change)
                                Text(verbatim: entry.file.path).lineLimit(1).truncationMode(.head)
                            }
                        }
                        .frame(width: 260)
                        Divider()
                    }
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                SkeletonCode()
            }
        }
        .frame(minWidth: 760, idealWidth: 1000, minHeight: 440, idealHeight: 620)
        .task {
            do {
                let loaded = try await load()
                entries = loaded
                selection = loaded.first?.id
            } catch {
                self.error = error
            }
        }
        .task(id: DiffKey(file: selection, options: model.workingCopy.diffOptions)) { await loadDiff() }
    }

    @ViewBuilder
    private var detail: some View {
        if selection != nil, diffFor != selection {
            SkeletonCode()
        } else if let diff {
            DiffFileView(file: diff, root: model.record.url, actions: nil).id(selection)
        } else if entries?.isEmpty == true {
            ContentUnavailableView("No changes", systemImage: "checkmark.circle")
        } else if selection != nil {
            ContentUnavailableView("No differences", systemImage: "equal.circle",
                                   description: Text("The working copy has this version of the file."))
        }
    }

    private func loadDiff() async {
        guard let entry = entries?.first(where: { $0.id == selection }) else {
            diff = nil
            diffFor = nil
            return
        }
        let loaded = try? await model.repository.diff(path: entry.file.path, originalPath: entry.file.originalPath,
                                                      area: entry.area, options: model.workingCopy.diffOptions)
        guard !Task.isCancelled else { return }
        diff = loaded
        diffFor = entry.id
    }
}
