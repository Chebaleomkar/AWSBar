import CoreServices
import Foundation

struct S3Provider: ResourceProvider {
    let aws: AWSContext

    struct Response: Decodable { let buckets: [Bucket]? }

    struct Bucket: Decodable {
        let name: String
        let creationDate: String?
    }

    func list() async throws -> [Resource] {
        let response = try await aws.decode(Response.self, "s3api", "list-buckets")
        return (response.buckets ?? []).map { b in
            let created = b.creationDate.map { "created \($0.prefix(10))" } ?? ""
            return Resource(id: b.name, name: b.name, detail: created,
                            status: .neutral, statusText: "bucket", actions: [])
        }
    }

    func perform(_ action: ResourceAction, on resource: Resource) async throws {}
}

struct S3Object: Decodable, Hashable, Sendable {
    let key: String
    let size: Int64
    let lastModified: String
    let storageClass: String?

    var modified: Date? { try? Date(lastModified, strategy: .iso8601) }
}

struct S3Listing: Equatable, Sendable {
    var folders: [String] = []
    var objects: [S3Object] = []
    var nextToken: String?
}

/// A folder (a common prefix ending in `/`) or an object, named relative to the folder being browsed.
struct S3Entry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case folder
        case object(S3Object)
    }

    let key: String
    let name: String
    let kind: Kind

    var id: String { key }

    /// Folders first, then objects, each in Finder order. The console's placeholder object for the folder itself
    /// has the folder's own key, so it's dropped.
    static func entries(_ listing: S3Listing, in prefix: String) -> [S3Entry] {
        func sorted(_ entries: [S3Entry]) -> [S3Entry] {
            entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        let folders = listing.folders.map { S3Entry(key: $0, name: S3Path.name($0, in: prefix), kind: .folder) }
        let objects = listing.objects.filter { $0.key != prefix }
            .map { S3Entry(key: $0.key, name: S3Path.name($0.key, in: prefix), kind: .object($0)) }
        return sorted(folders) + sorted(objects)
    }
}

enum S3Path {
    static func name(_ key: String, in prefix: String) -> String {
        let name = key.hasPrefix(prefix) ? key.dropFirst(prefix.count) : Substring(key)
        return segmentName(name.hasSuffix("/") ? name.dropLast() : name)
    }

    /// A key with `//` has an empty folder name between the slashes.
    private static func segmentName(_ segment: Substring) -> String {
        segment.isEmpty ? "(empty)" : String(segment)
    }

    static func parent(of prefix: String) -> String {
        guard let slash = prefix.dropLast().lastIndex(of: "/") else { return "" }
        return String(prefix[...slash])
    }

    /// Each folder from the bucket root down, with the prefix that opens it.
    static func breadcrumbs(_ prefix: String) -> [(name: String, prefix: String)] {
        var crumbs: [(name: String, prefix: String)] = []
        var path = ""
        for part in prefix.split(separator: "/", omittingEmptySubsequences: false).dropLast() {
            path += part + "/"
            crumbs.append((segmentName(part), path))
        }
        return crumbs
    }

    /// The last path component, so Quick Look and the save panel see the real extension. "." and ".." would
    /// name a directory, not a file.
    static func fileName(_ key: String) -> String {
        let name = String(key.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
        return ["", ".", ".."].contains(name) ? "object" : name
    }

    /// `fileName` shortened before its extension to fit macOS's limit of 255 UTF-16 units in a file name. Foundation
    /// decomposes a path before it opens it, so `é` counts as two units.
    static func localFileName(_ key: String) -> String {
        func fits(_ name: String) -> Bool { name.decomposedStringWithCanonicalMapping.utf16.count <= 255 }
        let name = fileName(key)
        if fits(name) { return name }
        let ext = (name as NSString).pathExtension
        let keepsExtension = !ext.isEmpty && fits("x." + ext)
        var stem = Substring(keepsExtension ? (name as NSString).deletingPathExtension : name)
        let suffix = keepsExtension ? "." + ext : ""
        while !fits(stem + suffix) { stem = stem.dropLast() }
        return stem + suffix
    }

    static func uri(bucket: String, key: String) -> String { "s3://\(bucket)/\(key)" }
}

/// Previews skip History: arrowing through a folder would add an entry per file.
struct S3Client: Sendable {
    let aws: AWSContext
    let previews: AWSContext

    struct ListObjectsResponse: Decodable {
        let contents: [S3Object]?
        let commonPrefixes: [CommonPrefix]?
        let isTruncated: Bool?
        let nextContinuationToken: String?

        struct CommonPrefix: Decodable { let prefix: String }

        var listing: S3Listing {
            S3Listing(folders: (commonPrefixes ?? []).map(\.prefix), objects: contents ?? [],
                      nextToken: isTruncated == true ? nextContinuationToken : nil)
        }
    }

    /// Pages with S3's own `--max-keys`, which also turns off the CLI's pagination. The CLI's `--max-items` counts
    /// only files, so a folder of subfolders fetched every page before printing. Values go after `=` because the
    /// CLI reads a separate value that starts with `-`, such as a folder named `-old/`, as a flag.
    static func listArguments(bucket: String, prefix: String, token: String?) -> [String] {
        var args = ["s3api", "list-objects-v2", "--bucket", bucket, "--delimiter", "/", "--max-keys", "1000"]
        if isParamFile(prefix) {
            args += ["--cli-input-json", inputJSON(["Prefix": prefix])]
        } else if !prefix.isEmpty {
            args.append("--prefix=\(prefix)")
        }
        if let token { args.append("--continuation-token=\(token)") }
        return args
    }

    /// get-object takes no `--cli-input-json`, but `s3 cp` names the object with an `s3://` URI, which is never read
    /// as a paramfile.
    static func getArguments(bucket: String, key: String, to file: URL) -> [String] {
        if isParamFile(key) { return ["s3", "cp", S3Path.uri(bucket: bucket, key: key), file.path, "--only-show-errors"] }
        return ["s3api", "get-object", "--bucket", bucket, "--key=\(key)", file.path]
    }

    /// aws reads a value that starts with `file://` or `fileb://` as a local file and sends the file's contents
    /// instead; aws-cli v1 also fetches `http://` and `https://` values from the network. Values inside
    /// `--cli-input-json` are sent as they are.
    static func isParamFile(_ value: String) -> Bool {
        ["file://", "fileb://", "http://", "https://"].contains { value.hasPrefix($0) }
    }

    private static func inputJSON(_ parameters: [String: String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try! encoder.encode(parameters), as: UTF8.self)
    }

    func listObjects(bucket: String, prefix: String, token: String?) async throws -> S3Listing {
        let args = Self.listArguments(bucket: bucket, prefix: prefix, token: token)
        return try await aws.runner.decode(ListObjectsResponse.self, aws.args(args)).listing
    }

    /// Quarantines the file the way a browser download is, so Gatekeeper checks it before it opens or runs.
    /// Returns false when the volume can't store the quarantine flag; the file is saved either way.
    func download(bucket: String, key: String, to file: URL) async throws -> Bool {
        try await aws.runner.check(aws.args(Self.getArguments(bucket: bucket, key: key, to: file)))
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "AWSBar",
                                       kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String]
        var file = file
        return (try? file.setResourceValues(values)) != nil
    }

    func downloadPreview(bucket: String, key: String, to file: URL) async throws {
        try await previews.runner.check(previews.args(Self.getArguments(bucket: bucket, key: key, to: file)))
    }
}
