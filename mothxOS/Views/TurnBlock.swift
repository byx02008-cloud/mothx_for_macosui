import SwiftUI

struct Turn: Identifiable {
    let id = UUID()
    let index: Int
    let userMessage: MothxMessage
    let subsequentMessages: [MothxMessage]
    let isLast: Bool

    /// Process: toolCall + toolResult messages (skip empty summaries)
    var processMessages: [MothxMessage] {
        subsequentMessages.filter { msg in
            if msg.isToolCall { return true }
            if msg.isToolResult { return !(msg.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return false
        }
    }

    /// Result: assistant messages (final answer), skip empty, trim
    var resultMessages: [MothxMessage] {
        subsequentMessages.filter {
            $0.isAssistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map { msg in
            MothxMessage(
                id: msg.id, seq: msg.seq, role: msg.role,
                content: msg.content.trimmingCharacters(in: .whitespacesAndNewlines),
                toolCallId: msg.toolCallId, toolName: msg.toolName,
                arguments: msg.arguments, summary: msg.summary,
                hasDetail: msg.hasDetail, createdAt: msg.createdAt
            )
        }
    }

    var hasProcess: Bool { !processMessages.isEmpty }
    var hasResponded: Bool { !subsequentMessages.isEmpty }

    var uniqueToolNames: [String] {
        let names = processMessages.compactMap(\.toolName)
        return Array(Set(names)).sorted()
    }

    /// Full process text, compact (no blank lines between entries)
    func processText(language: AppLanguage) -> String {
        var lines: [String] = []
        for msg in processMessages {
            if msg.isToolCall {
                let name = toolDisplayName(msg.toolName ?? "", language: language)
                if let args = toolArgSummary(toolName: msg.toolName ?? "", arguments: msg.arguments) {
                    lines.append("🔧 \(name): \(args)")
                } else {
                    lines.append("🔧 \(name)")
                }
            } else if msg.isToolResult {
                let name = toolDisplayName(msg.toolName ?? "", language: language)
                let text = (msg.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    lines.append("✓ \(name)")
                } else {
                    // Compact: replace multiple newlines with single space
                    let compact = text
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    if compact.count > 100 {
                        lines.append("✓ \(name): \(compact.prefix(100))…")
                    } else {
                        lines.append("✓ \(name): \(compact)")
                    }
                }
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
    @EnvironmentObject private var languageStore: LanguageStore
    let turn: Turn
    let sessionID: String
    let isExpanded: Bool
    let onToggle: () -> Void

    private var isRunActive: Bool { mothx.runSessionID == sessionID && mothx.isRunning }
    private var isCurrentRunSession: Bool { mothx.runSessionID == sessionID }

    /// Status for this turn: current-run live status for the last turn,
    /// otherwise historical run summary looked up from any message ID.
    private var turnStatus: (status: String, elapsed: TimeInterval, error: String?)? {
        // Current run, last turn → live status from service manager.
        if turn.isLast, isCurrentRunSession, let status = mothx.runStatus {
            return (status, mothx.runElapsed, mothx.runError)
        }
        // Historical turn → look up via any message ID (result or process).
        let candidateIDs = [turn.userMessage.id] + turn.resultMessages.map(\.id) + turn.processMessages.map(\.id)
        for msgID in candidateIDs {
            if let hr = mothx.historicalRunsByMessage[sessionID]?[msgID],
               hr.id != mothx.currentRunID {
                return (hr.status, hr.elapsed, hr.error)
            }
        }
        return nil
    }

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
                    if turn.isLast, isRunActive,
                       mothx.runStatus == "queued" || mothx.runStatus == "running" {
                        ThinkingIndicator(isActive: true)
                    }
                    // Show status for the last turn before the agent responds,
                    // so the user sees elapsed time while waiting.
                    if turn.isLast, isCurrentRunSession, let status = mothx.runStatus, !turn.hasResponded {
                        StatusInline(status: status, elapsed: mothx.runElapsed, error: mothx.runError)
                    }
                }
                .padding(.leading, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Agent Response Block

    private var agentResponseBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if turn.hasProcess {
                processBlock
                if !turn.resultMessages.isEmpty { Divider().padding(.vertical, 2) }
            }
            ForEach(turn.resultMessages) { message in
                MessageBubble(message: message, isCurrentRunning: isRunActive && mothx.currentRunningMessageID == message.id)
            }
            // One status per turn, always at the bottom.
            // Current run: use live status.  Historical: look up via any
            // message ID (result or process) so tool-only turns also show.
            if let s = turnStatus {
                StatusInline(status: s.status, elapsed: s.elapsed, error: s.error)
            }
        }
        .padding(8)
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
                    Text(languageStore.copy.process).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(turn.uniqueToolNames, id: \.self) { name in
                        HStack(spacing: 2) {
                            Image(systemName: toolIcon(for: name)).font(.system(size: 8))
                            Text(toolDisplayName(name, language: languageStore.language)).font(.system(size: 8))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(Capsule())
                    }
                    Spacer()
                    Image(systemName: isProcessExpanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isProcessExpanded {
                Divider()
                ScrollView {
                    Text(turn.processText(language: languageStore.language))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
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
