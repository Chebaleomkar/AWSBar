import XCTest
@testable import AWSBar

final class CostHistoryTests: XCTestCase {
    /// 2026-10-31 23:30 UTC, so today is Oct 31 and the last complete day is Oct 30.
    private let now = Date(timeIntervalSince1970: 1_793_489_400)

    private func day(_ date: String, _ groups: [(String, String)]) -> String {
        let items = groups.map { #"{"Keys":["\#($0.0)"],"Metrics":{"UnblendedCost":{"Amount":"\#($0.1)","Unit":"USD"}}}"# }
        return #"{"TimePeriod":{"Start":"\#(date)","End":"x"},"Total":{},"Groups":[\#(items.joined(separator: ","))]}"#
    }

    private func history(_ results: [String]) throws -> CostHistory {
        let page = try JSONDecoder.cli.decode(CostResponse.self, from: Data(#"{"ResultsByTime":[\#(results.joined(separator: ","))]}"#.utf8))
        return CostHistory([page], now: now)
    }

    func testWindowCoversFourteenCompleteDaysAndToday() {
        let window = CostHistory.window(now: now)
        XCTAssertEqual(CostReport.day(window.start), "2026-10-17")
        XCTAssertEqual(CostReport.day(window.end), "2026-11-01")
        XCTAssertEqual(CostReport.day(window.today), "2026-10-31")
    }

    func testWeekOverWeekChangeAndPartialToday() throws {
        // Oct 17-23 cost 1/day (7 total). Oct 24-30 cost 2/day (14 total). Today so far is 0.5.
        var results: [String] = []
        for d in 17...23 { results.append(day("2026-10-\(d)", [("Amazon Elastic Compute Cloud - Compute", "1")])) }
        for d in 24...30 { results.append(day("2026-10-\(d)", [("Amazon Elastic Compute Cloud - Compute", "1"), ("Amazon Relational Database Service", "1")])) }
        results.append(day("2026-10-31", [("Amazon Elastic Compute Cloud - Compute", "0.5")]))
        let h = try history(results)

        XCTAssertEqual(h.days.count, 14)
        XCTAssertEqual(CostReport.day(h.days.first!.date), "2026-10-17")
        XCTAssertEqual(CostReport.day(h.days.last!.date), "2026-10-30")
        XCTAssertEqual(h.previousTotal, 7)
        XCTAssertEqual(h.recentTotal, 14)
        XCTAssertEqual(h.change, 7)
        XCTAssertEqual(h.changePercent!, 100, accuracy: 0.001)
        XCTAssertEqual(h.today?.total, Decimal(string: "0.5"))
        // Only the database is new; compute stayed flat, so it isn't a mover.
        XCTAssertEqual(h.movers, [.init(name: "Amazon Relational Database Service", recent: 7, previous: 0)])
    }

    func testMissingDaysAreZeroTaxIsNotAServiceAndMoversAreRanked() throws {
        let h = try history([
            day("2026-10-20", [("AWS Lambda", "4"), ("Tax", "1")]),
            day("2026-10-28", [("AWS Lambda", "1"), ("Amazon Simple Storage Service", "3"), ("Tax", "1")]),
        ])
        XCTAssertEqual(h.days.count, 14)
        XCTAssertEqual(h.days.filter { $0.total == 0 }.count, 12)
        XCTAssertNil(h.today)
        XCTAssertEqual(h.previousTotal, 5)
        XCTAssertEqual(h.recentTotal, 5)
        XCTAssertEqual(Set(h.movers.map(\.name)), ["AWS Lambda", "Amazon Simple Storage Service"])
        XCTAssertFalse(h.movers.contains { $0.name == "Tax" })
        XCTAssertEqual(h.movers.first?.name, "AWS Lambda")
        XCTAssertEqual(h.movers.first?.change, -3)
    }

    func testNoPercentWhenEarlierWeekWasFree() throws {
        let h = try history([day("2026-10-29", [("AWS Lambda", "2")])])
        XCTAssertEqual(h.previousTotal, 0)
        XCTAssertNil(h.changePercent)
    }
}
