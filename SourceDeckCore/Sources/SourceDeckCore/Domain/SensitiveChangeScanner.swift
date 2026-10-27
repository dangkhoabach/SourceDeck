import Foundation

/// What `git-rule.md` calls its most important rule: no secrets, keys or
/// `.env` files in a commit. Checked on the staged changes when Commit is
/// pressed; a finding stops the commit until the user unstages
/// the files or explicitly commits anyway.
public enum SensitiveRule: String, CaseIterable, Sendable {
    // File names
    case environmentFile
    case privateKeyFile
    case signingIdentityFile
    case localSigningConfig
    case credentialsFile
    case environmentSettingsFile
    // Added lines
    case privateKeyBlock
    case resendAPIKey
    case gitHubToken
    case awsAccessKey
    case secretKeyToken
    case slackToken
    case googleAPIKey
    case passwordAssignment

    /// Checks added lines rather than file names.
    public var isContentRule: Bool { contentPattern != nil }

    /// Case-insensitive match on the file name (not the folder).
    func matches(fileName name: String) -> Bool {
        let lower = name.lowercased()
        switch self {
        case .environmentFile:
            return lower == ".env" || (lower.hasPrefix(".env.") && ![".env.example", ".env.sample", ".env.template"].contains(lower))
        case .privateKeyFile:
            return [".pem", ".key", ".p8"].contains { lower.hasSuffix($0) }
                || ((lower.hasPrefix("id_rsa") || lower.hasPrefix("id_ed25519") || lower.hasPrefix("id_ecdsa")) && !lower.hasSuffix(".pub"))
        case .signingIdentityFile:
            return [".p12", ".pfx", ".keystore", ".jks", ".mobileprovision"].contains { lower.hasSuffix($0) }
        case .localSigningConfig:
            return lower == "local.xcconfig"
        case .credentialsFile:
            return lower == "credentials.json" || lower.contains(".secret")
        case .environmentSettingsFile:
            // appsettings.Production.json and friends; appsettings.json itself is the shared default.
            return lower.hasPrefix("appsettings.") && lower.hasSuffix(".json") && lower != "appsettings.json"
        default:
            return false
        }
    }

    /// Lookbehinds keep a key-shaped tail of a longer word ("pre_release…",
    /// "task-…") from matching.
    var contentPattern: String? {
        switch self {
        case .privateKeyBlock: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#
        case .resendAPIKey: #"(?<![A-Za-z0-9_])re_[A-Za-z0-9_]{20,}"#
        case .gitHubToken: #"(?<![A-Za-z0-9_])(gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,})"#
        case .awsAccessKey: #"(?<![A-Z0-9])AKIA[0-9A-Z]{16}(?![A-Z0-9])"#
        case .secretKeyToken: #"(?<![A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}"#
        case .slackToken: #"(?<![A-Za-z0-9])xox[abposr]-[A-Za-z0-9-]{10,}"#
        case .googleAPIKey: #"(?<![A-Za-z0-9_-])AIza[0-9A-Za-z_-]{35}"#
        case .passwordAssignment: #"(?i)passw(or)?d["']?\s*[:=]\s*["'][^"'\s]{6,}["']"#
        default: nil
        }
    }
}

public struct SensitiveFinding: Sendable, Equatable {
    public let path: String
    public let rule: SensitiveRule
    /// Line in the new file, for content rules.
    public let line: Int?
    /// The match with all but its first four characters hidden, so the
    /// warning itself never shows the secret.
    public let maskedMatch: String?
}

public enum SensitiveChangeScanner {
    private static let expressions: [(SensitiveRule, NSRegularExpression)] = SensitiveRule.allCases.compactMap { rule in
        rule.contentPattern.map { (rule, try! NSRegularExpression(pattern: $0)) }
    }

    /// - Parameters:
    ///   - stagedPaths: every staged path, including binary files with no diff lines.
    ///   - stagedDiffs: the staged diff of those files; only added lines are read.
    public static func scan(stagedPaths: [String], stagedDiffs: [DiffFile]) -> [SensitiveFinding] {
        var findings: [SensitiveFinding] = []
        for path in stagedPaths {
            if let rule = pathRule(for: path) {
                findings.append(SensitiveFinding(path: path, rule: rule, line: nil, maskedMatch: nil))
            }
        }
        for file in stagedDiffs {
            for hunk in file.hunks {
                for line in hunk.lines where line.kind == .added {
                    let text = line.text
                    let range = NSRange(text.startIndex..., in: text)
                    for (rule, expression) in expressions {
                        guard let match = expression.firstMatch(in: text, range: range),
                              let matched = Range(match.range, in: text) else { continue }
                        findings.append(SensitiveFinding(path: file.path, rule: rule, line: line.newLine,
                                                         maskedMatch: mask(String(text[matched]))))
                    }
                }
            }
        }
        return findings
    }

    /// The file-name rule `path` breaks, if any; the file list marks such
    /// files before they are even staged.
    public static func pathRule(for path: String) -> SensitiveRule? {
        let name = (path as NSString).lastPathComponent
        return SensitiveRule.allCases.first { !$0.isContentRule && $0.matches(fileName: name) }
    }

    static func mask(_ value: String) -> String {
        String(value.prefix(4)) + String(repeating: "•", count: min(8, max(0, value.count - 4)))
    }
}
