import XCTest
@testable import AWSBar

final class QuickCommandsTests: XCTestCase {
    func testEveryQuickCommandOnlyReads() {
        let readVerbs = ["describe-", "list-", "get-", "lookup-", "ls"]
        for quick in QuickCommand.all() {
            let args = shellSplit(quick.command)
            XCTAssertGreaterThan(args.count, 1, quick.title)
            XCTAssertTrue(readVerbs.contains { args[1].hasPrefix($0) || args[1] == $0 }, "\(quick.title) runs \(args[1])")
        }
    }

    func testCostCommandCoversThisMonthInUTC() {
        let now = ISO8601DateFormatter().date(from: "2026-10-31T18:00:00Z")!
        let cost = QuickCommand.all(now: now).first { $0.title == "Cost this month" }!
        XCTAssertTrue(cost.command.contains("Start=2026-10-01,End=2026-11-01"))
    }
}
