import SourceDeckCore
import Foundation
import Observation

/// The Working Copy of one repository: which files are
/// listed and selected, the diff of the selected one, and the writes made
/// from the list and the diff.
@MainActor
@Observable
final class WorkingCopyModel {
    enum Area: Hashable {
        case conflicted, staged, unstaged
    }

    /// A row of the list. The same file can be both staged and unstaged
    /// (part of it staged), so the area is part of its identity.
    struct Row: Hashable {
        let area: Area
        let path: String
    }

    enum DiffContent {
        case none
        case several(Int)
        case conflict(String)
        /// Over 2 MB on disk: not read at all.
        case tooLarge(String)
        case file(DiffFile, area: Area, isUntracked: Bool)
        /// Nothing left to show: the change was undone meanwhile.
        case unchanged(String)
        case failed(Error)
    }

    /// What a discard will throw away, waiting for the user to confirm.
    struct DiscardRequest: Identifiable {
        let id = UUID()
        let entries: [StatusEntry]
        /// From the staged list: the staged part goes too.
        let includingStaged: Bool
    }

    unowned let model: RepositoryModel
    var selection: Set<Row> = []
    var search = ""
    var diffOptions: DiffOptions {
        didSet {
            UserDefaults.standard.set(diffOptions.context, forKey: AppSettings.diffContextKey)
            UserDefaults.standard.set(diffOptions.ignoresWhitespace, forKey: AppSettings.diffIgnoresWhitespaceKey)
        }
    }
    private(set) var diff: DiffContent = .none
    /// The row whose diff is shown; the diff view scrolls back to the top
    /// only when this changes, not when the same file is read again.
    private(set) var diffRow: Row?
    /// Lines picked in the diff on screen: hunk index → line indexes
    /// (line mode). Cleared whenever that diff changes.
    var selectedLines: [Int: Set<Int>] = [:]
    var discardRequest: DiscardRequest?
    /// Folders closed in the tree layout, per list: the same folder can be
    /// open under Staged and closed under Changes.
    var collapsedFolders: [Area: Set<String>] = [:]

    static let maxDiffFileSize = 2_000_000

    init(model: RepositoryModel) {
        self.model = model
        diffOptions = AppSettings.diffOptions
    }

    // MARK: - The lists

    /// The entries of one list, narrowed by the search text.
    func entries(_ area: Area) -> [StatusEntry] {
        let all = model.status?.entries ?? []
        let matching = search.isEmpty ? all : all.filter { entry in
            entry.path.localizedCaseInsensitiveContains(search)
                || entry.originalPath?.localizedCaseInsensitiveContains(search) == true
        }
        return switch area {
        case .conflicted: matching.filter(\.isConflict)
        case .staged: matching.filter(\.hasStagedChange)
        case .unstaged: matching.filter(\.hasUnstagedChange)
        }
    }

    func entry(_ row: Row) -> StatusEntry? {
        model.status?.entries.first { $0.path == row.path }
    }

    /// The selected rows of one list, as entries.
    func selectedEntries(_ area: Area, in rows: Set<Row>) -> [StatusEntry] {
        rows.filter { $0.area == area }.compactMap(entry).sorted { $0.path < $1.path }
    }

    // MARK: - Writes

    func stage(_ entries: [StatusEntry]) async {
        guard !entries.isEmpty else { return }
        let paths = entries.map(\.path)
        await model.write("git add -A -- \(Self.list(paths))") { [repository = model.repository] in
            try await repository.stage(paths)
        }
    }

    /// A rename is unstaged by both its paths, or the old one would stay
    /// staged as deleted.
    func unstage(_ entries: [StatusEntry]) async {
        guard !entries.isEmpty else { return }
        let paths = entries.flatMap { [$0.originalPath, $0.path].compactMap { $0 } }
        await model.write("git restore --staged -- \(Self.list(paths))") { [repository = model.repository] in
            try await repository.unstage(paths)
        }
    }

    /// Space on the selection: each row moves to the other list.
    func toggleStage(_ rows: Set<Row>) async {
        await unstage(selectedEntries(.staged, in: rows))
        await stage(selectedEntries(.unstaged, in: rows))
    }

    /// Conflicted files are left out: they are resolved elsewhere.
    func requestDiscard(_ rows: Set<Row>) {
        let staged = selectedEntries(.staged, in: rows)
        let unstaged = selectedEntries(.unstaged, in: rows).filter { entry in !staged.contains { $0.path == entry.path } }
        // From the staged list the whole file goes back to HEAD, so the
        // same file's unstaged row adds nothing.
        if !staged.isEmpty {
            discardRequest = DiscardRequest(entries: staged + unstaged, includingStaged: true)
        } else if !unstaged.isEmpty {
            discardRequest = DiscardRequest(entries: unstaged, includingStaged: false)
        }
    }

