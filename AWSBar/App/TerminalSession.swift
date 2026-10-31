import AppKit
import Observation
import SwiftTerm

/// Profile and region are fixed when the window opens, so switching profile in the menu can't retarget it.
struct ShellTarget: Codable, Hashable, Sendable {
    let instanceId: String
    let name: String
    let profile: String
    let region: String
}

/// One shell window's `aws ssm start-session`, run in the window's terminal.
@MainActor @Observable
final class TerminalSession {
    enum Phase {
        case locating
        case pluginMissing
        /// Waiting for the terminal view to run the session.
        case ready(plugin: URL)
        case running(Run)
        case ended(exitCode: Int32)
    }

    struct Run {
        let terminal: SessionTerminalView
        let started: Date
        var sessionId: String?
        var output = ""
        var closing = false
    }

    static let pluginName = "session-manager-plugin"

    let target: ShellTarget
    private let aws: AWSContext
    private let locate: (String) async -> URL?
    private(set) var phase: Phase = .locating
    /// Bumped for each new session, so the window builds a fresh terminal instead of reusing the ended one.
    private(set) var attempt = 0
    private var closed = false

    init(target: ShellTarget, aws: AWSContext, locate: @escaping (String) async -> URL? = CLI.locate) {
        self.target = target
        self.aws = aws
        self.locate = locate
    }

    func connect() async {
        if closed { return }
        if case .running = phase { return }
        phase = .locating
        let plugin = await locate(Self.pluginName)
        // A second Reconnect, or a close, may have landed while locating ran.
        guard !closed, case .locating = phase else { return }
        if let plugin {
            attempt += 1
            phase = .ready(plugin: plugin)
        } else {
            phase = .pluginMissing
        }
    }

    func start(in terminal: SessionTerminalView) {
        guard !closed, case .ready(let plugin) = phase else { return }
        let started = Date()
        terminal.session = self
        terminal.startProcess(executable: aws.runner.executable.path, args: SSMSession.startArguments(for: target),
                              environment: Self.environment(pluginDirectory: plugin.deletingLastPathComponent().path))
        guard terminal.process.running else { return finish(started: started, exitCode: -1) }
        phase = .running(Run(terminal: terminal, started: started))
    }

    func received(_ bytes: ArraySlice<UInt8>) {
        guard case .running(var run) = phase, run.sessionId == nil else { return }
        run.output += String(decoding: bytes, as: UTF8.self)
        run.sessionId = SSMSession.sessionId(in: run.output)
        run.output = run.sessionId == nil ? String(run.output.suffix(512)) : ""
        phase = .running(run)
    }

    func exited(waitStatus: Int32?) {
        guard case .running(let run) = phase else { return }
        run.terminal.session = nil
        finish(started: run.started, exitCode: waitStatus.map(CLI.exitCode) ?? -1)
    }

    /// Hangs up the whole process group, as closing a Terminal window does, so session-manager-plugin exits along
    /// with aws. A client that just disappears can leave the remote shell open until SSM's idle timeout, so the
    /// session is also ended by ID.
    func close() {
        closed = true
        guard case .running(var run) = phase, !run.closing else { return }
        run.closing = true
        phase = .running(run)
        if let id = run.sessionId { terminateRemote(id) }
        killpg(run.terminal.process.shellPid, SIGHUP)
    }

    /// Launched synchronously, so it still runs when close() comes from app quit, where a Task would never start.
    private func terminateRemote(_ sessionId: String) {
        let args = aws.args(["ssm", "terminate-session", "--session-id", sessionId])
        let process = Process()
        process.executableURL = aws.runner.executable
        process.arguments = args
        process.environment = CLI.environment(adding: aws.runner.executable.deletingLastPathComponent().path)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let started = Date()
        let runner = aws.runner
        process.terminationHandler = { process in
            let code = process.terminationStatus
            Task { await runner.log(args, started: started, exitCode: code) }
        }
        try? process.run()
    }

    private func finish(started: Date, exitCode: Int32) {
        phase = .ended(exitCode: exitCode)
        let aws = aws
        let args = SSMSession.startArguments(for: target)
        Task { await aws.runner.log(args, started: started, exitCode: exitCode) }
    }

    static func environment(pluginDirectory: String) -> [String] {
        var env = CLI.environment(adding: pluginDirectory)
        env["TERM"] = "xterm-256color"
        return env.map { "\($0.key)=\($0.value)" }
    }
}

/// Reports output and exit to its session. The session keeps this view while the process runs, and the view keeps
/// the session, so a window that closes mid-session still records the exit in History.
final class SessionTerminalView: LocalProcessTerminalView {
    var session: TerminalSession?
    private lazy var guardedDelegate = GuardedTerminalDelegate(view: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = guardedDelegate
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        terminalDelegate = guardedDelegate
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        session?.received(slice)
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        super.processTerminated(source, exitCode: exitCode)
        session?.exited(waitStatus: exitCode)
    }
}

/// Forwards SwiftTerm's callbacks to the view, except OSC 52 clipboard writes: output from the server (a tailed log,
/// say) could otherwise plant a command on the Mac clipboard. Links open only for http and https.
@MainActor
final class GuardedTerminalDelegate: @preconcurrency TerminalViewDelegate {
    private unowned let view: SessionTerminalView

    init(view: SessionTerminalView) {
        self.view = view
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        view.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        view.setTerminalTitle(source: source, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        view.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        view.send(source: source, data: data)
    }

    func scrolled(source: TerminalView, position: Double) {
        view.scrolled(source: source, position: position)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        view.rangeChanged(source: source, startY: startY, endY: endY)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        NSWorkspace.shared.open(url)
    }

    func bell(source: TerminalView) {
        NSSound.beep()
    }

    func clipboardCopy(source: TerminalView, content: Data) {}

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}
