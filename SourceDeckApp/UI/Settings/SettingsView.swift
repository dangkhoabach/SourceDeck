import SourceDeckCore
import SwiftUI

/// One `Form` with `.formStyle(.grouped)` and a `Section` per topic, like the
/// other DKB apps' Settings. Every change applies at once.
struct SettingsView: View {
    @AppStorage(ThemePreference.key) private var themeRaw = ThemePreference.system.rawValue
    @AppStorage(AppLocale.key) private var languageRaw = AppLocale.systemDefault.rawValue
    @AppStorage(AppSettings.pullModeKey) private var pullModeRaw = PullMode.fastForwardOnly.rawValue
    @AppStorage(AppSettings.autoFetchMinutesKey) private var autoFetchMinutes = 0
    @AppStorage(AppSettings.gitPathKey) private var gitPath = ""
    @State private var gitCheck: GitCheck?
    /// Mirrors Sparkle's own preference for display only: the write goes
    /// straight back to Sparkle, and `onAppear` re-reads it.
    @State private var automaticUpdateChecks = AppUpdater.automaticallyChecksForUpdates
    private let services = AppServices.shared

    /// What `--version` said about the path typed in.
    private enum GitCheck: Equatable {
        case checking
        case found(GitVersion)
        case notFound
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $themeRaw) {
                    ForEach(ThemePreference.allCases) { theme in
                        Text(theme.label).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Language", selection: Binding(
                    get: { AppLocale(rawValue: languageRaw) ?? .systemDefault },
                    set: { languageRaw = $0.rawValue }
                )) {
                    Text("VI").tag(AppLocale.vi)
                    Text("EN").tag(AppLocale.en)
                }
                .pickerStyle(.segmented)
            }

            Section("Remote") {
                Picker("Pull", selection: $pullModeRaw) {
                    Text("Fast-forward only").tag(PullMode.fastForwardOnly.rawValue)
                    Text("Rebase my commits").tag(PullMode.rebase.rawValue)
                }
                Picker("Fetch automatically", selection: $autoFetchMinutes) {
                    ForEach(AppSettings.autoFetchChoices, id: \.self) { minutes in
                        if minutes == 0 {
                            Text("Off").tag(0)
                        } else {
                            Text("Every \(minutes) minutes").tag(minutes)
                        }
                    }
                }
                Text("Pull never creates a merge commit. With fast-forward only, a branch that has its own new commits is left for you to decide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let list = services.repositories {
                AccountsSection(list: list)
            }

            Section("Git") {
                switch services.git {
                case .resolving:
                    LabeledContent("git") { Text("Looking…") }
                case .ready(let git, let version):
                    LabeledContent("git", value: "\(git.environment.gitURL.path) · \(version.description)")
                    LabeledContent("PATH for hooks") {
                        if git.environment.pathSource == .loginShell {
                            Text("From your login shell")
                        } else {
                            Text("Default (login shell unavailable)")
                        }
                    }
                case .unsupported(let version):
                    LabeledContent("git", value: version.description)
                        .foregroundStyle(.red)
                case .unavailable(let path):
                    LabeledContent("git", value: path)
                        .foregroundStyle(.red)
                }
                TextField("git to use", text: $gitPath, prompt: Text(verbatim: GitEnvironment.defaultGitPath))
                HStack {
                    Button("Check") { Task { await checkGit() } }
                        .disabled(gitCheck == .checking)
                    switch gitCheck {
                    case nil: EmptyView()
                    case .checking: ProgressView().controlSize(.small)
                    case .found(let version) where version.isSupported:
                        Label("git \(version.description)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .found(let version):
                        Label("git \(version.description) is too old", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    case .notFound:
                        Label("Nothing there answered `git --version`", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
                Text("Takes effect the next time the app opens. Leave it empty for /usr/bin/git.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { automaticUpdateChecks },
                    set: {
                        automaticUpdateChecks = $0
                        AppUpdater.automaticallyChecksForUpdates = $0
                    }
                ))
                Text("Checks updates.dangkhoabach.vn once a day. Turning this off means updates only happen when you ask for them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Check Now") { AppUpdater.checkForUpdates() }
                }
            }

            Section("Sensitive files and secrets") {
                ForEach(SensitiveRule.allCases, id: \.self) { rule in
                    LabeledContent {
                        Text(rule.isContentRule ? "Added lines" : "File name").foregroundStyle(.secondary)
                    } label: {
                        Text(SensitiveWarningSheet.name(of: rule))
                    }
                }
                Text("Checked on the staged changes at every commit. A finding stops the commit until the files are unstaged or you commit anyway.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
        // Sparkle's own prompt can answer this after the view was built.
        .onAppear { automaticUpdateChecks = AppUpdater.automaticallyChecksForUpdates }
        .onChange(of: themeRaw) { ThemePreference.apply() }
        .onChange(of: gitPath) { gitCheck = nil }
        .onChange(of: autoFetchMinutes) { services.repositories?.scheduleAutoFetch(minutes: autoFetchMinutes) }
    }

    private func checkGit() async {
        gitCheck = .checking
        let path = gitPath.trimmingCharacters(in: .whitespaces)
        let git = GitProcess(environment: GitEnvironment(gitPath: path.isEmpty ? GitEnvironment.defaultGitPath : path))
        gitCheck = (try? await git.version()).flatMap { $0 }.map(GitCheck.found) ?? .notFound
    }
}
