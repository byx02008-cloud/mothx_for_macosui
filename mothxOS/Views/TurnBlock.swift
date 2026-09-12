import SwiftUI

nonisolated struct Turn: Identifiable {
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
    /// True when the turn has no user message of its own: the server returned
    /// a bounded window that starts mid-turn (see `MothxServiceManager
    /// .extendWindowToUserAnchor`). The header is hidden and the body is always
    /// rendered so an anchorless window can never show an empty conversation.
    let isAnchorless: Bool

    init(index: Int, userMessage: MothxMessage, resultMessages: [MothxMessage], toolSummaries: [ToolInvocationSummary], fileToolCalls: [MothxMessage] = [], toolResultCount: Int, hasResponded: Bool, isLast: Bool, isAnchorless: Bool = false) {
        self.id = userMessage.id
        self.index = index
        self.userMessage = userMessage
        self.resultMessages = resultMessages
        self.toolSummaries = toolSummaries
        self.fileToolCalls = fileToolCalls
        self.toolResultCount = toolResultCount
        self.hasResponded = hasResponded
        self.isLast = isLast
        self.isAnchorless = isAnchorless
    }

    var hasProcess: Bool { !toolSummaries.isEmpty }

    var uniqueToolNames: [String] {
        let names = toolSummaries.map(\.toolName)
        return Array(Set(names)).sorted()
    }
}

/// A deliberately small projection of a tool call. Full tool messages never
/// enter the main SwiftUI transcript tree; details are fetched on demand.
nonisolated struct ToolInvocationSummary: Identifiable, Hashable {
    let id: String
    let toolName: String
    let argumentsPreview: String
    let arguments: String
    let resultSummary: String
    let hasDetail: Bool
    let isError: Bool
    let imagePreviews: [MothxImagePreview]
    let videoPreviews: [MothxVideoPreview]
    let documentPreviews: [MothxDocumentPreview]

    init(id: String, toolName: String, argumentsPreview: String, arguments: String, resultSummary: String, hasDetail: Bool, isError: Bool, imagePreviews: [MothxImagePreview] = [], videoPreviews: [MothxVideoPreview] = [], documentPreviews: [MothxDocumentPreview] = []) {
        self.id = id
        self.toolName = toolName
        self.argumentsPreview = argumentsPreview
        self.arguments = arguments
        self.resultSummary = resultSummary
        self.hasDetail = hasDetail
        self.isError = isError
        self.imagePreviews = imagePreviews
        self.videoPreviews = videoPreviews
        self.documentPreviews = documentPreviews
    }
}

