import Foundation

struct Runner: Sendable {
    let executable: URL
    let record: @Sendable (HistoryEntry) async -> Void

    var toolName: String { executable.lastPathComponent }

    func run(_ arguments: [String]) async throws -> CLIResult {
        let started = Date()
        do {
            let result = try await CLI.run(executable, arguments)
            await log(arguments, started: started, exitCode: result.exitCode)
            return result
        } catch {
            await log(arguments, started: started, exitCode: -1)
            throw error
        }
    }

    /// Also records processes that run outside `run`, such as the shell window's session.
    func log(_ arguments: [String], started: Date, exitCode: Int32) async {
        let display = ([toolName] + redactSecrets(arguments).map(quoteIfNeeded)).joined(separator: " ")
        await record(HistoryEntry(date: started, command: display, exitCode: exitCode,
                                  duration: Date().timeIntervalSince(started)))
    }

    @discardableResult
    func check(_ arguments: [String]) async throws -> CLIResult {
        let result = try await run(arguments)
        guard result.succeeded else {
            throw CLIError(command: toolName, message: result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    func decode<T: Decodable>(_ type: T.Type, _ arguments: [String]) async throws -> T {
        let result = try await check(arguments)
        return try JSONDecoder.cli.decode(T.self, from: result.stdout)
    }
}

struct AWSContext: Sendable {
    let runner: Runner
    let profile: String
    let region: String

    func args(_ arguments: [String]) -> [String] {
        arguments + ["--profile", profile, "--region", region, "--output", "json"]
    }

    func decode<T: Decodable>(_ type: T.Type, _ arguments: String...) async throws -> T {
        try await runner.decode(T.self, args(arguments))
    }

    func check(_ arguments: String...) async throws {
        try await runner.check(args(arguments))
    }
}

extension JSONDecoder {
    static let cli: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            AnyKey(camelCase(path.last!.stringValue))
        }
        return decoder
    }()
}

private struct AnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

func camelCase(_ key: String) -> String {
    let chars = Array(key)
    var upperRun = 0
    while upperRun < chars.count, chars[upperRun].isUppercase { upperRun += 1 }
    guard upperRun > 0 else { return key }
    // An acronym run keeps its last capital as the next word's start: "DBInstance" -> "db" + "Instance".
    let lowerCount = (upperRun == chars.count || upperRun == 1) ? upperRun : upperRun - 1
    return String(chars[..<lowerCount]).lowercased() + String(chars[lowerCount...])
}

private func quoteIfNeeded(_ arg: String) -> String {
    guard arg.isEmpty || arg.contains(where: { $0.isWhitespace || "\"'$`\\".contains($0) }) else { return arg }
    return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

