import Foundation

/// Where a skill was discovered from.
enum MothxSkillScope: String, Hashable {
    /// Installed in a global skills directory (e.g. ~/.skill, ~/.skills, ~/.agents/skills).
    case global
    /// Installed in the current project/working directory (e.g. <workDir>/.skill).
    case local
    /// Reported by the mothx server (SkillHub installed list) but not found on disk.
    case remote
}

struct MothxSkill: Identifiable, Hashable {
    let id: String
    let name: String
    let directory: String
    var scope: MothxSkillScope = .remote
}
// MARK: - SkillHub marketplace models

struct MothxSkillHubInstalledState: Codable, Hashable {
    let installed: Bool
    let scope: String
    let directory: String
    let market: String?
    let skillID: String?
    let name: String?
    let local: Bool
    let version: String?
    let active: Bool

    enum CodingKeys: String, CodingKey {
        case installed, scope, directory = "dir", market, skillID = "id", name, local, version, active
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        installed = try container.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? ""
        directory = try container.decodeIfPresent(String.self, forKey: .directory) ?? ""
        market = try container.decodeIfPresent(String.self, forKey: .market)
        skillID = try container.decodeIfPresent(String.self, forKey: .skillID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        local = try container.decodeIfPresent(Bool.self, forKey: .local) ?? false
        version = try container.decodeIfPresent(String.self, forKey: .version)
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
    }
}

struct MothxSkillHubSummary: Codable, Hashable {
    let market: String
    let id: String
    let slug: String
    let name: String
    let displayName: String
    let description: String
    let version: String
    let author: String
    let category: String
    let tags: [String]
    let iconURL: String
    let homepage: String
    let sourceURL: String
    let source: String
    let downloads: Int64
    let installs: Int64
    let stars: Int64
    let updatedAt: String
    let installed: MothxSkillHubInstalledState?

    /// Stable identity across marketplace pages.
    var key: String { "\(market)/\(id)" }
    var title: String { displayName.isEmpty ? name : displayName }

    enum CodingKeys: String, CodingKey {
        case market, id, slug, name, displayName, description, version, author, category, tags
        case iconURL = "iconUrl"
        case homepage, sourceURL = "sourceUrl", source, downloads, installs, stars, updatedAt, installed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        market = try container.decodeIfPresent(String.self, forKey: .market) ?? ""
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        slug = try container.decodeIfPresent(String.self, forKey: .slug) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        iconURL = try container.decodeIfPresent(String.self, forKey: .iconURL) ?? ""
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage) ?? ""
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        downloads = try container.decodeIfPresent(Int64.self, forKey: .downloads) ?? 0
        installs = try container.decodeIfPresent(Int64.self, forKey: .installs) ?? 0
        stars = try container.decodeIfPresent(Int64.self, forKey: .stars) ?? 0
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        installed = try container.decodeIfPresent(MothxSkillHubInstalledState.self, forKey: .installed)
    }
}

struct MothxSkillHubListResponse: Codable {
    let items: [MothxSkillHubSummary]
    let total: Int
    let page: Int
    let pageSize: Int

    enum CodingKeys: String, CodingKey { case items, total, page, pageSize }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([MothxSkillHubSummary].self, forKey: .items) ?? []
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
        page = try container.decodeIfPresent(Int.self, forKey: .page) ?? 1
        pageSize = try container.decodeIfPresent(Int.self, forKey: .pageSize) ?? max(items.count, 1)
    }
}

struct MothxSkillHubDownloadSource: Codable, Hashable {
    let url: String
    let kind: String
    let fallback: Bool

    enum CodingKeys: String, CodingKey {
        case url, kind, fallback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // SkillHub omits `fallback` for the primary download source.
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        fallback = try container.decodeIfPresent(Bool.self, forKey: .fallback) ?? false
    }
}

struct MothxSkillHubFile: Codable, Hashable {
    let path: String
    let sha256: String
    let size: Int64

    enum CodingKeys: String, CodingKey {
        case path, sha256, size
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
    }
}

