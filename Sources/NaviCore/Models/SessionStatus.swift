import SwiftUI

public enum SessionStatus: Equatable {
    case needsAttention, working, waitingForInput, idle

    public var icon: String {
        switch self {
        case .needsAttention: return "exclamationmark.circle.fill"
        case .working: return "gearshape.circle.fill"
        case .waitingForInput: return "ellipsis.circle.fill"
        case .idle: return "checkmark.circle.fill"
        }
    }

    public var color: Color {
        switch self {
        case .needsAttention: return .orange
        case .working: return .green
        case .waitingForInput: return .blue
        case .idle: return .green
        }
    }

    public var label: String {
        switch self {
        case .needsAttention: return "Needs attention"
        case .working: return "Working"
        case .waitingForInput: return "Idle"
        case .idle: return ""
        }
    }
}
