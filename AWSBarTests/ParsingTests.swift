import XCTest
@testable import AWSBar

final class ParsingTests: XCTestCase {
    func testCamelCase() {
        XCTAssertEqual(camelCase("InstanceId"), "instanceId")
        XCTAssertEqual(camelCase("DBInstanceStatus"), "dbInstanceStatus")
        XCTAssertEqual(camelCase("ID"), "id")
        XCTAssertEqual(camelCase("Names"), "names")
        XCTAssertEqual(camelCase("clusterArns"), "clusterArns")
    }

    func testShellSplit() {
        XCTAssertEqual(shellSplit("ec2 describe-instances --filters 'Name=tag:Name,Values=a b'"),
                       ["ec2", "describe-instances", "--filters", "Name=tag:Name,Values=a b"])
        XCTAssertEqual(shellSplit(#"s3 ls "my bucket" a\ b ''"#), ["s3", "ls", "my bucket", "a b", ""])
        XCTAssertEqual(shellSplit(#"--payload "{\"m\":\"a\nb\"}" "C:\tmp""#), ["--payload", #"{"m":"a\nb"}"#, #"C:\tmp"#])
    }

    func testRedactSecrets() {
        XCTAssertEqual(redactSecrets(["secretsmanager", "put-secret-value", "--secret-id", "db", "--secret-string", "hunter2"]),
                       ["secretsmanager", "put-secret-value", "--secret-id", "db", "--secret-string", "****"])
        XCTAssertEqual(redactSecrets(["rds", "modify-db-instance", "--no-manage-master-user-password", "--master-user-password", "pw"]),
                       ["rds", "modify-db-instance", "--no-manage-master-user-password", "--master-user-password", "****"])
        XCTAssertEqual(redactSecrets(["configure", "set", "profile.dev.aws_secret_access_key", "abc"]),
                       ["configure", "set", "profile.dev.aws_secret_access_key", "****"])
        XCTAssertEqual(redactSecrets(["lambda", "update-function-configuration", "--environment", "Variables={DB_PASSWORD=pw}"]),
                       ["lambda", "update-function-configuration", "--environment", "****"])
        XCTAssertEqual(redactSecrets(["rds", "create-db-instance", #"--cli-input-json={"MasterUserPassword":"x"}"#]),
                       ["rds", "create-db-instance", "--cli-input-json=****"])
        XCTAssertEqual(redactSecrets(["configure", "set", "aws_secret_access_key", "abc", "--profile", "dev"]),
                       ["configure", "set", "aws_secret_access_key", "****", "--profile", "dev"])
        XCTAssertEqual(redactSecrets(["rds", "modify-db-instance", "--master-user-password=pw"]),
                       ["rds", "modify-db-instance", "--master-user-password=****"])
        XCTAssertEqual(redactSecrets(["ec2", "describe-instances"]), ["ec2", "describe-instances"])
    }

    func testRunnerArguments() {
        XCTAssertEqual(runnerArguments("aws s3 ls", profile: "dev", region: "eu-west-1"),
                       ["s3", "ls", "--profile", "dev", "--region", "eu-west-1"])
        XCTAssertEqual(runnerArguments("ec2 describe-regions --profile=prod --region us-east-1", profile: "dev", region: "eu-west-1"),
                       ["ec2", "describe-regions", "--profile=prod", "--region", "us-east-1"])
    }

    func testProfilesFromConfigAndCredentials() {
        let config = AWSProfiles.parseINI("""
        [default]
        region = us-west-2
        [profile dev]
        sso_session = corp
        region = eu-west-1
        s3 =
          max_concurrent_requests = 20
        [profile console]
        login_session = arn:aws:iam::1:user/me
        [sso-session corp]
        sso_start_url = https://example.awsapps.com/start
        """)
        let credentials = AWSProfiles.sectionNames("""
        [default]
        aws_access_key_id = AKIA
        [legacy]
        aws_access_key_id = AKIB
        """)
        XCTAssertEqual(credentials, ["default", "legacy"])
        let profiles = AWSProfiles.merge(config: config, credentialProfiles: credentials)
        XCTAssertEqual(profiles.map(\.name), ["default", "console", "dev", "legacy"])
        XCTAssertEqual(profiles[0].region, "us-west-2")
        XCTAssertEqual(profiles[1].loginKind, .console)
        XCTAssertEqual(profiles[2].loginKind, .sso)
        XCTAssertEqual(profiles[2].region, "eu-west-1")
        XCTAssertEqual(profiles[3].loginKind, .other)
    }

    func testBlankNameTagFallsBackToInstanceId() throws {
        let json = #"{"Reservations":[{"Instances":[{"InstanceId":"i-9","State":{"Name":"running"},"Tags":[{"Key":"Name","Value":"  "}]}]}]}"#
        let instance = try JSONDecoder.cli.decode(EC2Provider.Response.self, from: Data(json.utf8)).reservations[0].instances[0]
        let resource = EC2Provider.resource(instance)
        XCTAssertEqual(resource.name, "i-9")
        XCTAssertEqual(resource.confirmation(for: .stop, in: .ec2), .typeName("i-9"))
    }

    func testEC2Decoding() throws {
        let json = """
        {"Reservations":[{"Instances":[
          {"InstanceId":"i-1","InstanceType":"t3.micro","State":{"Code":16,"Name":"running"},
           "Tags":[{"Key":"Name","Value":"web"}],"PrivateIpAddress":"10.0.0.1"},
          {"InstanceId":"i-2","State":{"Code":80,"Name":"stopped"}}
        ]}]}
        """
        let response = try JSONDecoder.cli.decode(EC2Provider.Response.self, from: Data(json.utf8))
        let resources = response.reservations.flatMap(\.instances).map(EC2Provider.resource)
        XCTAssertEqual(resources.map(\.name), ["web", "i-2"])
        XCTAssertEqual(resources.map(\.status), [.running, .stopped])
        XCTAssertEqual(resources.map(\.actions), [[.stop, .reboot], [.start]])
    }

    func testRDSAuroraUsesCluster() throws {
        let json = #"{"DBInstances":[{"DBInstanceIdentifier":"a1","DBInstanceStatus":"available","Engine":"aurora-postgresql","DBClusterIdentifier":"c1"}]}"#
        let db = try JSONDecoder.cli.decode(RDSProvider.Response.self, from: Data(json.utf8)).dbInstances[0]
        let resource = RDSProvider.resource(db)
        XCTAssertEqual(resource.prompt(for: .stop), "Stop cluster c1?")
        XCTAssertEqual(resource.prompt(for: .reboot), "Restart a1?")
        XCTAssertEqual(resource.status, .running)
    }

    func testCallerIdentityRoleName() throws {
        for (arn, name) in [("arn:aws:sts::123:assumed-role/Admin/14786498-9041-7017", "Admin"),
                            ("arn:aws:iam::123:user/team/bob", "bob"),
                            ("arn:aws:iam::123:root", "root")] {
            let json = #"{"UserId":"AROA:me","Account":"123","Arn":"\#(arn)"}"#
            let id = try JSONDecoder.cli.decode(CallerIdentity.self, from: Data(json.utf8))
            XCTAssertEqual(id.roleName, name)
        }
    }

    func testECSServiceStates() throws {
        let json = """
        {"services":[
          {"serviceArn":"arn:s/a","serviceName":"api","clusterArn":"arn:aws:ecs:x:1:cluster/prod","status":"ACTIVE",
           "desiredCount":2,"runningCount":2,"pendingCount":0,"launchType":"FARGATE"},
          {"serviceArn":"arn:s/b","serviceName":"worker","clusterArn":"arn:aws:ecs:x:1:cluster/prod","status":"ACTIVE",
           "desiredCount":0,"runningCount":0,"pendingCount":0}
        ]}
        """
        let services = try JSONDecoder.cli.decode(ECSProvider.ServiceDescriptions.self, from: Data(json.utf8)).services
        let resources = services.map(ECSProvider.resource)
        XCTAssertEqual(resources.map(\.status), [.running, .stopped])
        XCTAssertEqual(resources.map(\.actions), [[.stop, .reboot], [.start]])
        XCTAssertEqual(resources[0].detail, "prod · FARGATE · 2/2 running")
    }

    func testLambdaDecoding() throws {
        let json = #"{"Functions":[{"FunctionName":"fn","Runtime":"python3.13","MemorySize":128}]}"#
        let functions = try JSONDecoder.cli.decode(LambdaProvider.Response.self, from: Data(json.utf8)).functions
        XCTAssertEqual(functions.map(\.functionName), ["fn"])
    }
}
