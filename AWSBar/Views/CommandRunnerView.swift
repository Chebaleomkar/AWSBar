import SwiftUI

struct CommandRunnerView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("aws").font(.body.monospaced()).foregroundStyle(.secondary)
                TextField("ec2 describe-instances", text: $state.runnerCommand)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit { state.startRun() }
                if state.runnerTask != nil {
                    Button("Cancel") { state.cancelRun() }
                } else {
                    Button("Run") { state.startRun() }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.runnerCommand.trimmingCharacters(in: .whitespaces).isEmpty || state.awsURL == nil)
                }
            }
            Text("Runs with --profile \(state.selectedProfileName) --region \(state.region) unless set.")
                .font(.caption)
                .foregroundStyle(.secondary)
            quickCommands
            recent
            output
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var canRun: Bool { state.awsURL != nil && state.runnerTask == nil }

    private var quickCommands: some View {
        VStack(alignment: .leading, spacing: 10) {
            quickGroup("Status and cost", QuickCommand.all().filter { !$0.isSecurity })
            quickGroup("Security", QuickCommand.all().filter(\.isSecurity))
        }
    }

    private func quickGroup(_ title: String, _ commands: [QuickCommand]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(commands) { quick in
                    Button { state.run(quick.command) } label: {
                        Label(quick.title, systemImage: quick.symbol)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help(quick.help)
                    .disabled(!canRun)
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var recent: some View {
        if !state.recentCommands.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recent").font(.subheadline.weight(.semibold))
                ForEach(state.recentCommands, id: \.self) { command in
                    Button { state.runnerCommand = command } label: {
                        Text(command)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Put this back in the box")
                }
            }
        }
    }

    @ViewBuilder
    private var output: some View {
        if state.runnerTask != nil {
            HStack { ProgressView().controlSize(.small); Text("Running…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = state.runnerError {
            Label { Text(error).font(.caption.monospaced()) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let output = state.runnerOutput {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: output.exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(output.exitCode == 0 ? .green : .red)
                        .accessibilityLabel(output.exitCode == 0 ? "Succeeded" : "Failed")
                    Text("exit \(output.exitCode)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text("\(output.duration.formatted(.number.precision(.fractionLength(1)))) s · "
                        + ByteCountFormatter.string(fromByteCount: Int64(output.text.utf8.count), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output.text, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                ScrollView([.vertical, .horizontal]) {
                    Text(output.text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
        } else {
            Text("Output appears here.")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
