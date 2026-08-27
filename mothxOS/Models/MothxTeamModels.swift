import Foundation

// MARK: - Team Project（团队任务容器）

/// 侧边栏顶部「团队任务」下的一个任务实体，与「项目」并列。
///
/// mothx 本身没有“团队任务”概念：创建团队任务时，mothxOS 会在 mothx 中
/// 创建一个真实的 Project，所有成员/主 Agent Session 都归属到该 Project；
/// `mothxProjectID` 就是 mothxOS 记录的“团队任务 ↔ mothx 项目”关系。
struct MothxTeamProject: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var mothxProjectID: String
    var createdAt: Date
    var updatedAt: Date

    static func new(id: String = UUID().uuidString.lowercased()) -> MothxTeamProject {
        let now = Date()
        return MothxTeamProject(id: id, name: "", mothxProjectID: "", createdAt: now, updatedAt: now)
    }
}

// MARK: - Team Run

enum MothxTeamRunStatus: String, Codable, Hashable {
    case planning          // manager is producing the structured plan
    case planned           // plan accepted, tasks not started yet
    case running           // member tasks are executing
    case synthesizing      // all member tasks terminal, manager synthesizing
    case completed         // all tasks completed and manager synthesis succeeded
    case partial           // some tasks failed/skipped but manager synthesis succeeded
    case planningFailed    // the manager could not produce a valid team_plan
    case failed            // synthesis failed or a fatal scheduling error
    case canceling
    case canceled

    var isTerminal: Bool {
        [.completed, .partial, .planningFailed, .failed, .canceled].contains(self)
    }
}

/// One complete team task initiated by the user. Persisted client-side.
struct MothxTeamRun: Identifiable, Codable, Hashable {
    var id: String
    var projectID: String
    var managerAgentID: String
    var managerSessionID: String?
    var managerRunID: String?
    var userPrompt: String
    var status: MothxTeamRunStatus
    var finalAnswer: String
    var error: String
    var startedAt: Date
    var finishedAt: Date?
    var updatedAt: Date
}

// MARK: - Team Task

enum MothxTeamTaskStatus: String, Codable, Hashable {
    case pending    // waiting for dependency resolution
    case blocked    // one or more dependencies not yet terminal
    case queued     // ready to start, waiting for a concurrency slot
    case running
    case completed
    case failed
    case canceled
    case skipped    // never started because the team run ended

    var isTerminal: Bool {
        [.completed, .failed, .canceled, .skipped].contains(self)
    }
}

/// One member task within a Team Run. `dependsOn` lists task IDs that must
/// reach a terminal state before this task may start.
struct MothxTeamTask: Identifiable, Codable, Hashable {
    static let maxRetries = 5
    var id: String
    var teamRunID: String
    var agentProfileID: String
    var sessionID: String?
    var runID: String?
    /// Retry lineage: the task ID this task retries, when the user asked to
    /// re-run a failed/skipped task.
    var retryOf: String?
    /// Number of automatic member-run retries already consumed.
    var retryCount: Int = 0
    var title: String
    var prompt: String
    var status: MothxTeamTaskStatus
    var executionMode: String   // "parallel" | "serial" (from team_plan)
    var dependsOn: [String]
    var result: String          // final assistant text of the member run
    var error: String
    var startedAt: Date?
    var finishedAt: Date?
}

// MARK: - Structured team plan

/// The `team_plan` JSON protocol produced by the manager Agent and consumed
/// by mothxOS. The manager must not change member provider/model/workDir:
/// tasks only reference configured `agentId`s; execution config comes from
/// the Agent Profile.
struct MothxTeamPlan: Codable, Hashable {
    var type: String
    var version: Int
    var summary: String = ""
    var tasks: [MothxTeamPlanTask]

    private enum CodingKeys: String, CodingKey { case type, version, summary, tasks }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        version = try container.decode(Int.self, forKey: .version)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        tasks = try container.decode([MothxTeamPlanTask].self, forKey: .tasks)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(version, forKey: .version)
        try container.encode(summary, forKey: .summary)
        try container.encode(tasks, forKey: .tasks)
    }
}

struct MothxTeamPlanTask: Codable, Hashable, Identifiable {
    var id: String
    var agentId: String
    var title: String
    var prompt: String
    var dependsOn: [String] = []
    var execution: String = "parallel"

    private enum CodingKeys: String, CodingKey { case id, agentId, title, prompt, dependsOn, execution }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        agentId = try container.decode(String.self, forKey: .agentId)
        title = try container.decode(String.self, forKey: .title)
        prompt = try container.decode(String.self, forKey: .prompt)
        dependsOn = try container.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
        execution = try container.decodeIfPresent(String.self, forKey: .execution) ?? "parallel"
    }

    init(id: String, agentId: String, title: String, prompt: String, dependsOn: [String] = [], execution: String = "parallel") {
        self.id = id
        self.agentId = agentId
        self.title = title
        self.prompt = prompt
        self.dependsOn = dependsOn
        self.execution = execution
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(agentId, forKey: .agentId)
        try container.encode(title, forKey: .title)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(dependsOn, forKey: .dependsOn)
        try container.encode(execution, forKey: .execution)
    }
}

