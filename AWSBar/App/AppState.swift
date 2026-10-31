import Foundation
import Observation

struct SectionState {
    var resources: [Resource] = []
    var isLoading = false
    var error: String?
    var loaded = false
    var actionsInFlight: Set<Resource.ID> = []
}

enum AuthState: Equatable {
    case unknown, checking, signedIn, failed(String), loggingIn
}

struct RunnerOutput {
    let exitCode: Int32
    let text: String
    let duration: TimeInterval
}

@MainActor @Observable
final class AppState {
    var awsURL: URL?
    var located = false
    private var bootstrapTask: Task<Void, Never>?

    var profiles: [AWSProfile] = []
    var selectedProfileName: String {
        didSet { UserDefaults.standard.set(selectedProfileName, forKey: "selectedProfile") }
    }
    var identity: CallerIdentity?
    var auth: AuthState = .unknown
    private var loginTask: Task<Void, Never>?

    var sections: [ServiceKind: SectionState] = [:]
    var expanded: Set<ServiceKind> {
        didSet { UserDefaults.standard.set(expanded.map(\.rawValue), forKey: "expandedSections") }
    }

    private(set) var costs: CostReport?
    private(set) var costsError: String?
    private var costsTask: Task<Void, Never>?
    var costsLoading: Bool { costsTask != nil }

    var runnerCommand = "sts get-caller-identity"
    private(set) var runnerOutput: RunnerOutput?
    private(set) var runnerError: String?
    private(set) var runnerTask: Task<Void, Never>?
    /// Commands run this session, newest first, so the Run tab can offer them again.
    private(set) var recentCommands: [String] = []

    let history = HistoryStore()

    init() {
        selectedProfileName = UserDefaults.standard.string(forKey: "selectedProfile") ?? "default"
        let saved = UserDefaults.standard.stringArray(forKey: "expandedSections")
        expanded = Set((saved ?? ["ec2"]).compactMap(ServiceKind.init(rawValue:)))
    }

    var selectedProfile: AWSProfile? { profiles.first { $0.name == selectedProfileName } }

    var region: String {
        selectedProfile?.region
            ?? ProcessInfo.processInfo.environment["AWS_REGION"]
            ?? ProcessInfo.processInfo.environment["AWS_DEFAULT_REGION"]
            ?? "us-east-1"
    }

    private func runner(_ url: URL) -> Runner {
        let history = history
        return Runner(executable: url) { entry in await history.record(entry) }
    }

    var aws: AWSContext? {
        awsURL.map { AWSContext(runner: runner($0), profile: selectedProfileName, region: region) }
    }

    private func contexts(profile: String, region: String) -> (recorded: AWSContext, unrecorded: AWSContext)? {
        guard let awsURL else { return nil }
        return (AWSContext(runner: runner(awsURL), profile: profile, region: region),
                AWSContext(runner: Runner(executable: awsURL) { _ in }, profile: profile, region: region))
    }

    func context(profile: String, region: String) -> AWSContext? {
        contexts(profile: profile, region: region)?.recorded
    }

    func s3(profile: String, region: String) -> S3Client? {
        contexts(profile: profile, region: region).map { S3Client(aws: $0.recorded, previews: $0.unrecorded) }
    }

    func provider(for kind: ServiceKind) -> (any ResourceProvider)? {
        guard let aws, auth == .signedIn else { return nil }
        return switch kind {
        case .ec2: EC2Provider(aws: aws)
        case .rds: RDSProvider(aws: aws)
        case .ecs: ECSProvider(aws: aws)
        case .elb: ELBProvider(aws: aws)
        case .lambda: LambdaProvider(aws: aws)
        case .s3: S3Provider(aws: aws)
        }
    }

