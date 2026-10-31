import XCTest
@testable import AWSBar

final class SSMSessionTests: XCTestCase {
    func testParametersCarryTheCommandUnchanged() throws {
        for command in [SSMSession.remoteCommand, #"echo "it's" 'a \b' $HOME/x"#] {
            let json = SSMSession.parameters(command: command)
            let decoded = try JSONDecoder().decode([String: [String]].self, from: Data(json.utf8))
            XCTAssertEqual(decoded, ["command": [command]])
        }
    }

    func testStartArguments() {
        let target = ShellTarget(instanceId: "i-0abc", name: "web", profile: "dev", region: "ap-south-1")
        XCTAssertEqual(SSMSession.startArguments(for: target), [
            "ssm", "start-session", "--target", "i-0abc", "--profile", "dev", "--region", "ap-south-1",
            "--document-name", "AWS-StartInteractiveCommand",
            "--parameters", SSMSession.parameters(command: SSMSession.remoteCommand),
        ])
    }

    func testSessionIdWaitsForTheLineEnding() {
        XCTAssertEqual(SSMSession.sessionId(in: "\r\nStarting session with SessionId: me@corp.com-0a1b2c3d\r\n\r\n$ "),
                       "me@corp.com-0a1b2c3d")
        XCTAssertEqual(SSMSession.sessionId(in: "\r\r\nStarting session with SessionId: s-1\r\r\n"), "s-1")
        XCTAssertNil(SSMSession.sessionId(in: "\r\nStarting session with SessionId: me@corp.com-0a"))
        XCTAssertNil(SSMSession.sessionId(in: "An error occurred (TargetNotConnected) when calling the StartSession operation\n"))
    }
}

/// Runs `SSMSession.remoteCommand` through the same layers as on the instance: the agent's `sh -c`, `sudo -i`, then
/// bash. The fake `sudo` escapes its arguments the way sudo's `-i` does and starts in a stand-in for root's home.
/// It skips the login profile because macOS's profile would put the real `docker` first on PATH. The fake `docker`
/// answers only the exact query the command makes, so a quoting slip shows up as the home folder.
final class RemoteCommandTests: XCTestCase {
    private var dir: URL!
    private var bin: URL!
    private var home: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("AWSBarTests-\(UUID().uuidString)")
        bin = dir.appendingPathComponent("bin")
        home = dir.appendingPathComponent("root")
        for folder in [bin!, home!] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try script("sudo", """
        #!/bin/sh
        [ "$1" = -i ] || exit 97
        shift
        command=""
        for arg in "$@"; do
            command="$command${command:+ }$(printf '%s' "$arg" | LC_ALL=C sed 's/[^A-Za-z0-9_$-]/\\\\&/g')"
        done
        HOME='\(home.path)'
        export HOME
        cd "$HOME" || exit 98
        exec /bin/bash --noprofile --norc -c "$command"
        """)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func script(_ name: String, _ text: String) throws {
        let file = bin.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    private func docker(printing lines: [String]) throws {
        let output = dir.appendingPathComponent("docker-output")
        try lines.map { $0 + "\n" }.joined().write(to: output, atomically: true, encoding: .utf8)
        try script("docker", """
        #!/bin/sh
        [ $# = 5 ] || exit 1
        [ "$*" = 'ps --filter label=com.docker.compose.project.working_dir --format {{.Label "com.docker.compose.project.working_dir"}}' ] || exit 1
        cat '\(output.path)'
        """)
    }

    /// The interactive shell at the end reads `pwd` from stdin, so stdout is the folder the session starts in.
    private func startingFolder() async throws -> (folder: String, stderr: String) {
        let agent = #"PATH="$2"; export PATH; echo pwd | sh -c "$1""#
        let result = try await CLI.run(URL(fileURLWithPath: "/bin/sh"),
                                       ["-c", agent, "sh", SSMSession.remoteCommand, bin.path + ":/usr/bin:/bin"])
        return (result.stdoutString.trimmingCharacters(in: .newlines), result.stderrString)
    }

    func testStartsInTheFirstComposeProjectEvenWithSpacesInItsName() async throws {
        let project = dir.appendingPathComponent("my app $HOME 'x'")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try docker(printing: [project.path, "/srv/other"])
        let (folder, _) = try await startingFolder()
        XCTAssertEqual(folder, project.path)
    }

    func testFallsBackToHomeWithoutDocker() async throws {
        let (folder, stderr) = try await startingFolder()
        XCTAssertEqual(folder, home.path)
        XCTAssertFalse(stderr.contains("docker"), stderr)
    }

    func testFallsBackToHomeWithoutAComposeProject() async throws {
        try docker(printing: [])
        let (folder, _) = try await startingFolder()
        XCTAssertEqual(folder, home.path)
    }
}
