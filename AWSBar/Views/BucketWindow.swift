import Quartz
import SwiftUI

struct BucketWindow: View {
    @Environment(AppState.self) private var state
    let target: BucketTarget
    @State private var browser: BucketBrowser?

    var body: some View {
        Group {
            if let browser {
                BucketBrowserView(browser: browser)
            } else if state.located && state.awsURL == nil {
                Label("AWS CLI not found", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(target.bucket)
        .background(NonRestorableWindow())
        .task {
            await state.bootstrap()
            guard !Task.isCancelled, browser == nil, let s3 = state.s3(profile: target.profile, region: target.region) else { return }
            let browser = BucketBrowser(target: target, s3: s3)
            self.browser = browser
            browser.start()
        }
        .onDisappear { browser?.close() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            browser?.close()
        }
    }
}

struct BucketBrowserView: View {
    @Bindable var browser: BucketBrowser

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                listing.frame(minWidth: 380, idealWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                PreviewPane(browser: browser).frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 360)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { browser.back() } label: { Image(systemName: "chevron.left") }
                .help("Back")
                .keyboardShortcut("[", modifiers: .command)
                .disabled(browser.backStack.isEmpty)
            Button { browser.up() } label: { Image(systemName: "arrow.up") }
                .help("Enclosing folder")
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(browser.prefix.isEmpty)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    crumb(browser.target.bucket, prefix: "", symbol: "archivebox")
                    ForEach(S3Path.breadcrumbs(browser.prefix), id: \.prefix) { crumb in
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        self.crumb(crumb.name, prefix: crumb.prefix, symbol: nil)
                    }
                }
            }
            Label(browser.target.profile, systemImage: "person.crop.circle")
            Label(browser.target.region, systemImage: "globe")
            Button { browser.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
                .keyboardShortcut("r")
        }
        .font(.callout)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func crumb(_ name: String, prefix: String, symbol: String?) -> some View {
        let current = prefix == browser.prefix
        return Button { browser.open(prefix) } label: {
            if let symbol { Label(name, systemImage: symbol) } else { Text(name) }
        }
        .foregroundStyle(current ? .primary : .secondary)
        .fontWeight(current ? .semibold : .regular)
        .lineLimit(1)
    }

    @ViewBuilder
    private var listing: some View {
        if case .failed(let message) = browser.phase {
            VStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                Button("Retry") { browser.refresh() }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            table.overlay {
                if browser.phase == .loading {
                    ProgressView()
                } else if browser.entries.isEmpty {
                    Text("This folder is empty.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var table: some View {
        Table(browser.entries, selection: $browser.selection) {
            TableColumn("Name") { entry in
                Label {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: entry.kind == .folder ? "folder.fill" : "doc")
                        .foregroundStyle(entry.kind == .folder ? Color.accentColor : .secondary)
                }
            }
            .width(min: 120, ideal: 190)
            TableColumn("Size") { entry in
                if case .object(let object) = entry.kind {
                    Text(object.size.formatted(.byteCount(style: .file))).monospacedDigit()
                }
            }
            .width(min: 60, ideal: 70, max: 120)
            TableColumn("Modified") { entry in
                if case .object(let object) = entry.kind {
                    Text(object.modified?.formatted(date: .numeric, time: .shortened) ?? object.lastModified)
                }
            }
            .width(min: 100, ideal: 140, max: 220)
        }
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: S3Entry.ID.self) { ids in
            if let entry = browser.entries.first(where: { ids.contains($0.id) }) {
                switch entry.kind {
                case .folder:
                    Button("Open") { browser.open(entry.key) }
                case .object(let object):
                    Button("Preview") { browser.forcePreview(entry.id) }
                    Button("Download…") { save(object, browser) }
                        .disabled(browser.isDownloading)
                }
                Divider()
                Button("Copy S3 URI") { copy(S3Path.uri(bucket: browser.target.bucket, key: entry.key)) }
            }
        } primaryAction: { ids in
            if let id = ids.first { browser.activate(id) }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if browser.phase == .loaded {
                Text(browser.entries.count == 1 ? "1 item" : "\(browser.entries.count) items").foregroundStyle(.secondary)
            }
            if browser.loadingMore {
                ProgressView().controlSize(.small)
            } else if browser.nextToken != nil {
                Button("Load More") { browser.loadMore() }
            }
            if let error = browser.moreError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(1)
            }
            Spacer()
            transfer
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var transfer: some View {
        switch browser.transfer {
        case .running(let name):
            ProgressView().controlSize(.small)
            Text("Downloading \(name)…").foregroundStyle(.secondary).lineLimit(1)
        case .saved(let file, let quarantined):
            Label(quarantined ? "Saved \(file.lastPathComponent)" : "Saved \(file.lastPathComponent), not marked for Gatekeeper",
                  systemImage: "checkmark.circle.fill").lineLimit(1)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                .buttonStyle(.borderless)
        case .failed(let name, let message):
            Label("Couldn't download \(name): \(message)", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
                .textSelection(.enabled)
        case nil:
            EmptyView()
        }
    }
}

private struct PreviewPane: View {
    let browser: BucketBrowser

    var body: some View {
        if case .object(let object)? = browser.selectedEntry?.kind {
            VStack(spacing: 0) {
                details(object)
                Divider()
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            Text(browser.selectedEntry == nil ? "Select a file to preview it." : "Double-click a folder to open it.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func details(_ object: S3Object) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(S3Path.fileName(object.key)).font(.headline).lineLimit(1).truncationMode(.middle)
                Text([object.size.formatted(.byteCount(style: .file)), object.storageClass].compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            Spacer()
            Button("Download…") { save(object, browser) }
                .disabled(browser.isDownloading)
            Button { copy(S3Path.uri(bucket: browser.target.bucket, key: object.key)) } label: {
                Image(systemName: "link")
            }
            .help("Copy S3 URI")
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        switch browser.preview {
        case .none:
            EmptyView()
        case .loading:
            ProgressView("Downloading preview…")
        case .ready(_, let file):
            QuickLookView(file: file)
        case .tooLarge(_, let size):
            VStack(spacing: 10) {
                Text("This file is \(size.formatted(.byteCount(style: .file))), so it isn't previewed automatically.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Preview Anyway") { browser.previewSelection(force: true) }
            }
            .padding(20)
        case .failed(_, let message):
            VStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                Button("Retry") { browser.previewSelection(force: true) }
            }
            .padding(20)
        }
    }
}

struct QuickLookView: NSViewRepresentable {
    let file: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)
        view.autostarts = true
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != file { view.previewItem = file as NSURL }
    }

    /// Calling `close()` here aborts the app inside Quick Look (`-[QLPreviewView deactivate]` assertion) whenever the
    /// preview switches to another file. Dropping the item is enough; the view closes with its window.
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.previewItem = nil
    }
}

@MainActor
private func save(_ object: S3Object, _ browser: BucketBrowser) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = S3Path.localFileName(object.key)
    // A menu bar app's app-modal panel can open behind other windows and silently block every AWSBar window,
    // so attach it to the bucket window as a sheet.
    guard let window = NSApp.keyWindow else {
        NSApp.activate()
        guard panel.runModal() == .OK, let file = panel.url else { return }
        return browser.download(object, to: file)
    }
    panel.beginSheetModal(for: window) { response in
        guard response == .OK, let file = panel.url else { return }
        browser.download(object, to: file)
    }
}

@MainActor
private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
