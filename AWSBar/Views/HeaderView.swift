import SwiftUI

struct HeaderView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Menu {
                    if state.profiles.isEmpty {
                        Text("No profiles in ~/.aws")
                    }
                    ForEach(state.profiles) { profile in
                        Button {
                            Task { await state.selectProfile(profile.name) }
                        } label: {
                            if profile.name == state.selectedProfileName {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(profile.name)
                            }
                        }
                    }
                } label: {
                    Text(state.selectedProfileName).font(.title3.weight(.semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Switch profile")
                Spacer()
                Text(state.region)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await state.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
                .accessibilityLabel("Refresh")
                .keyboardShortcut("r")
            }
            identity
        }
    }

    @ViewBuilder
    private var identity: some View {
        switch state.auth {
        case .unknown, .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking credentials…").foregroundStyle(.secondary)
            }
            .font(.callout)
        case .signedIn:
            if let id = state.identity {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(id.account)
                            .monospacedDigit()
                            .textSelection(.enabled)
                        Text(id.roleName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(id.arn)
                    }
                    spend
                }
                .font(.callout)
            }
        case .loggingIn:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Finish signing in in your browser…").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { state.cancelLogin() }
            }
            .font(.callout)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    StatusDot(status: .failed)
                    Text("Not signed in").font(.callout.weight(.medium))
                    Spacer()
                    Button("Retry") { Task { await state.checkAuth() } }
                    if state.loginArguments != nil {
                        Button("Login") { state.login() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
    }
}

private extension HeaderView {
    @ViewBuilder
    var spend: some View {
        if let costs = state.costs {
            let money = { (amount: Decimal) in amount.formatted(.currency(code: costs.currency)) }
            HStack(spacing: 6) {
                Text(money(costs.thisMonth)).monospacedDigit()
                Text("this month").foregroundStyle(.secondary)
                if costs.total != costs.thisMonth {
                    Text(money(costs.total)).monospacedDigit()
                    Text("since \(costs.since.formatted(Date.FormatStyle(timeZone: .gmt).month(.abbreviated).year()))")
                        .foregroundStyle(.secondary)
                }
            }
            .help("Charges before credits and refunds, from Cost Explorer, which updates a few times a day. "
                + "Last month: \(money(costs.lastMonth)). Checked \(costs.fetched.formatted(date: .omitted, time: .shortened)).")
        } else if state.costsLoading {
            Text("Loading costs…").foregroundStyle(.secondary)
        } else if state.costsError != nil {
            Text("Costs unavailable").foregroundStyle(.secondary)
                .help(state.costsError ?? "")
        }
    }
}

struct StatusDot: View {
    let status: ResourceStatus

    var body: some View {
        Group {
            if status == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityElement()
        .accessibilityLabel(status.title)
    }

    private var color: Color {
        switch status {
        case .running: .green
        case .stopped: .red
        case .transitioning: .orange
        case .failed: .red
        case .neutral: .clear
        }
    }
}
