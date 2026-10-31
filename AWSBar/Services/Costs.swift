import Foundation

/// What AWS charged the account, by service, from Cost Explorer. Amounts are before credits and refunds.
struct CostReport: Equatable, Sendable {
    struct Service: Equatable, Sendable, Identifiable {
        let name: String
        let thisMonth: Decimal
        let lastMonth: Decimal
        var id: String { name }
    }

    let currency: String
    let thisMonth: Decimal
    let lastMonth: Decimal
    /// Everything charged from `since`, the first month with a charge in the last 12, until today.
    let total: Decimal
    let since: Date
    /// Services with usage this month or last month, most expensive first.
    let services: [Service]
    let fetched: Date
}

struct CostResponse: Decodable {
    struct Result: Decodable {
        let timePeriod: Period
        let groups: [Group]
    }

    struct Period: Decodable { let start: String }

    struct Group: Decodable {
        let keys: [String]
        let metrics: Metrics
    }

    struct Metrics: Decodable { let unblendedCost: Amount }

    struct Amount: Decodable {
        let amount: String
        let unit: String
    }

    let resultsByTime: [Result]
    let nextPageToken: String?
}

extension CostReport {
    /// Cost Explorer works in UTC calendar months.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func day(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }

    /// This month and the 11 before it. End is exclusive, so it's tomorrow.
    static func window(now: Date) -> (start: Date, end: Date, thisMonth: Date, lastMonth: Date) {
        let thisMonth = calendar.dateInterval(of: .month, for: now)!.start
        return (calendar.date(byAdding: .month, value: -11, to: thisMonth)!,
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!,
                thisMonth,
                calendar.date(byAdding: .month, value: -1, to: thisMonth)!)
    }

    init(_ pages: [CostResponse], now: Date) {
        let window = Self.window(now: now)
        let thisKey = Self.day(window.thisMonth)
        let lastKey = Self.day(window.lastMonth)
        var this: [String: Decimal] = [:]
        var last: [String: Decimal] = [:]
        var total: Decimal = 0
        var currency: String?
        var firstCharged: String?
        for result in pages.flatMap(\.resultsByTime) {
            for group in result.groups {
                let name = group.keys.first ?? "Other"
                let amount = Decimal(string: group.metrics.unblendedCost.amount) ?? 0
                currency = currency ?? group.metrics.unblendedCost.unit
                total += amount
                if amount != 0, firstCharged.map({ result.timePeriod.start < $0 }) ?? true {
                    firstCharged = result.timePeriod.start
                }
                if result.timePeriod.start == thisKey { this[name, default: 0] += amount }
                if result.timePeriod.start == lastKey { last[name, default: 0] += amount }
            }
        }
        // Tax is charged with the bill but isn't a service.
        let names = Set(this.keys).union(last.keys).subtracting(["Tax"])
        self.init(currency: currency ?? "USD",
                  thisMonth: this.values.reduce(0, +),
                  lastMonth: last.values.reduce(0, +),
                  total: total,
                  since: firstCharged.flatMap { try? Date($0, strategy: .iso8601.year().month().day()) } ?? window.thisMonth,
                  services: names.map { Service(name: $0, thisMonth: this[$0] ?? 0, lastMonth: last[$0] ?? 0) }
                      .sorted { ($1.thisMonth, $1.lastMonth, $0.name) < ($0.thisMonth, $0.lastMonth, $1.name) },
                  fetched: now)
    }
}

extension AWSContext {
    /// Cost Explorer bills $0.01 per request, so callers should reuse a report instead of fetching on every refresh.
    func costReport(now: Date = Date()) async throws -> CostReport {
        let window = CostReport.window(now: now)
        // Cost Explorer only has an endpoint in us-east-1.
        let ce = AWSContext(runner: runner, profile: profile, region: "us-east-1")
        var pages: [CostResponse] = []
        var token: String?
        repeat {
            var args = ["ce", "get-cost-and-usage",
                        "--time-period", "Start=\(CostReport.day(window.start)),End=\(CostReport.day(window.end))",
                        "--granularity", "MONTHLY",
                        "--metrics", "UnblendedCost",
                        "--group-by", "Type=DIMENSION,Key=SERVICE",
                        "--filter", #"{"Not":{"Dimensions":{"Key":"RECORD_TYPE","Values":["Credit","Refund"]}}}"#]
            if let token { args += ["--next-page-token", token] }
            let page = try await ce.runner.decode(CostResponse.self, ce.args(args))
            pages.append(page)
            token = page.nextPageToken
        } while token != nil
        return CostReport(pages, now: now)
    }
}

/// Daily spend for the last 14 complete days, plus today so far, from Cost Explorer. Amounts are before credits and refunds.
struct CostHistory: Equatable, Sendable {
    struct Day: Equatable, Sendable, Identifiable {
        let date: Date
        let total: Decimal
        var id: Date { date }
    }

