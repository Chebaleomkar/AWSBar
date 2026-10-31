import XCTest
@testable import AWSBar

final class S3Tests: XCTestCase {
    private func listing(_ json: String) throws -> S3Listing {
        try JSONDecoder.cli.decode(S3Client.ListObjectsResponse.self, from: Data(json.utf8)).listing
    }

    func testListObjectsDecoding() throws {
        let page = try listing("""
        {
            "Contents": [
                {"Key": "docs/a.pdf", "LastModified": "2026-01-02T03:04:05+00:00", "ETag": "\\"x\\"",
                 "Size": 30000000000, "StorageClass": "STANDARD"},
                {"Key": "docs/b.txt", "LastModified": "2026-01-02T03:04:05.000Z", "Size": 0}
            ],
            "CommonPrefixes": [{"Prefix": "docs/old/"}],
            "IsTruncated": true,
            "NextContinuationToken": "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM="
        }
        """)
        XCTAssertEqual(page.folders, ["docs/old/"])
        XCTAssertEqual(page.objects.map(\.key), ["docs/a.pdf", "docs/b.txt"])
        XCTAssertEqual(page.objects[0].size, 30_000_000_000)
        XCTAssertEqual(page.objects[0].storageClass, "STANDARD")
        XCTAssertNil(page.objects[1].storageClass)
        XCTAssertEqual(page.objects.map(\.modified), [Date(timeIntervalSince1970: 1_767_323_045), Date(timeIntervalSince1970: 1_767_323_045)])
        XCTAssertEqual(page.nextToken, "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=")
    }

