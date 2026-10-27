import Foundation
import Testing
@testable import SourceDeckCore

@Suite struct CommitDraftTests {
    private let example = CommitDraft(keyword: .fixBug, lines: [
        .init(text: "Fix login not returning token"),
        .init(isSub: true, text: "Add null check before serialization"),
        .init(isSub: true, text: "Update response format"),
        .init(text: "Fix timeout when calling third-party API"),
    ])

    @Test func outlineRendersTheGitRuleFormatByteForByte() {
        #expect(Array(example.message.utf8) == Array(CommitMessageTests.gitRuleExample.utf8))
        #expect(CommitMessage.validate(example.message).isEmpty)
    }

    /// ⏎ adds a line before it is typed in; pasted text may carry newlines.
    @Test func emptyLinesAreLeftOutAndEachItemStaysOnOneLine() {
        let draft = CommitDraft(keyword: .update, lines: [
            .init(text: ""), .init(text: "  Plan\nupdated  "), .init(isSub: true, text: "   "), .init(isSub: true, text: "a\r\nb"),
        ])
        #expect(draft.message == "+ Update +\n - Plan updated\n  + a b")
    }

    @Test func rawTextIsSentAsTyped() {
        var draft = example
        draft.rawText = "+ Update +\n - typed  "
        #expect(draft.message == "+ Update +\n - typed  ")
    }

    @Test func rawTextInTheFormatSwitchesBackToAnOutline() throws {
        var draft = CommitDraft(pushAfterCommit: true)
        draft.rawText = CommitMessageTests.gitRuleExample
        let outline = try #require(draft.outline())
        #expect(outline.rawText == nil)
        #expect(outline.lines.map(\.text) == example.lines.map(\.text))
        #expect(outline.lines.map(\.isSub) == example.lines.map(\.isSub))
        #expect(outline.message == CommitMessageTests.gitRuleExample)
        #expect(outline.pushAfterCommit)
    }

    @Test func rawTextOutsideTheFormatCantBecomeAnOutline() throws {
        var draft = CommitDraft()
        draft.rawText = "fix stuff"
        #expect(draft.outline() == nil)
        draft.rawText = " \n"
        #expect(draft.outline()?.isEmpty == true)
        // Outline → raw → outline before any detail was typed.
        draft.rawText = "+ Clean Code +\n"
        let headerOnly = try #require(draft.outline())
        #expect(headerOnly.keyword == .cleanCode && headerOnly.isEmpty && headerOnly.rawText == nil)
        draft.rawText = "+ Nope +"
        #expect(draft.outline() == nil)
    }

    @Test func isEmpty() {
        #expect(CommitDraft().isEmpty)
        #expect(!example.isEmpty)
        #expect(CommitDraft(rawText: "x").isEmpty == false)
    }
}

@Suite struct CommitDraftStoreTests {
    @Test func savesLoadsAndGoesWithItsRepository() throws {
        let database = try AppDatabase.inMemory()
        let repositories = RepositoryStore(dbQueue: database.dbQueue)
        let drafts = CommitDraftStore(dbQueue: database.dbQueue)
        let record = try repositories.add(path: "/Users/x/repo")
        #expect(try drafts.draft(repositoryID: record.id) == nil)

        var draft = CommitDraft(keyword: .create, lines: [.init(text: "Thêm"), .init(isSub: true, text: "sub")], pushAfterCommit: true)
        try drafts.save(draft, repositoryID: record.id)
        #expect(try drafts.draft(repositoryID: record.id) == draft)
        draft.rawText = "+ Create +\n - raw"
        try drafts.save(draft, repositoryID: record.id)
        #expect(try drafts.draft(repositoryID: record.id) == draft)

        try repositories.remove(id: record.id)
        #expect(try drafts.draft(repositoryID: record.id) == nil)
    }
}
