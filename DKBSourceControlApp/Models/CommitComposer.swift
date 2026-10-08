import DKBSourceControlCore
import Foundation
import Observation

/// The commit message of one repository and the way to a commit (plan F4,
/// F4b): the draft, kept in the database as it is typed; why Commit can't
/// run yet; the sensitive check; amend; push after.
@MainActor
@Observable
final class CommitComposer {
    /// Why Commit is greyed out, shown under the button (plan §7.3).
    enum Blocker: Equatable {
        case conflicts(Int)
        case nothingStaged
        case emptyMessage
        case message(CommitMessageIssue)
    }

    unowned let model: RepositoryModel
    var draft: CommitDraft {
        didSet { scheduleSave() }
    }
    /// Only offered while HEAD is on no remote (plan D9).
    private(set) var canAmend = false
    var amend = false {
        didSet {
            // Amending usually starts from the message being amended.
            if amend, !oldValue, draft.isEmpty { useHeadMessage() }
        }
    }
    private(set) var isCommitting = false
    /// Findings of the last check; the sheet is up while there are any.
    var findings: [SensitiveFinding] = []
    /// Raw text that doesn't follow the format can't go back to the outline.
    var outlineSwitchFailed = false
    @ObservationIgnored private var pushAfterFindings = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var amendCheckedFor: String?

    init(model: RepositoryModel) {
        self.model = model
        draft = (try? model.drafts.draft(repositoryID: model.id)) ?? CommitDraft()
    }

    var isRaw: Bool {
        get { draft.rawText != nil }
        set {
            if newValue {
                if draft.rawText == nil { draft.rawText = draft.message }
            } else if let outline = draft.outline() {
                draft = outline
            } else {
                outlineSwitchFailed = true
            }
        }
    }

    var issues: [CommitMessageIssue] {
        CommitMessage.validate(draft.message)
    }

    var blockers: [Blocker] {
        var blockers: [Blocker] = []
        if let status = model.status {
            let conflicts = status.entries.count(where: \.isConflict)
            if conflicts > 0 { blockers.append(.conflicts(conflicts)) }
            if status.stagedCount == 0, !amend { blockers.append(.nothingStaged) }
        }
        if draft.isEmpty {
            blockers.append(.emptyMessage)
        } else {
            blockers += issues.filter(\.isBlocking).map(Blocker.message)
        }
        return blockers
    }

    var warnings: [CommitMessageIssue] {
        draft.isEmpty ? [] : issues.filter { !$0.isBlocking }
    }

    /// The last commit's message: as an outline when it follows the
    /// format, as raw text otherwise.
    func useHeadMessage() {
        guard let message = model.lastCommit?.message else { return }
        if let parsed = CommitMessage.parse(message) {
            draft = CommitDraft(parsed, pushAfterCommit: draft.pushAfterCommit)
        } else {
            draft.rawText = message
        }
    }

    /// Read again when HEAD, its upstream or the ahead count changes: a
    /// push makes the same HEAD unamendable.
    func checkAmend() async {
        let head = model.status?.head
        let key = "\(head?.oid ?? "")|\(head?.upstream ?? "")|\(head?.ahead ?? 0)"
        guard key != amendCheckedFor else { return }
        amendCheckedFor = key
        let onRemote = head?.oid == nil ? true : try? await model.repository.isHeadOnRemote()
        canAmend = onRemote == false
        if !canAmend { amend = false }
    }

    // MARK: - Committing

    /// Checks the staged changes for secrets first (plan F4b); findings stop
    /// here and wait in the sheet. Hooks run; their output is in the log.
    func commit(push: Bool, checkingSensitive: Bool = true) async {
        guard blockers.isEmpty, !isCommitting else { return }
        isCommitting = true
        defer { isCommitting = false }
        if checkingSensitive {
            let paths = model.status?.entries.filter(\.hasStagedChange).map(\.path) ?? []
            let found: [SensitiveFinding]
            do {
                found = SensitiveChangeScanner.scan(stagedPaths: paths, stagedDiffs: try await model.repository.stagedDiff())
            } catch {
                await model.write("git diff --cached") { throw error }
                return
            }
            if !found.isEmpty {
                pushAfterFindings = push
                findings = found
                return
            }
        }
        let message = draft.message
        let amend = amend
        let committed = await model.write(amend ? "git commit --amend" : "git commit", logsSuccess: true) { [repository = model.repository] in
            try await repository.commit(message, amend: amend)
        }
        guard committed else { return }
        draft = CommitDraft(pushAfterCommit: draft.pushAfterCommit)
        self.amend = false
        if push { await model.push() }
    }

    /// The sheet's default: take the flagged files out of the commit.
    func unstageFindings() async {
        let paths = Set(findings.map(\.path))
        findings = []
        let entries = model.status?.entries.filter { paths.contains($0.path) } ?? []
        await model.workingCopy.unstage(entries)
    }

    func commitDespiteFindings() async {
        findings = []
        await commit(push: pushAfterFindings, checkingSensitive: false)
    }

    // MARK: - Saving the draft

    /// Half a second after the last keystroke, and right away when the
    /// repository goes off screen.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        try? model.drafts.save(draft, repositoryID: model.id)
    }
}