    /// Files git would delete for good go to the Trash first:
    /// untracked ones, and with the staged part, newly added files and the
    /// new side of a rename — `restore --source=HEAD` removes those outright.
    func discard(_ request: DiscardRequest) async {
        let toTrash = request.entries.filter { entry in
            entry.isUntracked || (request.includingStaged && [.added, .renamed, .copied].contains(entry.index))
        }.map(\.path)
        let toRestore = request.entries.filter { !$0.isUntracked }.flatMap { entry in
            request.includingStaged ? [entry.originalPath, entry.path].compactMap { $0 } : [entry.path]
        }
        var command: [String] = []
        if !toTrash.isEmpty { command.append(String(localized: "Move to Trash: \(Self.list(toTrash))", bundle: AppLocale.bundle)) }
        if !toRestore.isEmpty {
            command.append("git restore \(request.includingStaged ? "--source=HEAD --staged " : "")--worktree -- \(Self.list(toRestore))")
        }
        let root = model.record.url
        await model.write(command.joined(separator: "\n"), logsSuccess: true) { [repository = model.repository] in
            try TrashService.moveToTrash(toTrash, in: root)
            guard !toRestore.isEmpty else { return OperationOutput() }
            return try await repository.discard(toRestore, includingStaged: request.includingStaged)
        }
    }

    /// Only untracked files: a tracked file stays tracked whatever
    /// `.gitignore` says. The file is edited, not committed.
    func ignore(_ entries: [StatusEntry]) async {
        let paths = entries.filter(\.isUntracked).map(\.path)
        guard !paths.isEmpty else { return }
        let root = model.record.url
        await model.write(String(localized: "Add to .gitignore: \(Self.list(paths))", bundle: AppLocale.bundle), logsSuccess: true) {
            for path in paths { try GitIgnore.append(path: path, root: root) }
            return OperationOutput()
        }
    }

    /// Stage, unstage or discard one hunk of the diff on screen.
    func apply(hunk index: Int, of file: DiffFile, mode: PatchMode) async {
        let patch = PatchBuilder.patch(file, hunks: [index], reverse: mode != .stage)
        let command = switch mode {
        case .stage: "git apply --cached"
        case .unstage: "git apply --cached --reverse"
        case .discard: "git apply --reverse"
        }
        await model.write("\(command) (\(file.path), hunk \(index + 1))", logsSuccess: mode == .discard) { [repository = model.repository] in
            try await repository.applyPatch(patch, mode: mode)
        }
    }

    /// Stage, unstage or discard only the picked lines of one hunk.
    func apply(lines: Set<Int>, hunk index: Int, of file: DiffFile, mode: PatchMode) async {
        guard !lines.isEmpty else { return }
        let patch = PatchBuilder.patch(file, hunk: index, lines: lines, reverse: mode != .stage)
        let command = switch mode {
        case .stage: "git apply --cached"
        case .unstage: "git apply --cached --reverse"
        case .discard: "git apply --reverse"
        }
        await model.write("\(command) (\(file.path), \(lines.count) lines)", logsSuccess: mode == .discard) { [repository = model.repository] in
            try await repository.applyPatch(patch, mode: mode)
        }
    }

    func toggleLine(_ line: Int, hunk: Int) {
        selectedLines[hunk, default: []].formSymmetricDifference([line])
        if selectedLines[hunk]?.isEmpty == true { selectedLines[hunk] = nil }
    }

    // MARK: - The diff

    /// Reads the diff of the selected file. The one on screen stays until
    /// the new one is read, so reading the same file again (after staging a
    /// hunk, or a change on disk) keeps the scroll position.
    func loadDiff() async {
        guard selection.count == 1, let row = selection.first, let entry = entry(row) else {
            diffRow = nil
            diff = selection.count > 1 ? .several(selection.count) : .none
            return
        }
        if row.area == .conflicted {
            show(.conflict(entry.path), for: row)
            return
        }
        // The file on disk stands for the staged copy too: close enough to
        // keep a huge file from being read into the viewer.
        let url = model.record.url.appendingPathComponent(entry.path)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Self.maxDiffFileSize {
            show(.tooLarge(entry.path), for: row)
            return
        }
        let area: DiffArea = row.area == .staged ? .staged : entry.isUntracked ? .untracked : .unstaged
        do {
            let file = try await model.repository.diff(path: entry.path, originalPath: row.area == .staged ? entry.originalPath : nil,
                                                       area: area, options: diffOptions)
            guard !Task.isCancelled else { return }
            show(file.map { .file($0, area: row.area, isUntracked: entry.isUntracked) } ?? .unchanged(entry.path), for: row)
        } catch {
            guard !Task.isCancelled else { return }
            show(.failed(error), for: row)
        }
    }

    /// Another file is selected and its diff isn't read yet. Reading the
    /// same file again keeps its diff on screen instead.
    var isLoadingDiff: Bool {
        guard selection.count == 1, let row = selection.first, entry(row) != nil else { return false }
        return row != diffRow
    }

    private func show(_ content: DiffContent, for row: Row) {
        // Picked lines only mean something in the diff they were picked in.
        var sameDiff = false
        if case .file(let new, _, _) = content, case .file(let old, _, _) = diff { sameDiff = row == diffRow && new == old }
        if !sameDiff { selectedLines = [:] }
        diffRow = row
        diff = content
    }

    /// "a.txt b.txt c.txt … (+3)" for the log: the full list can be long.
    static func list(_ paths: [String]) -> String {
        let shown = paths.prefix(3).joined(separator: " ")
        return paths.count > 3 ? "\(shown) … (+\(paths.count - 3))" : shown
    }
}