    func testListObjectsDecodingWithoutContentsOrPrefixes() throws {
        XCTAssertEqual(try listing(#"{"RequestCharged": null, "Prefix": "empty/", "IsTruncated": false}"#), S3Listing())
        XCTAssertEqual(try listing(#"{"CommonPrefixes": [{"Prefix": "a/"}]}"#), S3Listing(folders: ["a/"]))
    }

    func testEntriesPutFoldersFirstInFinderOrderAndDropThePlaceholder() {
        func object(_ key: String) -> S3Object { S3Object(key: key, size: 1, lastModified: "", storageClass: nil) }
        let listing = S3Listing(folders: ["p/b10/", "p/B2/", "p/a/"],
                                objects: [object("p/"), object("p/file10.txt"), object("p/file2.txt"), object("p/Zed")])
        let entries = S3Entry.entries(listing, in: "p/")
        XCTAssertEqual(entries.map(\.name), ["a", "B2", "b10", "file2.txt", "file10.txt", "Zed"])
        XCTAssertEqual(entries.map(\.key), ["p/a/", "p/B2/", "p/b10/", "p/file2.txt", "p/file10.txt", "p/Zed"])
        XCTAssertEqual(entries.filter { $0.kind == .folder }.count, 3)
    }

    func testArgumentsKeepDashLeadingNamesAsValues() {
        XCTAssertEqual(S3Client.listArguments(bucket: "b", prefix: "", token: nil),
                       ["s3api", "list-objects-v2", "--bucket", "b", "--delimiter", "/", "--max-keys", "1000"])
        XCTAssertEqual(S3Client.listArguments(bucket: "b", prefix: "-old/", token: "t").suffix(2),
                       ["--prefix=-old/", "--continuation-token=t"])
        XCTAssertEqual(S3Client.getArguments(bucket: "b", key: "-x.pdf", to: URL(fileURLWithPath: "/tmp/x.pdf")),
                       ["s3api", "get-object", "--bucket", "b", "--key=-x.pdf", "/tmp/x.pdf"])
    }

    func testParamFileLookalikesAvoidTheArgumentsTheCLILoadsFilesFrom() {
        XCTAssertEqual(S3Client.listArguments(bucket: "b", prefix: "fileb://x/", token: "t"),
                       ["s3api", "list-objects-v2", "--bucket", "b", "--delimiter", "/", "--max-keys", "1000",
                        "--cli-input-json", #"{"Prefix":"fileb://x/"}"#, "--continuation-token=t"])
        XCTAssertEqual(S3Client.getArguments(bucket: "b", key: "fileb://x/a.pdf", to: URL(fileURLWithPath: "/tmp/a.pdf")),
                       ["s3", "cp", "s3://b/fileb://x/a.pdf", "/tmp/a.pdf", "--only-show-errors"])
        XCTAssertEqual(S3Client.getArguments(bucket: "b", key: "https://evil.example/a.pdf", to: URL(fileURLWithPath: "/tmp/a.pdf")),
                       ["s3", "cp", "s3://b/https://evil.example/a.pdf", "/tmp/a.pdf", "--only-show-errors"])
        XCTAssertEqual(S3Client.getArguments(bucket: "b", key: "x/file://a", to: URL(fileURLWithPath: "/tmp/a")),
                       ["s3api", "get-object", "--bucket", "b", "--key=x/file://a", "/tmp/a"])
    }

    func testPathHelpers() {
        XCTAssertEqual(S3Path.name("a/b/", in: "a/"), "b")
        XCTAssertEqual(S3Path.name("a/c.txt", in: "a/"), "c.txt")
        XCTAssertEqual(S3Path.name("top.txt", in: ""), "top.txt")

        XCTAssertEqual(S3Path.parent(of: "a/b/"), "a/")
        XCTAssertEqual(S3Path.parent(of: "a/"), "")
        XCTAssertEqual(S3Path.parent(of: ""), "")

        XCTAssertTrue(S3Path.breadcrumbs("").isEmpty)
        let crumbs = S3Path.breadcrumbs("a/b c/d/")
        XCTAssertEqual(crumbs.map(\.name), ["a", "b c", "d"])
        XCTAssertEqual(crumbs.map(\.prefix), ["a/", "a/b c/", "a/b c/d/"])
        let doubled = S3Path.breadcrumbs("/a//")
        XCTAssertEqual(doubled.map(\.name), ["(empty)", "a", "(empty)"])
        XCTAssertEqual(doubled.map(\.prefix), ["/", "/a/", "/a//"])
        XCTAssertEqual(S3Path.name("a//", in: "a/"), "(empty)")
        XCTAssertEqual(S3Path.name("/", in: ""), "(empty)")

        XCTAssertEqual(S3Path.fileName("cvs/jane doe.pdf"), "jane doe.pdf")
        XCTAssertEqual(S3Path.fileName("a/.."), "object")
        XCTAssertEqual(S3Path.uri(bucket: "b", key: "a/x.pdf"), "s3://b/a/x.pdf")
    }

    /// The files are created for real through FileManager, which decomposes names the way Quick Look's URL does.
    func testLocalFileNameFitsTheFileSystemAndKeepsTheExtension() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AWSBarTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let accented = "cvs/" + String(repeating: "Jos\u{E9} \u{D55C} ", count: 30) + ".pdf"
        let cases = [
            (accented, "Jos\u{E9} \u{D55C} "),
            ("a/" + String(repeating: "a", count: 300), String(repeating: "a", count: 255)),
            ("a." + String(repeating: "b", count: 300), "a." + String(repeating: "b", count: 253)),
        ]
        for (key, expectedStart) in cases {
            let name = S3Path.localFileName(key)
            XCTAssertFalse(FileManager.default.createFile(atPath: dir.appendingPathComponent(S3Path.fileName(key)).path, contents: nil))
            XCTAssertTrue(FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: nil), name)
            XCTAssertTrue(name.hasPrefix(expectedStart), name)
        }
        XCTAssertTrue(S3Path.localFileName(accented).hasSuffix(".pdf"))
        XCTAssertEqual(S3Path.localFileName("cvs/short.pdf"), "short.pdf")
    }
}

/// Drives BucketBrowser against a fake `aws` that answers slowly for keys and prefixes starting with "slow", and
/// splits the "paged/" folder into two pages. Downloading a key that starts with "broken" writes part of the file and fails. It ignores SIGTERM, so a cancelled request still finishes, the way a
/// stale result can still arrive. It logs each call's arguments, one per line, to `calls`. It answers `s3 cp` and
/// reads a prefix from `--cli-input-json`.
@MainActor
final class BucketBrowserTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("AWSBarTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("aws")
        try #"""
        #!/bin/sh
        trap '' TERM
        echo "$*" >> "$(dirname "$0")/calls"
        if [ "$2" = cp ]; then printf '%s' "${3#s3://b/}" > "$4"; exit 0; fi
        op=$2; prefix=""; key=""; out=""; token=""
        shift 2
        while [ $# -gt 0 ]; do
            case "$1" in
                --prefix=*) prefix=${1#--prefix=}; shift ;;
                --continuation-token=*) token=${1#--continuation-token=}; shift ;;
                --cli-input-json) prefix=$(printf '%s' "$2" | sed -n 's/^{"Prefix":"\(.*\)"}$/\1/p'); shift 2 ;;
                --key=*) key=${1#--key=}; out=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        case "$prefix$key" in slow*) sleep 1 ;; esac
        case "$op$key" in get-objectbroken*) printf 'part' > "$out"; echo 'An error occurred (InternalError)' >&2; exit 1 ;; esac
        if [ "$op" = get-object ]; then printf '%s' "$key" > "$out"; echo '{}'; exit 0; fi
        if [ "$prefix" = paged/ ] && [ -z "$token" ]; then
            echo '{"CommonPrefixes":[{"Prefix":"paged/b/"}],"Contents":[{"Key":"paged/z.txt","Size":1,"LastModified":"2026-01-01T00:00:00+00:00"}],"IsTruncated":true,"NextContinuationToken":"next/page="}'
            exit 0
        fi
        if [ "$prefix" = paged/ ] && [ "$token" = next/page= ]; then
            echo '{"CommonPrefixes":[{"Prefix":"paged/a/"}],"Contents":[{"Key":"paged/m.txt","Size":1,"LastModified":"2026-01-01T00:00:00+00:00"}],"IsTruncated":false}'
            exit 0
        fi
        printf '{"CommonPrefixes":[{"Prefix":"%ssub/"}],"Contents":[' "$prefix"
        printf '{"Key":"%sslow.txt","Size":4,"LastModified":"2026-01-01T00:00:00+00:00"},' "$prefix"
        printf '{"Key":"%sfast.txt","Size":4,"LastModified":"2026-01-01T00:00:00+00:00"},' "$prefix"
        printf '{"Key":"%sbroken.txt","Size":4,"LastModified":"2026-01-01T00:00:00+00:00"},' "$prefix"
        printf '{"Key":"%sbig.bin","Size":26000000,"LastModified":"2026-01-01T00:00:00+00:00"}]}' "$prefix"
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func browser() -> BucketBrowser {
        let runner = Runner(executable: dir.appendingPathComponent("aws")) { _ in }
        let context = AWSContext(runner: runner, profile: "p", region: "r")
        return BucketBrowser(target: BucketTarget(bucket: "b", profile: "p", region: "r"),
                             s3: S3Client(aws: context, previews: context))
    }

    private func calls() throws -> [Substring] {
        try String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n")
    }

    private func previewFolders(_ browser: BucketBrowser) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: browser.previewDirectory.path)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(condition())
    }

    func testStaleListingDoesNotReplaceTheCurrentFolder() async throws {
        let browser = browser()
        browser.open("slow/")
        try await Task.sleep(for: .milliseconds(200))
        browser.open("fast/")
        try await waitUntil { browser.phase == .loaded }
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(browser.phase, .loaded)
        XCTAssertEqual(browser.prefix, "fast/")
        XCTAssertEqual(browser.entries.map(\.key), ["fast/sub/", "fast/big.bin", "fast/broken.txt", "fast/fast.txt", "fast/slow.txt"])

        browser.back()
        XCTAssertEqual(browser.prefix, "slow/")
        browser.up()
        XCTAssertEqual(browser.prefix, "")
        browser.close()
    }

    func testStalePreviewDoesNotReplaceTheCurrentOne() async throws {
        let browser = browser()
        browser.start()
        try await waitUntil { browser.phase == .loaded }
        browser.selection = "slow.txt"
        XCTAssertEqual(browser.preview, .loading(key: "slow.txt"))
        try await Task.sleep(for: .milliseconds(200))
        browser.selection = "fast.txt"
        try await waitUntil { if case .ready = browser.preview { true } else { false } }
        try await Task.sleep(for: .milliseconds(1200))
        guard case .ready(let key, let file) = browser.preview else { return XCTFail("\(browser.preview)") }
        XCTAssertEqual(key, "fast.txt")
        XCTAssertEqual(file.lastPathComponent, "fast.txt")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "fast.txt")
        XCTAssertEqual(try previewFolders(browser), [file.deletingLastPathComponent().lastPathComponent])

        let mode = try FileManager.default.attributesOfItem(atPath: browser.previewDirectory.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
        browser.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: browser.previewDirectory.path))
    }

    func testLargeFilesWaitForPreviewAnyway() async throws {
        let browser = browser()
        browser.start()
        try await waitUntil { browser.phase == .loaded }
        browser.selection = "big.bin"
        XCTAssertEqual(browser.preview, .tooLarge(key: "big.bin", size: 26_000_000))
        browser.previewSelection(force: true)
        try await waitUntil { if case .ready = browser.preview { true } else { false } }
        browser.selection = "sub/"
        XCTAssertEqual(browser.preview, .none)
        browser.close()
    }

    func testLoadMoreSendsTheContinuationTokenAndSortsAcrossPages() async throws {
        let browser = browser()
        browser.open("paged/")
        try await waitUntil { browser.phase == .loaded }
        XCTAssertEqual(browser.nextToken, "next/page=")
        browser.loadMore()
        try await waitUntil { browser.nextToken == nil && !browser.loadingMore }
        XCTAssertEqual(browser.entries.map(\.key), ["paged/a/", "paged/b/", "paged/m.txt", "paged/z.txt"])
        XCTAssertEqual(try calls(), [
            "s3api list-objects-v2 --bucket b --delimiter / --max-keys 1000 --prefix=paged/ --profile p --region r --output json",
            "s3api list-objects-v2 --bucket b --delimiter / --max-keys 1000 --prefix=paged/ --continuation-token=next/page= "
                + "--profile p --region r --output json",
        ])
        browser.close()
    }

    func testDoubleClickKeepsTheSizeLimit() async throws {
        let browser = browser()
        browser.start()
        try await waitUntil { browser.phase == .loaded }
        browser.activate("big.bin")
        XCTAssertEqual(browser.preview, .tooLarge(key: "big.bin", size: 26_000_000))
        browser.activate("fast.txt")
        try await waitUntil { if case .ready = browser.preview { true } else { false } }
        XCTAssertFalse(try calls().contains { $0.contains("--key=big.bin") })
        browser.activate("sub/")
        XCTAssertEqual(browser.prefix, "sub/")
        browser.close()
    }

    func testFailedPreviewDeletesThePartialFile() async throws {
        let browser = browser()
        browser.start()
        try await waitUntil { browser.phase == .loaded }
        browser.selection = "broken.txt"
        try await waitUntil { if case .failed = browser.preview { true } else { false } }
        XCTAssertEqual(browser.preview, .failed(key: "broken.txt", "An error occurred (InternalError)"))
        XCTAssertEqual(try previewFolders(browser), [])
        browser.close()
    }

    func testParamFileLookalikeFolderAndKeyStayLiteral() async throws {
        let browser = browser()
        browser.open("file:///etc/")
        try await waitUntil { browser.phase == .loaded }
        XCTAssertEqual(browser.entries.first?.key, "file:///etc/sub/")
        browser.selection = "file:///etc/fast.txt"
        try await waitUntil { if case .ready = browser.preview { true } else { false } }
        guard case .ready(_, let file) = browser.preview else { return XCTFail("\(browser.preview)") }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "file:///etc/fast.txt")
        XCTAssertEqual(try calls(), [
            #"s3api list-objects-v2 --bucket b --delimiter / --max-keys 1000 --cli-input-json {"Prefix":"file:///etc/"} "#
                + "--profile p --region r --output json",
            "s3 cp s3://b/file:///etc/fast.txt \(file.path) --only-show-errors --profile p --region r --output json",
        ])
        browser.close()
    }

    func testDownloadIsQuarantined() async throws {
        let browser = browser()
        let file = dir.appendingPathComponent("saved.txt")
        browser.download(S3Object(key: "fast.txt", size: 4, lastModified: "", storageClass: nil), to: file)
        try await waitUntil { browser.transfer == .saved(file, quarantined: true) }
        let quarantine = try XCTUnwrap(file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        XCTAssertEqual(quarantine[kLSQuarantineAgentNameKey as String] as? String, "AWSBar")
        XCTAssertEqual(quarantine[kLSQuarantineTypeKey as String] as? String, kLSQuarantineTypeWebDownload as String)
    }

    func testLeftoverPreviewFoldersOfEndedProcessesAreRemoved() throws {
        let fm = FileManager.default
        let names = ["AWSBar-\(getpid())-\(UUID().uuidString)", "AWSBar-99999999-\(UUID().uuidString)",
                     "AWSBar-\(UUID().uuidString)", "AWSBar-12345678-1234-1234-1234-123456789012", "AWSBarTests-x", "other"]
        for name in names { try fm.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true) }
        BucketBrowser.removeLeftoverPreviews(in: dir)
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: dir.path)).intersection(names),
                       Set(names).subtracting([names[1]]))
    }
}
