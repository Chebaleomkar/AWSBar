import Foundation

struct AWSProfile: Identifiable, Hashable, Sendable {
    let name: String
    var region: String?
    var loginKind: LoginKind = .other

    var id: String { name }

    enum LoginKind: Sendable {
        case sso
        case console
        case other
    }
}

enum AWSProfiles {
    static var configURL: URL {
        if let path = ProcessInfo.processInfo.environment["AWS_CONFIG_FILE"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: NSHomeDirectory() + "/.aws/config")
    }

    static var credentialsURL: URL {
        if let path = ProcessInfo.processInfo.environment["AWS_SHARED_CREDENTIALS_FILE"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: NSHomeDirectory() + "/.aws/credentials")
    }

    static func load() -> [AWSProfile] {
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let credentials = (try? String(contentsOf: credentialsURL, encoding: .utf8)) ?? ""
        return merge(config: parseINI(config), credentialProfiles: sectionNames(credentials))
    }

    static func merge(config: [String: [String: String]], credentialProfiles: [String]) -> [AWSProfile] {
        var byName: [String: AWSProfile] = [:]
        for (section, keys) in config {
            let name: String
            if section == "default" {
                name = "default"
            } else if section.hasPrefix("profile ") {
                name = String(section.dropFirst("profile ".count)).trimmingCharacters(in: .whitespaces)
            } else {
                continue
            }
            var profile = AWSProfile(name: name, region: keys["region"])
            if keys["sso_session"] != nil || keys["sso_start_url"] != nil {
                profile.loginKind = .sso
            } else if keys["login_session"] != nil {
                profile.loginKind = .console
            }
            byName[name] = profile
        }
        for name in credentialProfiles where byName[name] == nil {
            byName[name] = AWSProfile(name: name, region: nil)
        }
        return byName.values.sorted { a, b in
            if a.name == "default" { return b.name != "default" }
            if b.name == "default" { return false }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Only section names are kept from the credentials file, never key values.
    static func sectionNames(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[") && line.hasSuffix("]") else { return nil }
            return line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        }
    }

    static func parseINI(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var section: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                section = name
                if result[name] == nil { result[name] = [:] }
                continue
            }
            // Indented lines are nested sub-keys (e.g. under `s3 =`); skip them.
            guard let section, rawLine.first?.isWhitespace != true,
                  let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            result[section]?[key] = value
        }
        return result
    }
}
