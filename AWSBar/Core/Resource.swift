import Foundation

enum ServiceKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case ec2, rds, ecs, elb, lambda, s3

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ec2: "EC2"
        case .rds: "RDS"
        case .ecs: "ECS"
        case .elb: "Load balancers"
        case .lambda: "Lambda"
        case .s3: "S3"
        }
    }

    var symbol: String {
        switch self {
        case .ec2: "server.rack"
        case .rds: "cylinder.split.1x2"
        case .ecs: "square.stack.3d.up"
        case .elb: "arrow.triangle.branch"
        case .lambda: "function"
        case .s3: "archivebox"
        }
    }

    /// EC2 and RDS stop and restart power off a server. ECS only scales a service to 0 or redeploys it.
    var powersServers: Bool {
        switch self {
        case .ec2, .rds: true
        case .ecs, .elb, .lambda, .s3: false
        }
    }
}

/// How the Resources tab groups services, so related things sit together instead of five flat lists.
enum ServiceGroup: String, CaseIterable, Identifiable, Sendable {
    case compute, database, storage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compute: "Compute"
        case .database: "Database"
        case .storage: "Storage and functions"
        }
    }

    var symbol: String {
        switch self {
        case .compute: "server.rack"
        case .database: "cylinder.split.1x2"
        case .storage: "archivebox"
        }
    }

    var kinds: [ServiceKind] {
        switch self {
        case .compute: [.ec2, .ecs, .elb]
        case .database: [.rds]
        case .storage: [.s3, .lambda]
        }
    }
}

enum Confirmation: Equatable, Sendable {
    case none
    case click
    /// The action runs only after this exact text is typed.
    case typeName(String)
}

enum ResourceStatus: Sendable, Hashable {
    case running, stopped, transitioning, failed, neutral

    /// The word shown beside the dot, so state never depends on color alone.
    var title: String {
        switch self {
        case .running: "Running"
        case .stopped: "Stopped"
        case .transitioning: "Changing"
        case .failed: "Failed"
        case .neutral: ""
        }
    }
}

enum ResourceAction: String, Sendable, Hashable {
    case start, stop, reboot

    var title: String {
        switch self {
        case .start: "Start"
        case .stop: "Stop"
        case .reboot: "Restart"
        }
    }

    var symbol: String {
        switch self {
        case .start: "play.fill"
        case .stop: "stop.fill"
        case .reboot: "arrow.clockwise"
        }
    }

    var isDestructive: Bool { self != .start }
}

struct Resource: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
    let status: ResourceStatus
    let statusText: String
    let actions: [ResourceAction]
    var scope: Scope? = nil

    enum Scope: Hashable, Sendable {
        case ecsCluster(arn: String)
        /// Aurora members can't start or stop alone; those actions hit the whole cluster.
        case auroraCluster(id: String)
    }

    func prompt(for action: ResourceAction) -> String {
        if let cluster = cluster(for: action) { return "\(action.title) cluster \(cluster)?" }
        return "\(action.title) \(name)?"
    }

    func confirmation(for action: ResourceAction, in kind: ServiceKind) -> Confirmation {
        guard action.isDestructive else { return .none }
        guard kind.powersServers else { return .click }
        return .typeName(cluster(for: action) ?? name)
    }

    private func cluster(for action: ResourceAction) -> String? {
        guard case .auroraCluster(let id) = scope, action != .reboot else { return nil }
        return id
    }
}

protocol ResourceProvider: Sendable {
    func list() async throws -> [Resource]
    func perform(_ action: ResourceAction, on resource: Resource) async throws
}
