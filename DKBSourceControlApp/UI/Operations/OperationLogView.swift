import SwiftUI

/// git's own output of every fetch, pull, push, commit and discard this
/// session, and of every write that failed, newest first, selectable for
/// copying (plan §7.3).
struct OperationLogView: View {
    let log: OperationLog

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("git output").font(.headline)
                Spacer()
                Button("Clear", action: log.clear)
                    .disabled(log.entries.allSatisfy { $0.succeeded == nil })
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if log.entries.isEmpty {
                ContentUnavailableView("No git output yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Fetch, pull, push and commit show what git said here."))
                    .frame(maxHeight: .infinity)
            } else {
                List(log.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            switch entry.succeeded {
                            case nil: ProgressView().controlSize(.mini)
                            case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case false?: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                            }
                            Text(entry.repository).fontWeight(.medium)
                            Spacer()
                            if let finished = entry.finished {
                                Text("\(finished.timeIntervalSince(entry.started), format: .number.precision(.fractionLength(1))) s")
                                    .monospacedDigit()
                            }
                            Text(entry.started, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.secondary)
                        }
                        Text("$ \(entry.command)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if !entry.output.isEmpty {
                            Text(entry.output)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
