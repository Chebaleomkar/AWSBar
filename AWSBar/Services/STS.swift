import Foundation

struct CallerIdentity: Decodable, Sendable, Equatable {
    let account: String
    let arn: String
    let userId: String

    /// The role or user name. An assumed role drops its session name, which for SSO and console sign-in is a long
    /// opaque ID.
    var roleName: String {
        let resource = arn.split(separator: ":", maxSplits: 5).last.map(String.init) ?? arn
        let parts = resource.split(separator: "/")
        guard parts.count > 1 else { return resource }
        return String(resource.hasPrefix("assumed-role/") ? parts[1] : parts[parts.count - 1])
    }
}

extension AWSContext {
    func callerIdentity() async throws -> CallerIdentity {
        try await decode(CallerIdentity.self, "sts", "get-caller-identity")
    }
}
