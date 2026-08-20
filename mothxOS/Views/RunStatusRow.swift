import SwiftUI

struct RunStatusRow: View {
    let status: String
    let elapsed: TimeInterval
    let error: String?
    @EnvironmentObject private var languageStore: LanguageStore
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
        let copy = languageStore.copy
        switch status.lowercased() {
        case "queued": return copy.statusQueued
        case "running", "in_progress": return copy.runRowRunning
        case "completed", "succeeded": return copy.statusCompleted
        case "failed", "error": return copy.runRowFailed
        case "cancelled", "canceled": return copy.statusCancelled
        case "timeout": return copy.runRowTimeout
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
        formatElapsedShort(elapsed, language: languageStore.language)
    }
}
