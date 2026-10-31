import Foundation
import os

struct CLIResult: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data

    var succeeded: Bool { exitCode == 0 }
    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

struct CLIError: LocalizedError, Sendable {
    let command: String
    let message: String

    var errorDescription: String? { message.isEmpty ? "\(command) failed" : message }
}

enum CLI {
    /// launchd starts GUI apps with PATH=/usr/bin:/bin:/usr/sbin:/sbin, which misses Homebrew.
    static let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        NSHomeDirectory() + "/.local/bin",
        // aws looks up session-manager-plugin on PATH, and Amazon's installer puts it here.
        "/usr/local/sessionmanagerplugin/bin",
    ]

    static func locate(_ name: String) async -> URL? {
        let fm = FileManager.default
        for dir in searchPaths {
            let path = dir + "/" + name
            if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let result = try? await run(URL(fileURLWithPath: shell), ["-lc", "command -v \(name)"]),
              result.succeeded else { return nil }
        let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// aws runs credential_process helpers through PATH, so they need the same directories.
    static func environment(adding dir: String? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var paths = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for p in ([dir].compactMap { $0 } + searchPaths) where !paths.contains(p) {
            paths.append(p)
        }
        env["PATH"] = paths.joined(separator: ":")
        // stdin is /dev/null, so a pager or `cli_auto_prompt = on` in ~/.aws/config would fail every call.
        env["AWS_PAGER"] = ""
        env["AWS_CLI_AUTO_PROMPT"] = "off"
        return env
    }

    /// Runs a process and collects its output without holding a thread while it runs.
    static func run(_ executable: URL, _ arguments: [String]) async throws -> CLIResult {
        let env = environment(adding: executable.deletingLastPathComponent().path).map { "\($0.key)=\($0.value)" }
        let run = ProcessRun(path: executable.path, arguments: arguments, environment: env)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { run.start($0) }
        } onCancel: {
            run.cancel()
        }
    }

    /// Maps a raw `waitpid` status to an exit code. A signal maps to 128 + its number, as shells report it.
    static func exitCode(waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        return signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal
    }
}

/// Spawns with posix_spawn because Foundation's Process converts every argument and environment value to NFD, and
/// S3 compares keys byte for byte. Resumes once the process has been reaped and both pipes hit EOF.
private final class ProcessRun: Sendable {
    private struct State {
        var stdout = Data()
        var stderr = Data()
        var openPipes = 2
        /// Set from spawn until reaped, so cancel never signals a pid the system has reused.
        var pid: pid_t?
        var exitCode: Int32?
        var cancelled = false
        var continuation: CheckedContinuation<CLIResult, Error>?
    }

    private let path: String
    private let arguments: [String]
    private let environment: [String]
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(path: String, arguments: [String], environment: [String]) {
        self.path = path
        self.arguments = arguments
        self.environment = environment
    }

    func start(_ continuation: CheckedContinuation<CLIResult, Error>) {
        let cancelled = state.withLock { s in
            s.continuation = continuation
            return s.cancelled
        }
        if cancelled { return fail(CancellationError()) }

        let child: (pid: pid_t, stdout: Int32, stderr: Int32)
        do {
            child = try launch()
        } catch {
            return fail(error)
        }
        // A cancel can land between the check above and the spawn.
        state.withLock { s in
            s.pid = child.pid
            if s.cancelled { kill(child.pid, SIGTERM) }
        }
        read(child.stdout, isStderr: false)
        read(child.stderr, isStderr: true)
        let exited = DispatchSource.makeProcessSource(identifier: child.pid, eventMask: .exit, queue: .global())
        exited.setEventHandler { [self] in
            exited.cancel()
            reap(child.pid)
        }
        exited.resume()
    }

    func cancel() {
        state.withLock { s in
            s.cancelled = true
            if let pid = s.pid { kill(pid, SIGTERM) }
        }
    }

    /// Returns the child and the read ends of its output pipes. The parent's write ends are always closed, so the
    /// reads hit EOF once the child exits.
    private func launch() throws -> (pid: pid_t, stdout: Int32, stderr: Int32) {
        var out: [Int32] = [-1, -1]
        var err: [Int32] = [-1, -1]
        defer {
            close(out[1])
            close(err[1])
        }
        do {
            guard pipe(&out) == 0, pipe(&err) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            // A child forked elsewhere, such as the shell window's terminal, would hold a write end open and delay EOF.
            for fd in out + err { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            return (try spawn(stdout: out[1], stderr: err[1]), out[0], err[0])
        } catch {
            close(out[0])
            close(err[0])
            throw error
        }
    }

    private func spawn(stdout: Int32, stderr: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)

        // The calling thread may block signals, and a child that inherited that mask would ignore cancel's SIGTERM.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var none = sigset_t()
        var all = sigset_t()
        sigemptyset(&none)
        sigfillset(&all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        guard code == 0 else { throw CLIError(command: path, message: "\(path): \(String(cString: strerror(code)))") }
        return pid
    }

    private func read(_ fd: Int32, isStderr: Bool) {
        let io = DispatchIO(type: .stream, fileDescriptor: fd, queue: .global()) { _ in close(fd) }
        io.read(offset: 0, length: Int.max, queue: .global()) { [self] done, data, _ in
            state.withLock { s in
                data?.enumerateBytes { bytes, _, _ in
                    if isStderr { s.stderr.append(bytes) } else { s.stdout.append(bytes) }
                }
                if done { s.openPipes -= 1 }
            }
            if done {
                io.close()
                finishIfDone()
            }
        }
    }

    private func reap(_ pid: pid_t) {
        state.withLock { s in
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
            s.exitCode = result == pid ? CLI.exitCode(waitStatus: status) : -1
            s.pid = nil
        }
        finishIfDone()
    }

    private func finishIfDone() {
        let done: (CheckedContinuation<CLIResult, Error>, CLIResult)? = state.withLock { s in
            guard s.openPipes == 0, let code = s.exitCode, let c = s.continuation else { return nil }
            s.continuation = nil
            return (c, CLIResult(exitCode: code, stdout: s.stdout, stderr: s.stderr))
        }
        if let (continuation, result) = done { continuation.resume(returning: result) }
    }

    private func fail(_ error: Error) {
        let continuation = state.withLock { s in
            defer { s.continuation = nil }
            return s.continuation
        }
        continuation?.resume(throwing: error)
    }
}

func shellSplit(_ line: String) -> [String] {
    var args: [String] = []
    var current = ""
    var inToken = false
    var quote: Character?
    let chars = Array(line)
    var i = 0
    while i < chars.count {
        let ch = chars[i]
        i += 1
        if quote == "'" {
            if ch == "'" { quote = nil } else { current.append(ch) }
        } else if ch == "\\", i < chars.count {
            // Inside double quotes POSIX only treats \ before $ ` " \ and newline as an escape.
            if quote == "\"" && !"$`\"\\\n".contains(chars[i]) {
                current.append(ch)
            } else {
                current.append(chars[i])
                i += 1
            }
            inToken = true
        } else if quote == "\"" {
            if ch == "\"" { quote = nil } else { current.append(ch) }
        } else if ch == "'" || ch == "\"" {
            quote = ch
            inToken = true
        } else if ch.isWhitespace {
            if inToken { args.append(current); current = ""; inToken = false }
        } else {
            current.append(ch)
            inToken = true
        }
    }
    if inToken { args.append(current) }
    return args
}
