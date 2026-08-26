import Combine
import Foundation

enum TeamError: LocalizedError {
    case agentRunFailed(String)
    case noRunID
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .agentRunFailed(let detail): return detail
        case .noRunID: return "服务端未返回 run ID"
        case .http(let code, let detail): return "HTTP \(code)：\(detail)"
        }
    }
}

/// Orchestrates the Agent team layer described in AGENT_TEAM_DEVELOPMENT_PLAN.md:
///
/// - Agent Profile CRUD (client-owned SQLite via TeamStore);
/// - Team Run lifecycle: manager produces a structured `team_plan` JSON,
///   mothxOS validates it, then schedules member tasks (parallel when no
///   dependencies, serial otherwise);
/// - member runs use the ordinary Session Run API with each profile's own
///   provider/model/workDir/mode/tools/skills;
/// - after all member tasks are terminal, the manager synthesizes the final
///   answer;
/// - cancel / single-task retry / app-restart recovery.
///
/// mothx remains the source of truth for sessions and runs; everything here
/// is the mothxOS orchestration layer. All published mutations happen on the
/// main actor.
final class TeamRunManager: ObservableObject {
    @Published private(set) var agentProfiles: [MothxAgentProfile] = []
    @Published private(set) var teamProjects: [MothxTeamProject] = []
    @Published private(set) var teamRuns: [MothxTeamRun] = []
    @Published private(set) var teamTasksByRun: [String: [MothxTeamTask]] = [:]
    @Published var errorMessage: String?
    @Published private(set) var isBusy = false

    private let store: TeamStore?
    private let baseURL = URL(string: "http://127.0.0.1:7872")!
    private var pollTasks: [String: Task<Void, Never>] = [:]
    private var cancelFlags: [String: Bool] = [:]
    private let maxConcurrentTasks = 3
    private let maxPlanAttempts = 2
    private let maxResultLength = 30000

    private let terminalRunStatuses = ["completed", "succeeded", "failed", "error", "cancelled", "canceled", "timed_out", "timeout", "expired", "incomplete"]
    private let failedRunStatuses = ["failed", "error", "timed_out", "timeout", "expired", "incomplete"]

    init() {
        store = try? TeamStore()
        if store == nil { errorMessage = "本地团队数据库无法访问" }
    }

    // MARK: - Agent Profile CRUD

    @MainActor
    func loadData() async {
        guard let store else { return }
        agentProfiles = (try? store.agentProfiles()) ?? []
        teamProjects = (try? store.teamProjects()) ?? []
        teamRuns = (try? store.teamRuns()) ?? []
        for run in teamRuns { teamTasksByRun[run.id] = (try? store.teamTasks(for: run.id)) ?? [] }
        // Sweep orphaned agent profiles: drafts whose team project was never
        // created (or an earlier data model whose projects no longer exist).
        let validProjectIDs = Set(teamProjects.map(\.id))
        let orphans = agentProfiles.filter { !validProjectIDs.contains($0.projectID) }
        if !orphans.isEmpty {
            for orphan in orphans { try? store.deleteAgentProfile(id: orphan.id) }
            agentProfiles.removeAll { !validProjectIDs.contains($0.projectID) }
        }
    }

    // MARK: - Team Project CRUD

    /// True when the given mothx project belongs to a team task (and should be
    /// hidden from the regular 项目 section of the sidebar).
    @MainActor
    func isTeamProject(_ mothxProjectID: String) -> Bool {
        teamProjects.contains { $0.mothxProjectID == mothxProjectID }
    }

    @MainActor
    func teamProject(forTeamProjectID id: String) -> MothxTeamProject? {
        teamProjects.first { $0.id == id }
    }

    @MainActor
    func teamProject(forMothxProjectID mothxProjectID: String) -> MothxTeamProject? {
        teamProjects.first { $0.mothxProjectID == mothxProjectID }
    }

