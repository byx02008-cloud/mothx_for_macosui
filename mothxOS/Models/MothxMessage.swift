import Foundation

struct MothxImagePreview: Identifiable, Hashable {
    let id: String
    let source: String
    let mediaType: String
    let name: String?

    var isDataURL: Bool { source.hasPrefix("data:") }

    /// Resolves a source string (absolute path, `file://` URL, or relative
    /// path) to an on-disk image URL when the file exists. Returns nil for
    /// data URLs, remote http(s) URLs, unresolvable paths, and missing files.
    static func resolvedFileURL(for source: String, workDirectory: String) -> URL? {
        if source.hasPrefix("data:") || source.hasPrefix("http://") || source.hasPrefix("https://") {
            return nil
        }
        var path = source
        if path.hasPrefix("file://"), let url = URL(string: path) {
            path = url.path
        }
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else if !workDirectory.isEmpty {
            url = URL(fileURLWithPath: workDirectory).appendingPathComponent(path)
        } else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Scans text for `publish_artifact <path>` references (the notation the
    /// agent uses when it publishes a locally generated file) and returns
    /// previews for the image files that resolve to an existing file under
    /// the given working directory.
    static func publishArtifactPreviews(from text: String, workDirectory: String) -> [MothxImagePreview] {
        let pattern = #"publish_artifact[\s:]+([^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var previews: [MothxImagePreview] = []
        var index = 0
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges > 1,
                  let rawRange = Range(match.range(at: 1), in: text) else { continue }
            var raw = String(text[rawRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip wrapping punctuation that may follow the path inside
            // JSON arguments or Markdown (quotes, brackets, commas).
            while let last = raw.last, ["\"", "'", ",", ")", "]", "}", "`"].contains(String(last)) {
                raw.removeLast()
            }
            guard !raw.isEmpty,
                  let url = resolvedFileURL(for: raw, workDirectory: workDirectory) else { continue }
            guard ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"].contains(url.pathExtension.lowercased()) else { continue }
            previews.append(MothxImagePreview(
                id: "artifact-\(index)-\(UUID().uuidString)",
                source: url.path,
                mediaType: "image/png",
                name: url.lastPathComponent
            ))
            index += 1
        }
        return previews
    }

    /// Extracts a locally published image from a structured
    /// `publish_artifact` tool call. Tool arguments are persisted separately
    /// from the tool name, so the JSON path cannot be found by the textual
    /// `publish_artifact <path>` scanner above.
    static func publishArtifactPreviews(toolName: String?, arguments: String, workDirectory: String) -> [MothxImagePreview] {
        guard toolName?.lowercased() == "publish_artifact",
              let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["path"] as? String,
              !path.isEmpty,
              let url = resolvedFileURL(for: path, workDirectory: workDirectory),
              ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"].contains(url.pathExtension.lowercased()) else {
            return []
        }
        let filename = object["filename"] as? String
        return [MothxImagePreview(
            id: "artifact-argument-\(UUID().uuidString)",
            source: url.path,
            mediaType: "image/png",
            name: filename?.isEmpty == false ? filename : url.lastPathComponent
        )]
    }
}

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
    let imagePreviews: [MothxImagePreview]

    init(id: String, seq: Int?, role: String, content: String, toolCallId: String?, toolName: String?, arguments: String, plan: MothxPlan?, summary: String?, hasDetail: Bool, createdAt: String?, imagePreviews: [MothxImagePreview] = []) {
        self.id = id
        self.seq = seq
        self.role = role
        self.content = content
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.arguments = arguments
        self.plan = plan
        self.summary = summary
        self.hasDetail = hasDetail
        self.createdAt = createdAt
        self.imagePreviews = imagePreviews
    }

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
