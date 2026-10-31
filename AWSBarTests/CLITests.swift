import XCTest
@testable import AWSBar

private let sh = URL(fileURLWithPath: "/bin/sh")

private func openDescriptors() -> Int { (0..<getdtablesize()).filter { fcntl($0, F_GETFD) != -1 }.count }

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

final class CLITests: XCTestCase {
    func testCollectsLargeOutputOnBothPipes() async throws {
        let result = try await CLI.run(sh, ["-c", "head -c 1000000 /dev/zero; head -c 1000000 /dev/zero >&2; exit 3"])
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stdout.count, 1_000_000)
        XCTAssertEqual(result.stderr.count, 1_000_000)
    }

    func testCancelTerminatesProcess() async throws {
        let started = Date()
        let task = Task { try await CLI.run(sh, ["-c", "sleep 30"]) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = try await task.value
        XCTAssertEqual(result.exitCode, 128 + SIGTERM)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testCancelBeforeLaunchNeverRuns() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CLI.run(sh, ["-c", "sleep 30"])
        }
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {}
    }

    func testManyConcurrentRunsComplete() async throws {
        let outputs = try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<100 {
                group.addTask { try await CLI.run(sh, ["-c", "echo \(i)"]).stdoutString }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        XCTAssertEqual(outputs.count, 100)
    }

    /// S3 keys compare byte for byte, so a child that got `José` in NFD would ask for a different key.
    func testPassesArgumentAndEnvironmentBytesUnchanged() async throws {
        let nfc = "Jos\u{E9} \u{D55C}.pdf"
        setenv("AWSBAR_TEST_NFC", nfc, 1)
        defer { unsetenv("AWSBAR_TEST_NFC") }
        let result = try await CLI.run(sh, ["-c", #"printf '%s|%s' "$1" "$AWSBAR_TEST_NFC""#, "sh", nfc])
        XCTAssertEqual(hex(result.stdout), hex(Data("\(nfc)|\(nfc)".utf8)))
    }

    func testMissingExecutableThrowsAndClosesItsPipes() async throws {
        let before = openDescriptors()
        for _ in 0..<5 {
            do {
                _ = try await CLI.run(URL(fileURLWithPath: "/nonexistent/aws"), ["--version"])
                XCTFail("expected an error")
            } catch let error as CLIError {
                XCTAssertEqual(error.localizedDescription, "/nonexistent/aws: No such file or directory")
            }
        }
        XCTAssertEqual(openDescriptors(), before)
    }
}
