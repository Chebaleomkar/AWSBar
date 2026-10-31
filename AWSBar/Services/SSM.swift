import Foundation

enum SSMSession {
    /// Opens a root login shell in the folder of the first running Docker Compose project, else in root's home.
    /// The agent runs this with `sh -c`. `sudo -i` then backslash-escapes every character except letters, digits,
    /// `_`, `-`, and `$` before root's login shell parses it, so the script has no single quotes and uses `$` only
    /// where either shell may expand it.
    static let remoteCommand = #"sudo -i bash -c 'd=$(docker ps --filter label=com.docker.compose.project.working_dir --format "{{.Label \"com.docker.compose.project.working_dir\"}}" 2>/dev/null | head -n 1); cd "${d:-$HOME}" 2>/dev/null; exec bash -il'"#

    static func parameters(command: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try! encoder.encode(["command": [command]]), as: UTF8.self)
    }

    static func startArguments(for target: ShellTarget) -> [String] {
        ["ssm", "start-session", "--target", target.instanceId, "--profile", target.profile, "--region", target.region,
         "--document-name", "AWS-StartInteractiveCommand", "--parameters", parameters(command: remoteCommand)]
    }

    /// session-manager-plugin prints this line when the session opens. The line ending must have arrived, so an ID
    /// split across two reads isn't cut short. It matches scalars, because the PTY turns the plugin's `\r\n` into
    /// `\r\r\n`, which character matching misses.
    static func sessionId(in output: String) -> String? {
        output.firstMatch(of: /Starting session with SessionId: (\S+)[\r\n]/.matchingSemantics(.unicodeScalar))
            .map { String($0.1) }
    }
}
