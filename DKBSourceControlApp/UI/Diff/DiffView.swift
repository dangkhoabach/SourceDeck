import AppKit
import DKBSourceControlCore
import SwiftUI

/// The selected file's diff (plan F3): line numbers, colours, changed
/// words, and Stage, Unstage or Discard on each hunk or on the lines picked
/// in its gutter. Context and whitespace are chosen above it.
struct DiffView: View {
    @Bindable var workingCopy: WorkingCopyModel
    @State private var discarding: (file: DiffFile, hunk: Int, lines: Set<Int>?)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let row = workingCopy.diffRow {
                    Text(verbatim: row.path)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                DiffOptionsControls(options: $workingCopy.diffOptions)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog(discarding?.lines == nil ? "Discard this hunk?" : "Discard the selected lines?",
                            isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } })) {
            Button("Discard", role: .destructive) {
                guard let discarding else { return }
                Task {
                    if let lines = discarding.lines {
                        await workingCopy.apply(lines: lines, hunk: discarding.hunk, of: discarding.file, mode: .discard)
                    } else {
                        await workingCopy.apply(hunk: discarding.hunk, of: discarding.file, mode: .discard)
                    }
                }
            }
        } message: {
            Text("Their changes in the working copy are lost. This can't be undone.")
        }
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
            DiffFileView(file: file, root: workingCopy.model.record.url,
                         actions: actions(area: area, isUntracked: isUntracked))
                .id(workingCopy.diffRow)
        }
    }

    /// Patches are only built from a diff that is exactly the file, so
    /// not with whitespace ignored; a new file is staged whole.
    private func actions(area: WorkingCopyModel.Area, isUntracked: Bool) -> HunkActions? {
        guard !workingCopy.diffOptions.ignoresWhitespace, !isUntracked else { return nil }
        let modes: [PatchMode] = switch area {
        case .staged: [.unstage]
        case .unstaged: [.discard, .stage]
        case .conflicted: []
        }
        guard !modes.isEmpty else { return nil }
        return HunkActions(modes: modes, selectedLines: workingCopy.selectedLines,
                           toggleLine: { workingCopy.toggleLine($0, hunk: $1) },
                           perform: { mode, file, hunk, lines in
                               if mode == .discard {
                                   discarding = (file, hunk, lines)
                               } else if let lines {
                                   Task { await workingCopy.apply(lines: lines, hunk: hunk, of: file, mode: mode) }
                               } else {
                                   Task { await workingCopy.apply(hunk: hunk, of: file, mode: mode) }
                               }
                           })
    }
}

/// "Ignore Whitespace" and the context picker, shared by the working copy
/// and History.
struct DiffOptionsControls: View {
    @Binding var options: DiffOptions

    var body: some View {
        Toggle("Ignore Whitespace", isOn: $options.ignoresWhitespace)
            .toggleStyle(.checkbox)
            .help("Hide changes that only add or remove spaces. Hunk buttons are off meanwhile: what is shown isn't exactly what is in the file.")
        Picker("Context", selection: $options.context) {
            Text("3 lines").tag(3)
            Text("10 lines").tag(10)
            Text("Whole file").tag(DiffOptions.wholeFile)
        }
        .fixedSize()
        .help("Unchanged lines shown around each change")
    }
}

/// What the hunks of the diff on screen offer: whole hunks, or the lines
/// picked in a hunk's gutter (plan D8). nil for a read-only diff.
struct HunkActions {
    /// In button order: Discard and Stage for Changes, Unstage for Staged.
    let modes: [PatchMode]
    let selectedLines: [Int: Set<Int>]
    let toggleLine: (_ line: Int, _ hunk: Int) -> Void
    /// `lines` nil: the whole hunk.
    let perform: (_ mode: PatchMode, _ file: DiffFile, _ hunk: Int, _ lines: Set<Int>?) -> Void
}

/// One file's diff, or why it can't be shown.
struct DiffFileView: View {
    let file: DiffFile
    let root: URL
    let actions: HunkActions?

    var body: some View {
        if file.isBinary {
            ContentUnavailableView("Binary file", systemImage: "doc.zipper",
                                   description: Text("The file changed, but it isn't text to compare."))
        } else if file.isTooLarge {
            TooLargeView(url: root.appendingPathComponent(file.path))
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
            DiffLines(file: file, actions: actions)
        }
    }
}

