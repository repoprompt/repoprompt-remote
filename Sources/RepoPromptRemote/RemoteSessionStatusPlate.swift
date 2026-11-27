import SwiftUI

struct RemoteSessionStatusPlate: View {
    let row: RemoteSessionNavigationRow

    private var color: Color {
        switch row.status {
        case .opening, .working: return .remoteWarmOrange
        case .waiting: return .remoteSuccess
        case .blocked: return .remoteWarmOrange
        case .completed: return .remoteSuccess
        case .failed: return .remoteFailure
        case .unreadNarrative: return .remoteWarmOrange
        case .idle, .cancelled: return .secondary
        }
    }

    private var hasUnseenHalo: Bool {
        switch row.status {
        case let .waiting(unseen), let .blocked(unseen), let .completed(unseen), let .failed(unseen):
            return unseen
        case .unreadNarrative:
            return true
        default:
            return false
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(hasUnseenHalo ? 0.17 : 0.08))
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(hasUnseenHalo ? 0.8 : 0.2), lineWidth: hasUnseenHalo ? 1.5 : 1)

            statusGlyph

        }
        .frame(width: 24, height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        if row.status == .opening || row.status == .working {
            ProgressView().controlSize(.mini).tint(color)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
        }
    }

    private var symbol: String {
        switch row.status {
        case .opening, .working: "arrow.clockwise"
        case .waiting: "hand.raised.fill"
        case .blocked: "exclamationmark"
        case .completed: "checkmark"
        case .failed: "xmark"
        case .cancelled: "minus"
        case .unreadNarrative: "circle.fill"
        case .idle: row.depth == 0 ? "bubble.left" : "arrow.turn.down.right"
        }
    }

    private var accessibilityLabel: String {
        let identity = row.depth == 0 ? "Root chat" : "Child chat, level \(row.depth)"
        let state: String
        switch row.status {
        case .idle: state = "idle"
        case .opening: state = "opening"
        case .working: state = "working"
        case .waiting: state = "waiting for your input"
        case .blocked: state = "blocked"
        case .completed: state = "completed"
        case .failed: state = "failed"
        case .cancelled: state = "cancelled"
        case .unreadNarrative: state = "new activity"
        }
        if row.unseenDescendantCount > 0 {
            return "\(identity), \(state), \(row.unseenDescendantCount) child chats need attention"
        }
        return "\(identity), \(state)"
    }
}
