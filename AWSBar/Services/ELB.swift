import Foundation

/// Application, network and gateway load balancers. They bill by the hour while they exist, so this is read-only.
struct ELBProvider: ResourceProvider {
    let aws: AWSContext

    struct Response: Decodable {
        let loadBalancers: [LoadBalancer]
    }

    struct LoadBalancer: Decodable {
        let loadBalancerArn: String
        let loadBalancerName: String
        let type: String?
        let scheme: String?
        let state: State?

        struct State: Decodable { let code: String }
    }

    func list() async throws -> [Resource] {
        let response = try await aws.decode(Response.self, "elbv2", "describe-load-balancers")
        return response.loadBalancers.map(Self.resource)
    }

    static func resource(_ lb: LoadBalancer) -> Resource {
        let state = lb.state?.code ?? "unknown"
        let status: ResourceStatus = switch state {
        case "active": .running
        case "failed": .failed
        default: .transitioning
        }
        let detail = [lb.type, lb.scheme].compactMap { $0 }.joined(separator: " · ")
        return Resource(id: lb.loadBalancerArn, name: lb.loadBalancerName, detail: detail,
                        status: status, statusText: state, actions: [])
    }

    func perform(_ action: ResourceAction, on resource: Resource) async throws {}
}
