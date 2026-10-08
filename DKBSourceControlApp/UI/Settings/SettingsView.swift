import DKBSourceControlCore
import SwiftUI

/// One `Form` with `.formStyle(.grouped)` and a `Section` per topic, like the
/// other DKB apps' Settings. Every change applies at once.
struct SettingsView: View {
    @AppStorage(ThemePreference.key) private var themeRaw = ThemePreference.system.rawValue
    @AppStorage(AppLocale.key) private var languageRaw = AppLocale.systemDefault.rawValue
    @AppStorage(AppSettings.pullModeKey) private var pullModeRaw = PullMode.fastForwardOnly.rawValue
    @AppStorage(AppSettings.autoFetchMinutesKey) private var autoFetchMinutes = 0
    private let services = AppServices.shared

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
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onChange(of: themeRaw) { ThemePreference.apply() }
        .onChange(of: autoFetchMinutes) { services.repositories?.scheduleAutoFetch(minutes: autoFetchMinutes) }
    }
}
