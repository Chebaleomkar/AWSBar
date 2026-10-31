import Foundation
import Observation

struct HistoryEntry: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    let date: Date
    let command: String
    let exitCode: Int32
    let duration: TimeInterval

    var succeeded: Bool { exitCode == 0 }
}

@MainActor @Observable
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []
    private let limit = 500
    private let fileURL: URL

    init(fileURL: URL = HistoryStore.defaultURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AWSBar", isDirectory: true)
        return dir.appendingPathComponent("history.json")
    }

    func record(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

/// Masks the value after any flag that names a secret (`--secret-string x`, `--password=x`), the
/// value after a credential key in `configure set`, and any later argument that mentions a secret.
/// Service and operation (the first two arguments) are left alone.
func redactSecrets(_ arguments: [String]) -> [String] {
    let markers = ["secret", "password", "passwd", "token", "private-key"]
    let configKeys: Set = ["aws_secret_access_key", "aws_session_token"]
    func mentionsSecret(_ text: String) -> Bool {
        let lower = text.lowercased()
        return markers.contains { lower.contains($0) }
    }
    func isSecretFlag(_ flag: String) -> Bool {
        let lower = flag.lowercased()
        if lower == "--value" { return true }
        return mentionsSecret(lower) && !["-id", "-arn", "-name"].contains(where: lower.hasSuffix)
    }
    func isConfigKey(_ arg: String) -> Bool {
        configKeys.contains(arg.lowercased().split(separator: ".").last.map(String.init) ?? "")
    }
    var result: [String] = []
    var maskNext = false
    for (index, arg) in arguments.enumerated() {
        if arg.hasPrefix("--") {
            // Switches like --no-manage-master-user-password take no value, so a flag never gets masked.
            if let eq = arg.firstIndex(of: "="),
               isSecretFlag(String(arg[..<eq])) || mentionsSecret(String(arg[arg.index(after: eq)...])) {
                result.append(arg[...eq] + "****")
                maskNext = false
            } else {
                result.append(arg)
                maskNext = isSecretFlag(arg)
            }
        } else if isConfigKey(arg) {
            result.append(arg)
            maskNext = true
        } else if maskNext || (index >= 2 && mentionsSecret(arg)) {
            result.append("****")
            maskNext = false
        } else {
            result.append(arg)
        }
    }
    return result
}
