#if DEBUG
import AppKit
import SwiftUI

/// `AWSBar -snapshot <dir>` renders each tab in light and dark mode to PNGs, then quits, so the
/// popover can be checked without clicking the menu bar. Adding `-snapshotBucket <bucket>` renders the
/// bucket browser instead, after its first listing, at the root or at `-snapshotPrefix <prefix>`, and previews
/// nothing. The flags arrive through UserDefaults' launch-argument domain.
enum Snapshot {
    @MainActor
    static func runIfRequested(_ state: AppState) async {
        guard let dir = UserDefaults.standard.string(forKey: "snapshot") else { return }
        for _ in 0..<60 {
            let pending = state.expanded.contains { state.provider(for: $0) != nil && state.sections[$0]?.loaded != true }
            if state.located, state.auth != .checking, state.auth != .unknown, !pending, !state.costsLoading { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let dirURL = URL(fileURLWithPath: dir)
        if let bucket = UserDefaults.standard.string(forKey: "snapshotBucket") {
            await renderBucket(bucket, prefix: UserDefaults.standard.string(forKey: "snapshotPrefix"), state, to: dirURL)
        } else {
            for tab in PopoverView.Tab.allCases {
                await render(PopoverView(tab: tab).environment(state), width: 400, height: 560,
                             to: dirURL, name: tab.rawValue)
            }
        }
        NSApplication.shared.terminate(nil)
    }

    @MainActor
    private static func renderBucket(_ bucket: String, prefix: String?, _ state: AppState, to dir: URL) async {
        guard let s3 = state.s3(profile: state.selectedProfileName, region: state.region) else { return }
        let browser = BucketBrowser(target: BucketTarget(bucket: bucket, profile: state.selectedProfileName, region: state.region),
                                    s3: s3)
        browser.start()
        if let prefix { browser.open(prefix) }
        for _ in 0..<240 {
            if browser.phase != .loading { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        await render(BucketBrowserView(browser: browser), width: 860, height: 560, to: dir, name: "Bucket")
        browser.close()
    }

    @MainActor
    private static func render(_ content: some View, width: CGFloat, height: CGFloat, to dir: URL, name: String) async {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: 0, width: width, height: height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = view
            window.orderFront(nil)
            try? await Task.sleep(for: .milliseconds(500))
            let bounds = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            view.cacheDisplay(in: bounds, to: rep)
            let url = dir.appendingPathComponent("\(name)-\(suffix).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            window.orderOut(nil)
        }
    }
}
#endif
