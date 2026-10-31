import Foundation

struct RDSProvider: ResourceProvider {
    let aws: AWSContext

    struct Response: Decodable {
        let dbInstances: [DBInstance]
    }

    struct DBInstance: Decodable {
        let dbInstanceIdentifier: String
        let dbInstanceStatus: String
        let engine: String?
        let dbInstanceClass: String?
        let dbClusterIdentifier: String?
    }

    func list() async throws -> [Resource] {
        let response = try await aws.decode(Response.self, "rds", "describe-db-instances")
        return response.dbInstances.map(Self.resource)
    }

    static func resource(_ db: DBInstance) -> Resource {
        let state = db.dbInstanceStatus
        let status: ResourceStatus = switch state {
        case "available": .running
        case "stopped": .stopped
        case "failed", "storage-full", "incompatible-parameters", "incompatible-restore",
             "inaccessible-encryption-credentials", "restore-error": .failed
        default: .transitioning
        }
        let actions: [ResourceAction] = switch state {
        case "available": [.stop, .reboot]
        case "stopped": [.start]
        default: []
        }
        var detailParts = [db.engine, db.dbInstanceClass].compactMap { $0 }
        if let cluster = db.dbClusterIdentifier { detailParts.append("cluster \(cluster)") }
        return Resource(id: db.dbInstanceIdentifier, name: db.dbInstanceIdentifier,
                        detail: detailParts.joined(separator: " · "), status: status,
                        statusText: state, actions: actions,
                        scope: db.dbClusterIdentifier.map { .auroraCluster(id: $0) })
    }

    func perform(_ action: ResourceAction, on resource: Resource) async throws {
        switch (action, resource.scope) {
        case (.start, .auroraCluster(let cluster)?): try await aws.check("rds", "start-db-cluster", "--db-cluster-identifier", cluster)
        case (.stop, .auroraCluster(let cluster)?): try await aws.check("rds", "stop-db-cluster", "--db-cluster-identifier", cluster)
        case (.start, _): try await aws.check("rds", "start-db-instance", "--db-instance-identifier", resource.id)
        case (.stop, _): try await aws.check("rds", "stop-db-instance", "--db-instance-identifier", resource.id)
        case (.reboot, _): try await aws.check("rds", "reboot-db-instance", "--db-instance-identifier", resource.id)
        }
    }
}
