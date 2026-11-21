import SwiftUI

struct StatusBadgeView: View {
    let status: ItemStatus

    var body: some View {
        Text(status.label)
            .font(.caption)
            .bold()
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(backgroundColor, in: Capsule())
    }

    private var foregroundColor: Color {
        switch status {
        case .orphaned, .unavailable:
            .orange
        case .worktree:
            .blue
        case .booted:
            .green
        case .stale:
            .secondary
        case .active:
            .primary
        case .systemManaged:
            .purple
        }
    }

    private var backgroundColor: Color {
        foregroundColor.opacity(0.14)
    }
}

#if DEBUG && canImport(SwiftUI)
    #Preview {
        HStack {
            StatusBadgeView(status: .orphaned)
            StatusBadgeView(status: .worktree)
            StatusBadgeView(status: .unavailable)
            StatusBadgeView(status: .booted)
            StatusBadgeView(status: .stale)
            StatusBadgeView(status: .active)
            StatusBadgeView(status: .systemManaged)
        }
        .padding()
    }
#endif