nonisolated func computeTurns(_ messages: [MothxMessage]) -> [Turn] {
    guard !messages.isEmpty else { return [] }
    var turns: [Turn] = []
    var curUser: MothxMessage?
    var curSub: [MothxMessage] = []
    func makeTurn(index: Int, user: MothxMessage, messages: [MothxMessage], isLast: Bool, isAnchorless: Bool = false) -> Turn {
        var results: [MothxMessage] = []
        var calls: [String: ToolInvocationSummary] = [:]
        var order: [String] = []
        var resultCount = 0
        var fileCalls: [MothxMessage] = []
        for msg in messages {
            if msg.isAssistant,
               (!msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !msg.imagePreviews.isEmpty || !msg.videoPreviews.isEmpty || !msg.documentPreviews.isEmpty) {
                results.append(MothxMessage(id: msg.id, seq: msg.seq, role: msg.role, content: msg.content.trimmingCharacters(in: .whitespacesAndNewlines), toolCallId: msg.toolCallId, toolName: msg.toolName, arguments: msg.arguments, plan: msg.plan, summary: msg.summary, hasDetail: msg.hasDetail, createdAt: msg.createdAt, imagePreviews: msg.imagePreviews, videoPreviews: msg.videoPreviews, documentPreviews: msg.documentPreviews))
            } else if msg.isToolCall {
                let id = msg.toolCallId ?? msg.id
                let name = msg.toolName ?? "tool"
                calls[id] = ToolInvocationSummary(id: id, toolName: name, argumentsPreview: toolArgSummary(toolName: name, arguments: msg.arguments) ?? "", arguments: msg.arguments, resultSummary: "", hasDetail: false, isError: false, imagePreviews: msg.imagePreviews, videoPreviews: msg.videoPreviews, documentPreviews: msg.documentPreviews)
                order.append(id)
                if ["edit", "write", "insert", "edit_file", "write_file", "insert_file", "insert_text"].contains((msg.toolName ?? "").lowercased().replacingOccurrences(of: "-", with: "_")) {
                    fileCalls.append(msg)
                }
            } else if msg.isToolResult {
                resultCount += 1
                let id = msg.toolCallId ?? msg.id
                let old = calls[id] ?? ToolInvocationSummary(id: id, toolName: msg.toolName ?? "tool", argumentsPreview: "", arguments: "", resultSummary: "", hasDetail: false, isError: false, imagePreviews: [], videoPreviews: [])
                var previews = old.imagePreviews
                for preview in msg.imagePreviews where !previews.contains(where: { $0.source == preview.source }) {
                    previews.append(preview)
                }
                var videoPreviews = old.videoPreviews
                for preview in msg.videoPreviews where !videoPreviews.contains(where: { $0.source == preview.source }) {
                    videoPreviews.append(preview)
                }
                var documentPreviews = old.documentPreviews
                for preview in msg.documentPreviews where !documentPreviews.contains(where: { $0.source == preview.source }) {
                    documentPreviews.append(preview)
                }
                calls[id] = ToolInvocationSummary(id: id, toolName: old.toolName, argumentsPreview: old.argumentsPreview, arguments: old.arguments, resultSummary: compactToolSummary(msg.summary ?? ""), hasDetail: msg.hasDetail, isError: false, imagePreviews: previews, videoPreviews: videoPreviews, documentPreviews: documentPreviews)
                if !order.contains(id) { order.append(id) }
            }
        }
        // A turn may contain intermediate assistant projections around tool
        // work. Only the final non-empty assistant projection belongs in the
        // main transcript; the rest is process detail, loaded separately.
        let finalResult = results.last.map { [$0] } ?? []
        return Turn(index: index, userMessage: user, resultMessages: finalResult, toolSummaries: order.compactMap { calls[$0] }, fileToolCalls: fileCalls, toolResultCount: resultCount, hasResponded: !messages.isEmpty, isLast: isLast, isAnchorless: isAnchorless)
    }
    for msg in messages {
        if msg.isUser {
            if let u = curUser { turns.append(makeTurn(index: turns.count, user: u, messages: curSub, isLast: false)) }
            curUser = msg; curSub = []
        } else { curSub.append(msg) }
    }
    if let u = curUser { turns.append(makeTurn(index: turns.count, user: u, messages: curSub, isLast: false)) }
    if turns.isEmpty, !messages.isEmpty {
        // The window starts mid-turn and has no user message to anchor it — the
        // server answered with a bounded tail page for a very long session.
        // Render everything under a synthetic anchor instead of returning zero
        // turns, which would leave the conversation area blank.
        let anchor = MothxMessage(
            id: "window-anchor-\(messages.first?.id ?? "start")",
            seq: nil, role: "user", content: "",
            toolCallId: nil, toolName: nil, arguments: "",
            plan: nil, summary: nil, hasDetail: false, createdAt: nil
        )
        turns.append(makeTurn(index: 0, user: anchor, messages: messages, isLast: false, isAnchorless: true))
    }
    if !turns.isEmpty {
        let last = turns[turns.count - 1]
        turns[turns.count - 1] = Turn(index: last.index, userMessage: last.userMessage, resultMessages: last.resultMessages, toolSummaries: last.toolSummaries, fileToolCalls: last.fileToolCalls, toolResultCount: last.toolResultCount, hasResponded: last.hasResponded, isLast: true, isAnchorless: last.isAnchorless)
    }
    return turns
}

private nonisolated func compactToolSummary(_ text: String) -> String {
    let compact = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    return compact.count > 140 ? String(compact.prefix(140)) + "…" : compact
}

