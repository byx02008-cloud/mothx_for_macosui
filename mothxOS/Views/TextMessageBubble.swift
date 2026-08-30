import Foundation
import SwiftUI

struct TextMessageBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: MothxMessage
    let isCurrentRunning: Bool
    /// When non-nil, shows the "fork session" action on hover. The callback
    /// carries the completed assistant reply used as the API boundary.
    var onFork: (() -> Void)? = nil
    var isForking = false
    var onPreviewImage: ((MothxImagePreview) -> Void)? = nil

    private var isUser: Bool { message.isUser }

    @State private var displayedCharCount = 0
    @State private var typewriterTimer: Timer?
    @State private var blinkOpacity: Double = 1.0
    // Tracks the latest known text while running; the Timer closure reads
    // this @State (stable storage) instead of `message` (a frozen value-type
    // snapshot from whenever the closure was created), so newly polled
    // content keeps getting typed out instead of appearing in one jump.
    @State private var typingTarget: String = ""
    @State private var isHovered = false
    @State private var didCopy = false

    private var displayText: String {
        if isCurrentRunning { return String(typingTarget.prefix(displayedCharCount)) }
        return message.displayText
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 70) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !isUser && !isCurrentRunning && !displayText.isEmpty {
                            MarkdownMessageText(markdown: displayText)
                        } else {
                            Text(displayText.isEmpty ? (isUser ? "…" : "Thinking…") : displayText)
                                .textSelection(.enabled)
                                .lineSpacing(4)
                                .frame(maxWidth: 560, alignment: .leading)
                        }
                        if !message.imagePreviews.isEmpty {
                            ImagePreviewStrip(images: message.imagePreviews, onSelect: onPreviewImage ?? { _ in })
                        }
                        if isTyping {
                            Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 8, height: 16)
                                .opacity(blinkOpacity).padding(.leading, 2).padding(.top, -16)
                        }
                    }
                }
                .padding(14)
                .background(isUser ? userBackground : assistantBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                if isUser || onFork != nil {
                    messageMetadata
                        .frame(height: 22, alignment: isUser ? .topTrailing : .topLeading)
                }
            }
            if !isUser { Spacer(minLength: 70) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .onHover { isHovered = $0 }
        .onAppear {
            if isCurrentRunning && !message.displayText.isEmpty {
                typingTarget = message.displayText
                startTypewriter()
            } else {
                displayedCharCount = message.displayText.count
            }
        }
        .onChange(of: message.displayText) { _, newText in
            if isCurrentRunning {
                // New content arrived from polling — extend the typing
                // target and keep (or restart) the timer so it keeps
                // catching up smoothly instead of stalling.
                typingTarget = newText
                if typewriterTimer == nil { startTypewriter(resetProgress: false) }
            } else {
                typewriterTimer?.invalidate(); typewriterTimer = nil
                displayedCharCount = newText.count
            }
        }
        .onChange(of: isCurrentRunning) { _, running in
            if !running {
                // Run finished (or its grace period ended) — stop and show
                // whatever text remains in full rather than freezing mid-type.
                typewriterTimer?.invalidate(); typewriterTimer = nil
                displayedCharCount = message.displayText.count
            }
        }
        .onDisappear { typewriterTimer?.invalidate(); typewriterTimer = nil }
    }

    private var isTyping: Bool { isCurrentRunning && displayedCharCount < typingTarget.count }

    private func startTypewriter(resetProgress: Bool = true) {
        if resetProgress { displayedCharCount = 0 }
        typewriterTimer?.invalidate()
        typewriterTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            if displayedCharCount < typingTarget.count {
                displayedCharCount += 1
            }
            // Don't invalidate on catching up — more text may still arrive
            // from the next poll while the run is in progress; onDisappear
            // and the isCurrentRunning onChange handle teardown instead.
        }
        withAnimation(.easeInOut(duration: 0.6).repeatForever()) { blinkOpacity = 0.0 }
    }

    private var messageMetadata: some View {
        HStack(spacing: 10) {
            if isHovered {
                if isUser {
                    Button {
                        copyQuestion()
                    } label: {
                        HStack(spacing: 4) {
                            Text(didCopy ? "已复制" : "复制主题")
                            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(didCopy ? "已复制 / Copied" : "复制主题 / Copy topic")
                }

                if let onFork {
                    Button {
                        onFork()
                    } label: {
                        HStack(spacing: 4) {
                            Text("会话分叉")
                            Image(systemName: "arrow.triangle.branch")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isForking)
                    .help("从这里开始创建新的会话 / Start a new session from here")
                }
            }
        }
        .opacity(isHovered ? 1 : 0)
    }

    private func copyQuestion() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.displayText, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            didCopy = false
        }
    }

    private var assistantBackground: Color { colorScheme == .light ? .white : .codexCard }
    private var userBackground: Color { colorScheme == .light ? Color(red: 0.94, green: 0.94, blue: 0.95) : Color.orange.opacity(0.18) }
}

