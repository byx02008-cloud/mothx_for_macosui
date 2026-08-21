import Foundation

// MARK: - Message

struct MothxMessage: Identifiable, Hashable {
    let id: String
    let seq: Int?
    let role: String           // "user", "assistant", "toolCall", "toolResult"
    let content: String        // Plain text content
    let toolCallId: String?    // toolCall & toolResult
    let toolName: String?      // toolCall & toolResult
    let arguments: String      // JSON string (toolCall)
    let plan: MothxPlan?       // structured plan projection (toolCall)
    let summary: String?       // toolResult summary (short)
    let hasDetail: Bool        // toolResult: whether full content is available via API
    let createdAt: String?

    var isUser: Bool { role == "user" }
    var isAssistant: Bool { role == "assistant" }
    var isToolCall: Bool { role == "toolCall" }
    var isToolResult: Bool { role == "toolResult" }
    var isPlan: Bool { isToolCall && toolName == "plan" }

    /// Display text: content for user/assistant, summary for toolResult, arg preview for toolCall
    var displayText: String {
        if isToolCall { return toolArgSummary(toolName: toolName ?? "", arguments: arguments) ?? arguments }
        if isToolResult { return summary ?? "" }
        return content
    }

    /// Extract argument value for display
    func argValue(for key: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = obj[key] as? String, !value.isEmpty else { return nil }
        return value.count > 60 ? String(value.prefix(60)) + "…" : value
    }
}

// MARK: - Plan

struct MothxPlanStep: Identifiable, Hashable {
    let id: String
    let title: String
    let status: String
}

struct MothxPlan: Identifiable, Hashable {
    let id: String
    let title: String
    let steps: [MothxPlanStep]
    let note: String?

    var isComplete: Bool { !steps.isEmpty && steps.allSatisfy { $0.status == "done" } }
    var hasFailedStep: Bool { steps.contains { $0.status == "failed" } }
}

extension MothxPlan {
    static func parse(from object: Any) -> MothxPlan? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(from: text)
    }

    static func parse(from text: String) -> MothxPlan? {
        // Plan tool arguments are persisted as structured JSON. Keep the
        // line-based parser below for older transcript projections.
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rawSteps = object["steps"] as? [[String: Any]], !rawSteps.isEmpty {
            let title = (object["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let note = (object["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let steps = rawSteps.enumerated().compactMap { index, raw -> MothxPlanStep? in
                guard let stepTitle = raw["title"] as? String,
                      let rawStatus = raw["status"] as? String else { return nil }
                let status = rawStatus.lowercased()
                guard !stepTitle.isEmpty, ["pending", "running", "done", "failed"].contains(status) else { return nil }
                return MothxPlanStep(id: "\(index)-\(stepTitle)", title: stepTitle, status: status)
            }
            guard !steps.isEmpty else { return nil }
            return MothxPlan(id: title + "|" + steps.map(\.title).joined(separator: "|"), title: title, steps: steps, note: note?.isEmpty == true ? nil : note)
        }

        let lines = text.components(separatedBy: .newlines)
        var title = ""
        var steps: [MothxPlanStep] = []
        var note: String? = nil
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("Plan:") || trimmed.hasPrefix("Plan updated:") {
                title = trimmed.replacingOccurrences(of: "Plan:", with: "")
                    .replacingOccurrences(of: "Plan updated:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Note:") {
                note = trimmed.replacingOccurrences(of: "Note:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("- [") {
                guard let statusEnd = trimmed.range(of: "] ") else { continue }
                let statusPart = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<statusEnd.lowerBound]
                let stepTitle = String(trimmed[statusEnd.upperBound...]).trimmingCharacters(in: .whitespaces)
                let status = String(statusPart).lowercased()
                guard !stepTitle.isEmpty, ["pending","running","done","failed"].contains(status) else { continue }
                steps.append(MothxPlanStep(id: "\(steps.count)-\(stepTitle)", title: stepTitle, status: status))
            }
        }
        guard !steps.isEmpty else { return nil }
        return MothxPlan(id: title + "|" + steps.map(\.title).joined(separator: "|"), title: title, steps: steps, note: note)
    }
}
