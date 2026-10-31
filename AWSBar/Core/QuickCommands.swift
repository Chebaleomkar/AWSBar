import Foundation

/// One-click, read-only AWS CLI commands for the Run tab. None of them change anything in the account.
struct QuickCommand: Identifiable, Equatable, Sendable {
    let title: String
    let symbol: String
    let help: String
    let command: String
    var isSecurity = false
    var id: String { title }
}

extension QuickCommand {
    static func all(now: Date = Date()) -> [QuickCommand] {
        let window = CostReport.window(now: now)
        let cost = "ce get-cost-and-usage --time-period Start=\(CostReport.day(window.thisMonth)),End=\(CostReport.day(window.end))"
            + " --granularity MONTHLY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE"
            + #" --query "ResultsByTime[].Groups[].[Keys[0],Metrics.UnblendedCost.Amount]" --output table --region us-east-1"#
        return [
            QuickCommand(title: "Who am I", symbol: "person.crop.circle",
                         help: "The account and role you are signed in as.", command: "sts get-caller-identity"),
            QuickCommand(title: "Running servers", symbol: "server.rack",
                         help: "EC2 instances that are running now.",
                         command: "ec2 describe-instances --filters Name=instance-state-name,Values=running"
                             + #" --query "Reservations[].Instances[].[Tags[?Key=='Name']|[0].Value,InstanceId,InstanceType,State.Name]" --output table"#),
            QuickCommand(title: "Databases", symbol: "cylinder.split.1x2",
                         help: "RDS databases and whether they are available or stopped.",
                         command: #"rds describe-db-instances --query "DBInstances[].[DBInstanceIdentifier,DBInstanceStatus,Engine]" --output table"#),
            QuickCommand(title: "Container clusters", symbol: "square.stack.3d.up",
                         help: "ECS clusters in this region.", command: "ecs list-clusters"),
            QuickCommand(title: "Load balancers", symbol: "arrow.triangle.branch",
                         help: "Load balancers in this region. They bill by the hour while they exist.",
                         command: #"elbv2 describe-load-balancers --query "LoadBalancers[].[LoadBalancerName,Type,State.Code]" --output table"#),
            QuickCommand(title: "Buckets", symbol: "archivebox",
                         help: "S3 buckets in the account.", command: "s3 ls"),
            QuickCommand(title: "Functions", symbol: "function",
                         help: "Lambda functions in this region.",
                         command: #"lambda list-functions --query "Functions[].[FunctionName,Runtime]" --output table"#),
            QuickCommand(title: "Cost this month", symbol: "dollarsign.circle",
                         help: "Charges so far this month, by service. Cost Explorer bills $0.01 per request.", command: cost),
            QuickCommand(title: "Open firewall rules", symbol: "lock.open",
                         help: "Security groups that allow traffic from anywhere on the internet (0.0.0.0/0).",
                         command: "ec2 describe-security-groups --filters Name=ip-permission.cidr,Values=0.0.0.0/0"
                             + #" --query "SecurityGroups[].[GroupId,GroupName,VpcId]" --output table"#,
                         isSecurity: true),
            QuickCommand(title: "Unencrypted disks", symbol: "externaldrive.badge.xmark",
                         help: "EBS disks in this region that are not encrypted.",
                         command: "ec2 describe-volumes --filters Name=encrypted,Values=false"
                             + #" --query "Volumes[].[VolumeId,Size,State]" --output table"#,
                         isSecurity: true),
            QuickCommand(title: "IAM users", symbol: "person.2",
                         help: "People and keys with access. Compare with MFA devices to spot users without MFA.",
                         command: #"iam list-users --query "Users[].[UserName,CreateDate,PasswordLastUsed]" --output table"#,
                         isSecurity: true),
            QuickCommand(title: "MFA devices", symbol: "key",
                         help: "Which users have an MFA device set up.",
                         command: #"iam list-virtual-mfa-devices --query "VirtualMFADevices[].[User.UserName,SerialNumber]" --output table"#,
                         isSecurity: true),
            QuickCommand(title: "Secrets", symbol: "lock",
                         help: "Names of stored secrets and when they last changed. Never shows the values.",
                         command: #"secretsmanager list-secrets --query "SecretList[].[Name,LastChangedDate]" --output table"#,
                         isSecurity: true),
            QuickCommand(title: "Recent sign-ins", symbol: "clock.arrow.circlepath",
                         help: "The last 10 console sign-ins from the audit log.",
                         command: "cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=ConsoleLogin"
                             + #" --max-results 10 --query "Events[].[EventTime,Username]" --output table"#,
                         isSecurity: true),
        ]
    }
}
