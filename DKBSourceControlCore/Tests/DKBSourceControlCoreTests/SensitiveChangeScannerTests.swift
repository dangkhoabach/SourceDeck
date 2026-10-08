import Foundation
import Testing
@testable import DKBSourceControlCore

/// Fake secrets, each split in two so this source file never holds a
/// complete secret-shaped string for GitHub secret scanning to flag.
enum FakeSecret {
    static let privateKey = "-----BEGIN " + "PRIVATE KEY-----"
    static let opensshKey = "-----BEGIN OPENSSH " + "PRIVATE KEY-----"
    static let resend = "re" + "_AbCd1234_EfGhIjKlMnOpQrStUv"
    static let gitHub = "gh" + "p_abcdefghijklmnopqrstuvwxyz0123456789"
    static let gitHubFineGrained = "github" + "_pat_11ABCDEFG0123456789_abcdefghijklmnop"
    static let aws = "AK" + "IAIOSFODNN7EXAMPLE"
    static let openAI = "sk" + "-proj-abcdefghijklmnopqrstuvwx"
    static let anthropic = "sk" + "-ant-api03-abcdefghijklmnopqrstuvwxyz"
    static let slack = "xo" + "xb-1234567890-abcdefghij"
    static let google = "AI" + "zaSyA1234567890abcdefghijklmnopqrstuv"
}

/// One positive and one negative case per rule (plan F4b).
@Suite struct SensitiveChangeScannerTests {
    private func pathRule(_ path: String) -> SensitiveRule? {
        SensitiveChangeScanner.scan(stagedPaths: [path], stagedDiffs: []).first?.rule
    }

    private func contentRules(_ line: String) -> [SensitiveRule] {
        let file = DiffFile(oldPath: "a.swift", newPath: "a.swift", change: .modified, isBinary: false, isTooLarge: false,
                            headerLines: [], hunks: [DiffHunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: 1, section: "",
                                                              lines: [DiffLine(kind: .added, text: line, oldLine: nil, newLine: 7)])])
        return SensitiveChangeScanner.scan(stagedPaths: [], stagedDiffs: [file]).map(\.rule)
    }

    @Test(arguments: [
        (".env", SensitiveRule.environmentFile), ("deploy/.env", .environmentFile), ("web/.env.production", .environmentFile),
        ("certs/server.pem", .privateKeyFile), ("AuthKey_ABC.p8", .privateKeyFile), ("ssh/id_ed25519", .privateKeyFile),
        ("Distribution.p12", .signingIdentityFile), ("app.mobileprovision", .signingIdentityFile), ("release.keystore", .signingIdentityFile),
        ("Local.xcconfig", .localSigningConfig),
        ("config/credentials.json", .credentialsFile), ("app.secrets.json", .credentialsFile),
        ("MyWebsiteAPI/appsettings.Production.json", .environmentSettingsFile),
    ])
    func sensitiveFileNames(path: String, rule: SensitiveRule) {
        #expect(pathRule(path) == rule)
    }

    @Test(arguments: [".env.example", ".env.sample", "deploy/.env.template", "envfile.txt", "id_ed25519.pub", "Local.xcconfig.example",
                      "appsettings.json", "keynote-notes.md", "Package.resolved", "credentials.swift", "monkey.swift"])
    func ordinaryFileNames(path: String) {
        #expect(pathRule(path) == nil)
    }

    static let secretLines: [(String, SensitiveRule)] = [
        (FakeSecret.privateKey, SensitiveRule.privateKeyBlock),
        (FakeSecret.opensshKey, .privateKeyBlock),
        ("RESEND_API_KEY=" + FakeSecret.resend, .resendAPIKey),
        ("token: " + FakeSecret.gitHub, .gitHubToken),
        (FakeSecret.gitHubFineGrained, .gitHubToken),
        ("aws_access_key_id = " + FakeSecret.aws, .awsAccessKey),
        ("OPENAI_API_KEY=" + FakeSecret.openAI, .secretKeyToken),
        ("key = \"" + FakeSecret.anthropic + "\"", .secretKeyToken),
        ("SLACK=" + FakeSecret.slack, .slackToken),
        ("maps: " + FakeSecret.google, .googleAPIKey),
        ("\"Password\": \"hunter2hunter2\"", .passwordAssignment),
        ("DB_PASSWORD='s3cr3tvalue'", .passwordAssignment),
    ]

    @Test(arguments: secretLines)
    func secretsInAddedLines(line: String, rule: SensitiveRule) {
        #expect(contentRules(line) == [rule])
    }

    @Test(arguments: [
        "-----BEGIN PUBLIC KEY-----",
        "https://example.com/pre_release_notes_for_version_two",
        "let store_receipt_identifier_value_long = 1",
        "github_pat_",
        "AKIA_TOO_SHORT",
        "let task-runner-configuration-name = 1",
        "xoxb-",
        "AIzaShort",
        "password = \"\"",
        "password = readPassword()",
        "Text(\"Password\")",
    ])
    func ordinaryAddedLines(line: String) {
        #expect(contentRules(line).isEmpty)
    }

    @Test func removedAndContextLinesAreNotScanned() {
        let file = DiffFile(oldPath: "a", newPath: "a", change: .modified, isBinary: false, isTooLarge: false, headerLines: [],
                            hunks: [DiffHunk(oldStart: 1, oldCount: 2, newStart: 1, newCount: 1, section: "", lines: [
                                DiffLine(kind: .removed, text: FakeSecret.privateKey, oldLine: 1, newLine: nil),
                                DiffLine(kind: .context, text: "RESEND=" + FakeSecret.resend, oldLine: 2, newLine: 1),
                            ])])
        #expect(SensitiveChangeScanner.scan(stagedPaths: [], stagedDiffs: [file]).isEmpty)
    }

    @Test func findingCarriesTheLineAndNeverTheWholeSecret() throws {
        let file = DiffFile(oldPath: "deploy/env.txt", newPath: "deploy/env.txt", change: .modified, isBinary: false, isTooLarge: false,
                            headerLines: [], hunks: [DiffHunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: 1, section: "",
                                                              lines: [DiffLine(kind: .added, text: "KEY=" + FakeSecret.resend, oldLine: nil, newLine: 12)])])
        let finding = try #require(SensitiveChangeScanner.scan(stagedPaths: ["deploy/env.txt"], stagedDiffs: [file]).first)
        #expect(finding.path == "deploy/env.txt")
        #expect(finding.line == 12)
        #expect(finding.maskedMatch == "re_A••••••••")
    }
}
