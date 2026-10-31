import SwiftTerm
import SwiftUI

struct ShellWindow: View {
    @Environment(AppState.self) private var state
    let target: ShellTarget
    @State private var session: TerminalSession?

    var body: some View {
        Group {
            if let session {
                ShellView(session: session)
            } else if state.located && state.awsURL == nil {
                Label("AWS CLI not found", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("\(target.name) shell")
        .background(NonRestorableWindow())
        .task {
            await state.bootstrap()
            guard !Task.isCancelled, session == nil,
                  let aws = state.context(profile: target.profile, region: target.region) else { return }
            let session = TerminalSession(target: target, aws: aws)
            self.session = session
            await session.connect()
        }
        .onDisappear { session?.close() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            session?.close()
        }
    }
}

struct ShellView: View {
    let session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    private var header: some View {
        let target = session.target
        return HStack(spacing: 8) {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            Text(target.name).font(.headline).lineLimit(1)
            Text(target.instanceId).font(.callout.monospaced()).foregroundStyle(.secondary)
            Spacer()
            Label(target.profile, systemImage: "person.crop.circle")
            Label(target.region, systemImage: "globe")
            Divider().frame(height: 14)
            status
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var status: some View {
        switch session.phase {
        case .locating:
            Text("Checking…").foregroundStyle(.secondary)
        case .pluginMissing:
            indicator(.failed, "Plugin missing")
        case .ready:
            indicator(.transitioning, "Connecting…")
        case .running(let run):
            if run.sessionId == nil { indicator(.transitioning, "Connecting…") } else { indicator(.running, "Connected") }
        case .ended(let exitCode):
            indicator(exitCode == 0 ? .stopped : .failed, "Session ended, exit \(exitCode)")
            Button("Reconnect") { Task { await session.connect() } }
        }
    }

    private func indicator(_ status: ResourceStatus, _ text: String) -> some View {
        HStack(spacing: 6) {
            StatusDot(status: status)
            Text(text)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .locating:
            ProgressView()
        case .pluginMissing:
            PluginMissingView { Task { await session.connect() } }
        case .ready, .running, .ended:
            TerminalHost(session: session)
                .id(session.attempt)
                .padding(6)
                .background(Color(nsColor: TerminalHost.background))
        }
    }
}

private struct PluginMissingView: View {
    static let install = "brew install --cask session-manager-plugin"
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Install the Session Manager plugin").font(.headline)
            Text(LocalizedStringKey("The shell opens an interactive session with `aws ssm start-session`. The aws CLI "
                 + "needs Amazon's `session-manager-plugin` for that, and this Mac doesn't have it. Install it with "
                 + "Homebrew, then click Retry."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            HStack(spacing: 6) {
                Text(Self.install)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.install, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }
}

/// Dark in both appearances, because remote programs pick ANSI colors for dark backgrounds, and yellow or white
/// text would be unreadable on a light one.
private struct TerminalHost: NSViewRepresentable {
    static let background = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    let session: TerminalSession

    func makeNSView(context: Context) -> SessionTerminalView {
        let view = SessionTerminalView(frame: .zero)
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = Self.background
        view.nativeForegroundColor = NSColor(white: 0.9, alpha: 1)
        // Starts after SwiftUI lays the view out, so the session opens at the window's size. A window closed before
        // then must not leave a session running unseen.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            session.start(in: view)
            window.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ view: SessionTerminalView, context: Context) {}
}
