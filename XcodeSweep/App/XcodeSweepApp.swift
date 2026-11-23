import SwiftUI

/// Chooses the app to run. As a test host it runs one with no windows, because the main window
/// scans the real `~/Library/Developer` as soon as it appears.
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
    @State private var xcodeSweepStore = XcodeSweepStore()

    var body: some Scene {
        // One window: the store holds selection, search, and dialog state that a second window would share.
        Window("XcodeSweep", id: "main") {
            ContentView(store: xcodeSweepStore)
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
