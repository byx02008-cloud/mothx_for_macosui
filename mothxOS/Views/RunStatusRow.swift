import SwiftUI

struct RunStatusRow: View {
    let status: String
    let elapsed: TimeInterval
    let error: String?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Text("\(statusLabel) \(formattedElapsed)")
                        .font(.caption)
                        .foregroundStyle(isErrorStatus || !(error ?? "").isEmpty ? Color.red : Color.primary.opacity(0.68))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            if expanded, let error, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.bottom, 5)
            }
            Divider()
        }
    }

    private var statusLabel: String {
        switch status.lowercased() {
        case "queued": return "排队中"
        case "running", "in_progress": return "模型处理中"
        case "completed", "succeeded": return "已完成"
        case "failed", "error": return "处理失败"
        case "cancelled", "canceled": return "已取消"
        case "timeout": return "等待超时"
        default: return status
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
        return String(format: "%.0f 分 %.0f 秒", floor(elapsed / 60), elapsed.truncatingRemainder(dividingBy: 60))
    }
}
