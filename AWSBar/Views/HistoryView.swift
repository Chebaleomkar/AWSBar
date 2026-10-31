import SwiftUI

struct HistoryView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let entries = state.history.entries
        VStack(spacing: 0) {
            if entries.isEmpty {
                Text("No commands yet.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    HistoryRow(entry: entry)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                HStack {
                    Text("\(entries.count) commands").foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { state.history.clear() }
                        .buttonStyle(.borderless)
                }
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    /// Every call the app makes starts with aws and ends with the same context flags, which buried the part that differs.
    private var shortCommand: String {
        var command = entry.command
        if command.hasPrefix("aws ") { command.removeFirst(4) }
        if let tail = command.range(of: #" --profile \S+ --region \S+ --output json$"#, options: .regularExpression) {
            command.removeSubrange(tail)
        }
        return command
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.succeeded ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(entry.succeeded ? .green : .red)
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(shortCommand)
                    .font(.subheadline.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(entry.command)
                HStack(spacing: 6) {
                    Text(entry.date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    Text("·")
                    Text(entry.duration, format: .number.precision(.fractionLength(1))) + Text("s")
                    if !entry.succeeded {
                        Text("· exit \(entry.exitCode)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.command, forType: .string)
            }
        }
    }
}
