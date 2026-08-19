import SwiftUI

struct ToolResultCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let toolName: String
    let content: String
    let isError: Bool
    let callCount: Int

    @State private var isExpanded = false
    @State private var iconBounce = false

    private var iconName: String { toolIcon(for: toolName) }
    private var displayName: String { toolDisplayName(toolName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isError ? .red : .green)
                        .scaleEffect(iconBounce ? 1.0 : 0.3)
                        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: iconBounce)

                    Image(systemName: iconName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Text(displayName)
                        .font(.subheadline.weight(.medium))

                    if callCount > 1 {
                        Text("×\(callCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.6))
                            .clipShape(Capsule())
                    }

                    Spacer()

                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(isError ? .red : .secondary)
                        .lineLimit(1)

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
                    if content.isEmpty {
                        Text(isError ? "执行失败" : "执行完成")
                            .font(.caption)
                            .foregroundStyle(isError ? .red : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    } else if callCount > 1 {
                        // Stack multiple results
                        let parts = content.components(separatedBy: "\n---\n")
                        ForEach(Array(parts.enumerated()), id: \.offset) { idx, part in
                            if idx > 0 { Divider().padding(.leading, 12) }
                            Text(part.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.caption)
                                .foregroundStyle(isError ? .red : .secondary)
                                .textSelection(.enabled)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text(content)
                            .font(.caption)
                            .foregroundStyle(isError ? .red : .secondary)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            (isError ? Color.red : Color.green)
                .opacity(colorScheme == .light ? 0.05 : 0.08)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke((isError ? Color.red : Color.green).opacity(0.2), lineWidth: 1)
        )
        .onAppear { iconBounce = true }
    }

    private var summary: String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return isError ? "失败" : "完成" }
        let maxLen = 60
        if trimmed.count <= maxLen { return trimmed }
        return String(trimmed.prefix(maxLen)) + "…"
    }
}

// MARK: - Tool result deduplication helper

/// Groups consecutive toolResult messages by toolName, counting calls.
/// Returns an array of (toolName, content, isError, callCount) tuples.
func deduplicateToolResults(_ messages: [MothxMessage]) -> [MothxMessage] {
    var result: [MothxMessage] = []
    var currentGroup: [MothxMessage] = []

    for msg in messages {
        if msg.isToolResult {
            if let last = currentGroup.last,
               last.toolName == msg.toolName,
               last.isError == msg.isError {
                currentGroup.append(msg)
            } else {
                // Flush previous group
                if let first = currentGroup.first {
                    let merged = MothxMessage(
                        id: first.id,
                        role: "toolResult",
                        content: currentGroup.map(\.content).joined(separator: "\n---\n"),
                        contents: [],
                        toolCallId: first.toolCallId,
                        toolName: first.toolName,
                        isError: first.isError,
                        createdAt: first.createdAt
                    )
                    result.append(merged)
                }
                currentGroup = [msg]
            }
        } else {
            // Flush tool results before non-tool message
            if let first = currentGroup.first {
                let merged = MothxMessage(
                    id: first.id,
                    role: "toolResult",
                    content: currentGroup.map(\.content).joined(separator: "\n---\n"),
                    contents: [],
                    toolCallId: first.toolCallId,
                    toolName: first.toolName,
                    isError: first.isError,
                    createdAt: first.createdAt
                )
                result.append(merged)
            }
            currentGroup = []
            result.append(msg)
        }
    }

    // Flush remaining
    if let first = currentGroup.first {
        let merged = MothxMessage(
            id: first.id,
            role: "toolResult",
            content: currentGroup.map(\.content).joined(separator: "\n---\n"),
            contents: [],
            toolCallId: first.toolCallId,
            toolName: first.toolName,
            isError: first.isError,
            createdAt: first.createdAt
        )
        result.append(merged)
    }

    return result
}

/// Count consecutive tool results with same toolName
func toolResultCallCount(in messages: [MothxMessage], at index: Int) -> Int {
    guard index < messages.count,
          messages[index].isToolResult,
          let toolName = messages[index].toolName else { return 1 }

    var count = 1
    var i = index + 1
    while i < messages.count,
          messages[i].isToolResult,
          messages[i].toolName == toolName,
          messages[i].isError == messages[index].isError {
        count += 1
        i += 1
    }
    return count
}