/// JSON values used by SkillHub's security report and evaluation payloads.
/// They are intentionally kept lossless so the UI can show future server fields.
enum MothxSkillHubJSONValue: Codable, Hashable {
    case object([String: MothxSkillHubJSONValue])
    case array([MothxSkillHubJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode([String: MothxSkillHubJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([MothxSkillHubJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func prettyJSONString() -> String {
        guard let data = try? JSONEncoder.skillHubEncoder.encode(self),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    /// Converts structured SkillHub evaluation data into a readable Markdown
    /// document instead of exposing the raw JSON representation in the UI.
    func markdownDocument() -> String {
        var lines: [String] = []
        appendMarkdown(self, label: nil, level: 2, into: &lines)
        return lines.joined(separator: "\n\n")
    }

    private func appendMarkdown(
        _ value: MothxSkillHubJSONValue,
        label: String?,
        level: Int,
        into lines: inout [String]
    ) {
        switch value {
        case .object(let object):
            if let label {
                lines.append("\(String(repeating: "#", count: min(max(level, 2), 6))) \(humanizedKey(label))")
            }
            for key in object.keys.sorted() {
                guard let child = object[key] else { continue }
                if child.isScalar {
                    lines.append("- **\(humanizedKey(key))**: \(child.inlineMarkdownValue)")
                } else {
                    appendMarkdown(child, label: key, level: level + 1, into: &lines)
                }
            }
        case .array(let array):
            if let label {
                lines.append("\(String(repeating: "#", count: min(max(level, 2), 6))) \(humanizedKey(label))")
            }
            for item in array {
                if item.isScalar {
                    lines.append("- \(item.inlineMarkdownValue)")
                } else {
                    appendMarkdown(item, label: nil, level: level, into: &lines)
                }
            }
        case .string, .number, .bool, .null:
            if let label {
                lines.append("- **\(humanizedKey(label))**: \(inlineMarkdownValue)")
            } else {
                lines.append(inlineMarkdownValue)
            }
        }
    }

    private var isScalar: Bool {
        switch self {
        case .object, .array: return false
        case .string, .number, .bool, .null: return true
        }
    }

    private var inlineMarkdownValue: String {
        switch self {
        case .string(let value):
            return value.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        case .number(let value):
            return value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "—"
        case .object, .array:
            return ""
        }
    }

    private func humanizedKey(_ key: String) -> String {
        var result = ""
        for (index, character) in key.enumerated() {
            if index > 0, character.isUppercase { result.append(" ") }
            if character == "_" || character == "-" {
                result.append(" ")
            } else {
                result.append(character)
            }
        }
        return result.prefix(1).uppercased() + result.dropFirst()
    }
}

private extension JSONEncoder {
    static var skillHubEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

struct MothxSkillHubDetail: Codable {
    let summary: MothxSkillHubSummary
    let files: [MothxSkillHubFile]
    let downloadSources: [MothxSkillHubDownloadSource]
    let readme: String
    let securityReports: MothxSkillHubJSONValue?
    let evaluation: MothxSkillHubJSONValue?

    init(from decoder: Decoder) throws {
        summary = try MothxSkillHubSummary(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = try container.decodeIfPresent([MothxSkillHubFile].self, forKey: .files) ?? []
        downloadSources = try container.decodeIfPresent([MothxSkillHubDownloadSource].self, forKey: .downloadSources) ?? []
        readme = try container.decodeIfPresent(String.self, forKey: .readme) ?? ""
        securityReports = try container.decodeIfPresent(MothxSkillHubJSONValue.self, forKey: .securityReports)
        evaluation = try container.decodeIfPresent(MothxSkillHubJSONValue.self, forKey: .evaluation)
    }

    private enum CodingKeys: String, CodingKey {
        case files, downloadSources, readme, securityReports, evaluation
    }
}

struct MothxSkillHubTarget: Codable, Hashable {
    let path: String
    let scope: String
    let label: String
}

struct MothxSkillHubTargetsResponse: Codable {
    let sessionID: String
    let workDir: String
    let targets: [MothxSkillHubTarget]

    enum CodingKeys: String, CodingKey { case sessionID = "sessionId", workDir, targets }
}
