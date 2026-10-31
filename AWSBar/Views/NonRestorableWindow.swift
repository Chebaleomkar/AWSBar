import SwiftUI

/// A restored window would run AWS commands at login with no click (a shell window opens a root session),
/// so shell and bucket windows aren't restored.
struct NonRestorableWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.isRestorable = false }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
