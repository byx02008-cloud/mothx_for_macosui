import SwiftUI

/// Inline status indicator replacing RunStatusRow.
/// Shows a dot + label + elapsed time, with dot blink animation during running states.
struct StatusInline: View {
    let status: String
    let elapsed: TimeInterval
    let error: String?

    @State private var isExpanded = false
    @State private var dotBlink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    // Status dot
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                        .opacity(isRunningStatus ? (dotBlink ? 0.3 : 1.0) : 1.0)
                        .animation(
                            isRunningStatus
                                ? .easeInOut(duration: 0.8).repeatForever()
                                : .default,
                            value: dotBlink
                        )

                    // Status icon (SF Symbol with content transition)
                    Image(systemName: statusIcon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusColor)
                        .contentTransition(.symbolEffect(.replace))

                    // Status label
                    Text(statusLabel)
                        .font(.caption)
                        .foregroundStyle(isErrorStatus || !(error ?? "").isEmpty
                            ? Color.red : Color.primary.opacity(0.68))

                    // Elapsed
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(formattedElapsed)
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    // Expand chevron
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Spacer()
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if let error, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.bottom, 5)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Divider()
            }
        }
        .onAppear {
            if isRunningStatus { dotBlink = true }
        }
        .onChange(of: status) { _, newStatus in
            dotBlink = isRunningStatus
        }
    }

    // MARK: - Computed

    private var statusLabel: String {
        switch status.lowercased() {
        case "queued":       return "排队中"
        case "running", "in_progress": return "处理中"
        case "completed", "succeeded": return "已完成"
        case "failed", "error": return "失败"
        case "cancelled", "canceled": return "已取消"
        case "timeout":      return "超时"
        default:             return status
        }
    }

    private var statusIcon: String {
        switch status.lowercased() {
        case "queued":       return "clock"
        case "running", "in_progress": return "ellipsis.circle"
        case "completed", "succeeded": return "checkmark.circle"
        case "failed", "error": return "xmark.circle"
        case "cancelled", "canceled": return "stop.circle"
        case "timeout":      return "clock.badge.exclamationmark"
        default:             return "circle"
        }
    }

    private var statusColor: Color {
        switch status.lowercased() {
        case "queued":                     return .orange
        case "running", "in_progress":     return .blue
        case "completed", "succeeded":     return .green
        case "failed", "error", "timeout", "cancelled", "canceled": return .red
        default:                           return .secondary
        }
    }

    private var isRunningStatus: Bool {
        switch status.lowercased() {
        case "running", "in_progress": return true
        default: return false
        }
    }

    private var isErrorStatus: Bool {
        switch status.lowercased() {
        case "failed", "error", "timeout", "cancelled", "canceled": return true
        default: return false
        }
    }

    private var formattedElapsed: String {
        if elapsed < 60 { return String(format: "%.1f 秒", elapsed) }
        return String(format: "%.0f 分 %.0f 秒",
            floor(elapsed / 60),
            elapsed.truncatingRemainder(dividingBy: 60))
    }
}