    /// Callers wait for the first bootstrap to finish, so a shell window that opens at launch sees `awsURL`.
    func bootstrap() async {
        // Unit tests launch the app as their host, and that launch must not call AWS.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        if bootstrapTask == nil {
            bootstrapTask = Task {
                awsURL = await CLI.locate("aws")
                located = true
                reloadProfiles()
                await checkAuth()
            }
        }
        await bootstrapTask?.value
    }

    func reloadProfiles() {
        profiles = AWSProfiles.load()
        if !profiles.isEmpty, selectedProfile == nil {
            selectedProfileName = profiles[0].name
        }
    }

    func selectProfile(_ name: String) async {
        guard name != selectedProfileName else { return }
        cancelLogin()
        selectedProfileName = name
        sections = [:]
        resetCosts()
        await checkAuth()
    }

    func checkAuth() async {
        guard let aws else {
            auth = .failed("AWS CLI not found. Install it with `brew install awscli`.")
            return
        }
        guard loginTask == nil else { return }
        let profile = aws.profile
        auth = .checking
        do {
            let id = try await aws.callerIdentity()
            guard profile == selectedProfileName, loginTask == nil else { return }
            identity = id
            auth = .signedIn
            refreshExpanded()
            refreshCosts()
        } catch {
            guard profile == selectedProfileName, loginTask == nil else { return }
            identity = nil
            auth = .failed(error.localizedDescription)
        }
    }

    var loginArguments: [String]? {
        guard awsURL != nil, let profile = selectedProfile else { return nil }
        return switch profile.loginKind {
        case .sso: ["sso", "login", "--profile", profile.name]
        case .console: ["login", "--profile", profile.name]
        case .other: nil
        }
    }

    func login() {
        guard let aws, let args = loginArguments, loginTask == nil else { return }
        let profile = aws.profile
        auth = .loggingIn
        loginTask = Task {
            var failure: String?
            do {
                try await aws.runner.check(args)
            } catch {
                failure = error.localizedDescription
            }
            // cancelLogin already reset the state, and a newer login may own loginTask.
            guard !Task.isCancelled else { return }
            loginTask = nil
            if let failure, profile == selectedProfileName {
                auth = .failed(failure)
            } else {
                await checkAuth()
            }
        }
    }

    func cancelLogin() {
        guard let loginTask else { return }
        loginTask.cancel()
        self.loginTask = nil
        auth = .failed("Login cancelled.")
    }

    func toggle(_ kind: ServiceKind) {
        if expanded.remove(kind) == nil {
            expanded.insert(kind)
            if sections[kind]?.loaded != true { Task { await refresh(kind) } }
        }
    }

    func isExpanded(_ group: ServiceGroup) -> Bool {
        group.kinds.contains(where: expanded.contains)
    }

    func toggle(_ group: ServiceGroup) {
        if isExpanded(group) {
            group.kinds.forEach { expanded.remove($0) }
        } else {
            group.kinds.forEach { expanded.insert($0) }
            for kind in group.kinds where sections[kind]?.loaded != true { Task { await refresh(kind) } }
        }
    }

    func refreshExpanded() {
        for kind in expanded {
            Task { await refresh(kind) }
        }
    }

    func refreshAll() async {
        let before = (selectedProfileName, region)
        reloadProfiles()
        if before != (selectedProfileName, region) { sections = [:] }
        if before.0 != selectedProfileName { resetCosts() }
        await checkAuth()
    }

    /// Cost Explorer bills $0.01 per request and updates only a few times a day, so a report is reused for 6 hours
    /// unless `force` is set.
    func refreshCosts(force: Bool = false) {
        guard let aws, auth == .signedIn, costsTask == nil else { return }
        if !force, let costs, Date().timeIntervalSince(costs.fetched) < 6 * 3600 { return }
        costsTask = Task {
            do {
                let report = try await aws.costReport()
                guard !Task.isCancelled else { return }
                costs = report
                costsError = nil
            } catch {
                guard !Task.isCancelled else { return }
                costsError = error.localizedDescription
            }
            costsTask = nil
        }
    }

    private func resetCosts() {
        costsTask?.cancel()
        costsTask = nil
        costs = nil
        costsError = nil
    }

    func refresh(_ kind: ServiceKind) async {
        guard let provider = provider(for: kind) else { return }
        let context = (selectedProfileName, region)
        func isCurrent() -> Bool { context == (selectedProfileName, region) }
        sections[kind, default: SectionState()].isLoading = true
        do {
            let resources = try await provider.list()
            guard isCurrent() else { return }
            sections[kind, default: SectionState()].resources = resources
            sections[kind]?.error = nil
        } catch {
            guard isCurrent() else { return }
            sections[kind, default: SectionState()].error = error.localizedDescription
        }
        sections[kind]?.isLoading = false
        sections[kind]?.loaded = true
    }

    func perform(_ action: ResourceAction, on resource: Resource, in kind: ServiceKind) async {
        guard let provider = provider(for: kind) else { return }
        sections[kind, default: SectionState()].actionsInFlight.insert(resource.id)
        do {
            try await provider.perform(action, on: resource)
        } catch {
            sections[kind]?.actionsInFlight.remove(resource.id)
            await refresh(kind)
            sections[kind]?.error = error.localizedDescription
            return
        }
        sections[kind]?.actionsInFlight.remove(resource.id)
        await refresh(kind)
        // EC2 and RDS take seconds to minutes to settle, and some changes show up late,
        // so always check once more, then back off while it's still transitioning.
        for (attempt, delay) in [5, 10, 15, 30, 30, 30, 30, 30].enumerated() {
            if attempt > 0, status(of: resource.id, in: kind) != .transitioning { break }
            try? await Task.sleep(for: .seconds(delay))
            await refresh(kind)
        }
    }

    private func status(of id: Resource.ID, in kind: ServiceKind) -> ResourceStatus? {
        sections[kind]?.resources.first { $0.id == id }?.status
    }

    func startRun() {
        guard runnerTask == nil, let awsURL,
              !runnerCommand.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let args = runnerArguments(runnerCommand, profile: selectedProfileName, region: region)
        let runner = runner(awsURL)
        let line = runnerCommand.trimmingCharacters(in: .whitespaces)
        recentCommands = Array(([line] + recentCommands.filter { $0 != line }).prefix(5))
        runnerError = nil
        let started = Date()
        runnerTask = Task {
            defer { runnerTask = nil }
            do {
                let result = try await runner.run(args)
                try Task.checkCancellation()
                runnerOutput = RunnerOutput(exitCode: result.exitCode, text: Self.displayText(result),
                                            duration: Date().timeIntervalSince(started))
            } catch {
                runnerOutput = nil
                runnerError = error is CancellationError ? "Cancelled." : error.localizedDescription
            }
        }
    }

    func run(_ command: String) {
        guard runnerTask == nil else { return }
        runnerCommand = command
        startRun()
    }

    func cancelRun() {
        runnerTask?.cancel()
    }

    /// SwiftUI Text gets slow with very large strings, so cap what's rendered.
    private nonisolated static func displayText(_ result: CLIResult) -> String {
        let text = [result.stdoutString, result.stderrString].filter { !$0.isEmpty }.joined(separator: "\n")
        let limit = 200_000
        return text.count > limit ? String(text.prefix(limit)) + "\n… (truncated)" : text
    }
}

func runnerArguments(_ line: String, profile: String, region: String) -> [String] {
    var args = shellSplit(line)
    if args.first == "aws" { args.removeFirst() }
    func has(_ flag: String) -> Bool { args.contains { $0 == flag || $0.hasPrefix(flag + "=") } }
    if !has("--profile") { args += ["--profile", profile] }
    if !has("--region") { args += ["--region", region] }
    return args
}
