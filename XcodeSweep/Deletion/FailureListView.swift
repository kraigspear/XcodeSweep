import SwiftUI

/// Every failure from a cleanup, for when the completion alert's list is cut short.
struct FailureListView: View {
    let failures: [DeletionFailure]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Could Not Remove \(failures.count) \(failures.count == 1 ? "Item" : "Items")")
                .font(.headline)
            ScrollView {
                FailureRowsView(failures: failures)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 240, idealHeight: 360)
    }
}

/// The rows alone, without the scroll view and text selection, which an image render can't capture.
struct FailureRowsView: View {
    let failures: [DeletionFailure]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(failures, id: \.self) { failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.itemName)
                        .fontWeight(.medium)
                    Text(failure.reason)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
