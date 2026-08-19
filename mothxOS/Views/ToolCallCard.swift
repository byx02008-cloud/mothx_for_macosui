import SwiftUI

struct ToolCallCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let toolCall: MothxToolCallBlock
    let isRunning: Bool

    @State private var isExpanded = false
    @State private var iconPulse = false

    private var iconName: String { toolIcon(for: toolCall.name) }
    private var displayName: String { toolDisplayName(toolCall.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: iconName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.orange)
                        .scaleEffect(iconPulse ? 1.2 : 1.0)
                        .animation(
                            isRunning
                                ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                                : .default,
                            value: iconPulse
                        )

                    Text(displayName)
                        .font(.subheadline.weight(.medium))

                    if let summary = toolArgSummary(toolName: toolCall.name, arguments: toolCall.arguments) {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if !toolCall.arguments.isEmpty {
                        // Show raw args preview
                        Text(rawArgPreview)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                    if !toolCall.arguments.isEmpty {
                        Text(formattedArguments)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    } else {
                        HStack(spacing: 6) {
                            Text("ID:")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(toolCall.id)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            colorScheme == .light
                ? Color.orange.opacity(0.06)
                : Color.orange.opacity(0.1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        )
        .onAppear {
            if isRunning { iconPulse = true }
        }
        .onChange(of: isRunning) { _, running in
            iconPulse = running
        }
    }

    private var formattedArguments: String {
        guard let data = toolCall.arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else {
            return toolCall.arguments
        }
        return str
    }

    /// Short preview of raw args for collapsed display
    private var rawArgPreview: String {
        let trimmed = toolCall.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 50 { return trimmed }
        return String(trimmed.prefix(50)) + "…"
    }
}