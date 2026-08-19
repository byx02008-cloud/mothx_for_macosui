import SwiftUI

/// MessageBubble is the dispatcher that routes to appropriate sub-components
/// based on message role and content type.
struct MessageBubble: View {
    let message: MothxMessage
    let isCurrentRunning: Bool
    let isLastToolResult: Bool  // true if this is the last in a group of consecutive tool results

    var body: some View {
        Group {
            switch message.role {
            case "user":
                TextMessageBubble(message: message, isCurrentRunning: false)

            case "assistant":
                VStack(alignment: .leading, spacing: 8) {
                    // Text content (with typewriter)
                    if !message.displayText.isEmpty {
                        TextMessageBubble(message: message, isCurrentRunning: isCurrentRunning)
                    }

                    // Tool call cards
                    ForEach(message.toolCallBlocks) { block in
                        if let tc = block.toolCall {
                            ToolCallCard(
                                toolCall: tc,
                                isRunning: isCurrentRunning
                            )
                            .padding(.leading, 28)
                            .transition(
                                .move(edge: .bottom).combined(with: .opacity)
                            )
                        }
                    }
                }

            case "toolResult":
                if isLastToolResult {
                    ToolResultCard(
                        toolName: message.toolName ?? "",
                        content: message.content,
                        isError: message.isError,
                        callCount: 1
                    )
                    .padding(.leading, 28)
                    .transition(
                        .scale(scale: 0.8).combined(with: .opacity)
                    )
                }

            default:
                TextMessageBubble(message: message, isCurrentRunning: false)
            }
        }
        .transition(
            .move(edge: .bottom).combined(with: .opacity)
        )
    }
}

// MARK: - Deduplicated tool result view

/// A wrapper that deduplicates consecutive tool results and shows count badges.
struct ToolResultGroupView: View {
    let messages: [MothxMessage]
    let startIndex: Int

    private var group: ToolResultGroup {
        ToolResultGroup.from(messages: messages, startIndex: startIndex)
    }

    var body: some View {
        ToolResultCard(
            toolName: group.toolName,
            content: group.mergedContent,
            isError: group.isError,
            callCount: group.count
        )
        .padding(.leading, 28)
        .transition(
            .scale(scale: 0.8).combined(with: .opacity)
        )
    }
}

/// Represents a group of consecutive tool results with the same toolName
struct ToolResultGroup {
    let toolName: String
    let mergedContent: String
    let isError: Bool
    let count: Int

    static func from(messages: [MothxMessage], startIndex: Int) -> ToolResultGroup {
        guard startIndex < messages.count,
              messages[startIndex].isToolResult,
              let toolName = messages[startIndex].toolName else {
            return ToolResultGroup(toolName: "", mergedContent: "", isError: false, count: 0)
        }

        let baseIsError = messages[startIndex].isError
        var contents: [String] = []
        var count = 0
        var i = startIndex

        while i < messages.count,
              messages[i].isToolResult,
              messages[i].toolName == toolName,
              messages[i].isError == baseIsError {
            contents.append(messages[i].content)
            count += 1
            i += 1
        }

        return ToolResultGroup(
            toolName: toolName,
            mergedContent: contents.joined(separator: "\n---\n"),
            isError: baseIsError,
            count: count
        )
    }
}