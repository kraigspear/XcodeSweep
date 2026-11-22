import SwiftUI

@main
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
                    Task {
                        await xcodeSweepStore.refresh()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(xcodeSweepStore.operation.isBusy)
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
