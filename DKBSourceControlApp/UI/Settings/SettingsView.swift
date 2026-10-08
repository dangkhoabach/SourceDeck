import DKBSourceControlCore
import SwiftUI

/// One `Form` with `.formStyle(.grouped)` and a `Section` per topic, like the
/// other DKB apps' Settings. Every change applies at once.
struct SettingsView: View {
    @AppStorage(ThemePreference.key) private var themeRaw = ThemePreference.system.rawValue
    @AppStorage(AppLocale.key) private var languageRaw = AppLocale.systemDefault.rawValue
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
    }
}
