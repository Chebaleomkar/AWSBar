import XCTest
@testable import AWSBar

/// Runs sessions in a real PTY against a fake `aws`. It prints the plugin's "Starting session" line, then either
/// exits 3 (target i-exit) or waits on a child standing in for session-manager-plugin (target i-hang).
@MainActor
final class TerminalSessionTests: XCTestCase {
    private var dir: URL!
    private var plugin: URL!
    private var history: HistoryStore!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("AWSBarTests-\(UUID().uuidString)")
        let pluginDir = dir.appendingPathComponent("plugin bin")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        plugin = pluginDir.appendingPathComponent(TerminalSession.pluginName)
        try executable(plugin, "#!/bin/sh\n")
        try executable(dir.appendingPathComponent("aws"), """
        #!/bin/sh
        if [ "$2" = terminate-session ]; then echo "$*" > '\(dir.path)/terminate'; echo '{}'; exit 0; fi
        command -v session-manager-plugin > '\(dir.path)/plugin'
        echo "$TERM" > '\(dir.path)/term'
        printf '%s|%s' "$4" "$AWSBAR_TEST_NFC" > '\(dir.path)/bytes'
        printf '\\r\\nStarting session with SessionId: s-123\\r\\n\\r\\n'
        case "$4" in
            i-exit) sleep 0.5; exit 3 ;;
            i-hang) sleep 60 & echo $! > '\(dir.path)/child'; wait ;;
        esac
        """)
        history = HistoryStore(fileURL: dir.appendingPathComponent("history.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func executable(_ file: URL, _ text: String) throws {
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    private func session(_ instanceId: String) -> TerminalSession {
        let history = history!
        let runner = Runner(executable: dir.appendingPathComponent("aws")) { await history.record($0) }
        let target = ShellTarget(instanceId: instanceId, name: "web", profile: "p", region: "r")
        let plugin = plugin!
        return TerminalSession(target: target, aws: AWSContext(runner: runner, profile: "p", region: "r")) { _ in plugin }
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8).trimmingCharacters(in: .newlines)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out")
    }

    private func sessionId(_ session: TerminalSession) -> String? {
        if case .running(let run) = session.phase { return run.sessionId }
        return nil
    }

    private func exitCode(_ session: TerminalSession) -> Int32? {
        if case .ended(let code) = session.phase { return code }
        return nil
    }

    func testMissingPluginShowsThePanelUntilRetryFindsIt() async {
        var installed = false
        var asked: [String] = []
        let runner = Runner(executable: URL(fileURLWithPath: "/usr/bin/false")) { _ in }
        let session = TerminalSession(target: ShellTarget(instanceId: "i-1", name: "web", profile: "p", region: "r"),
                                      aws: AWSContext(runner: runner, profile: "p", region: "r")) { name in
            asked.append(name)
            return installed ? URL(fileURLWithPath: "/opt/bin/\(name)") : nil
        }
        await session.connect()
        guard case .pluginMissing = session.phase else { return XCTFail("\(session.phase)") }
        installed = true
        await session.connect()
        guard case .ready(let found) = session.phase else { return XCTFail("\(session.phase)") }
        XCTAssertEqual(found.path, "/opt/bin/session-manager-plugin")
        XCTAssertEqual(asked, ["session-manager-plugin", "session-manager-plugin"])
    }

    func testSessionFindsThePluginOnPathAndRecordsItsExit() async throws {
        let session = session("i-exit")
        await session.connect()
        session.start(in: SessionTerminalView(frame: .zero))
        try await waitUntil { sessionId(session) != nil }
        XCTAssertEqual(sessionId(session), "s-123")
        try await waitUntil { exitCode(session) != nil }
        XCTAssertEqual(exitCode(session), 3)

        XCTAssertEqual(try read("plugin"), plugin.path)
        XCTAssertEqual(try read("term"), "xterm-256color")
        try await waitUntil { !history.entries.isEmpty }
        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(entry.exitCode, 3)
        XCTAssertTrue(entry.command.hasPrefix("aws ssm start-session --target i-exit --profile p --region r "
            + "--document-name AWS-StartInteractiveCommand --parameters '{\"command\":[\"sudo -i bash -c "), entry.command)
    }

    func testCloseHangsUpTheProcessGroupAndTerminatesTheRemoteSession() async throws {
        let session = session("i-hang")
        await session.connect()
        session.start(in: SessionTerminalView(frame: .zero))
        try await waitUntil { sessionId(session) != nil && (try? read("child")) != nil }
        let child = try XCTUnwrap(pid_t(try read("child")))

        session.close()
        try await waitUntil { exitCode(session) != nil }
        XCTAssertEqual(exitCode(session), 128 + SIGHUP)
        try await waitUntil { kill(child, 0) != 0 }

        try await waitUntil { history.entries.count == 2 }
        XCTAssertEqual(try read("terminate"), "ssm terminate-session --session-id s-123 --profile p --region r --output json")
        let start = try XCTUnwrap(history.entries.first { $0.command.contains("start-session") })
        XCTAssertEqual(start.exitCode, 128 + SIGHUP)
    }

    func testReconnectBuildsANewTerminal() async throws {
        let session = session("i-exit")
        await session.connect()
        session.start(in: SessionTerminalView(frame: .zero))
        try await waitUntil { exitCode(session) != nil }
        let attempt = session.attempt
        await session.connect()
        guard case .ready = session.phase else { return XCTFail("\(session.phase)") }
        XCTAssertEqual(session.attempt, attempt + 1)
    }

    /// The terminal spawns aws itself, so it gets the same check as CLI.run that NFC text isn't decomposed.
    func testSessionPassesArgumentAndEnvironmentBytesUnchanged() async throws {
        let nfc = "i-Jos\u{E9}\u{D55C}"
        setenv("AWSBAR_TEST_NFC", nfc, 1)
        defer { unsetenv("AWSBAR_TEST_NFC") }
        let session = session(nfc)
        await session.connect()
        session.start(in: SessionTerminalView(frame: .zero))
        try await waitUntil { exitCode(session) != nil }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("bytes")), Data("\(nfc)|\(nfc)".utf8))
    }
}