    /// Creates the mothx counterpart (a real mothx Project) and records the
    /// team-task ↔ project relationship locally. `id` is the client-side team
    /// project id that agent profiles/runs reference.
    @MainActor
    func createTeamProject(name: String, id: String) async -> MothxTeamProject? {
        guard let store else { errorMessage = "本地团队数据库无法访问"; return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let body = try jsonData(["name": trimmed])
            let data = try await request(path: "api/projects", method: "POST", body: body)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mothxProjectID = object["id"] as? String else {
                errorMessage = "创建 mothx 项目失败"
                return nil
            }
            let now = Date()
            let project = MothxTeamProject(id: id, name: trimmed, mothxProjectID: mothxProjectID, createdAt: now, updatedAt: now)
            try store.saveTeamProject(project)
            teamProjects.append(project)
            errorMessage = nil
            return project
        } catch {
            errorMessage = "创建团队任务失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// Renames both the mothx project and the local team project record.
    @MainActor
    func renameTeamProject(id: String, name: String) async {
        guard var project = teamProject(forTeamProjectID: id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != project.name else { return }
        let body = try? jsonData(["name": trimmed])
        _ = try? await request(path: "api/projects/\(project.mothxProjectID)", method: "PATCH", body: body)
        project.name = trimmed
        project.updatedAt = Date()
        try? store?.saveTeamProject(project)
        if let index = teamProjects.firstIndex(where: { $0.id == id }) {
            teamProjects[index] = project
        }
    }

    /// Deletes a team task: removes the mothx project (sessions stay, like
    /// project deletion in mothx) and all locally recorded team data.
    @MainActor
    func deleteTeamProject(id: String) async {
        guard let store, let project = teamProject(forTeamProjectID: id) else { return }
        if !project.mothxProjectID.isEmpty {
            _ = try? await request(path: "api/projects/\(project.mothxProjectID)", method: "DELETE")
        }
        try? store.deleteTeamProject(projectID: id)
        teamProjects.removeAll { $0.id == id }
        agentProfiles.removeAll { $0.projectID == id }
        teamRuns.removeAll { $0.projectID == id }
        for runID in teamTasksByRun.keys where teamRuns.first(where: { $0.id == runID }) == nil {
            teamTasksByRun.removeValue(forKey: runID)
        }
    }

    /// Removes leftover in-memory drafts of a team project that was never
    /// confirmed (cancelled team setup).
    @MainActor
    func discardTeamProjectDraft(id: String) async {
        guard let store else { return }
        try? store.deleteTeamProject(projectID: id)
        teamProjects.removeAll { $0.id == id }
        agentProfiles.removeAll { $0.projectID == id }
    }

    @MainActor
    func profiles(for projectID: String) -> [MothxAgentProfile] {
        agentProfiles
            .filter { $0.projectID == projectID }
            .sorted { lhs, rhs in
                if lhs.role != rhs.role { return lhs.role == .manager }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    @MainActor
    func managerProfile(for projectID: String) -> MothxAgentProfile? {
        profiles(for: projectID).first { $0.role == .manager }
    }

    @MainActor
    func profile(id: String) -> MothxAgentProfile? {
        agentProfiles.first { $0.id == id }
    }

    /// Saves a profile; enforces exactly one manager per project.
    @MainActor
    @discardableResult
    func saveProfile(_ profile: MothxAgentProfile) async -> Bool {
        guard let store else { errorMessage = "本地团队数据库无法访问"; return false }
        if profile.role == .manager,
           let existing = agentProfiles.first(where: { $0.projectID == profile.projectID && $0.role == .manager && $0.id != profile.id }) {
            errorMessage = "每个项目只能有一个主 Agent（当前已存在：\(existing.name)）"
            return false
        }
        do {
            try store.saveAgentProfile(profile)
            if let index = agentProfiles.firstIndex(where: { $0.id == profile.id }) {
                agentProfiles[index] = profile
            } else {
                agentProfiles.append(profile)
            }
            return true
        } catch {
            errorMessage = "保存 Agent 配置失败：\(error.localizedDescription)"
            return false
        }
    }

    @MainActor
    func deleteProfile(id: String) async {
        guard let store else { return }
        try? store.deleteAgentProfile(id: id)
        agentProfiles.removeAll { $0.id == id }
    }

    // MARK: - Single agent execution (阶段 3)

    /// Ensures the profile has a mothx session (created lazily on first run)
    /// and submits a run using the profile's own provider/model/workdir/mode.
    @MainActor
    private func runAgent(profile: MothxAgentProfile, message: String) async throws -> (sessionID: String, runID: String) {
        let sessionID = profile.sessionID ?? UUID().uuidString.lowercased()
        var payload: [String: Any] = ["message": message, "mode": profile.mode.isEmpty ? "agent" : profile.mode, "transcript": true]
        if !profile.providerID.isEmpty { payload["provider"] = profile.providerID }
        if !profile.modelID.isEmpty { payload["model"] = profile.modelID }
        if !profile.tools.isEmpty { payload["tools"] = profile.tools }
        if !profile.skills.isEmpty { payload["skills"] = profile.skills }
        if !profile.workDir.isEmpty { payload["workDir"] = profile.workDir }
        let body = try jsonData(payload)

        // A UUID session id becomes a persisted mothx session on its first run.
        let response = try await request(path: "api/sessions/\(sessionID)/runs", method: "POST", body: body, headers: ["Idempotency-Key": UUID().uuidString])
        let object = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any]
        guard let runID = (object?["runId"] as? String) ?? (object?["runID"] as? String) else {
            throw TeamError.noRunID
        }

        // Persist the lazy session binding, then attach the session to the
        // team task's mothx project (the team task is a project to mothx), so
        // every session produced by the task lives under it.
        var updated = profile
        updated.sessionID = sessionID
        updated.updatedAt = Date()
        try? store?.saveAgentProfile(updated)
        if let index = agentProfiles.firstIndex(where: { $0.id == updated.id }) {
            agentProfiles[index] = updated
        }
        if !profile.projectID.isEmpty {
            let attachProjectID = teamProject(forTeamProjectID: profile.projectID)?.mothxProjectID ?? profile.projectID
            _ = try? await request(path: "api/sessions/\(sessionID)/metadata", method: "PATCH", body: try? jsonData(["projectId": attachProjectID]))
        }
        return (sessionID, runID)
    }

    /// 阶段 3 UI: runs a one-off prompt against one profile and returns the reply.
    @MainActor
    func testRunAgent(profile: MothxAgentProfile, prompt: String) async -> Result<String, Error> {
        do {
            let (sessionID, runID) = try await runAgent(profile: profile, message: prompt)
            guard let status = await pollRun(runID, shouldStop: { false }) else {
                return .failure(URLError(.cancelled))
            }
            if failedRunStatuses.contains(status.lowercased()) {
                return .failure(TeamError.agentRunFailed(await runError(runID)))
            }
            let reply = (await assistantTexts(sessionID: sessionID)).joined(separator: "\n\n")
            return .success(String(reply.prefix(maxResultLength)))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Team Run lifecycle (阶段 4–7)

    /// Starts a team run: plans with the manager, then schedules members.
    @MainActor
    @discardableResult
    func startTeamRun(projectID: String, prompt: String) async -> String? {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let manager = managerProfile(for: projectID), manager.enabled else {
            errorMessage = "请先为该团队任务配置并启用主 Agent"
            return nil
        }
        let members = profiles(for: projectID).filter { $0.role == .member && $0.enabled }
        guard !members.isEmpty else {
            errorMessage = "请先为该团队任务配置至少一个启用的成员 Agent"
            return nil
        }
        guard let store else { errorMessage = "本地团队数据库无法访问"; return nil }

        isBusy = true
        defer { isBusy = false }

        let run = MothxTeamRun(
            id: UUID().uuidString.lowercased(),
            projectID: projectID,
            managerAgentID: manager.id,
            managerSessionID: nil,
            managerRunID: nil,
            userPrompt: prompt,
            status: .planning,
            finalAnswer: "",
            error: "",
            startedAt: Date(),
            finishedAt: nil,
            updatedAt: Date()
        )
        do {
            try store.saveTeamRun(run)
        } catch {
            errorMessage = "保存团队任务失败：\(error.localizedDescription)"
            return nil
        }
        persist(run)
        teamTasksByRun[run.id] = []
        startPollTask(run.id)
        return run.id
    }

    @MainActor
    func cancelTeamRun(runID: String) async {
        cancelFlags[runID] = true
        guard let run = loadRun(runID), !run.status.isTerminal else { return }
        if [.planning, .planned, .synthesizing].contains(run.status), let managerRunID = run.managerRunID {
            try? await cancelServerRun(managerRunID)
        }
        await cancelChildRuns(runID)
    }

    /// Retries a single failed/canceled/skipped task of a team run. If the
    /// team run already finished, it is reopened so the scheduler resumes.
    @MainActor
    func retryTask(runID: String, taskID: String) async {
        guard let store else { errorMessage = "本地团队数据库无法访问"; return }
        guard var run = loadRun(runID) else { return }
        var tasks = loadTasks(runID)
        guard let index = tasks.firstIndex(where: { $0.id == taskID }),
              tasks[index].status == .failed || tasks[index].status == .canceled || tasks[index].status == .skipped else {
            errorMessage = "只有失败或已取消的任务可以重试"
            return
        }
        var task = tasks[index]
        task.retryOf = task.retryOf ?? task.id
        task.status = .pending
        task.runID = nil
        task.sessionID = nil
        task.result = ""
        task.error = ""
        task.startedAt = nil
        task.finishedAt = nil
        tasks[index] = task
        for item in tasks { try? store.saveTeamTask(item) }
        publishTasks(runID)

        guard run.status.isTerminal else { return }
        if run.status == .completed || run.status == .partial || run.status == .failed {
            run.status = .running
            run.finalAnswer = ""
            run.error = ""
            run.finishedAt = nil
            run.updatedAt = Date()
            persist(run)
            startPollTask(runID)
        }
    }

    /// App-restart recovery: resume polling every active team run (member
    /// runs continue server-side even if the desktop app was closed).
    @MainActor
    func recoverActiveRuns() async {
        guard let store else { return }
        let active = (try? store.activeTeamRuns()) ?? []
        for run in active where pollTasks[run.id] == nil && cancelFlags[run.id] == nil {
            startPollTask(run.id)
        }
    }

    // MARK: - Executor

    @MainActor
    private func startPollTask(_ runID: String) {
        guard pollTasks[runID] == nil else { return }
        pollTasks[runID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.executeTeamRun(runID: runID)
            self.pollTasks[runID] = nil
            self.cancelFlags[runID] = nil
        }
    }

    /// Full team run execution: planning → validate → schedule → synthesize.
    ///
    /// Recovery-friendly: when restarting with an already-materialized run
    /// (.planned/.running/.synthesizing) it skips planning, resumes polling the
    /// in-flight planning/synthesis run instead of submitting a duplicate.
    @MainActor
    private func executeTeamRun(runID: String) async {
        guard var run = loadRun(runID) else { return }
        guard let manager = profile(id: run.managerAgentID) else {
            finishRun(run, status: .failed, error: "主 Agent 配置不存在")
            return
        }
        let members = profiles(for: run.projectID).filter { $0.role == .member && $0.enabled }
        let isRecovered = run.status != .planning

        // ---- Phase 1: manager produces a structured team_plan ----
        if run.status == .planning {
            // A run stuck at .planned without tasks (crash between persist and
            // task creation) restarts planning.
            guard let plan = await performPlanning(run: &run, manager: manager, members: members) else { return }
            run.status = .planned
            persist(run)
            let idMap = Dictionary(uniqueKeysWithValues: plan.tasks.map { ($0.id, "\(runID)/\($0.id)") })
            let tasks = plan.tasks.map { task in
                MothxTeamTask(
                    id: idMap[task.id] ?? task.id,
                    teamRunID: runID,
                    agentProfileID: task.agentId,
                    sessionID: nil,
                    runID: nil,
                    retryOf: nil,
                    title: task.title,
                    prompt: task.prompt,
                    status: .pending,
                    executionMode: task.execution,
                    dependsOn: task.dependsOn.compactMap { idMap[$0] },
                    result: "",
                    error: "",
                    startedAt: nil,
                    finishedAt: nil
                )
            }
            for task in tasks { try? store?.saveTeamTask(task) }
            publishTasks(runID)
            run.status = .running
            persist(run)
        } else if run.status == .planned, loadTasks(runID).isEmpty {
            run.status = .planning
            persist(run)
            guard let plan = await performPlanning(run: &run, manager: manager, members: members) else { return }
            run.status = .planned
            persist(run)
            let idMap = Dictionary(uniqueKeysWithValues: plan.tasks.map { ($0.id, "\(runID)/\($0.id)") })
            let tasks = plan.tasks.map { task in
                MothxTeamTask(
                    id: idMap[task.id] ?? task.id,
                    teamRunID: runID,
                    agentProfileID: task.agentId,
                    sessionID: nil,
                    runID: nil,
                    retryOf: nil,
                    title: task.title,
                    prompt: task.prompt,
                    status: .pending,
                    executionMode: task.execution,
                    dependsOn: task.dependsOn.compactMap { idMap[$0] },
                    result: "",
                    error: "",
                    startedAt: nil,
                    finishedAt: nil
                )
            }
            for task in tasks { try? store?.saveTeamTask(task) }
            publishTasks(runID)
            run.status = .running
            persist(run)
        }

        // ---- Phase 2: scheduling loop (parallel + serial dependencies) ----
        while !isCancelRequested(runID) {
            var tasks = loadTasks(runID)
            var changed = false

            // Poll running runs; move them to completed/failed.
            for index in tasks.indices where tasks[index].status == .running {
                guard let childRunID = tasks[index].runID else { continue }
                guard let status = await runStatusOnce(childRunID) else { continue }
                guard terminalRunStatuses.contains(status.lowercased()) else { continue }
                if failedRunStatuses.contains(status.lowercased()) {
                    tasks[index].status = .failed
                    tasks[index].error = String((await runError(childRunID)).prefix(2000))
                } else {
                    tasks[index].status = .completed
                    if let sessionID = tasks[index].sessionID {
                        tasks[index].result = String((await assistantTexts(sessionID: sessionID)).joined(separator: "\n\n").prefix(maxResultLength))
                    }
                }
                tasks[index].finishedAt = Date()
                changed = true
            }

            // Resolve dependencies: a task becomes queued when all its
            // dependencies are terminal (completed OR failed — a failed member
            // does not automatically block remaining work; the summary marks
            // the missing result).
            for index in tasks.indices where tasks[index].status == .pending || tasks[index].status == .blocked {
                let dependencies = tasks.filter { tasks[index].dependsOn.contains($0.id) }
                if dependencies.allSatisfy({ $0.status.isTerminal }) {
                    tasks[index].status = .queued
                } else {
                    tasks[index].status = .blocked
                }
                changed = true
            }

            // Launch queued tasks up to the concurrency limit.
            var runningCount = tasks.filter { $0.status == .running }.count
            for index in tasks.indices where tasks[index].status == .queued && runningCount < maxConcurrentTasks {
                let task = tasks[index]
                guard let agent = profile(id: task.agentProfileID) else {
                    tasks[index].status = .skipped
                    tasks[index].error = "成员 Agent 配置不存在"
                    changed = true
                    continue
                }
                do {
                    let (sessionID, memberRunID) = try await runAgent(profile: agent, message: task.prompt)
                    tasks[index].sessionID = sessionID
                    tasks[index].runID = memberRunID
                    tasks[index].status = .running
                    tasks[index].startedAt = Date()
                    tasks[index].error = ""
                } catch {
                    tasks[index].status = .failed
                    tasks[index].error = "启动成员 Run 失败：\(error.localizedDescription)"
                }
                runningCount += 1
                changed = true
            }

            if changed { saveTasks(runID, tasks) }
            if tasks.allSatisfy({ $0.status.isTerminal }) { break }
            try? await Task.sleep(for: .milliseconds(800))
        }

        if isCancelRequested(runID) {
            await cancelChildRuns(runID)
            let tasks = loadTasks(runID).map { task -> MothxTeamTask in
                var task = task
                if !task.status.isTerminal {
                    task.status = .canceled
                    task.finishedAt = Date()
                }
                return task
            }
            saveTasks(runID, tasks)
            finishRun(run, status: .canceled, error: "")
            return
        }

        // ---- Phase 3: manager synthesis ----
        // A recovered .synthesizing run still has its in-flight synthesis run;
        // resume polling it. Otherwise clear the completed planning run id and
        // submit a fresh synthesis run.
        let resumeSynthesisRunID = (isRecovered && run.status == .synthesizing) ? run.managerRunID : nil
        await performSynthesis(run: run, manager: manager, resumeRunID: resumeSynthesisRunID)
    }

    /// Planning phase with retry. Returns the validated plan, or nil when the
    /// run reached a terminal state (planningFailed/canceled). On recovery of
    /// an in-flight planning run, the existing manager run is polled instead
    /// of submitting a duplicate.
    @MainActor
    private func performPlanning(run: inout MothxTeamRun, manager: MothxAgentProfile, members: [MothxAgentProfile]) async -> MothxTeamPlan? {
        let runID = run.id
        var attempt = 0
        var feedback = ""
        while !isCancelRequested(runID) {
            do {
                let sessionID: String
                let planRunID: String
                if let existing = run.managerRunID, attempt == 0, feedback.isEmpty {
                    sessionID = run.managerSessionID ?? ""
                    planRunID = existing
                } else {
                    let result = try await runAgent(profile: manager, message: buildPlanPrompt(userPrompt: run.userPrompt, manager: manager, members: members, feedback: feedback))
                    sessionID = result.sessionID
                    planRunID = result.runID
                    run.managerSessionID = sessionID
                    run.managerRunID = planRunID
                    run.updatedAt = Date()
                    persist(run)
                }
                guard let status = await pollRun(planRunID, shouldStop: { self.isCancelRequested(runID) }) else {
                    try? await cancelServerRun(planRunID)
                    finishRun(run, status: .canceled, error: "")
                    return nil
                }
                if failedRunStatuses.contains(status.lowercased()) {
                    guard attempt < maxPlanAttempts else {
                        finishRun(run, status: .planningFailed, error: "主 Agent 规划 Run 失败：\(await runError(planRunID))")
                        return nil
                    }
                    attempt += 1
                    feedback = "上一次规划运行失败（\(status)），请重新输出 team_plan JSON。"
                    continue
                }
                let texts = await assistantTexts(sessionID: sessionID)
                let candidates = texts.compactMap { MothxTeamPlan.extractJSON(from: $0) }
                guard let jsonData = candidates.last,
                      case .success(let parsed) = MothxTeamPlan.parse(data: jsonData, profiles: profiles(for: run.projectID)) else {
                    guard attempt < maxPlanAttempts else {
                        finishRun(run, status: .planningFailed, error: "主 Agent 未能输出合法的 team_plan JSON")
                        return nil
                    }
                    attempt += 1
                    feedback = "上一次输出不是合法的 team_plan JSON，请只输出符合要求格式的 JSON。"
                    continue
                }
                return parsed
            } catch {
                guard attempt < maxPlanAttempts else {
                    finishRun(run, status: .planningFailed, error: "无法运行主 Agent：\(error.localizedDescription)")
                    return nil
                }
                attempt += 1
                feedback = "无法运行主 Agent（\(error.localizedDescription)），请重试输出 team_plan JSON。"
            }
        }
        finishRun(run, status: .canceled, error: "")
        return nil
    }

    /// Synthesis phase: the manager turns all member results into the final
    /// answer. Resumes an in-flight synthesis run when `resumeRunID` is set.
    @MainActor
    private func performSynthesis(run: MothxTeamRun, manager: MothxAgentProfile, resumeRunID: String?) async {
        let runID = run.id
        let tasks = loadTasks(runID)
        let anyFailure = tasks.contains { $0.status == .failed || $0.status == .skipped }
        var current = run
        current.status = .synthesizing
        persist(current)
        do {
            let sessionID: String
            let synthRunID: String
            if let resumeRunID, !resumeRunID.isEmpty {
                sessionID = current.managerSessionID ?? ""
                synthRunID = resumeRunID
            } else {
                let result = try await runAgent(profile: manager, message: buildSynthesisPrompt(run: run, tasks: tasks))
                sessionID = result.sessionID
                synthRunID = result.runID
                current.managerSessionID = sessionID
                current.managerRunID = synthRunID
                current.updatedAt = Date()
                persist(current)
            }
            guard let status = await pollRun(synthRunID, shouldStop: { self.isCancelRequested(runID) }) else {
                try? await cancelServerRun(synthRunID)
                finishRun(current, status: .canceled, error: "")
                return
            }
            if failedRunStatuses.contains(status.lowercased()) {
                finishRun(current, status: .failed, error: "主 Agent 汇总失败：\(await runError(synthRunID))")
                return
            }
            let answer = (await assistantTexts(sessionID: sessionID)).joined(separator: "\n\n")
            current.finalAnswer = String(answer.prefix(maxResultLength))
            current.status = anyFailure ? .partial : .completed
            current.finishedAt = Date()
            current.updatedAt = Date()
            persist(current)
        } catch {
            finishRun(current, status: .failed, error: "主 Agent 汇总失败：\(error.localizedDescription)")
        }
    }


    // MARK: - Prompt builders

    private func buildPlanPrompt(userPrompt: String, manager: MothxAgentProfile, members: [MothxAgentProfile], feedback: String) -> String {
        let agentLines = ([manager] + members).map { agent in
            "- \(agent.id) | \(agent.name) | role: \(agent.role.rawValue) | provider: \(agent.providerID.isEmpty ? "default" : agent.providerID) | model: \(agent.modelID.isEmpty ? "default" : agent.modelID) | workDir: \(agent.workDir)"
        }.joined(separator: "\n")
        let feedbackBlock = feedback.isEmpty ? "" : "\n\n上一次输出未通过校验：\(feedback)"
        return """
        你是项目的「主 Agent」。用户提交了一个任务，你需要把它拆解为子任务并输出严格的 JSON（不要输出除 JSON 之外的任何内容）。

        可用 Agent（只能引用这些 id）：
        \(agentLines)

        输出格式（type 必须为 "team_plan"，version 必须为 1）：
        {
          "type": "team_plan",
          "version": 1,
          "summary": "任务摘要",
          "tasks": [
            {
              "id": "task-1",
              "agentId": "成员 agent id",
              "title": "子任务标题",
              "prompt": "子任务的完整指令",
              "dependsOn": [],
              "execution": "parallel"
            }
          ]
        }

        规则：
        - 每个 task 的 agentId 必须来自上面列表；
        - dependsOn 引用其他 task 的 id；汇总任务依赖前面的任务；
        - 无依赖的任务并行执行（execution: "parallel"），有依赖的串行（execution: "serial"）；
        - 最后应包含一个汇总任务，交给 manager 汇总成员结果；
        - 不要编造不存在的 agentId；只输出 JSON。
        \(feedbackBlock)

        用户任务：\(userPrompt)
        """
    }

    private func buildSynthesisPrompt(run: MothxTeamRun, tasks: [MothxTeamTask]) -> String {
        let profileByID = Dictionary(uniqueKeysWithValues: agentProfiles.map { ($0.id, $0) })
        var sections: [String] = ["用户原始任务：\n\(run.userPrompt)"]
        sections.append("以下是团队成员的结果：")
        for task in tasks {
            let agentName = profileByID[task.agentProfileID]?.name ?? task.agentProfileID
            let body: String
            if task.status == .completed, !task.result.isEmpty {
                body = task.result
            } else if !task.error.isEmpty {
                body = "（状态：\(task.status.rawValue)，错误：\(task.error)）"
            } else {
                body = "（状态：\(task.status.rawValue)，无结果）"
            }
            sections.append("[任务：\(task.title)]（Agent：\(agentName)，状态：\(task.status.rawValue)）\n\(body)")
        }
        sections.append("""
        请根据以上团队成员结果生成最终答复（只输出最终答复本身）。请区分：
        - 已确认的问题；
        - 潜在问题；
        - 建议的验证项。
        如果有成员失败或结果缺失，请明确说明。
        """)
        return sections.joined(separator: "\n\n")
    }

    // MARK: - State persistence helpers

    @MainActor
    private func persist(_ run: MothxTeamRun) {
        try? store?.saveTeamRun(run)
        if let index = teamRuns.firstIndex(where: { $0.id == run.id }) {
            if teamRuns[index] != run { teamRuns[index] = run }
        } else {
            teamRuns.insert(run, at: 0)
        }
    }

    @MainActor
    private func publishTasks(_ runID: String) {
        teamTasksByRun[runID] = (try? store?.teamTasks(for: runID)) ?? []
    }

    @MainActor
    private func saveTasks(_ runID: String, _ tasks: [MothxTeamTask]) {
        for task in tasks { try? store?.saveTeamTask(task) }
        publishTasks(runID)
    }

    @MainActor
    private func loadTasks(_ runID: String) -> [MothxTeamTask] {
        (try? store?.teamTasks(for: runID)) ?? teamTasksByRun[runID] ?? []
    }

    @MainActor
    private func loadRun(_ runID: String) -> MothxTeamRun? {
        teamRuns.first { $0.id == runID }
    }

    @MainActor
    private func finishRun(_ run: MothxTeamRun, status: MothxTeamRunStatus, error: String) {
        var updated = run
        updated.status = status
        updated.error = error
        updated.finishedAt = Date()
        updated.updatedAt = Date()
        persist(updated)
        pollTasks[run.id] = nil
        cancelFlags[run.id] = nil
    }

    @MainActor
    private func isCancelRequested(_ runID: String) -> Bool {
        cancelFlags[runID] == true
    }

    @MainActor
    private func cancelChildRuns(_ runID: String) async {
        for task in loadTasks(runID) where task.status == .running {
            if let childRunID = task.runID { try? await cancelServerRun(childRunID) }
        }
    }

    // MARK: - HTTP helpers

    private func request(path: String, method: String, body: Data? = nil, headers: [String: String] = [:]) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw TeamError.http(http.statusCode, detail)
        }
        return data
    }

    private func cancelServerRun(_ runID: String) async throws {
        _ = try await request(path: "api/runs/\(runID)/cancel", method: "POST")
    }

    /// Single status probe for one run; nil on transient network failure.
    private func runStatusOnce(_ runID: String) async -> String? {
        do {
            let data = try await request(path: "api/runs/\(runID)", method: "GET")
            let object = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return (object["status"] as? String) ?? (object["state"] as? String)
        } catch {
            return nil
        }
    }

    private func runError(_ runID: String) async -> String {
        guard let data = try? await request(path: "api/runs/\(runID)", method: "GET"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return (object["error"] as? String) ?? (object["errorMessage"] as? String) ?? ""
    }

    private func pollRun(_ runID: String, shouldStop: @escaping () -> Bool) async -> String? {
        while !Task.isCancelled {
            if shouldStop() { return nil }
            if let status = await runStatusOnce(runID), terminalRunStatuses.contains(status.lowercased()) {
                return status
            }
            try? await Task.sleep(for: .milliseconds(800))
        }
        return nil
    }

    private func assistantTexts(sessionID: String) async -> [String] {
        guard let data = try? await request(path: "api/sessions/\(sessionID)/messages?limit=200", method: "GET"),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let values: [[String: Any]]
        if let direct = object as? [[String: Any]] { values = direct }
        else { values = (object as? [String: Any])?["messages"] as? [[String: Any]] ?? [] }
        return values.compactMap { item in
            let role = (item["role"] as? String) ?? "assistant"
            guard role == "assistant" else { return nil }
            let content = (item["content"] as? String) ?? (item["text"] as? String) ?? ""
            return content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : content
        }
    }

    private func jsonData(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
}