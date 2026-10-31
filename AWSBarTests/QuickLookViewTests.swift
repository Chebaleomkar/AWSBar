import SwiftUI
import XCTest
@testable import AWSBar

/// Switching the S3 preview to another file tears down the Quick Look view; Quick Look used to abort the app there.
@MainActor
final class QuickLookViewTests: XCTestCase {
    func testReplacingAndClosingThePreviewDoesNotCrash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try ["a.txt", "b.txt"].map { name in
            let url = dir.appendingPathComponent(name)
            try "preview \(name)\n".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let host = NSHostingView(rootView: AnyView(QuickLookView(file: files[0])))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        for file in files + files {
            host.rootView = AnyView(ProgressView())
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.rootView = AnyView(QuickLookView(file: file))
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        }
        window.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
}
