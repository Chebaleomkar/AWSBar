import XCTest
@testable import AWSBar

final class CostsTests: XCTestCase {
    /// 2026-10-31 23:30 UTC, the last half hour of October.
    private let now = Date(timeIntervalSince1970: 1_793_489_400)

    func testWindowUsesUTCMonths() {
        let window = CostReport.window(now: now)
        XCTAssertEqual(CostReport.day(window.start), "2025-11-01")
        XCTAssertEqual(CostReport.day(window.end), "2026-11-01")
        XCTAssertEqual(CostReport.day(window.thisMonth), "2026-10-01")
        XCTAssertEqual(CostReport.day(window.lastMonth), "2026-09-01")
    }

    func testReportSumsPagesAndSortsServicesByThisMonth() throws {
        let page1 = """
        {"ResultsByTime":[
          {"TimePeriod":{"Start":"2026-08-01","End":"2026-09-01"},"Total":{},"Groups":[
            {"Keys":["AWS Lambda"],"Metrics":{"UnblendedCost":{"Amount":"5","Unit":"USD"}}}]},
          {"TimePeriod":{"Start":"2026-09-01","End":"2026-10-01"},"Total":{},"Groups":[
            {"Keys":["Amazon Simple Storage Service"],"Metrics":{"UnblendedCost":{"Amount":"1.50","Unit":"USD"}}},
            {"Keys":["Amazon Relational Database Service"],"Metrics":{"UnblendedCost":{"Amount":"20","Unit":"USD"}}}]}],
         "NextPageToken":"t"}
        """
        let page2 = """
        {"ResultsByTime":[
          {"TimePeriod":{"Start":"2026-10-01","End":"2026-11-01"},"Total":{},"Groups":[
            {"Keys":["Amazon Elastic Compute Cloud - Compute"],"Metrics":{"UnblendedCost":{"Amount":"12.25","Unit":"USD"}}},
            {"Keys":["Amazon Simple Storage Service"],"Metrics":{"UnblendedCost":{"Amount":"0.75","Unit":"USD"}}},
            {"Keys":["AWS Key Management Service"],"Metrics":{"UnblendedCost":{"Amount":"0","Unit":"USD"}}},
            {"Keys":["Tax"],"Metrics":{"UnblendedCost":{"Amount":"2","Unit":"USD"}}}]}]}
        """
        let pages = try [page1, page2].map { try JSONDecoder.cli.decode(CostResponse.self, from: Data($0.utf8)) }
        let report = CostReport(pages, now: now)

        XCTAssertEqual(report.currency, "USD")
        XCTAssertEqual(report.thisMonth, Decimal(string: "15"))
        XCTAssertEqual(report.lastMonth, Decimal(string: "21.5"))
        XCTAssertEqual(report.total, Decimal(string: "41.5"))
        XCTAssertEqual(CostReport.day(report.since), "2026-08-01")
        // Lambda only ran before last month, so it isn't active. Free usage still counts, and Tax isn't a service.
        XCTAssertEqual(report.services.map(\.name), [
            "Amazon Elastic Compute Cloud - Compute",
            "Amazon Simple Storage Service",
            "Amazon Relational Database Service",
            "AWS Key Management Service",
        ])
        XCTAssertEqual(report.services[1], .init(name: "Amazon Simple Storage Service",
                                                 thisMonth: Decimal(string: "0.75")!, lastMonth: Decimal(string: "1.5")!))
    }
}
