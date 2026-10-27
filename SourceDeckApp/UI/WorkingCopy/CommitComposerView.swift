import SourceDeckCore
import SwiftUI

/// The git-rule commit message: keyword and an outline of
/// details, or raw text; the exact bytes git will get; why Commit can't run
/// yet; amend and push after. ⌘⏎ commits, ⇧⌘⏎ commits and pushes.
struct CommitComposerView: View {
    @Bindable var composer: CommitComposer
    @FocusState private var focusedLine: UUID?
    @State private var showsPreview = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            if composer.isRaw {
                TextEditor(text: Binding(get: { composer.draft.rawText ?? "" }, set: { composer.draft.rawText = $0 }))
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            } else {
                CommitOutlineEditor(draft: $composer.draft, focusedLine: $focusedLine)
            }
            DisclosureGroup("Preview", isExpanded: $showsPreview) {
                CommitPreview(message: composer.draft.message)
            }
            .font(.callout)
            CommitIssues(blockers: composer.blockers, warnings: composer.warnings)
            footer
        }
        .padding(12)
        .sheet(isPresented: Binding(get: { !composer.findings.isEmpty }, set: { if !$0 { composer.findings = [] } })) {
            SensitiveWarningSheet(composer: composer).environment(\.locale, AppLocale.current.locale)
        }
        .alert("The message doesn't follow the format yet", isPresented: $composer.outlineSwitchFailed) {
            Button("OK") {}
        } message: {
            Text("Fix what is listed under the message, or keep writing it as raw text.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Keyword", selection: $composer.draft.keyword) {
                    ForEach(CommitKeyword.allCases, id: \.self) { keyword in
                        (Text(verbatim: keyword.rawValue + " — ") + Text(Self.description(of: keyword))).tag(keyword)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(verbatim: composer.draft.keyword.rawValue)
            }
            .fixedSize()
            .disabled(composer.isRaw)
            .help(Self.description(of: composer.draft.keyword))
            Spacer(minLength: 0)
            if !composer.isRaw {
                Button {
                    indentFocusedLine(true)
                } label: {
                    Image(systemName: "increase.indent")
                }
                .keyboardShortcut("]")
                .help("Make the detail a sub-detail (⇥ or ⌘])")
                Button {
                    indentFocusedLine(false)
                } label: {
                    Image(systemName: "decrease.indent")
                }
                .keyboardShortcut("[")
                .help("Make the sub-detail a detail (⇧⇥ or ⌘[)")
            }
            Picker("Mode", selection: $composer.isRaw) {
                Text("Outline").tag(false)
                Text("Raw").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Menu {
                Button("Use the Last Commit's Message") { composer.useHeadMessage() }
                    .disabled(composer.model.lastCommit == nil)
                Button("Clear Message") { composer.draft = CommitDraft(pushAfterCommit: composer.draft.pushAfterCommit) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .controlSize(.small)
    }

    private var footer: some View {
        let disabled = !composer.blockers.isEmpty || composer.isCommitting
        return HStack(spacing: 12) {
            Toggle("Amend", isOn: $composer.amend)
                .disabled(!composer.canAmend)
                .help(composer.canAmend ? "Replace the last commit instead of adding one"
                                        : "The last commit is already on a remote, so it can't be amended")
            Toggle("Push after", isOn: $composer.draft.pushAfterCommit)
                .help("Push once the commit is made")
            Spacer(minLength: 0)
            if composer.isCommitting { ProgressView().controlSize(.small) }
            Button {
                Task { await composer.commit(push: composer.draft.pushAfterCommit) }
            } label: {
                Text(commitTitle).frame(minWidth: 60)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            // Disabled, the prominent style stays almost as blue; grey says
            // "not yet" next to the reasons below the message.
            .tint(disabled ? .gray : nil)
            .disabled(disabled)
            .help("Commit the staged changes (⌘⏎), or commit and push (⇧⌘⏎)")
            // The same reason the screen shows under the message.
            .accessibilityHint(composer.blockers.first.map { Text(CommitIssues.text($0)) } ?? Text("Commit the staged changes"))
        }
        .toggleStyle(.checkbox)
        .lineLimit(1)
        .background {
            Button("Commit & Push") { Task { await composer.commit(push: true) } }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(disabled)
                .hidden()
        }
    }

    private var commitTitle: LocalizedStringKey {
        switch (composer.amend, composer.draft.pushAfterCommit) {
        case (false, false): "Commit"
        case (false, true): "Commit & Push"
        case (true, false): "Amend"
        case (true, true): "Amend & Push"
        }
    }

    private func indentFocusedLine(_ indent: Bool) {
        guard let id = focusedLine, let index = composer.draft.lines.firstIndex(where: { $0.id == id }) else { return }
        // The first line has no detail to belong to.
        composer.draft.lines[index].isSub = indent && index > 0
    }

    /// git-rule's own descriptions of the keywords.
    static func description(of keyword: CommitKeyword) -> LocalizedStringKey {
        switch keyword {
        case .update: "Update an existing feature"
        case .create: "Create a new feature"
        case .integration: "Integrate a large feature or external system"
        case .remove: "Remove a feature or code"
        case .cleanCode: "Clean up unused code or refactor"
        case .optimize: "Optimize a feature's performance or logic"
        case .fixBug: "Fix one or more bugs"
        case .checklist: "Review and complete a checklist, ready to deploy"
        case .initial: "Initialize the project"
        case .release: "Release a feature to production"
        }
    }
}

/// One text field per detail: ⏎ adds the next one, ⇥ / ⇧⇥ indent and
/// outdent, ⌫ on an empty one removes it; drag to reorder.
private struct CommitOutlineEditor: View {
    @Binding var draft: CommitDraft
    var focusedLine: FocusState<UUID?>.Binding

    var body: some View {
        List {
            ForEach($draft.lines) { $line in
                let index = draft.lines.firstIndex { $0.id == line.id } ?? 0
                HStack(spacing: 6) {
                    Text(verbatim: line.isSub ? "+" : "-")
                        .font(.system(.callout, design: .monospaced).weight(.bold))
                        .foregroundStyle(line.isSub ? .blue : .orange)
                        .padding(.leading, line.isSub ? 18 : 0)
                    TextField(line.isSub ? "Sub-detail" : "Detail", text: $line.text)
                        .textFieldStyle(.plain)
                        .focused(focusedLine, equals: line.id)
                        // Not `onSubmit`: on macOS it also fires when the field
                        // loses focus, which added a line on every click away.
                        .onKeyPress(.return, phases: .down) { press in
                            guard press.modifiers.isEmpty else { return .ignored }
                            insertLine(after: index)
                            return .handled
                        }
                        .onKeyPress(keys: [.tab, Self.backtab], phases: .down) { press in
                            let outdent = press.key == Self.backtab || press.modifiers.contains(.shift)
                            draft.lines[index].isSub = !outdent && index > 0
                            return .handled
                        }
                        .onKeyPress(.delete, phases: .down) { _ in
                            guard line.text.isEmpty, draft.lines.count > 1 else { return .ignored }
                            draft.lines.remove(at: index)
                            focusedLine.wrappedValue = draft.lines[max(0, index - 1)].id
                            return .handled
                        }
                }
            }
            .onMove { draft.lines.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.bordered)
        .alternatingRowBackgrounds(.disabled)
        .frame(minHeight: 70)
    }

    /// Shift-Tab arrives as the back-tab character.
    private static let backtab = KeyEquivalent("\u{19}")

    private func insertLine(after index: Int) {
        let line = CommitDraft.Line(isSub: draft.lines[index].isSub)
        draft.lines.insert(line, at: index + 1)
        focusedLine.wrappedValue = line.id
    }
}

/// The message exactly as git gets it, spaces at the start and end of a
/// line drawn as faint dots so the git-rule indentation can be checked.
private struct CommitPreview: View {
    let message: String

    var body: some View {
        ScrollView {
            Text(attributed)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 110)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for (index, line) in message.components(separatedBy: "\n").enumerated() {
            if index > 0 { result += AttributedString("\n") }
            let leading = line.prefix { $0 == " " }.count
            let body = line.dropFirst(leading)
            let trailing = body.reversed().prefix { $0 == " " }.count
            result += dots(leading)
            result += AttributedString(String(body.dropLast(trailing)))
            result += dots(trailing)
        }
        return result
    }

    private func dots(_ count: Int) -> AttributedString {
        var dots = AttributedString(String(repeating: "·", count: count))
        dots.foregroundColor = .secondary.opacity(0.5)
        return dots
    }
}

/// Why Commit is greyed out, in red; warnings that don't block, in orange.
private struct CommitIssues: View {
    let blockers: [CommitComposer.Blocker]
    let warnings: [CommitMessageIssue]

    var body: some View {
        if !blockers.isEmpty || !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(blockers.indices, id: \.self) { index in
                    Label { Text(Self.text(blockers[index])) } icon: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.red)
                }
                ForEach(warnings.indices, id: \.self) { index in
                    Label { Text(Self.text(warnings[index])) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
        }
    }

    static func text(_ blocker: CommitComposer.Blocker) -> LocalizedStringKey {
        switch blocker {
        case .conflicts(let count): "Resolve the conflicted files first (\(count))"
        case .nothingStaged: "Nothing staged to commit"
        case .emptyMessage: "Write the message"
        case .message(let issue): text(issue)
        }
    }

    static func text(_ issue: CommitMessageIssue) -> LocalizedStringKey {
        switch issue {
        case .invalidHeader: "Line 1 must be “+ Keyword +” with one of the ten keywords"
        case .noDetails: "Add at least one detail"
        case .blankLine(let line): "Line \(line) is blank: git-rule has no blank lines"
        case .malformedLine(let line): "Line \(line) must start with “ - ” (detail) or “  + ” (sub-detail)"
        case .subDetailBeforeDetail(let line): "Line \(line) is a sub-detail with no detail above it"
        case .aiAttribution(let line): "Line \(line) is AI attribution, which git-rule forbids"
        case .mentionsAITool(let line): "Line \(line) names an AI tool: fine if it is about the code"
        case .nonEnglishText(let line): "Line \(line) isn't English: git-rule asks for English, names are fine"
        case .longLine(let line): "Line \(line) is longer than 200 characters"
        }
    }
}
