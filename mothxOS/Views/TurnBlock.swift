import SwiftUI

/// A turn groups: 1 user message + all following assistant/toolResult messages
/// until the next user message.
struct Turn: Identifiable {
    let id = UUID()
    let index: Int
    let userMessage: MothxMessage
    let subsequentMessages: [MothxMessage]
    let isLast: Bool

    var responseMessages: [MothxMessage] { subsequentMessages }

    var hasProcess: Bool {
        responseMessages.contains { $0.isToolResult || ($0.isAssistant && $0.hasStructuredContent) }
    }
    var hasResponded: Bool { !responseMessages.isEmpty }

    var toolResultGroups: [ToolResultGroup] {
        let trs = responseMessages.filter(\.isToolResult)
        var groups: [ToolResultGroup] = []
        var i = 0
        while i < trs.count {
            let g = ToolResultGroup.from(messages: trs, startIndex: i)
            groups.append(g); i += g.count
        }
        return groups
    }

    var uniqueToolNames: [String] {
        var names = Set<String>()
        for msg in responseMessages {
            for b in msg.toolCallBlocks { if let tc = b.toolCall { names.insert(tc.name) } }
            if let n = msg.toolName { names.insert(n) }
        }
        return names.sorted()
    }

    var allToolCallBlocks: [MothxToolCallBlock] {
        responseMessages.flatMap { $0.toolCallBlocks.compactMap(\.toolCall) }
    }

    var resultMessages: [MothxMessage] {
        responseMessages.filter { $0.isAssistant && !$0.hasStructuredContent }
    }
}

func computeTurns(_ messages: [MothxMessage]) -> [Turn] {
    guard !messages.isEmpty else { return [] }
    var turns: [Turn] = []
    var curUser: MothxMessage?
    var curSub: [MothxMessage] = []
    for msg in messages {
        if msg.isUser {
            if let u = curUser { turns.append(Turn(index: turns.count, userMessage: u, subsequentMessages: curSub, isLast: false)) }
            curUser = msg; curSub = []
        } else { curSub.append(msg) }
    }
    if let u = curUser { turns.append(Turn(index: turns.count, userMessage: u, subsequentMessages: curSub, isLast: false)) }
    if !turns.isEmpty {
        let last = turns[turns.count - 1]
        turns[turns.count - 1] = Turn(index: last.index, userMessage: last.userMessage, subsequentMessages: last.subsequentMessages, isLast: true)
    }
    return turns
}

// MARK: - TurnBlock

struct TurnBlock: View {
    @EnvironmentObject private var mothx: MothxServiceManager

    let turn: Turn
    let sessionID: String
    let isExpanded: Bool
    let onToggle: () -> Void

    private var isRunActive: Bool { mothx.runSessionID == sessionID && mothx.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clickable header (user message preview)
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Text(turn.userMessage.content)
                        .font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                    Spacer()
                }
                .padding(.vertical, 8).padding(.horizontal, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    MessageBubble(message: turn.userMessage, isCurrentRunning: false, isLastToolResult: true)
                    if turn.hasResponded { agentResponseBlock }
                    if turn.isLast, isRunActive, mothx.runReplyMessageID == nil, mothx.runStatus == "running" {
                        ThinkingIndicator(isActive: true)
                    }
                }
                .padding(.leading, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Agent Response Block

    private var agentResponseBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if turn.hasProcess {
                processBlock
                if !turn.resultMessages.isEmpty { Divider().padding(.vertical, 4) }
            }
            ForEach(turn.resultMessages) { message in
                if let hr = mothx.historicalRunsByMessage[sessionID]?[message.id],
                   hr.id != mothx.currentRunID {
                    StatusInline(status: hr.status, elapsed: hr.elapsed, error: hr.error)
                }
                if mothx.runReplyMessageID == message.id {
                    StatusInline(status: mothx.runStatus ?? "", elapsed: mothx.runElapsed, error: mothx.runError)
                }
                MessageBubble(message: message, isCurrentRunning: isRunActive && mothx.currentRunningMessageID == message.id, isLastToolResult: true)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.015))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(turn.hasProcess ? Color.blue.opacity(0.2) : Color.primary.opacity(0.08), lineWidth: 1))
    }

    // MARK: - Process Block

    @State private var isProcessExpanded: Bool = true

    private var processBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { isProcessExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.2").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text("过程").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(turn.uniqueToolNames, id: \.self) { name in
                        HStack(spacing: 2) {
                            Image(systemName: toolIcon(for: name)).font(.system(size: 8))
                            Text(toolDisplayName(name)).font(.system(size: 8))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(Capsule())
                    }
                    Spacer()
                    Image(systemName: isProcessExpanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isProcessExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    ForEach(turn.allToolCallBlocks) { tc in
                        ToolCallCard(toolCall: tc, isRunning: isRunActive && mothx.currentRunningMessageID == tc.id)
                    }
                    ForEach(turn.toolResultGroups.indices, id: \.self) { idx in
                        let tr = turn.toolResultGroups[idx]
                        ToolResultCard(toolName: tr.toolName, content: tr.mergedContent, isError: tr.isError, callCount: tr.count)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                    if turn.isLast, isRunActive, let status = mothx.runStatus {
                        StatusInline(status: status, elapsed: mothx.runElapsed, error: mothx.runError)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.orange.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.15), lineWidth: 1))
    }
}