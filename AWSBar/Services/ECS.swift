import Foundation

struct ECSProvider: ResourceProvider {
    let aws: AWSContext

    struct ClusterList: Decodable { let clusterArns: [String] }
    struct ServiceList: Decodable { let serviceArns: [String] }
    struct ServiceDescriptions: Decodable { let services: [Service] }

    struct Service: Decodable {
        let serviceArn: String
        let serviceName: String
        let clusterArn: String
        let status: String
        let desiredCount: Int
        let runningCount: Int
        let pendingCount: Int
        let launchType: String?
    }

    func list() async throws -> [Resource] {
        let clusters = try await aws.decode(ClusterList.self, "ecs", "list-clusters").clusterArns
        // One cluster at a time: each aws call is a Python process, and accounts can have many clusters.
        var all: [Service] = []
        for cluster in clusters { all += try await services(in: cluster) }
        return all.sorted { $0.serviceName < $1.serviceName }.map(Self.resource)
    }

    private func services(in cluster: String) async throws -> [Service] {
        let arns = try await aws.decode(ServiceList.self, "ecs", "list-services", "--cluster", cluster).serviceArns
        var services: [Service] = []
        // describe-services accepts at most 10 services per call.
        for start in stride(from: 0, to: arns.count, by: 10) {
            let batch = Array(arns[start..<min(start + 10, arns.count)])
            let args = ["ecs", "describe-services", "--cluster", cluster, "--services"] + batch
            services += try await aws.runner.decode(ServiceDescriptions.self, aws.args(args)).services
        }
        return services
    }

    static func resource(_ s: Service) -> Resource {
        let status: ResourceStatus
        if s.status != "ACTIVE" {
            status = .transitioning
        } else if s.desiredCount == 0 && s.runningCount == 0 {
            status = .stopped
        } else if s.runningCount == s.desiredCount && s.pendingCount == 0 {
            status = .running
        } else {
            status = .transitioning
        }
        let actions: [ResourceAction] = s.desiredCount == 0 ? [.start] : [.stop, .reboot]
        let clusterName = s.clusterArn.split(separator: "/").last.map(String.init) ?? s.clusterArn
        let detail = [clusterName, s.launchType, "\(s.runningCount)/\(s.desiredCount) running"]
            .compactMap { $0 }.joined(separator: " · ")
        return Resource(id: s.serviceArn, name: s.serviceName, detail: detail, status: status,
                        statusText: s.status.lowercased(), actions: actions, scope: .ecsCluster(arn: s.clusterArn))
    }

    func perform(_ action: ResourceAction, on resource: Resource) async throws {
        guard case .ecsCluster(let cluster)? = resource.scope else { return }
        let base = ["ecs", "update-service", "--cluster", cluster, "--service", resource.id]
        let extra = switch action {
        case .start: ["--desired-count", "1"]
        case .stop: ["--desired-count", "0"]
        case .reboot: ["--force-new-deployment"]
        }
        try await aws.runner.check(aws.args(base + extra))
    }
}
