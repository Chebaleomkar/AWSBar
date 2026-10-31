import SwiftUI

struct PopoverView: View {
    @Environment(AppState.self) private var state
    @State var tab: Tab = .resources

    enum Tab: String, CaseIterable {
        case resources = "Overview"
        case runner = "Run"
        case history = "History"
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: tab) { state.costHistoryOpen = false }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            Group {
                if state.costHistoryOpen {
                    CostHistoryView()
                } else {
                    switch tab {
                    case .resources: ResourcesView()
                    case .runner: CommandRunnerView()
                    case .history: HistoryView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            FooterView()
                .background(Color.primary.opacity(0.04))
        }
        .frame(width: 400, height: 560)
    }
}

private struct FooterView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack {
            if state.located && state.awsURL == nil {
                Label("AWS CLI not found", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if let url = state.awsURL {
                Text(url.path).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
