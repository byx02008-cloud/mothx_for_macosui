import SwiftUI

struct Turn: Identifiable {
    /// The user message is the durable identity of a turn. A random UUID here
    /// makes every transcript refresh look like a completely new long list to
    /// SwiftUI, which is especially expensive while scrolling.
    let id: String
    let index: Int
    let userMessage: MothxMessage
    let resultMessages: [MothxMessage]
    let toolSummaries: [ToolInvocationSummary]
    let fileToolCalls: [MothxMessage]
    let toolResultCount: Int
    let hasResponded: Bool
    let isLast: Bool

    init(index: Int, userMessage: MothxMessage, resultMessages: [MothxMessage], toolSummaries: [ToolInvocationSummary], fileToolCalls: [MothxMessage] = [], toolResultCount: Int, hasResponded: Bool, isLast: Bool) {
        self.id = userMessage.id
        self.index = index
        self.userMessage = userMessage
        self.resultMessages = resultMessages
        self.toolSummaries = toolSummaries
        self.fileToolCalls = fileToolCalls
        self.toolResultCount = toolResultCount
        self.hasResponded = hasResponded
        self.isLast = isLast
    }

    var hasProcess: Bool { !toolSummaries.isEmpty }

    var uniqueToolNames: [String] {
        let names = toolSummaries.map(\.toolName)
        return Array(Set(names)).sorted()
    }
}

/// A deliberately small projection of a tool call. Full tool messages never
/// enter the main SwiftUI transcript tree; details are fetched on demand.
struct ToolInvocationSummary: Identifiable, Hashable {
    let id: String
    let toolName: String
    let argumentsPreview: String
    let arguments: String
    let resultSummary: String
    let hasDetail: Bool
    let isError: Bool
}

func computeTurns(_ messages: [MothxMessage]) -> [Turn] {
    guard !messages.isEmpty else { return [] }
    var turns: [Turn] = []
    var curUser: MothxMessage?
    var curSub: [MothxMessage] = []
    func makeTurn(index: Int, user: MothxMessage, messages: [MothxMessage], isLast: Bool) -> Turn {
        var results: [MothxMessage] = []
        var calls: [String: ToolInvocationSummary] = [:]
        var order: [String] = []
        var resultCount = 0
        var fileCalls: [MothxMessage] = []
        for msg in messages {
            if msg.isAssistant, !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results.append(MothxMessage(id: msg.id, seq: msg.seq, role: msg.role, content: msg.content.trimmingCharacters(in: .whitespacesAndNewlines), toolCallId: msg.toolCallId, toolName: msg.toolName, arguments: msg.arguments, plan: msg.plan, summary: msg.summary, hasDetail: msg.hasDetail, createdAt: msg.createdAt))
            } else if msg.isToolCall {
                let id = msg.toolCallId ?? msg.id
                let name = msg.toolName ?? "tool"
                calls[id] = ToolInvocationSummary(id: id, toolName: name, argumentsPreview: toolArgSummary(toolName: name, arguments: msg.arguments) ?? "", arguments: msg.arguments, resultSummary: "", hasDetail: false, isError: false)
                order.append(id)
                if ["edit", "write", "insert", "edit_file", "write_file", "insert_file", "insert_text"].contains((msg.toolName ?? "").lowercased().replacingOccurrences(of: "-", with: "_")) {
                    fileCalls.append(msg)
                }
            } else if msg.isToolResult {
                resultCount += 1
                let id = msg.toolCallId ?? msg.id
                let old = calls[id] ?? ToolInvocationSummary(id: id, toolName: msg.toolName ?? "tool", argumentsPreview: "", arguments: "", resultSummary: "", hasDetail: false, isError: false)
                calls[id] = ToolInvocationSummary(id: id, toolName: old.toolName, argumentsPreview: old.argumentsPreview, arguments: old.arguments, resultSummary: compactToolSummary(msg.summary ?? ""), hasDetail: msg.hasDetail, isError: false)
                if !order.contains(id) { order.append(id) }
            }
        }
        // A turn may contain intermediate assistant projections around tool
        // work. Only the final non-empty assistant projection belongs in the
        // main transcript; the rest is process detail, loaded separately.
        let finalResult = results.last.map { [$0] } ?? []
        return Turn(index: index, userMessage: user, resultMessages: finalResult, toolSummaries: order.compactMap { calls[$0] }, fileToolCalls: fileCalls, toolResultCount: resultCount, hasResponded: !messages.isEmpty, isLast: isLast)
    }
    for msg in messages {
        if msg.isUser {
            if let u = curUser { turns.append(makeTurn(index: turns.count, user: u, messages: curSub, isLast: false)) }
            curUser = msg; curSub = []
        } else { curSub.append(msg) }
    }
    if let u = curUser { turns.append(makeTurn(index: turns.count, user: u, messages: curSub, isLast: false)) }
    if !turns.isEmpty {
        let last = turns[turns.count - 1]
        turns[turns.count - 1] = Turn(index: last.index, userMessage: last.userMessage, resultMessages: last.resultMessages, toolSummaries: last.toolSummaries, fileToolCalls: last.fileToolCalls, toolResultCount: last.toolResultCount, hasResponded: last.hasResponded, isLast: true)
    }
    return turns
}

