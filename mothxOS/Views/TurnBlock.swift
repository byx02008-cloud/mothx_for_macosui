import SwiftUI

struct Turn: Identifiable {
    let id = UUID()
    let index: Int
    let userMessage: MothxMessage
    let subsequentMessages: [MothxMessage]
    let isLast: Bool

    /// Process: toolCall + toolResult messages
    var processMessages: [MothxMessage] {
        subsequentMessages.filter { $0.isToolCall || $0.isToolResult }
    }

    /// Result: assistant messages (final answer)
    var resultMessages: [MothxMessage] {
        subsequentMessages.filter { $0.isAssistant }
    }

    var hasProcess: Bool { !processMessages.isEmpty }
    var hasResponded: Bool { !subsequentMessages.isEmpty }

    var uniqueToolNames: [String] {
        let names = processMessages.compactMap(\.toolName)
        return Array(Set(names)).sorted()
    }

    /// Full process text
    var processText: String {
        var lines: [String] = []
        for msg in processMessages {
            if msg.isToolCall {
                let name = toolDisplayName(msg.toolName ?? "")
                let args = toolArgSummary(toolName: msg.toolName ?? "", arguments: msg.arguments)
                if let args { lines.append("🔧 \(name): \(args)") }
                else { lines.append("🔧 \(name)") }
            } else if msg.isToolResult {
                let name = toolDisplayName(msg.toolName ?? "")
                let text = msg.summary ?? ""
                if text.isEmpty { lines.append("✓ \(name)") }
                else { lines.append("✓ \(name): \(text)") }
            }
        }
        return lines.joined(separator: "\n")
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

struct TurnBlock: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    let turn: Turn
    let sessionID: String
    let isExpanded: Bool
    let onToggle: () -> Void

    private var isRunActive: Bool { mothx.runSessionID == sessionID && mothx.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                    MessageBubble(message: turn.userMessage, isCurrentRunning: false)
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
                MessageBubble(message: message, isCurrentRunning: isRunActive && mothx.currentRunningMessageID == message.id)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.015))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Process Block

    @State private var isProcessExpanded: Bool = false

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
                Divider()
                ScrollView {
                    Text(turn.processText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .frame(maxHeight: 300)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.orange.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.15), lineWidth: 1))
    }
}