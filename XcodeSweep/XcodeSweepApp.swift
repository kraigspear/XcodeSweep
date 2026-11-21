import SwiftUI

@main
struct XcodeSweepApp: App {
    @State private var xcodeSweepStore = XcodeSweepStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: xcodeSweepStore)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Scan") {
                    Task {
                        await xcodeSweepStore.refresh()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!xcodeSweepStore.canRefresh)
            }

            CommandGroup(after: .pasteboard) {
                Button("Delete Selected…") {
                    xcodeSweepStore.requestDeleteSelected()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(xcodeSweepStore.deletableSelectedItems.isEmpty || !xcodeSweepStore.canDelete)
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