private func compactToolSummary(_ text: String) -> String {
    let compact = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    return compact.count > 140 ? String(compact.prefix(140)) + "…" : compact
}

struct TurnBlock: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    let turn: Turn
    let sessionID: String
    let isExpanded: Bool
    /// Expanded turns are prepared before their body is exposed to the
    /// scrolling container. This prevents LazyVStack from constructing a
    /// large transcript while the user is dragging the scrollbar.
    let isContentReady: Bool
    let onToggle: () -> Void
    /// Called when the user asks to fork from a completed assistant response.
    var onFork: ((MothxMessage) -> Void)? = nil
    var forkingMessageID: String? = nil
    var onReviewChanges: ((MothxTurnChanges) -> Void)? = nil
    var onPreviewSkill: ((MothxSkill) -> Void)? = nil
    var onPreviewTool: ((ToolInvocationSummary) -> Void)? = nil

    /// Explicit message forks are accepted only at the final assistant text
    /// entry of a completed turn. This mirrors mothx's `fork_unavailable`
    /// validation and avoids offering an action that the API must reject.
    private var forkableAssistantMessage: MothxMessage? {
        guard !isRunActive,
              let message = turn.resultMessages.last,
              let seq = message.seq,
              seq > 0,
              !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return message
    }

    /// The control is presented below the user's question, but it carries the
    /// completed assistant message required by the server as its fork boundary.
    private var forkAction: (() -> Void)? {
        guard let target = forkableAssistantMessage, let onFork else { return nil }
        return { onFork(target) }
    }

    private var isRunActive: Bool { mothx.runSessionID == sessionID && mothx.isRunning }
    /// A session-level Run is rendered as live state only by its final turn.
    /// Earlier turns remain historical while a new turn is executing.
    private var isTurnRunActive: Bool { turn.isLast && isRunActive }
    private var isCurrentRunSession: Bool { mothx.runSessionID == sessionID }

    private var turnChanges: MothxTurnChanges? {
        if let changes = mothx.changesByMessage[sessionID]?[turn.userMessage.id] {
            return changes
        }
        if turn.isLast, isCurrentRunSession, let runID = mothx.currentRunID {
            // The current run ID is also retained while the final transcript
            // is being attached. If its change capture is unavailable, keep
            // looking through the historical message mapping below instead of
            // returning nil and hiding a persisted Diff summary.
            if let changes = mothx.changesByRun[runID] { return changes }
        }
        let candidateIDs = [turn.userMessage.id] + turn.resultMessages.map(\.id) + turn.toolSummaries.map(\.id)
        for messageID in candidateIDs {
            if let run = mothx.historicalRunsByMessage[sessionID]?[messageID],
               let changes = mothx.changesByRun[run.id] {
                return changes
            }
        }
        let expectedLatestRunID = historicalRunID
            ?? (turn.isLast && isCurrentRunSession ? mothx.currentRunID : nil)
        if turn.isLast,
           let changes = mothx.latestChangesBySession[sessionID],
           let expectedLatestRunID,
           changes.runID == expectedLatestRunID {
            return changes
        }
        return nil
    }

    private var historicalRunID: String? {
        let candidateIDs = [turn.userMessage.id] + turn.resultMessages.map(\.id) + turn.toolSummaries.map(\.id)
        return candidateIDs.compactMap { mothx.historicalRunsByMessage[sessionID]?[$0]?.id }.first
    }

    /// Status for this turn: current-run live status for the last turn,
    /// otherwise historical run summary looked up from any message ID.
    private var turnStatus: (status: String, elapsed: TimeInterval, error: String?)? {
        // Current run, last turn → live status from service manager.
        if turn.isLast, isCurrentRunSession, let status = mothx.runStatus {
            return (status, mothx.runElapsed, mothx.runError)
        }
        // Historical turn → look up via any message ID (result or process).
        let candidateIDs = [turn.userMessage.id] + turn.resultMessages.map(\.id) + turn.toolSummaries.map(\.id)
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
                if isContentReady {
                    VStack(alignment: .leading, spacing: 10) {
                        MessageBubble(
                            message: turn.userMessage,
                            isCurrentRunning: false,
                            onFork: forkAction,
                            isForking: forkingMessageID == forkableAssistantMessage?.id
                        )
                        if turn.hasResponded { agentResponseBlock }
                        // Show status for the last turn before the agent responds,
                        // so the user sees elapsed time while waiting.
                        if turn.isLast, isCurrentRunSession, let status = mothx.runStatus, !turn.hasResponded {
                            StatusInline(
                                status: status,
                                elapsed: mothx.runElapsed,
                                error: mothx.runError,
                                thinking: isRunActive ? mothx.thinkingBySession[sessionID] : nil,
                                allowsExpansion: isRunActive
                            )
                        }
                    }
                    .padding(.leading, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("加载中… / Loading…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
                }
            }
        }
        .padding(.vertical, 4)
        .task(id: turn.id) {
            guard !turn.fileToolCalls.isEmpty,
                  turnChanges == nil else { return }
            await mothx.ensureHistoricalChanges(sessionID: sessionID, runID: historicalRunID, toolCalls: turn.fileToolCalls)
        }
    }

    // MARK: - Agent Response Block

    private var agentResponseBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if turn.hasProcess {
                processBlock
                if !turn.resultMessages.isEmpty { Divider().padding(.vertical, 2) }
            }
            ForEach(turn.resultMessages) { message in
                MessageBubble(
                    message: message,
                    isCurrentRunning: isTurnRunActive && mothx.currentRunningMessageID == message.id
                )
            }
            if !isTurnRunActive, let turnChanges, !turnChanges.files.isEmpty {
                ChangeSummaryCard(
                    changes: turnChanges,
                    onReview: { onReviewChanges?(turnChanges) },
                    onPreview: { onReviewChanges?(turnChanges) }
                )
            }
            // One status per turn, always below the change card.
            // Current run: use live status.  Historical: look up via any
            // message ID (result or process) so tool-only turns also show.
            if let s = turnStatus {
                StatusInline(
                    status: s.status,
                    elapsed: s.elapsed,
                    error: s.error,
                    thinking: isTurnRunActive ? mothx.thinkingBySession[sessionID] : nil,
                    allowsExpansion: isTurnRunActive
                )
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.015))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Process Block

    @State private var isProcessExpanded: Bool = false
    @State private var isProcessLoading = false
    @State private var processPage = 0
    @State private var loadedToolDetails: [String: String] = [:]
    @State private var processLoadError: String?
    private let processPageSize = 8

    private var processBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { isProcessExpanded.toggle() }
                    if isProcessExpanded { loadProcessPage(0) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.2").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text(languageStore.copy.process).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text("· 调用 \(turn.toolSummaries.count) · 结果 \(turn.toolResultCount)").font(.caption2).foregroundStyle(.tertiary)
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
                // Process details are already paged. Keep them in the parent
                // conversation scroll tree so this card never creates a
                // nested scrollbar or a second scroll gesture target.
                processDetails
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.orange.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.15), lineWidth: 1))
    }

    private var currentProcessSummaries: ArraySlice<ToolInvocationSummary> {
        let start = processPage * processPageSize
        guard start < turn.toolSummaries.count else { return turn.toolSummaries[turn.toolSummaries.count..<turn.toolSummaries.count] }
        return turn.toolSummaries[start..<min(start + processPageSize, turn.toolSummaries.count)]
    }

    @ViewBuilder
    private var processDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isProcessLoading {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("加载过程… / Loading process…").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(Array(currentProcessSummaries)) { item in
                let skill = referencedSkill(for: item)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: skill == nil ? (item.isError ? "xmark.circle" : "wrench.and.screwdriver") : "sparkles").foregroundStyle(item.isError ? .red : .orange)
                        if let skill {
                            Button {
                                onPreviewSkill?(skill)
                            } label: {
                                HStack(spacing: 4) {
                                    Text(skill.name).fontWeight(.medium)
                                    Image(systemName: "arrow.up.right").font(.caption2)
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.orange)
                        } else {
                            Text(toolDisplayName(item.toolName, language: languageStore.language)).fontWeight(.medium)
                            if !item.argumentsPreview.isEmpty { Text(item.argumentsPreview).lineLimit(1).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if let skill {
                            Button {
                                onPreviewSkill?(skill)
                            } label: {
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("在右侧栏中查看技能")
                        } else if item.hasDetail || !item.resultSummary.isEmpty {
                            Button {
                                onPreviewTool?(item)
                            } label: {
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("在右侧栏中查看")
                        }
                    }
                }
                .font(.caption.monospaced())
            }
            if let processLoadError { Text(processLoadError).font(.caption).foregroundStyle(.red) }
            if turn.toolSummaries.count > processPageSize {
                HStack {
                    Button("上一页") { loadProcessPage(processPage - 1) }.disabled(processPage == 0 || isProcessLoading)
                    Text("第 \(processPage + 1) / \((turn.toolSummaries.count + processPageSize - 1) / processPageSize) 页").font(.caption2).foregroundStyle(.secondary)
                    Button("下一页") { loadProcessPage(processPage + 1) }.disabled((processPage + 1) * processPageSize >= turn.toolSummaries.count || isProcessLoading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private func referencedSkill(for item: ToolInvocationSummary) -> MothxSkill? {
        let tool = item.toolName.lowercased().replacingOccurrences(of: "-", with: "_")
        guard ["skill", "skill_reference", "skill_ref", "load_skill", "skill_use"].contains(tool) else { return nil }
        let name: String?
        if let data = item.arguments.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            name = (object["name"] as? String) ?? (object["skill"] as? String) ?? (object["skillName"] as? String)
        } else {
            name = item.argumentsPreview.isEmpty ? nil : item.argumentsPreview
        }
        guard let name, !name.isEmpty else { return nil }
        return mothx.installedSkills.first(where: { $0.name == name }) ?? MothxSkill(id: name, name: name, directory: "")
    }

    private func loadProcessPage(_ page: Int) {
        guard page >= 0, page * processPageSize < turn.toolSummaries.count else { return }
        processPage = page
        let items = Array(turn.toolSummaries[(page * processPageSize)..<min((page + 1) * processPageSize, turn.toolSummaries.count)])
        let sessionID = sessionID
        isProcessLoading = true
        processLoadError = nil
        Task { @MainActor in
            var loaded: [String: String] = [:]
            for item in items where referencedSkill(for: item) == nil &&
                                  item.hasDetail &&
                                  loadedToolDetails[item.id] == nil {
                if let detail = await mothx.loadToolResultDetail(sessionID: sessionID, toolCallID: item.id) {
                    loaded[item.id] = detail.content
                }
            }
            loadedToolDetails.merge(loaded) { _, new in new }
            isProcessLoading = false
        }
    }
}
