import SwiftUI

struct ResourcesView: View {
    @Environment(AppState.self) private var state

    /// Kinds that feed the summary strip and the status words in the spend list, so they load even when collapsed.
    private static let liveKinds: [ServiceKind] = [.ec2, .rds, .ecs, .elb]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                SummaryStrip()
                ForEach(ServiceGroup.allCases) { group in
                    GroupSectionView(group: group)
                }
                ActiveServicesSection()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .task(id: "\(state.selectedProfileName)|\(state.region)|\(state.auth == .signedIn)") {
            for kind in Self.liveKinds where state.provider(for: kind) != nil && state.sections[kind]?.loaded != true {
                Task { await state.refresh(kind) }
            }
        }
    }
}

/// How many resources are running, stopped or failed right now, so nobody has to open a section to find out.
private struct SummaryStrip: View {
    @Environment(AppState.self) private var state

    private static let kinds: [ServiceKind] = [.ec2, .rds, .ecs, .elb]

    private var resources: [Resource] { Self.kinds.flatMap { state.sections[$0]?.resources ?? [] } }
    private var anyLoaded: Bool { Self.kinds.contains { state.sections[$0]?.loaded == true } }

    var body: some View {
        if anyLoaded {
            let statuses = resources.map(\.status)
            HStack(spacing: 14) {
                item(.running, statuses)
                item(.stopped, statuses)
                item(.failed, statuses)
                if statuses.contains(.transitioning) { item(.transitioning, statuses) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }

    private func item(_ status: ResourceStatus, _ all: [ResourceStatus]) -> some View {
        let count = all.filter { $0 == status }.count
        return HStack(spacing: 5) {
            StatusDot(status: status)
            Text("\(count) \(status.title.lowercased())").monospacedDigit()
        }
        .font(.callout)
        .foregroundStyle(count == 0 ? .secondary : .primary)
    }
}

private struct GroupSectionView: View {
    @Environment(AppState.self) private var state
    let group: ServiceGroup

    private var sections: [SectionState] { group.kinds.map { state.sections[$0] ?? SectionState() } }
    private var isExpanded: Bool { state.isExpanded(group) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: group.title, symbol: group.symbol,
                          count: sections.allSatisfy(\.loaded) ? sections.map(\.resources.count).reduce(0, +) : nil,
                          isExpanded: isExpanded, isLoading: sections.contains(where: \.isLoading),
                          refresh: state.auth == .signedIn ? { group.kinds.forEach { kind in Task { await state.refresh(kind) } } } : nil) {
                withAnimation(.snappy(duration: 0.2)) { state.toggle(group) }
            }
            if isExpanded {
                content
                    .padding(.leading, 22)
                    .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let note = unavailableNote {
            Text(note).font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
        } else if sections.allSatisfy(\.loaded) && sections.allSatisfy({ $0.resources.isEmpty && $0.error == nil }) {
            Text("Nothing here").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
        }
        ForEach(group.kinds) { kind in
            let section = state.sections[kind] ?? SectionState()
            if let error = section.error {
                Label("\(kind.title): \(error)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            }
            ForEach(section.resources) { resource in
                ResourceRow(resource: resource, kind: kind, isBusy: section.actionsInFlight.contains(resource.id))
            }
        }
    }

    private var unavailableNote: String? {
        if state.located && state.awsURL == nil { return "AWS CLI not found" }
        if case .failed = state.auth { return "Sign in to load \(group.title)" }
        return nil
    }
}

private struct SectionHeader: View {
    let title: String
    let symbol: String
    let count: Int?
    let isExpanded: Bool
    let isLoading: Bool
    let refresh: (() -> Void)?
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title).font(.headline)
            if let count {
                Text("\(count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isLoading {
                ProgressView().controlSize(.mini)
            } else if isExpanded, let refresh {
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh \(title)")
                .accessibilityLabel("Refresh \(title)")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}

/// Every service Cost Explorer saw usage for this month or last month, with what it cost.
private struct ActiveServicesSection: View {
    @Environment(AppState.self) private var state
    @AppStorage("activeServicesExpanded") private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Spend by service", symbol: "square.grid.2x2",
                          count: state.costs?.services.count,
                          isExpanded: isExpanded, isLoading: state.costsLoading,
                          refresh: state.auth == .signedIn ? { state.refreshCosts(force: true) } : nil) {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            }
            if isExpanded {
                content
                    .padding(.leading, 22)
                    .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = state.costsError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(4)
                .textSelection(.enabled)
                .padding(.vertical, 4)
        }
        if case .failed = state.auth {
            Text("Sign in to load services").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
        } else if let costs = state.costs {
            if costs.services.isEmpty {
                Text("No usage this month or last month").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(costs.services) { service in
                ServiceCostRow(service: service, currency: costs.currency, live: live(for: service))
            }
        }
    }

    /// Cost Explorer only reports charges, so liveness comes from the lists above. Other services get no dot.
    private func live(for service: CostReport.Service) -> (status: ResourceStatus, text: String)? {
        let kind: ServiceKind
        switch service.name {
        case "Amazon Elastic Compute Cloud - Compute": kind = .ec2
        case "Amazon Relational Database Service": kind = .rds
        case "Amazon Elastic Container Service": kind = .ecs
        case "Amazon Elastic Load Balancing": kind = .elb
        default: return nil
        }
        guard let section = state.sections[kind], section.loaded, section.error == nil else { return nil }
        let statuses = section.resources.map(\.status)
        if statuses.isEmpty { return (.neutral, "None in \(state.region)") }
        for status in [ResourceStatus.running, .transitioning, .failed] where statuses.contains(status) {
            return (status, status.title)
        }
        return (.stopped, ResourceStatus.stopped.title)
    }
}

private struct ServiceCostRow: View {
    let service: CostReport.Service
    let currency: String
    let live: (status: ResourceStatus, text: String)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(status: live?.status ?? .neutral)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(service.name)
                let note = [live?.text,
                            service.lastMonth != 0 ? "\(service.lastMonth.formatted(.currency(code: currency))) last month" : nil]
                    .compactMap { $0 }.joined(separator: " · ")
                if !note.isEmpty {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Text(service.thisMonth.formatted(.currency(code: currency)))
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .padding(.leading, 22)
        .padding(.trailing, 6)
    }
}

private enum RowWindow {
    case shell(ShellTarget)
    case bucket(BucketTarget)

    var title: String {
        switch self {
        case .shell: "Open Shell"
        case .bucket: "Browse"
        }
    }

    var help: String {
        switch self {
        case .shell: "Double-click to open a shell"
        case .bucket: "Double-click to browse"
        }
    }
}

private struct ResourceRow: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    let resource: Resource
    let kind: ServiceKind
    let isBusy: Bool
    @State private var confirming: ResourceAction?
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                StatusDot(status: resource.status)
                    .help(resource.statusText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(resource.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(resource.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if resource.status != .neutral && !(hovering || focused) {
                    Text(resource.status.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if isBusy {
                    ProgressView().controlSize(.small)
                } else if hovering || focused {
                    ForEach(resource.actions, id: \.self) { action in
                        Button {
                            request(action)
                        } label: {
                            Image(systemName: action.symbol).frame(width: 16)
                        }
                        .buttonStyle(.borderless)
                        .help(action.title)
                        .accessibilityLabel(action.title)
                    }
                }
            }
            if let action = confirming {
                ConfirmRow(action: action, prompt: resource.prompt(for: action),
                           confirmation: resource.confirmation(for: action, in: kind),
                           onConfirm: {
                               confirming = nil
                               perform(action)
                           },
                           onCancel: { confirming = nil })
                    .id(action)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering || focused ? Color.primary.opacity(0.06) : .clear))
        .onHover { hovering = $0 }
        .focusable()
        .focused($focused)
        // A confirm row left open (or half typed) must not still be armed when the popover reopens later.
        .onDisappear { confirming = nil }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if confirming == nil, let window { open(window) } }
        .help(window?.help ?? "")
        .contextMenu {
            if let window {
                Button(window.title) { open(window) }
                Divider()
            }
            if !resource.actions.isEmpty && !isBusy {
                ForEach(resource.actions, id: \.self) { action in
                    Button(action.title) { request(action) }
                }
                Divider()
            }
            Button("Copy ID") { copy(resource.id) }
            Button("Copy Name") { copy(resource.name) }
        }
    }

    private var window: RowWindow? {
        switch kind {
        case .ec2 where resource.status == .running:
            .shell(ShellTarget(instanceId: resource.id, name: resource.name,
                               profile: state.selectedProfileName, region: state.region))
        case .s3:
            .bucket(BucketTarget(bucket: resource.id, profile: state.selectedProfileName, region: state.region))
        default:
            nil
        }
    }

    private func open(_ window: RowWindow) {
        switch window {
        case .shell(let target): openWindow(id: "ec2-shell", value: target)
        case .bucket(let target): openWindow(id: "s3-bucket", value: target)
        }
        NSApp.activate()
    }

    private func request(_ action: ResourceAction) {
        if resource.confirmation(for: action, in: kind) == .none {
            perform(action)
        } else {
            confirming = action
        }
    }

    private func perform(_ action: ResourceAction) {
        Task { await state.perform(action, on: resource, in: kind) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Server stops are typed out because one stray click in the cramped popover once stopped production.
private struct ConfirmRow: View {
    let action: ResourceAction
    let prompt: String
    let confirmation: Confirmation
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    private var confirmed: Bool {
        if case .typeName(let expected) = confirmation { return !expected.isEmpty && typed == expected }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .typeName(let expected) = confirmation {
                Text("\(prompt) Type its name to confirm.")
                    .font(.caption)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    TextField(expected, text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .focused($fieldFocused)
                        .onSubmit { if confirmed { onConfirm() } }
                        .onExitCommand(perform: onCancel)
                        .onAppear { fieldFocused = true }
                    buttons
                }
            } else {
                HStack(spacing: 8) {
                    Text(prompt)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    buttons
                }
            }
        }
        .controlSize(.small)
        .padding(.leading, 16)
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Cancel", action: onCancel)
            .keyboardShortcut(.cancelAction)
        Button(action.title, role: .destructive, action: onConfirm)
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!confirmed)
    }
}
