import Foundation

// MARK: - Content Block Types

struct MothxContentBlock: Identifiable, Hashable {
    let id = UUID()
    let type: String           // "text", "toolCall", "thinking", "image", "file"
    let text: String?
    let toolCall: MothxToolCallBlock?
    let thinking: String?
}

struct MothxToolCallBlock: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: String?
    let input: String?         // Display-friendly input summary
    let arguments: String      // Raw JSON arguments
}

// MARK: - Plan

struct MothxPlanStep: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let status: String         // "pending", "running", "done", "failed"
}

struct MothxPlan: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let steps: [MothxPlanStep]
    let note: String?
}

// MARK: - Message

struct MothxMessage: Identifiable, Hashable {
    let id: String
    let role: String           // "user", "assistant", "toolResult"
    let content: String        // Plain text content (or fallback)
    let contents: [MothxContentBlock]
    let toolCallId: String?    // Only for toolResult
    let toolName: String?      // Only for toolResult
    let isError: Bool          // Only for toolResult
    let createdAt: String?

    // Computed helpers
    var isUser: Bool { role == "user" }
    var isAssistant: Bool { role == "assistant" }
    var isToolResult: Bool { role == "toolResult" }

    /// Text blocks extracted from contents (for assistant messages)
    var textBlocks: [MothxContentBlock] {
        contents.filter { $0.type == "text" }
    }

    /// Tool call blocks extracted from contents
    var toolCallBlocks: [MothxContentBlock] {
        contents.filter { $0.type == "toolCall" }
    }

    /// Thinking blocks extracted from contents
    var thinkingBlocks: [MothxContentBlock] {
        contents.filter { $0.type == "thinking" }
    }

    /// True if this is a plan tool result
    var isPlanResult: Bool {
        isToolResult && toolName == "plan"
    }

    /// Parse plan from a plan tool result message content
    var plan: MothxPlan? {
        guard isPlanResult else { return nil }
        return MothxPlan.parse(from: content)
    }

    /// Whether this message has any structured content beyond plain text
    var hasStructuredContent: Bool {
        !toolCallBlocks.isEmpty || !thinkingBlocks.isEmpty
    }

    /// Combined text from all text blocks, or content fallback
    var displayText: String {
        if !content.isEmpty && contents.isEmpty { return content }
        let text = textBlocks.compactMap(\.text).joined()
        return text.isEmpty ? content : text
    }
}

// MARK: - Plan Parsing

extension MothxPlan {
    /// Parse plan from plan tool result text:
    ///   Plan: Title
    ///   - [status] Step title
    ///   Note: Note text
    static func parse(from text: String) -> MothxPlan? {
        let lines = text.components(separatedBy: .newlines)
        var title = ""
        var steps: [MothxPlanStep] = []
        var note: String? = nil

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("Plan:") || trimmed.hasPrefix("Plan updated:") {
                title = trimmed.replacingOccurrences(of: "Plan:", with: "")
                    .replacingOccurrences(of: "Plan updated:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Note:") {
                note = trimmed.replacingOccurrences(of: "Note:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("- [") {
                // Extract status and title from "- [pending] Step title"
                guard let statusEnd = trimmed.range(of: "] ") else { continue }
                let statusPart = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<statusEnd.lowerBound]
                let stepTitle = String(trimmed[statusEnd.upperBound...]).trimmingCharacters(in: .whitespaces)
                let status = String(statusPart).lowercased()
                guard !stepTitle.isEmpty,
                      ["pending", "running", "done", "failed"].contains(status) else { continue }
                steps.append(MothxPlanStep(title: stepTitle, status: status))
            }
        }

        guard !steps.isEmpty else { return nil }
        return MothxPlan(title: title, steps: steps, note: note)
    }
}