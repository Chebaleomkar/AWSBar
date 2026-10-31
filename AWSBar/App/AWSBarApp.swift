import SwiftUI

@main
struct AWSBarApp: App {
    @State private var state = AppState()

    init() {
        Task.detached(priority: .utility) { BucketBrowser.removeLeftoverPreviews() }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(state)
                .task { await state.bootstrap() }
        } label: {
            menuBarIcon
                .task {
                    await state.bootstrap()
                    #if DEBUG
                    await Snapshot.runIfRequested(state)
                    #endif
                }
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Shell", id: "ec2-shell", for: ShellTarget.self) { $target in
            if let target {
                ShellWindow(target: target)
                    .environment(state)
            } else {
                Text("Double-click a running EC2 instance in the menu bar to open a shell.")
                    .foregroundStyle(.secondary)
                    .padding(40)
            }
        }
        .defaultSize(width: 760, height: 520)

        WindowGroup("Bucket", id: "s3-bucket", for: BucketTarget.self) { $target in
            if let target {
                BucketWindow(target: target)
                    .environment(state)
            } else {
                Text("Double-click an S3 bucket in the menu bar to browse it.")
                    .foregroundStyle(.secondary)
                    .padding(40)
            }
        }
        .defaultSize(width: 860, height: 560)
    }

    @ViewBuilder
    private var menuBarIcon: some View {
        if case .failed = state.auth {
            Image(systemName: "exclamationmark.icloud")
        } else {
            Image("MenuBarCloud").resizable().scaledToFit().frame(height: 14)
        }
    }
}
