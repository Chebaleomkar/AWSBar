import XCTest
@testable import AWSBar

final class ConfirmationTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.cli.decode(T.self, from: Data(json.utf8))
    }

    func testEC2StopAndRestartNeedTheTypedName() throws {
        let response = try decode(EC2Provider.Response.self, """
        {"Reservations":[{"Instances":[
          {"InstanceId":"i-1","State":{"Name":"running"},"Tags":[{"Key":"Name","Value":"web-prod"}]},
          {"InstanceId":"i-2","State":{"Name":"stopped"}}
        ]}]}
        """)
        let resources = response.reservations.flatMap(\.instances).map(EC2Provider.resource)
        XCTAssertEqual(resources[0].confirmation(for: .stop, in: .ec2), .typeName("web-prod"))
        XCTAssertEqual(resources[0].confirmation(for: .reboot, in: .ec2), .typeName("web-prod"))
        XCTAssertEqual(resources[1].confirmation(for: .start, in: .ec2), .none)
        XCTAssertEqual(resources[1].confirmation(for: .stop, in: .ec2), .typeName("i-2"))
    }

    func testRDSNeedsTheTypedNameAndAuroraStopNamesTheCluster() throws {
        let response = try decode(RDSProvider.Response.self, """
        {"DBInstances":[
          {"DBInstanceIdentifier":"db1","DBInstanceStatus":"available","Engine":"postgres"},
          {"DBInstanceIdentifier":"a1","DBInstanceStatus":"available","Engine":"aurora-postgresql","DBClusterIdentifier":"c1"}
        ]}
        """)
        let resources = response.dbInstances.map(RDSProvider.resource)
        XCTAssertEqual(resources[0].confirmation(for: .stop, in: .rds), .typeName("db1"))
        XCTAssertEqual(resources[0].confirmation(for: .reboot, in: .rds), .typeName("db1"))
        XCTAssertEqual(resources[1].confirmation(for: .stop, in: .rds), .typeName("c1"))
        XCTAssertEqual(resources[1].confirmation(for: .start, in: .rds), .none)
        XCTAssertEqual(resources[1].confirmation(for: .reboot, in: .rds), .typeName("a1"))
    }

    func testECSKeepsTheOneClickConfirm() throws {
        let service = try decode(ECSProvider.Service.self, """
        {"serviceArn":"arn:s/a","serviceName":"api","clusterArn":"arn:aws:ecs:x:1:cluster/prod","status":"ACTIVE",
         "desiredCount":1,"runningCount":1,"pendingCount":0}
        """)
        let resource = ECSProvider.resource(service)
        XCTAssertEqual(resource.confirmation(for: .stop, in: .ecs), .click)
        XCTAssertEqual(resource.confirmation(for: .reboot, in: .ecs), .click)
        XCTAssertEqual(resource.confirmation(for: .start, in: .ecs), .none)
    }
}