/// Every hunk header and line as one flat lazy list, so a long diff only
/// lays out what is on screen.
private struct DiffLines: View {
    let file: DiffFile
    let actions: HunkActions?

    private enum Item {
        case header(Int)
        /// The line, and the one it replaced or was replaced by, for word highlights.
        case line(hunk: Int, index: Int, partner: DiffLine?)
    }

    var body: some View {
        let items = file.hunks.enumerated().flatMap { hunkIndex, hunk in
            let pairs = WordDiff.pairs(in: hunk)
            return [Item.header(hunkIndex)] + hunk.lines.indices.map { index in
                Item.line(hunk: hunkIndex, index: index, partner: pairs[index].map { hunk.lines[$0] })
            }
        }
        let numberWidth = CGFloat(String(Self.largestLine(file)).count) * 8 + 10
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items.indices, id: \.self) { position in
                    switch items[position] {
                    case .header(let index):
                        HunkHeader(file: file, index: index, actions: actions)
                    case .line(let hunk, let index, let partner):
                        let line = file.hunks[hunk].lines[index]
                        let pickable = actions != nil && line.kind != .context && line.kind != .noNewlineMarker
                            && PatchBuilder.supportsLineSelection(file, hunk: hunk)
                        DiffLineRow(line: line, partner: partner, numberWidth: numberWidth,
                                    isPicked: actions?.selectedLines[hunk]?.contains(index) == true,
                                    pick: pickable ? { actions?.toggleLine(index, hunk) } : nil)
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
        let picked = actions?.selectedLines[index] ?? []
        HStack(spacing: 8) {
            Text(verbatim: "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@ \(hunk.section)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let actions {
                ForEach(actions.modes, id: \.self) { mode in
                    Button(title(mode, lines: picked.count)) {
                        actions.perform(mode, file, index, picked.isEmpty ? nil : picked)
                    }
                }
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

    private func title(_ mode: PatchMode, lines: Int) -> LocalizedStringKey {
        switch (mode, lines) {
        case (.stage, 0): "Stage Hunk"
        case (.unstage, 0): "Unstage Hunk"
        case (.discard, 0): "Discard Hunk…"
        case (.stage, _): "Stage Lines (\(lines))"
        case (.unstage, _): "Unstage Lines (\(lines))"
        case (.discard, _): "Discard Lines (\(lines))…"
        }
    }
}

/// Numbers and sign form the gutter; clicking it picks an added or
/// removed line. Words that differ from the paired line are marked.
private struct DiffLineRow: View {
    let line: DiffLine
    let partner: DiffLine?
    let numberWidth: CGFloat
    let isPicked: Bool
    let pick: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            gutter
            if line.kind == .noNewlineMarker {
                Text("No newline at end of file").italic().foregroundStyle(.secondary)
            } else {
                Text(text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .background(background)
    }

    @ViewBuilder
    private var gutter: some View {
        let content = HStack(spacing: 0) {
            number(line.oldLine)
            number(line.newLine)
            Text(verbatim: sign)
                .foregroundStyle(isPicked ? Color.white : signColor)
                .frame(width: 16)
        }
        .background(isPicked ? Color.accentColor : .clear)
        if let pick {
            Button(action: pick) { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("Pick this line to stage, unstage or discard it alone")
        } else {
            content
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(verbatim: value.map(String.init) ?? "")
            .foregroundStyle(isPicked ? AnyShapeStyle(Color.white) : AnyShapeStyle(.tertiary))
            .frame(width: numberWidth, alignment: .trailing)
            .padding(.trailing, 4)
    }

    /// The line with the words its pair doesn't have set on a stronger tint.
    private var text: AttributedString {
        // An empty Text is laid out taller than a line of text.
        var text = AttributedString(line.displayText.isEmpty ? " " : line.displayText)
        guard let partner, line.kind == .added || line.kind == .removed,
              let changes = line.kind == .removed ? WordDiff.changes(old: line.displayText, new: partner.displayText)
                                                    : WordDiff.changes(old: partner.displayText, new: line.displayText) else { return text }
        let tint: Color = line.kind == .added ? .green.opacity(0.35) : .red.opacity(0.35)
        for range in line.kind == .removed ? changes.old : changes.new {
            let start = text.index(text.startIndex, offsetByCharacters: range.lowerBound)
            let end = text.index(start, offsetByCharacters: range.count)
            text[start..<end].backgroundColor = tint
        }
        return text
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
