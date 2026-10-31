import SwiftUI
import Charts

/// How daily spend changed over the last 14 days. Opened from the spend line in the header.
struct CostHistoryView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            ScrollView {
                content
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Button { state.costHistoryOpen = false } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            Text("Spend, last 14 days").font(.headline)
            Spacer()
            if state.costHistoryLoading {
                ProgressView().controlSize(.mini)
            } else {
                Button { state.loadCostHistory(force: true) } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh. Cost Explorer bills $0.01 per request.")
                .accessibilityLabel("Refresh spend history")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if let error = state.costHistoryError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(4)
                .textSelection(.enabled)
                .padding(.vertical, 4)
        }
        if let history = state.costHistory {
            HistoryBody(history: history)
        } else if state.costHistoryLoading {
            HStack { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else if state.costHistoryError == nil {
            Text("Sign in to see spend history").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
        }
    }
}

private struct HistoryBody: View {
    let history: CostHistory

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar
    }()

    private func money(_ amount: Decimal) -> String { amount.formatted(.currency(code: history.currency)) }
    private func double(_ amount: Decimal) -> Double { NSDecimalNumber(decimal: amount).doubleValue }
    private func dayNumber(_ date: Date) -> String { String(Self.utc.component(.day, from: date)) }
    private func dayName(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(timeZone: .gmt).weekday(.abbreviated).day().month(.abbreviated))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary
            chart
            if !history.movers.isEmpty { movers }
            daily
            Text("From Cost Explorer, which updates a few times a day, so the latest day can still grow. Days are UTC and amounts are before credits and refunds. Opening this costs $0.01, then it is reused for 6 hours.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(money(history.recentTotal)).font(.title2.weight(.semibold)).monospacedDigit()
                Text("in the last 7 days").foregroundStyle(.secondary)
            }
            changeLine
        }
    }

    @ViewBuilder
    private var changeLine: some View {
        let change = history.change
        // A jump from almost nothing is real but a percentage of it says little, so only show it when it is readable.
        let percent = history.changePercent.flatMap { abs($0) < 1000 ? $0 : nil }.map { " (\(Int(abs($0).rounded()))%)" } ?? ""
        if abs(double(change)) < 0.005 {
            Text("Same as the 7 days before").font(.callout).foregroundStyle(.secondary)
        } else if change > 0 {
            Label("Up \(money(change))\(percent) from the 7 days before", systemImage: "arrow.up.right")
                .font(.callout).foregroundStyle(.orange)
        } else {
            Label("Down \(money(-change))\(percent) from the 7 days before", systemImage: "arrow.down.right")
                .font(.callout).foregroundStyle(.green)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(history.days) { day in
                BarMark(x: .value("Day", dayNumber(day.date)), y: .value("Spend", double(day.total)))
                    .foregroundStyle(Color.accentColor)
            }
            if let today = history.today {
                BarMark(x: .value("Day", "Now"), y: .value("Spend", double(today.total)))
                    .foregroundStyle(Color.accentColor.opacity(0.35))
            }
        }
        .chartXAxis { AxisMarks { AxisValueLabel() } }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.quaternary)
                AxisValueLabel()
            }
        }
        .frame(height: 120)
        .accessibilityLabel("Daily spend for the last 14 days")
    }

    private var movers: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What changed").font(.subheadline.weight(.semibold))
            ForEach(history.movers) { mover in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mover.name).lineLimit(1).truncationMode(.tail).help(mover.name)
                        Text("\(money(mover.recent)) this week, \(money(mover.previous)) before")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    delta(mover.change)
                }
            }
        }
    }

    private var daily: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Day by day").font(.subheadline.weight(.semibold)).padding(.bottom, 2)
            if let today = history.today {
                HStack {
                    Text("Today so far").foregroundStyle(.secondary)
                    Spacer()
                    Text(money(today.total)).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            ForEach(Array(history.days.enumerated()).reversed(), id: \.element.id) { index, day in
                HStack(spacing: 8) {
                    Text(dayName(day.date))
                    Spacer()
                    if index > 0 { delta(day.total - history.days[index - 1].total).font(.subheadline) }
                    Text(money(day.total)).monospacedDigit().frame(minWidth: 64, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// An arrow and a word, so direction never depends on color alone.
    @ViewBuilder
    private func delta(_ amount: Decimal) -> some View {
        if abs(double(amount)) < 0.005 {
            Text("no change").font(.subheadline).foregroundStyle(.secondary)
        } else if amount > 0 {
            Label(money(amount), systemImage: "arrow.up")
                .foregroundStyle(.orange)
                .accessibilityLabel("up \(money(amount))")
        } else {
            Label(money(-amount), systemImage: "arrow.down")
                .foregroundStyle(.green)
                .accessibilityLabel("down \(money(-amount))")
        }
    }
}