// MARK: - Plan validation

enum MothxTeamPlanValidationError: LocalizedError, Equatable {
    case notJSON
    case wrongType(String)
    case wrongVersion(Int)
    case duplicateTaskID(String)
    case emptyTaskList
    case unknownAgent(String)
    case agentDisabled(String)
    case agentNotInProject(String)
    case missingDependency(String, String)
    case cyclicDependency
    case tooManyTasks(Int)

    var errorDescription: String? {
        switch self {
        case .notJSON: return "plan is not valid JSON"
        case .wrongType(let type): return "unsupported plan type: \(type)"
        case .wrongVersion(let version): return "unsupported plan version: \(version)"
        case .duplicateTaskID(let id): return "duplicate task id: \(id)"
        case .emptyTaskList: return "plan has no tasks"
        case .unknownAgent(let agentID): return "unknown agent id: \(agentID)"
        case .agentDisabled(let agentID): return "agent is disabled: \(agentID)"
        case .agentNotInProject(let agentID): return "agent does not belong to the project: \(agentID)"
        case .missingDependency(let taskID, let dep): return "task \(taskID) depends on missing task \(dep)"
        case .cyclicDependency: return "plan contains a cyclic dependency"
        case .tooManyTasks(let max): return "plan exceeds the maximum task count (\(max))"
        }
    }
}

extension MothxTeamPlan {
    /// Capacity limits for the first version.
    static let maxTasks = 12

    /// Decodes and validates a raw `team_plan` JSON payload against the
    /// project's enabled Agent Profiles.
    static func parse(data: Data, profiles: [MothxAgentProfile]) -> Result<MothxTeamPlan, MothxTeamPlanValidationError> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.notJSON)
        }
        guard (object["type"] as? String) == "team_plan" else {
            return .failure(.wrongType(object["type"] as? String ?? "unknown"))
        }
        guard (object["version"] as? Int) == 1 else {
            return .failure(.wrongVersion(object["version"] as? Int ?? 0))
        }
        guard let plan = try? JSONDecoder().decode(MothxTeamPlan.self, from: data) else {
            return .failure(.notJSON)
        }
        return validate(plan, profiles: profiles)
    }

    static func validate(_ plan: MothxTeamPlan, profiles: [MothxAgentProfile]) -> Result<MothxTeamPlan, MothxTeamPlanValidationError> {
        let profileByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        guard !plan.tasks.isEmpty else { return .failure(.emptyTaskList) }
        guard plan.tasks.count <= maxTasks else { return .failure(.tooManyTasks(maxTasks)) }

        var seen = Set<String>()
        for task in plan.tasks {
            guard seen.insert(task.id).inserted else { return .failure(.duplicateTaskID(task.id)) }
            guard let profile = profileByID[task.agentId] else { return .failure(.unknownAgent(task.agentId)) }
            guard profile.enabled else { return .failure(.agentDisabled(task.agentId)) }
        }

        // Dependency edges must exist and must not form a cycle.
        let taskIDs = Set(plan.tasks.map(\.id))
        var adjacency: [String: [String]] = [:]
        for task in plan.tasks {
            for dep in task.dependsOn {
                guard taskIDs.contains(dep) else { return .failure(.missingDependency(task.id, dep)) }
                adjacency[dep, default: []].append(task.id)
            }
        }
        // Kahn's algorithm for cycle detection.
        var inDegree: [String: Int] = [:]
        for task in plan.tasks { inDegree[task.id] = task.dependsOn.count }
        var queue = inDegree.filter { $0.value == 0 }.map(\.key)
        var visited = 0
        while !queue.isEmpty {
            let node = queue.removeFirst()
            visited += 1
            for dependent in adjacency[node] ?? [] {
                inDegree[dependent, default: 0] -= 1
                if inDegree[dependent] == 0 { queue.append(dependent) }
            }
        }
        guard visited == taskIDs.count else { return .failure(.cyclicDependency) }
        return .success(plan)
    }

    /// Extracts a standalone JSON object from assistant output (agents often
    /// wrap JSON in fenced code blocks or prose). Finds the outermost `{...}`
    /// block and re-validates balanced braces.
    static func extractJSON(from text: String) -> Data? {
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}") else { return nil }
        let candidate = String(text[first...last])
        guard let data = candidate.data(using: .utf8) else { return nil }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        return data
    }
}
