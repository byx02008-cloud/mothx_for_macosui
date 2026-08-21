import Foundation
import SwiftUI

struct TextMessageBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: MothxMessage
    let isCurrentRunning: Bool

    private var isUser: Bool { message.isUser }

    @State private var displayedCharCount = 0
    @State private var typewriterTimer: Timer?
    @State private var blinkOpacity: Double = 1.0
    // Tracks the latest known text while running; the Timer closure reads
    // this @State (stable storage) instead of `message` (a frozen value-type
    // snapshot from whenever the closure was created), so newly polled
    // content keeps getting typed out instead of appearing in one jump.
    @State private var typingTarget: String = ""

    private var displayText: String {
        if isCurrentRunning { return String(typingTarget.prefix(displayedCharCount)) }
        return message.displayText
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 70) }
            HStack(alignment: .top, spacing: 10) {
                if !isUser { Image("MothxLogo").resizable().scaledToFit().frame(width: 18, height: 18) }
                VStack(alignment: .leading, spacing: 0) {
                    if !isUser && !isCurrentRunning && !displayText.isEmpty {
                        MarkdownMessageText(markdown: displayText)
                    } else {
                        Text(displayText.isEmpty ? (isUser ? "…" : "Thinking…") : displayText)
                            .textSelection(.enabled)
                            .frame(maxWidth: 560, alignment: .leading)
                    }
                    if isTyping {
                        Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 8, height: 16)
                            .opacity(blinkOpacity).padding(.leading, 2).padding(.top, -16)
                    }
                }
                if isUser { Image(systemName: "person.circle").foregroundStyle(Color.secondary) }
            }
            .padding(14)
            .background(isUser ? userBackground : assistantBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if !isUser { Spacer(minLength: 70) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
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

    private var assistantBackground: Color { colorScheme == .light ? .white : .codexCard }
    private var userBackground: Color { colorScheme == .light ? Color(red: 0.94, green: 0.94, blue: 0.95) : Color.orange.opacity(0.18) }
}

/// Renders a completed assistant response as Markdown while keeping a plain-text
/// fallback for malformed or unsupported Markdown input.
private struct MarkdownMessageText: View {
    let markdown: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(segments) { segment in
                if segment.isCodeBlock {
                    Text(segment.content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(codeBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else if !segment.content.isEmpty {
                    if let attributedString = attributedString(for: segment.content) {
                        Text(attributedString)
                    } else {
                        Text(segment.content)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: 560, alignment: .leading)
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
            result.append(MarkdownSegment(content: codeContent(from: String(markdown[range])), isCodeBlock: true))
            cursor = range.upperBound
        }
        if cursor < markdown.endIndex {
            result.append(MarkdownSegment(content: String(markdown[cursor...]), isCodeBlock: false))
        }
        return result.isEmpty ? [MarkdownSegment(content: markdown, isCodeBlock: false)] : result
    }

    private func codeContent(from fencedBlock: String) -> String {
        var lines = fencedBlock.components(separatedBy: "\n")
        if !lines.isEmpty { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private func attributedString(for markdown: String) -> AttributedString? {
        let normalized = normalizedMarkdown(for: markdown)
        if let parsed = try? AttributedString(
            markdown: normalized,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) {
            return parsed
        }

        // A malformed fragment should not make the entire historical message
        // fall back to raw Markdown. Parse each line independently so valid
        // formatting in the rest of the response is still rendered.
        let lines = normalized.components(separatedBy: "\n")
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            if let parsedLine = try? AttributedString(
                markdown: line,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
            ) {
                result += parsedLine
            } else {
                result += AttributedString(line)
            }
            if index < lines.count - 1 { result += AttributedString("\n") }
        }
        return result
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
}
