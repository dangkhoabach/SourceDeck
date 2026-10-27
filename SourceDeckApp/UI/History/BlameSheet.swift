import SourceDeckCore
import SwiftUI

/// Who last changed each line of a file, in
/// the working copy or at a commit. The commit is named on the first line
/// of each run of its lines; clicking it shows it in the file's history.
struct BlameSheet: View {
    let model: RepositoryModel
    let path: String
    let commit: Commit?
    @State private var lines: [BlameLine]?
    @State private var error: Error?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Blame").font(.headline)
                Text(verbatim: path).lineLimit(1).truncationMode(.head)
                if let commit {
                    Text("at \(commit.shortOID)").foregroundStyle(.secondary)
                } else {
                    Text("in the working copy").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, idealWidth: 960, minHeight: 420, idealHeight: 600)
        .task {
            do {
                lines = try await model.repository.blame(path: path, at: commit?.oid)
            } catch {
                self.error = error
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            GitErrorBanner(error: error).padding(12).frame(maxHeight: .infinity, alignment: .top)
        } else if let lines {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        row(line, startsRun: index == 0 || lines[index - 1].oid != line.oid)
                    }
                }
                .padding(.vertical, 4)
            }
            .font(.system(.callout, design: .monospaced))
        } else {
            SkeletonCode(lines: 24, gutter: 120)
        }
    }

    private func row(_ line: BlameLine, startsRun: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if !startsRun {
                    Color.clear
                } else if line.isCommitted {
                    Button {
                        model.history.showCommit(line.oid, inHistoryOf: path)
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Text(verbatim: line.shortOID).foregroundStyle(Color.accentColor)
                            Text(verbatim: line.author).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(line.date, format: .dateTime.year().month().day()).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(Text(verbatim: line.summary))
                } else {
                    Text("Not committed yet").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .frame(width: 260, alignment: .leading)
            Text(verbatim: "\(line.number)")
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.top, startsRun ? 3 : 0)
        .overlay(alignment: .top) {
            if startsRun { Divider().opacity(0.5) }
        }
    }
}
