import SwiftUI

/// Chooses the app to run. As a test host it opens no main window, because that window scans the
/// real `~/Library/Developer` as soon as it appears.
@main
enum XcodeSweepLauncher {
    static func main() {
        // Xcode sets this only in a process hosting tests.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            TestHostApp.main()
        } else {
            XcodeSweepApp.main()
        }
    }
}

private struct TestHostApp: App {
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

struct XcodeSweepApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var xcodeSweepStore = XcodeSweepStore()

    var body: some Scene {
        // One window: the store holds selection, search, and dialog state that a second window would share.
        Window("XcodeSweep", id: "main") {
            ContentView(store: xcodeSweepStore)
                // Closing the only window quits the app; while a cleanup runs, quitting goes
                // through the confirmation in `AppDelegate` instead.
                .windowDismissBehavior(xcodeSweepStore.operation.isDeleting ? .disabled : .automatic)
                .onAppear { appDelegate.xcodeSweepStore = xcodeSweepStore }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Scan") {
                    xcodeSweepStore.startRefresh()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(xcodeSweepStore.operation.isBusy)

                Button(xcodeSweepStore.operation.isDeleting ? "Cancel Cleanup" : "Stop Scan") {
                    xcodeSweepStore.cancelOperation()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!xcodeSweepStore.operation.isBusy)
            }

            CommandGroup(after: .pasteboard) {
                Button(xcodeSweepStore.selectionPlan.requestTitle) {
                    xcodeSweepStore.requestDeleteSelected()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(xcodeSweepStore.selectionPlan.isEmpty || xcodeSweepStore.operation.isBusy)
            }

            CommandGroup(after: .sidebar) {
                Button(xcodeSweepStore.inspectorPresented ? "Hide Inspector" : "Show Inspector") {
                    xcodeSweepStore.inspectorPresented.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}

/// Asks before quitting during a cleanup, and stops it cleanly if the user agrees.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var xcodeSweepStore: XcodeSweepStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A scan only reads, so quitting during one needs no question.
        guard let xcodeSweepStore, xcodeSweepStore.operation.isDeleting else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "A cleanup is still running"
        alert.informativeText = "Stop it and quit? The item being removed now is finished or stopped, and nothing after it is removed."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Keep Running")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        Task {
            await xcodeSweepStore.stopForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