/// Renders a completed assistant response as Markdown while keeping a plain-text
/// fallback for malformed or unsupported Markdown input. Shared by the session
/// conversation and the team task final answer.
struct MarkdownMessageText: View {
    let markdown: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var renderedSegments: [MarkdownSegment] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(renderedSegments.isEmpty ? [MarkdownSegment(content: markdown, isCodeBlock: false)] : renderedSegments) { segment in
                if segment.isCodeBlock {
                    Group {
                        if let attributedString = segment.attributedString {
                            Text(attributedString)
                        } else {
                            Text(segment.rawContent)
                        }
                    }
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(codeBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else if !segment.content.isEmpty {
                    if let attributedString = segment.attributedString {
                        Text(attributedString).lineSpacing(4)
                    } else {
                        Text(segment.rawContent).lineSpacing(4)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: 560, alignment: .leading)
        .onAppear { updateRenderedSegments() }
        .onChange(of: markdown) { _, _ in updateRenderedSegments() }
    }

    private var codeBackground: Color {
        colorScheme == .light ? Color.black.opacity(0.06) : Color.white.opacity(0.09)
    }

    private var segments: [MarkdownSegment] {
        let pattern = "```[\\s\\S]*?```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [MarkdownSegment(content: markdown, isCodeBlock: false)]
        }

        let matches = regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown))
        var result: [MarkdownSegment] = []
        var cursor = markdown.startIndex
        for match in matches {
            guard let range = Range(match.range, in: markdown) else { continue }
            if cursor < range.lowerBound {
                result.append(MarkdownSegment(content: String(markdown[cursor..<range.lowerBound]), isCodeBlock: false))
            }
            result.append(MarkdownSegment(
                content: codeContent(from: String(markdown[range])),
                isCodeBlock: true,
                rawContent: String(markdown[range])
            ))
            cursor = range.upperBound
        }
        if cursor < markdown.endIndex {
            result.append(MarkdownSegment(content: String(markdown[cursor...]), isCodeBlock: false))
        }
        return result.isEmpty ? [MarkdownSegment(content: markdown, isCodeBlock: false)] : result
    }

    private func updateRenderedSegments() {
        guard MarkdownSafety.isSafeToParse(markdown) else {
            renderedSegments = [MarkdownSegment(content: markdown, isCodeBlock: false)]
            return
        }
        renderedSegments = segments.map { segment in
            MarkdownSegment(
                content: segment.content,
                isCodeBlock: segment.isCodeBlock,
                attributedString: attributedString(for: segment.content),
                rawContent: segment.rawContent
            )
        }
    }