/// A small wrapping layout for compact process/tool chips.
///
/// SwiftUI's HStack keeps all children on one row and allows them to be
/// proposed less width than they need. That is a poor fit for the process
/// summary, where chips should stay readable and simply continue on another
/// line when the conversation column becomes narrow.
private struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = proposal.width ?? .greatestFiniteMagnitude
        let result = measure(subviews: subviews, maxWidth: availableWidth)
        return CGSize(
            width: proposal.width ?? result.width,
            height: result.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let placements = layout(subviews: subviews, maxWidth: bounds.width)
        for placement in placements {
            subviews[placement.index].place(
                at: CGPoint(x: bounds.minX + placement.x, y: bounds.minY + placement.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private func measure(subviews: Subviews, maxWidth: CGFloat) -> (width: CGFloat, height: CGFloat) {
        guard !subviews.isEmpty else { return (0, 0) }
        let placements = layout(subviews: subviews, maxWidth: maxWidth)
        let width = placements.map { $0.x + $0.size.width }.max() ?? 0
        let height = placements.map { $0.y + $0.size.height }.max() ?? 0
        return (width, height)
    }

    private func layout(subviews: Subviews, maxWidth: CGFloat) -> [Placement] {
        var placements: [Placement] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        let finiteWidth = maxWidth.isFinite

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let wouldOverflow = finiteWidth && x > 0 && x + size.width > maxWidth
            if wouldOverflow {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }

            placements.append(Placement(index: index, x: x, y: y, size: size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return placements
    }

    private struct Placement {
        let index: Int
        let x: CGFloat
        let y: CGFloat
        let size: CGSize
    }
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
    var onPreviewImage: ((MothxImagePreview) -> Void)? = nil
    var onPreviewVideo: ((MothxVideoPreview) -> Void)? = nil
    var onPreviewDocument: ((MothxDocumentPreview) -> Void)? = nil

    /// Explicit message forks are accepted only at the final assistant text
    /// entry of a completed turn. This mirrors mothx's `fork_unavailable`
    /// validation and avoids offering an action that the API must reject.
    private var forkableAssistantMessage: MothxMessage? {
        guard !isRunActive,
              !turn.isAnchorless,
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

    /// Resolves the Run that owns this turn's artifacts. A live final turn
    /// must use the current Run; a historical turn must use the Run mapped to
    /// its own user message. Do not fall back to a session-level latest Run.
    private var turnRunID: String? {
        if turn.isLast, isCurrentRunSession, let currentRunID = mothx.currentRunID {
            return currentRunID
        }
        return historicalRunID
    }

    /// Locally published image files found in this turn's tool outputs or
    /// reply text (`publish_artifact <path>`), resolved against the session
    /// working directory. Shown as a card after the final answer so the user
    /// can click through to the right-sidebar preview.
    /// Locally generated or downloaded video files found in this turn. They
    /// are shown after the final answer as a file card and open in the same
    /// sliding right-sidebar preview used by generated images.
    private var turnPublishArtifactVideos: [MothxVideoPreview] {
        guard turnRunID != nil else { return [] }
        let workDir = mothx.workDir(for: sessionID)
        let directPreviews = turn.resultMessages.flatMap(\.videoPreviews)
            + turn.toolSummaries.flatMap(\.videoPreviews)
        let texts = turn.resultMessages.map(\.content)
            + turn.toolSummaries.map(\.arguments)
            + turn.toolSummaries.map(\.resultSummary)
        var seen = Set<String>()
        var result: [MothxVideoPreview] = []
        for preview in directPreviews where seen.insert(preview.source).inserted {
            result.append(preview)
        }
        for preview in texts.flatMap({ MothxVideoPreview.previews(from: $0, workDirectory: workDir) }) {
            if seen.insert(preview.source).inserted { result.append(preview) }
        }
        return result
    }

    private var turnPublishArtifactImages: [MothxImagePreview] {
        guard turnRunID != nil else { return [] }
        let workDir = mothx.workDir(for: sessionID)
        let directPreviews = turn.toolSummaries.flatMap(\.imagePreviews)
        let texts = turn.resultMessages.map(\.content)
            + turn.toolSummaries.map(\.arguments)
            + turn.toolSummaries.map(\.resultSummary)
        var seen = Set<String>()
        var result: [MothxImagePreview] = []
        for preview in directPreviews where seen.insert(preview.source).inserted {
            result.append(preview)
        }
        for preview in texts.flatMap({ MothxImagePreview.publishArtifactPreviews(from: $0, workDirectory: workDir) }) {
            if seen.insert(preview.source).inserted { result.append(preview) }
        }
        return result
    }

    private var turnPublishArtifactDocuments: [MothxDocumentPreview] {
        guard turnRunID != nil else { return [] }
        let workDir = mothx.workDir(for: sessionID)
        let directPreviews = turn.resultMessages.flatMap(\.documentPreviews)
            + turn.toolSummaries.flatMap(\.documentPreviews)
        let texts = turn.resultMessages.map(\.content)
            + turn.toolSummaries.map(\.arguments)
            + turn.toolSummaries.map(\.resultSummary)
        var seen = Set<String>()
        var result: [MothxDocumentPreview] = []
        for preview in directPreviews where seen.insert(preview.source).inserted {
            result.append(preview)
        }
        for preview in texts.flatMap({ MothxDocumentPreview.publishArtifactPreviews(from: $0, workDirectory: workDir) }) {
            if seen.insert(preview.source).inserted { result.append(preview) }
        }
        return result
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
            // An anchorless turn (a mid-turn server window) has no user message
            // to title the accordion row with, so render its content directly.
            if !turn.isAnchorless {
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
            }

            if isExpanded || turn.isAnchorless {
                if isContentReady {
                    VStack(alignment: .leading, spacing: 10) {
                        if !turn.isAnchorless {
                            MessageBubble(
                                message: turn.userMessage,
                                isCurrentRunning: false,
                                onFork: forkAction,
                                isForking: forkingMessageID == forkableAssistantMessage?.id,
                                onPreviewImage: onPreviewImage
                            )
                        }
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
                    isCurrentRunning: isTurnRunActive && mothx.currentRunningMessageID == message.id,
                    onPreviewImage: onPreviewImage,
                    onPreviewDocument: onPreviewDocument
                )
            }
            if !isTurnRunActive, let turnChanges, !turnChanges.files.isEmpty {
                ChangeSummaryCard(
                    changes: turnChanges,
                    onReview: { onReviewChanges?(turnChanges) },
                    onPreview: { onReviewChanges?(turnChanges) }
                )
            }
            let artifactImages = turnPublishArtifactImages
            if let runID = turnRunID, !artifactImages.isEmpty {
                PublishArtifactCard(images: artifactImages, runID: runID) { image in
                    onPreviewImage?(image)
                }
                .padding(.top, 2)
            }
            let artifactVideos = turnPublishArtifactVideos
            if let runID = turnRunID, !artifactVideos.isEmpty {
                PublishArtifactVideoCard(videos: artifactVideos, runID: runID) { video in
                    onPreviewVideo?(video)
                }
                .padding(.top, 2)
            }
            let artifactDocuments = turnPublishArtifactDocuments
            if let runID = turnRunID, !artifactDocuments.isEmpty {
                PublishArtifactDocumentCard(documents: artifactDocuments, runID: runID) { document in
                    onPreviewDocument?(document)
                }
                .padding(.top, 2)
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
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 18)

                    VStack(alignment: .leading, spacing: 4) {
                        // Keep the title and summary at their intrinsic width.
                        // Without this, a narrow conversation column can make
                        // the Chinese title collapse into a vertical stack.
                        FlowLayout(horizontalSpacing: 6, verticalSpacing: 2) {
                            Text(languageStore.copy.process)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                            Text("· 调用 \(turn.toolSummaries.count) · 结果 \(turn.toolResultCount)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // HStack does not wrap its children, so the tool chips
                        // used to compress each other (and the title) as the
                        // conversation narrowed. FlowLayout keeps each chip
                        // at its natural size and moves it to the next line.
                        FlowLayout(horizontalSpacing: 5, verticalSpacing: 4) {
                            ForEach(turn.uniqueToolNames, id: \.self) { name in
                                HStack(spacing: 3) {
                                    Image(systemName: toolIcon(for: name))
                                        .font(.system(size: 8))
                                    Text(toolDisplayName(name, language: languageStore.language))
                                        .font(.system(size: 8))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.1))
                                .clipShape(Capsule())
                                .fixedSize()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: isProcessExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, height: 18)
                        .fixedSize()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
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
        .onAppear {
            if turn.toolSummaries.contains(where: { $0.toolName == "image_generation" }) {
                loadProcessPage(0)
            }
        }
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
