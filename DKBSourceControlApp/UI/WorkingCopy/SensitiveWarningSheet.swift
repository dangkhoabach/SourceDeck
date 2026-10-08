import DKBSourceControlCore
import SwiftUI

/// git-rule's most important rule, enforced at Commit (plan F4b): the
/// staged changes look like they hold a secret. Unstaging those files is
/// the default; committing anyway is the red, deliberate choice.
struct SensitiveWarningSheet: View {
    let composer: CommitComposer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("This commit may contain secrets", systemImage: "exclamationmark.shield.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.red)
            Text("Secrets, keys and .env files must be ignored, never committed. These staged changes look like one:")
                .fixedSize(horizontal: false, vertical: true)
            List(composer.findings.indices, id: \.self) { index in
                let finding = composer.findings[index]
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: finding.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                    HStack(spacing: 6) {
                        Text(Self.name(of: finding.rule))
                        if let line = finding.line { Text("line \(line)") }
                        if let match = finding.maskedMatch { Text(verbatim: match).monospaced() }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.bordered)
            HStack {
                Button("Cancel", role: .cancel) { composer.findings = [] }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Commit Anyway", role: .destructive) { Task { await composer.commitDespiteFindings() } }
                    .foregroundStyle(.red)
                Button("Unstage These Files") { Task { await composer.unstageFindings() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 380)
    }

    static func name(of rule: SensitiveRule) -> LocalizedStringKey {
        switch rule {
        case .environmentFile: "Environment file (.env)"
        case .privateKeyFile: "Private key file"
        case .signingIdentityFile: "Signing identity or keystore"
        case .localSigningConfig: "Local signing settings"
        case .credentialsFile: "Credentials or secrets file"
        case .environmentSettingsFile: "Environment-specific app settings"
        case .privateKeyBlock: "Private key"
        case .resendAPIKey: "Resend API key"
        case .gitHubToken: "GitHub token"
        case .awsAccessKey: "AWS access key"
        case .secretKeyToken: "Secret API key"
        case .slackToken: "Slack token"
        case .googleAPIKey: "Google API key"
        case .passwordAssignment: "Password in the code"
        }
    }
}