    struct Mover: Equatable, Sendable, Identifiable {
        let name: String
        let recent: Decimal
        let previous: Decimal
        var change: Decimal { recent - previous }
        var id: String { name }
    }

    static let dayCount = 14

    let currency: String
    /// Complete UTC days, oldest first. Days with no charges are zero.
    let days: [Day]
    /// Today so far. Cost Explorer lags, so this is usually low.
    let today: Day?
    /// The last 7 complete days and the 7 before them.
    let recentTotal: Decimal
    let previousTotal: Decimal
    /// Services whose 7-day spend changed most, largest change first.
    let movers: [Mover]
    let fetched: Date

    var change: Decimal { recentTotal - previousTotal }

    /// Nil when the earlier week had no charges, because a percentage of zero means nothing.
    var changePercent: Double? {
        previousTotal > 0 ? NSDecimalNumber(decimal: change / previousTotal * 100).doubleValue : nil
    }
}

extension CostHistory {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// The 14 complete days before today, and today. End is exclusive, so it's tomorrow.
    static func window(now: Date) -> (start: Date, end: Date, today: Date) {
        let today = calendar.startOfDay(for: now)
        return (calendar.date(byAdding: .day, value: -dayCount, to: today)!,
                calendar.date(byAdding: .day, value: 1, to: today)!,
                today)
    }

    init(_ pages: [CostResponse], now: Date) {
        let window = Self.window(now: now)
        var totals: [Date: Decimal] = [:]
        var services: [Date: [String: Decimal]] = [:]
        var currency: String?
        for result in pages.flatMap(\.resultsByTime) {
            guard let date = try? Date(result.timePeriod.start, strategy: .iso8601.year().month().day()) else { continue }
            for group in result.groups {
                let amount = Decimal(string: group.metrics.unblendedCost.amount) ?? 0
                currency = currency ?? group.metrics.unblendedCost.unit
                totals[date, default: 0] += amount
                // Tax is charged with the bill but isn't a service.
                let name = group.keys.first ?? "Other"
                if name != "Tax" { services[date, default: [:]][name, default: 0] += amount }
            }
        }
        let days = (1...Self.dayCount).reversed().map { back -> Day in
            let date = Self.calendar.date(byAdding: .day, value: -back, to: window.today)!
            return Day(date: date, total: totals[date] ?? 0)
        }
        let previousDays = days.prefix(7), recentDays = days.suffix(7)
        func perService(_ slice: some Sequence<Day>) -> [String: Decimal] {
            slice.reduce(into: [:]) { sum, day in
                for (name, amount) in services[day.date] ?? [:] { sum[name, default: 0] += amount }
            }
        }
        let recent = perService(recentDays), previous = perService(previousDays)
        let movers = Set(recent.keys).union(previous.keys)
            .map { Mover(name: $0, recent: recent[$0] ?? 0, previous: previous[$0] ?? 0) }
            .filter { abs(NSDecimalNumber(decimal: $0.change).doubleValue) >= 0.005 }
            .sorted { (abs(NSDecimalNumber(decimal: $0.change).doubleValue), $1.name) > (abs(NSDecimalNumber(decimal: $1.change).doubleValue), $0.name) }
        self.init(currency: currency ?? "USD",
                  days: days,
                  today: totals[window.today].map { Day(date: window.today, total: $0) },
                  recentTotal: recentDays.reduce(0) { $0 + $1.total },
                  previousTotal: previousDays.reduce(0) { $0 + $1.total },
                  movers: Array(movers.prefix(5)),
                  fetched: now)
    }
}

extension AWSContext {
    /// One Cost Explorer request, billed at $0.01, so callers reuse the result.
    func costHistory(now: Date = Date()) async throws -> CostHistory {
        let window = CostHistory.window(now: now)
        // Cost Explorer only has an endpoint in us-east-1.
        let ce = AWSContext(runner: runner, profile: profile, region: "us-east-1")
        var pages: [CostResponse] = []
        var token: String?
        repeat {
            var args = ["ce", "get-cost-and-usage",
                        "--time-period", "Start=\(CostReport.day(window.start)),End=\(CostReport.day(window.end))",
                        "--granularity", "DAILY",
                        "--metrics", "UnblendedCost",
                        "--group-by", "Type=DIMENSION,Key=SERVICE",
                        "--filter", #"{"Not":{"Dimensions":{"Key":"RECORD_TYPE","Values":["Credit","Refund"]}}}"#]
            if let token { args += ["--next-page-token", token] }
            let page = try await ce.runner.decode(CostResponse.self, ce.args(args))
            pages.append(page)
            token = page.nextPageToken
        } while token != nil
        return CostHistory(pages, now: now)
    }
}