    private func codeContent(from fencedBlock: String) -> String {
        var lines = fencedBlock.components(separatedBy: "\n")
        if !lines.isEmpty { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// AttributedString.MarkdownParsingOptions(interpretedSyntax: .full) collapses
    /// every newline in the source — soft breaks become spaces and paragraph breaks
    /// are dropped entirely — so a multi-line response would render as one unbroken
    /// run of text. Parse line-by-line instead (inline formatting such as **bold**,
    /// `code`, and links is preserved) and re-insert the breaks the author typed.
    private func attributedString(for markdown: String) -> AttributedString? {
        guard MarkdownSafety.isSafeToParse(markdown) else { return nil }
        let normalized = normalizedMarkdown(for: markdown)
        let lines = normalized.components(separatedBy: "\n")
        var result = AttributedString()
        var needParagraphBreak = false
        for rawLine in lines {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                needParagraphBreak = true
                continue
            }
            if !result.characters.isEmpty {
                result += AttributedString(needParagraphBreak ? "\n\n" : "\n")
            }
            needParagraphBreak = false
            guard let parsedLine = parsedInlineLine(trimmed) else { return nil }
            result += parsedLine
        }
        guard !markdown.isEmpty || !result.characters.isEmpty else { return nil }
        return result.characters.isEmpty && !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : result
    }

    /// Parse one line with full inline syntax. Block markers such as `- `, `* `,
    /// or `1. ` are stripped by the parser when the block is a single line, so
    /// restore them to keep lists readable.
    private func parsedInlineLine(_ line: String) -> AttributedString? {
        let marker = listMarkerPrefix(of: line)
        let content = marker.map { String(line.dropFirst($0.count)) } ?? line
        if let parsed = try? AttributedString(
            markdown: content,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) {
            if let marker {
                var result = AttributedString(marker)
                result += parsed
                return result
            }
            return parsed
        }
        // A malformed fragment falls back to the original segment. Do not
        // keep partially parsed output because losing one line is worse than
        // showing the source Markdown.
        return nil
    }

    private func listMarkerPrefix(of line: String) -> String? {
        let patterns = [#"^([-*+])\s+"#, #"^(\d+[.)])\s+"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { continue }
            return String(line[range]) + " "
        }
        return nil
    }

    /// Some model responses put whitespace inside emphasis delimiters, for
    /// example `** text **`. Normalize those delimiters before parsing while
    /// leaving code spans and fenced code blocks byte-for-byte unchanged.
    private func normalizedMarkdown(for markdown: String) -> String {
        let protectedCodePattern = "```[\\s\\S]*?```|`[^`\\n]*`"
        guard let protectedCodeRegex = try? NSRegularExpression(pattern: protectedCodePattern) else {
            return normalizeEmphasis(in: markdown)
        }

        let matches = protectedCodeRegex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown))
        var output = ""
        var cursor = markdown.startIndex
        for match in matches {
            guard let range = Range(match.range, in: markdown) else { continue }
            output += normalizeEmphasis(in: String(markdown[cursor..<range.lowerBound]))
            output += String(markdown[range])
            cursor = range.upperBound
        }
        output += normalizeEmphasis(in: String(markdown[cursor...]))
        return output
    }

    private func normalizeEmphasis(in text: String) -> String {
        let patternsAndTemplates = [
            (#"\*\*[\t\p{Zs}]+([^*\n]*?[^\s\p{Zs}])[\t\p{Zs}]+\*\*"#, "**$1**"),
            (#"__[\t\p{Zs}]+([^_\n]*?[^\s\p{Zs}])[\t\p{Zs}]+__"#, "__$1__"),
            (#"(?<!\*)\*[\t\p{Zs}]+([^*\n]*?[^\s\p{Zs}])[\t\p{Zs}]+\*(?!\*)"#, "*$1*"),
            (#"(?<![_A-Za-z0-9])_[\t\p{Zs}]+([^_\n]*?[^\s\p{Zs}])[\t\p{Zs}]+_(?![_A-Za-z0-9])"#, "_$1_")
        ]

        var normalized = text
        for (pattern, template) in patternsAndTemplates {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(normalized.startIndex..., in: normalized)
            normalized = regex.stringByReplacingMatches(
                in: normalized,
                range: range,
                withTemplate: template
            )
        }
        return normalized
    }
}

private struct MarkdownSegment: Identifiable {
    let id = UUID()
    let content: String
    let isCodeBlock: Bool
    let attributedString: AttributedString?
    let rawContent: String

    init(content: String, isCodeBlock: Bool, attributedString: AttributedString? = nil, rawContent: String? = nil) {
        self.content = content
        self.isCodeBlock = isCodeBlock
        self.attributedString = attributedString
        self.rawContent = rawContent ?? content
    }
}

private enum MarkdownSafety {
    // Keep pathological transcripts out of Foundation's Markdown parser. The
    // original source is still rendered as plain selectable text below.
    static let maxDocumentCharacters = 20_000
    static let maxLineCharacters = 4_000
    static let maxLineCount = 800
    static let maxFenceCount = 80

    static func isSafeToParse(_ text: String) -> Bool {
        guard text.count <= maxDocumentCharacters else { return false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count <= maxLineCount else { return false }
        guard lines.allSatisfy({ $0.count <= maxLineCharacters }) else { return false }
        let fenceCount = text.components(separatedBy: "```").count - 1
        return fenceCount <= maxFenceCount
    }
}
