import SwiftUI

/// Map tool name to SF Symbol icon.
func toolIcon(for toolName: String) -> String {
    switch toolName.lowercased() {
    // File operations
    case "read", "cat":           return "doc.text.magnifyingglass"
    case "write", "edit":         return "pencil"
    case "insert":                return "text.insert"
    case "find":                  return "magnifyingglass"
    case "grep":                  return "text.magnifyingglass"
    case "ls", "list":            return "list.bullet"
    case "mv", "move":            return "arrow.right.doc.on.clipboard"
    case "cp", "copy":            return "doc.on.doc"
    case "rm", "delete":          return "trash"

    // Shell / execution
    case "bash", "shell", "exec": return "terminal"
    case "run", "execute":        return "play.fill"
    case "kill", "killtool":      return "stop.circle"

    // Browser / web
    case "browser":               return "safari"
    case "web_search", "websearch": return "magnifyingglass.circle"
    case "fetch", "curl":         return "arrow.down.circle"

    // Planning
    case "plan":                  return "checklist"
    case "task", "todo":          return "checklist.checked"

    // Agent / multi-agent
    case "delegate":              return "person.2"
    case "multi_agent", "multi-agent": return "person.3.sequence"
    case "workflow":              return "flowchart"

    // Skills
    case "skill", "skill_ref":    return "sparkles"

    // Image
    case "image_generation", "image": return "photo"

    // Question
    case "question":              return "questionmark.bubble"

    // A2A
    case "a2a_dispatch":          return "arrow.triangle.swap"

    // Default
    default:                      return "wrench"
    }
}

/// Human-readable tool name for display
func toolDisplayName(_ name: String) -> String {
    switch name.lowercased() {
    case "read":                return "读取文件"
    case "write":               return "写入文件"
    case "edit":                return "编辑文件"
    case "insert":              return "插入内容"
    case "find":                return "查找文件"
    case "grep":                return "搜索内容"
    case "ls":                  return "列出文件"
    case "bash", "shell":       return "Shell"
    case "browser":             return "浏览器"
    case "web_search":          return "网页搜索"
    case "plan":                return "任务计划"
    case "delegate":            return "委托"
    case "multi_agent":         return "多 Agent"
    case "workflow":            return "工作流"
    case "skill_ref":           return "技能引用"
    case "image_generation":    return "图片生成"
    case "question":            return "提问"
    default:                    return name
    }
}

/// Extract a human-readable summary from a tool call's arguments JSON.
/// Returns the most relevant field value for the given tool name.
func toolArgSummary(toolName: String, arguments: String) -> String? {
    guard !arguments.isEmpty else { return nil }

    let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "{}", trimmed != "[]" else { return nil }

    // Try to parse as JSON
    guard let data = arguments.data(using: .utf8) else { return nil }
    let parsed = try? JSONSerialization.jsonObject(with: data)

    // Handle dictionary
    if let obj = parsed as? [String: Any] {
        return extractValue(from: obj, toolName: toolName)
    }

    // Handle array
    if let arr = parsed as? [Any], let first = arr.first as? [String: Any] {
        return extractValue(from: first, toolName: toolName)
    }

    // If it's just a plain string that's not JSON, use it directly
    if parsed == nil, !trimmed.hasPrefix("{") {
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    }

    return nil
}

private func extractValue(from obj: [String: Any], toolName: String) -> String? {
    let name = toolName.lowercased()

    let keys: [String]
    switch name {
    case "read", "cat":                                       keys = ["path", "file", "filePath", "file_path"]
    case "write", "edit":                                     keys = ["path", "file", "filePath", "file_path", "content", "new_str"]
    case "bash", "shell", "exec", "run":                       keys = ["command", "cmd", "script", "commands"]
    case "grep":                                              keys = ["pattern", "path", "file"]
    case "ls", "list":                                        keys = ["path", "dir", "directory"]
    case "find":                                              keys = ["pattern", "path", "dir"]
    case "browser", "web_search", "websearch", "fetch":       keys = ["url", "query", "search"]
    case "insert":                                            keys = ["path", "file", "content", "new_str"]
    case "mv", "move", "cp", "copy":                           keys = ["source", "src", "from", "destination", "dest", "to"]
    case "rm", "delete":                                      keys = ["path", "file"]
    case "kill", "killtool":                                  keys = ["pid", "name", "signal"]
    case "delegate":                                          keys = ["task", "prompt", "agent"]
    case "question":                                          keys = ["question", "text"]
    case "plan":                                              keys = ["title", "steps"]
    default:                                                  keys = ["path", "file", "command", "query", "url", "name", "text", "content"]
    }

    for key in keys {
        if let value = obj[key] as? String, !value.isEmpty {
            return value.count > 60 ? String(value.prefix(60)) + "…" : value
        }
        if let value = obj[key] as? [String], let first = value.first {
            return first.count > 60 ? String(first.prefix(60)) + "…" : first
        }
    }

    // Fallback: first non-empty string value
    for (_, value) in obj {
        if let str = value as? String, !str.isEmpty {
            return str.count > 60 ? String(str.prefix(60)) + "…" : str
        }
    }

    return nil
}