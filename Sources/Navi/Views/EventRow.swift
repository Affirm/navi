import SwiftUI
import NaviCore

struct EventRow: View {
    let event: NaviEvent
    @ObservedObject var monitor: EventMonitor
    @AppStorage("NaviFontScale") private var s: Double = 1.0
    @State private var showingDetails = false
    @AppStorage("NaviExp.PermissionDetails") private var permissionDetailsEnabled: Bool = true

    private var icon: String {
        switch event.type {
        case "permission":
            return event.resolved ? "checkmark.shield.fill" : "shield.lefthalf.filled"
        case "stop": return "checkmark.circle.fill"
        case "info": return "info.circle.fill"
        default: return "bell.fill"
        }
    }

    private var iconColor: Color {
        switch event.type {
        case "permission":
            if event.resolved { return event.response == "approve" ? .green : .red }
            return .orange
        case "stop": return .green
        case "info": return .blue
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .font(.system(size: 15 * s))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 13 * s, weight: .semibold))
                    // Authoritative tool args: monospaced, primary visual weight.
                    Text(event.body)
                        .font(.system(size: 12 * s, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                    // AI-generated summary (untrusted): italic, prefixed label,
                    // sans-serif. Distinct from the monospaced body above so a
                    // crafted description string cannot pose as a real command.
                    if !event.description.isEmpty {
                        (Text("AI summary: ").italic().foregroundStyle(.tertiary)
                            + Text(event.description).italic().foregroundStyle(.secondary))
                            .font(.system(size: 11 * s))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                // Anchor the popover to this always-rendered VStack. Attaching
                // it to the Show-details button causes SwiftUI to re-anchor
                // (or orphan) the popover when the button's parent row
                // switches from permissionButtons to the resolved row, which
                // produced a visible drop/offset during the transition.
                .popover(isPresented: $showingDetails, arrowEdge: .leading) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(event.body)
                                .font(.system(size: 12 * s, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !event.description.isEmpty {
                                Divider()
                                (Text("AI summary: ").italic().foregroundStyle(.tertiary)
                                    + Text(event.description).italic().foregroundStyle(.secondary))
                                    .font(.system(size: 11 * s))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                    }
                    .frame(width: 500, height: 400)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(event.timestamp, style: .time)
                        .font(.system(size: 11 * s))
                        .foregroundStyle(.tertiary)
                    if !event.isPending {
                        Button { monitor.dismiss(event.id) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10 * s, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if event.isPending {
                if let expires = event.expires {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if context.date < expires {
                            permissionButtons
                        } else {
                            respondInTerminalLabel
                        }
                    }
                } else {
                    permissionButtons
                }
            }

            if event.resolved, let response = event.response {
                HStack {
                    showDetailsButton
                    Spacer()
                    Label(
                        response == "dismissed" ? "Handled in Terminal" : response.capitalized,
                        systemImage: response == "approve"
                            ? "checkmark.circle.fill"
                            : response == "dismissed"
                                ? "terminal.fill" : "xmark.circle.fill"
                    )
                    .font(.system(size: 11 * s, weight: .medium))
                    .foregroundStyle(
                        response == "approve" ? .green
                            : response == "dismissed" ? .secondary : .red)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.clear)
        .animation(.easeInOut(duration: 0.2), value: event.resolved)
    }

    @ViewBuilder private var showDetailsButton: some View {
        if event.type == "permission" && permissionDetailsEnabled {
            Button {
                showingDetails = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 9 * s, weight: .bold))
                    Text("Show details")
                        .font(.system(size: 10 * s, weight: .medium))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var permissionButtons: some View {
        HStack(spacing: 8) {
            showDetailsButton
            Spacer()
            Button("Deny") {
                // Close the detail popover before the event-resolved layout
                // change kicks in — a popover dismiss that races with the
                // window resize produces a visible empty rectangle above Navi.
                showingDetails = false
                monitor.respond(to: event.id, with: "deny")
            }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
            Button("Approve") {
                showingDetails = false
                monitor.respond(to: event.id, with: "approve")
            }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.small)
        }
        .padding(.top, 2)
    }

    private var respondInTerminalLabel: some View {
        HStack(spacing: 4) {
            showDetailsButton
            Spacer()
            Label("Respond in terminal", systemImage: "terminal.fill")
                .font(.system(size: 11 * s, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }
}
