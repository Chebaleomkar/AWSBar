import Foundation
import Observation

/// Profile and region are fixed when the window opens, so switching profile in the menu can't retarget it.
struct BucketTarget: Codable, Hashable, Sendable {
    let bucket: String
    let profile: String
    let region: String
}

@MainActor @Observable
final class BucketBrowser {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    enum Preview: Equatable {
        case none
        case loading(key: String)
        case ready(key: String, URL)
        case tooLarge(key: String, size: Int64)
        case failed(key: String, String)
    }

    enum Transfer: Equatable {
        case running(name: String)
        case saved(URL, quarantined: Bool)
        case failed(name: String, String)
    }

    static let autoPreviewLimit: Int64 = 25_000_000

    let target: BucketTarget
    private let s3: S3Client
    private(set) var prefix = ""
    private(set) var entries: [S3Entry] = []
    private(set) var phase: Phase = .loading
    private(set) var nextToken: String?
    private(set) var loadingMore = false
    private(set) var moreError: String?
    private(set) var backStack: [String] = []
    private(set) var preview: Preview = .none
    private(set) var transfer: Transfer?
    var selection: S3Entry.ID? {
        didSet { if selection != oldValue { previewSelection(force: false) } }
    }

    private var listing = S3Listing()
    private var listTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewFiles: [String: URL] = [:]
    /// Per window, so closing it deletes exactly the files it downloaded. The pid lets a later launch find folders
    /// left by a crash or force quit.
    let previewDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AWSBar-\(getpid())-\(UUID().uuidString)", isDirectory: true)

    init(target: BucketTarget, s3: S3Client) {
        self.target = target
        self.s3 = s3
    }

    var selectedEntry: S3Entry? { entries.first { $0.id == selection } }

    func start() {
        if listTask == nil { show(prefix) }
    }

    func open(_ prefix: String) {
        guard prefix != self.prefix else { return }
        backStack.append(self.prefix)
        show(prefix)
    }

    func up() {
        if !prefix.isEmpty { open(S3Path.parent(of: prefix)) }
    }

    func back() {
        if let previous = backStack.popLast() { show(previous) }
    }

    func refresh() {
        previewFiles = [:]
        show(prefix)
    }

    private func show(_ prefix: String) {
        self.prefix = prefix
        selection = nil
        listing = S3Listing()
        entries = []
        nextToken = nil
        phase = .loading
        load(token: nil)
    }

    func loadMore() {
        guard let nextToken, !loadingMore else { return }
        load(token: nextToken)
    }

    /// Every load cancels the one before it, so a slow listing for a folder the user left never lands.
    private func load(token: String?) {
        listTask?.cancel()
        loadingMore = token != nil
        moreError = nil
        let prefix = prefix
        listTask = Task {
            do {
                let page = try await s3.listObjects(bucket: target.bucket, prefix: prefix, token: token)
                guard !Task.isCancelled else { return }
                var listing = listing
                listing.folders += page.folders
                listing.objects += page.objects
                // Each Load More sorts every page so far, which gets slow for the main actor after a few pages.
                let sorted = await Task.detached { [listing] in S3Entry.entries(listing, in: prefix) }.value
                guard !Task.isCancelled else { return }
                self.listing = listing
                entries = sorted
                nextToken = page.nextToken
                phase = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                if token == nil {
                    phase = .failed(error.localizedDescription)
                } else {
                    moreError = error.localizedDescription
                }
            }
            loadingMore = false
        }
    }

    /// Double-click. A file keeps the size limit, so only Preview Anyway or the Preview menu item downloads a large one.
    func activate(_ id: S3Entry.ID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        if entry.kind == .folder { return open(entry.key) }
        selection = id
        previewSelection(force: false)
    }

    func forcePreview(_ id: S3Entry.ID) {
        selection = id
        previewSelection(force: true)
    }

    /// Previews download into this window's own 0700 folder, under the key's file name so Quick Look picks the type.
    func previewSelection(force: Bool) {
        guard case .object(let object)? = selectedEntry?.kind else {
            previewTask?.cancel()
            preview = .none
            return
        }
        let key = object.key
        if preview == .loading(key: key) { return }
        previewTask?.cancel()
        if let file = previewFiles[key] {
            preview = .ready(key: key, file)
            return
        }
        guard force || object.size <= Self.autoPreviewLimit else {
            preview = .tooLarge(key: key, size: object.size)
            return
        }
        // Each download gets its own folder, so two keys with the same file name can't collide.
        let folder = previewDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent(S3Path.localFileName(key))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            preview = .failed(key: key, error.localizedDescription)
            return
        }
        preview = .loading(key: key)
        previewTask = Task {
            do {
                try await s3.downloadPreview(bucket: target.bucket, key: key, to: file)
                try Task.checkCancellation()
                previewFiles[key] = file
                preview = .ready(key: key, file)
            } catch {
                // get-object can leave part of the file behind, and a preview nobody sees shouldn't stay on disk.
                try? FileManager.default.removeItem(at: folder)
                guard !Task.isCancelled else { return }
                preview = .failed(key: key, error.localizedDescription)
            }
        }
    }

    var isDownloading: Bool {
        if case .running = transfer { return true }
        return false
    }

    /// Not cancelled when the window closes: the user asked for this file, and a cut-off file would be worse.
    func download(_ object: S3Object, to file: URL) {
        guard !isDownloading else { return }
        let name = file.lastPathComponent
        transfer = .running(name: name)
        Task {
            do {
                let quarantined = try await s3.download(bucket: target.bucket, key: object.key, to: file)
                transfer = .saved(file, quarantined: quarantined)
            } catch {
                transfer = .failed(name: name, error.localizedDescription)
            }
        }
    }

    func close() {
        listTask?.cancel()
        previewTask?.cancel()
        previewFiles = [:]
        try? FileManager.default.removeItem(at: previewDirectory)
    }

    /// Deletes preview folders whose process has ended, such as after a crash, because they can hold private files.
    nonisolated static func removeLeftoverPreviews(in directory: URL = FileManager.default.temporaryDirectory) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix("AWSBar-") {
            // Only this build's `AWSBar-<pid>-<UUID>` folders; an older build's `AWSBar-<UUID>` may still be in use.
            let parts = name.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 7, let pid = pid_t(parts[1]) else { continue }
            if kill(pid, 0) == 0 || errno == EPERM { continue }
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
