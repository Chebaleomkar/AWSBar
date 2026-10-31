import Foundation

struct EC2Provider: ResourceProvider {
    let aws: AWSContext

    struct Response: Decodable {
        let reservations: [Reservation]
    }

    struct Reservation: Decodable {
        let instances: [Instance]
    }

    struct Instance: Decodable {
        let instanceId: String
        let instanceType: String?
        let state: State
        let tags: [Tag]?
        let publicIpAddress: String?
        let privateIpAddress: String?

        struct State: Decodable { let name: String }
        struct Tag: Decodable { let key: String; let value: String }

        /// A blank Name tag counts as no name, so stopping it asks for the instance ID instead of an empty string.
        var name: String? {
            guard let value = tags?.first(where: { $0.key == "Name" })?.value.trimmingCharacters(in: .whitespaces),
                  !value.isEmpty else { return nil }
            return value
        }
    }

    func list() async throws -> [Resource] {
        let response = try await aws.decode(Response.self, "ec2", "describe-instances")
        return response.reservations.flatMap(\.instances).map(Self.resource)
    }

    static func resource(_ i: Instance) -> Resource {
        let state = i.state.name
        let status: ResourceStatus = switch state {
        case "running": .running
        case "stopped": .stopped
        case "terminated": .failed
        case "shutting-down": .failed
        default: .transitioning
        }
        let actions: [ResourceAction] = switch state {
        case "running": [.stop, .reboot]
        case "stopped": [.start]
        default: []
        }
        let detail = [i.instanceId, i.instanceType, i.publicIpAddress ?? i.privateIpAddress]
            .compactMap { $0 }.joined(separator: " · ")
        return Resource(id: i.instanceId, name: i.name ?? i.instanceId, detail: detail,
                        status: status, statusText: state, actions: actions)
    }

    func perform(_ action: ResourceAction, on resource: Resource) async throws {
        let command = switch action {
        case .start: "start-instances"
        case .stop: "stop-instances"
        case .reboot: "reboot-instances"
        }
        try await aws.check("ec2", command, "--instance-ids", resource.id)
    }
}
