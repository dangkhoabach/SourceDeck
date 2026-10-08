import AppKit
import DKBSourceControlCore
import SwiftUI

/// The selected file's diff (plan F3): line numbers, colours, and Stage,
/// Unstage or Discard on each hunk. Context and whitespace are chosen
/// above it.
struct DiffView: View {
    @Bindable var workingCopy: WorkingCopyModel
    @State private var discardingHunk: (file: DiffFile, index: Int)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog("Discard this hunk?", isPresented: Binding(get: { discardingHunk != nil },
                                                                       set: { if !$0 { discardingHunk = nil } })) {
            Button("Discard", role: .destructive) {
                if let hunk = discardingHunk { Task { await workingCopy.apply(hunk: hunk.index, of: hunk.file, mode: .discard) } }
            }
        } message: {
            Text("Its changes in the working copy are lost. This can't be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let row = workingCopy.diffRow {
                Text(verbatim: row.path)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Toggle("Ignore Whitespace", isOn: $workingCopy.diffOptions.ignoresWhitespace)
                .toggleStyle(.checkbox)
                .help("Hide changes that only add or remove spaces. Hunk buttons are off meanwhile: what is shown isn't exactly what is in the file.")
            Picker("Context", selection: $workingCopy.diffOptions.context) {
                Text("3 lines").tag(3)
                Text("10 lines").tag(10)
                Text("Whole file").tag(DiffOptions.wholeFile)
            }
            .fixedSize()
            .help("Unchanged lines shown around each change")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var content: some View {
        switch workingCopy.diff {
        case .none:
            ContentUnavailableView("No file selected", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Select a file to see its changes."))
        case .several(let count):
            ContentUnavailableView("\(count) files selected", systemImage: "doc.on.doc")
        case .conflict:
            ContentUnavailableView("Conflicted file", systemImage: "exclamationmark.triangle",
                                   description: Text("Resolve it in an editor or Sourcetree, then stage it."))
        case .tooLarge(let path):
            TooLargeView(url: workingCopy.model.record.url.appendingPathComponent(path))
        case .unchanged:
            ContentUnavailableView("No changes left", systemImage: "checkmark.circle",
                                   description: Text("The change was undone meanwhile."))
        case .failed(let error):
            GitErrorBanner(error: error).padding(12).frame(maxHeight: .infinity, alignment: .top)
        case .file(let file, let area, let isUntracked):
            if file.isBinary {
                ContentUnavailableView("Binary file", systemImage: "doc.zipper",
                                       description: Text("The file changed, but it isn't text to compare."))
            } else if file.isTooLarge {
                TooLargeView(url: workingCopy.model.record.url.appendingPathComponent(file.path))
            } else if file.hunks.isEmpty {
                // A mode change or an empty file: only the header says what changed.
                ScrollView {
                    Text(verbatim: file.headerLines.dropFirst().joined(separator: "\n"))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else {
                DiffLines(file: file, actions: hunkActions(area: area, isUntracked: isUntracked))
                    .id(workingCopy.diffRow)
            }
        }
    }

    /// Patches are only built from a diff that is exactly the file, so
    /// not with whitespace ignored; a new file is staged whole.
    private func hunkActions(area: WorkingCopyModel.Area, isUntracked: Bool) -> HunkActions? {
        guard !workingCopy.diffOptions.ignoresWhitespace, !isUntracked else { return nil }
        switch area {
        case .staged:
            return HunkActions(unstage: { file, index in Task { await workingCopy.apply(hunk: index, of: file, mode: .unstage) } })
        case .unstaged:
            return HunkActions(stage: { file, index in Task { await workingCopy.apply(hunk: index, of: file, mode: .stage) } },
                               discard: { file, index in discardingHunk = (file, index) })
        case .conflicted:
            return nil
        }
    }
}

private struct HunkActions {
    var stage: ((DiffFile, Int) -> Void)?
    var unstage: ((DiffFile, Int) -> Void)?
    var discard: ((DiffFile, Int) -> Void)?
}

/// Every hunk header and line as one flat lazy list, so a long diff only
/// lays out what is on screen.
private struct DiffLines: View {
    let file: DiffFile
    let actions: HunkActions?

    private enum Item {
        case header(Int)
        case line(DiffLine)
    }

    var body: some View {
        let items = file.hunks.enumerated().flatMap { index, hunk in
            [Item.header(index)] + hunk.lines.map(Item.line)
        }
        let numberWidth = CGFloat(String(Self.largestLine(file)).count) * 8 + 10
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items.indices, id: \.self) { position in
                    switch items[position] {
                    case .header(let index):
                        HunkHeader(file: file, index: index, actions: actions)
                    case .line(let line):
                        DiffLineRow(line: line, numberWidth: numberWidth)
                    }
                }
            }
            .font(.system(.callout, design: .monospaced))
        }
    }

    private static func largestLine(_ file: DiffFile) -> Int {
        guard let last = file.hunks.last else { return 0 }
        return max(last.oldStart + last.oldCount, last.newStart + last.newCount)
    }
}

private struct HunkHeader: View {
    let file: DiffFile
    let index: Int
    let actions: HunkActions?

    var body: some View {
        let hunk = file.hunks[index]
        HStack(spacing: 8) {
            Text(verbatim: "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@ \(hunk.section)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let discard = actions?.discard {
                Button("Discard Hunk…") { discard(file, index) }
            }
            if let unstage = actions?.unstage {
                Button("Unstage Hunk") { unstage(file, index) }
            }
            if let stage = actions?.stage {
                Button("Stage Hunk") { stage(file, index) }
            }
        }
        .font(.system(.caption, design: .monospaced))
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6))
        .padding(.top, index == 0 ? 0 : 8)
    }
}

private struct DiffLineRow: View {
    let line: DiffLine
    let numberWidth: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            number(line.oldLine)
            number(line.newLine)
            Text(verbatim: sign)
                .foregroundStyle(signColor)
                .frame(width: 16)
            if line.kind == .noNewlineMarker {
                Text("No newline at end of file").italic().foregroundStyle(.secondary)
            } else {
                Text(verbatim: line.displayText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .background(background)
    }

    private func number(_ value: Int?) -> some View {
        Text(verbatim: value.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: numberWidth, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var sign: String {
        switch line.kind {
        case .added: "+"
        case .removed: "-"
        case .context, .noNewlineMarker: " "
        }
    }

    private var signColor: Color {
        line.kind == .added ? .green : line.kind == .removed ? .red : .secondary
    }

    private var background: Color {
        switch line.kind {
        case .added: .green.opacity(0.12)
        case .removed: .red.opacity(0.12)
        case .context, .noNewlineMarker: .clear
        }
    }
}

/// Over the viewer's limit (plan D20): the editor is the place to read it.
private struct TooLargeView: View {
    let url: URL

    var body: some View {
        ContentUnavailableView {
            Label("Too large to show", systemImage: "doc.text")
        } description: {
            Text("Over 2 MB or 20,000 changed lines. Open it in an editor to read it.")
        } actions: {
            Button("Open") { NSWorkspace.shared.open(url) }
        }
    }
}
