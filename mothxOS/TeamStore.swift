import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Client-owned persistence for the Agent team layer (mothxOS-only).
/// mothx remains the source of truth for sessions/runs; this database stores
/// Agent Profiles, Team Runs, Team Tasks and task dependencies so the team
/// configuration and scheduling survive app restarts.
final class TeamStore {
    private var database: OpaquePointer?

    init() throws {
        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("mothxOS", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let databaseURL = supportDirectory.appendingPathComponent("teams.sqlite")
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw LocalProjectStoreError.openFailed
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS agent_profiles (
                id TEXT PRIMARY KEY NOT NULL,
                project_id TEXT NOT NULL,
                name TEXT NOT NULL,
                role TEXT NOT NULL,
                provider_id TEXT NOT NULL,
                model_id TEXT NOT NULL,
                work_dir TEXT NOT NULL,
                mode TEXT NOT NULL,
                tools TEXT NOT NULL,
                skills TEXT NOT NULL,
                max_iterations INTEGER NOT NULL,
                enabled INTEGER NOT NULL,
                session_id TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                summary TEXT NOT NULL DEFAULT ''
            )
        """)
        try execute("""
            CREATE TABLE IF NOT EXISTS team_projects (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                mothx_project_id TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try execute("""
            CREATE TABLE IF NOT EXISTS team_runs (
                id TEXT PRIMARY KEY NOT NULL,
                project_id TEXT NOT NULL,
                manager_agent_id TEXT NOT NULL,
                manager_session_id TEXT,
                manager_run_id TEXT,
                user_prompt TEXT NOT NULL,
                status TEXT NOT NULL,
                final_answer TEXT NOT NULL,
                error TEXT NOT NULL,
                started_at REAL NOT NULL,
                finished_at REAL,
                updated_at REAL NOT NULL
            )
        """)
        try execute("""
            CREATE TABLE IF NOT EXISTS team_tasks (
                id TEXT PRIMARY KEY NOT NULL,
                team_run_id TEXT NOT NULL,
                agent_profile_id TEXT NOT NULL,
                session_id TEXT,
                run_id TEXT,
                retry_of TEXT,
                retry_count INTEGER NOT NULL DEFAULT 0,
                title TEXT NOT NULL,
                prompt TEXT NOT NULL,
                status TEXT NOT NULL,
                execution_mode TEXT NOT NULL,
                result TEXT NOT NULL,
                error TEXT NOT NULL,
                started_at REAL,
                finished_at REAL
            )
        """)
        try execute("""
            CREATE TABLE IF NOT EXISTS team_task_dependencies (
                task_id TEXT NOT NULL,
                depends_on_task_id TEXT NOT NULL,
                PRIMARY KEY (task_id, depends_on_task_id)
            )
        """)
        // Migration for databases created before retry_of existed.
        try? execute("ALTER TABLE team_tasks ADD COLUMN retry_of TEXT")
        try? execute("ALTER TABLE team_tasks ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0")
        try? execute("ALTER TABLE team_runs ADD COLUMN manager_run_id TEXT")
        // Migration: Agent Profile skill/capability description added later.
        try? execute("ALTER TABLE agent_profiles ADD COLUMN summary TEXT NOT NULL DEFAULT ''")
        // Migration: nil dates used to be persisted as 0 (1970-01-01), which
        // made in-flight rows read back as finished and show negative durations.
        try? execute("UPDATE team_runs SET finished_at = NULL WHERE finished_at = 0")
        try? execute("UPDATE team_tasks SET started_at = NULL WHERE started_at = 0")
        try? execute("UPDATE team_tasks SET finished_at = NULL WHERE finished_at = 0")
    }

    deinit { sqlite3_close(database) }

    // MARK: - Agent Profiles

    func agentProfiles() throws -> [MothxAgentProfile] {
        let statement = try prepare("SELECT id, project_id, name, role, provider_id, model_id, work_dir, mode, tools, skills, max_iterations, enabled, session_id, created_at, updated_at, summary FROM agent_profiles ORDER BY updated_at DESC")
        defer { sqlite3_finalize(statement) }
        var result: [MothxAgentProfile] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(profile(statement))
        }
        return result
    }

    func agentProfiles(for projectID: String) throws -> [MothxAgentProfile] {
        let statement = try prepare("SELECT id, project_id, name, role, provider_id, model_id, work_dir, mode, tools, skills, max_iterations, enabled, session_id, created_at, updated_at, summary FROM agent_profiles WHERE project_id = ? ORDER BY role ASC, updated_at DESC")
        defer { sqlite3_finalize(statement) }
        try bind(projectID, to: statement, index: 1)
        var result: [MothxAgentProfile] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(profile(statement))
        }
        return result
    }

    func saveAgentProfile(_ profile: MothxAgentProfile) throws {
        let statement = try prepare("""
            INSERT INTO agent_profiles (id, project_id, name, role, provider_id, model_id, work_dir, mode, tools, skills, max_iterations, enabled, session_id, created_at, updated_at, summary)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                project_id = excluded.project_id,
                name = excluded.name,
                role = excluded.role,
                provider_id = excluded.provider_id,
                model_id = excluded.model_id,
                work_dir = excluded.work_dir,
                mode = excluded.mode,
                tools = excluded.tools,
                skills = excluded.skills,
                max_iterations = excluded.max_iterations,
                enabled = excluded.enabled,
                session_id = excluded.session_id,
                updated_at = excluded.updated_at,
                summary = excluded.summary
        """)
        defer { sqlite3_finalize(statement) }
        try bind(profile.id, to: statement, index: 1)
        try bind(profile.projectID, to: statement, index: 2)
        try bind(profile.name, to: statement, index: 3)
        try bind(profile.role.rawValue, to: statement, index: 4)
        try bind(profile.providerID, to: statement, index: 5)
        try bind(profile.modelID, to: statement, index: 6)
        try bind(profile.workDir, to: statement, index: 7)
        try bind(profile.mode, to: statement, index: 8)
        try bind(jsonArray(profile.tools), to: statement, index: 9)
        try bind(jsonArray(profile.skills), to: statement, index: 10)
        guard sqlite3_bind_int(statement, 11, Int32(profile.maxIterations)) == SQLITE_OK,
              sqlite3_bind_int(statement, 12, profile.enabled ? 1 : 0) == SQLITE_OK,
              sqlite3_bind_text(statement, 13, profile.sessionID, -1, sqliteTransient) == SQLITE_OK,
              sqlite3_bind_double(statement, 14, profile.createdAt.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_double(statement, 15, profile.updatedAt.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_text(statement, 16, profile.summary, -1, sqliteTransient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw LocalProjectStoreError.writeFailed
        }
    }

    func deleteAgentProfile(id: String) throws {
        try execute("DELETE FROM agent_profiles WHERE id = ?", bindings: [id])
    }

    /// Removes draft agent profiles that belong to a team project id that was
    /// never confirmed (used by the cancelled team setup flow).
    func deleteAgentProfiles(projectID: String) throws {
        try execute("DELETE FROM agent_profiles WHERE project_id = ?", bindings: [projectID])
    }

    // MARK: - Team Projects（团队任务容器）

    func teamProjects() throws -> [MothxTeamProject] {
        let statement = try prepare("SELECT id, name, mothx_project_id, created_at, updated_at FROM team_projects ORDER BY created_at ASC")
        defer { sqlite3_finalize(statement) }
        var result: [MothxTeamProject] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(MothxTeamProject(
                id: string(statement, column: 0),
                name: string(statement, column: 1),
                mothxProjectID: string(statement, column: 2),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            ))
        }
        return result
    }

    func saveTeamProject(_ project: MothxTeamProject) throws {
        let statement = try prepare("""
            INSERT INTO team_projects (id, name, mothx_project_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                mothx_project_id = excluded.mothx_project_id,
                updated_at = excluded.updated_at
        """)
        defer { sqlite3_finalize(statement) }
        try bind(project.id, to: statement, index: 1)
        try bind(project.name, to: statement, index: 2)
        try bind(project.mothxProjectID, to: statement, index: 3)
        guard sqlite3_bind_double(statement, 4, project.createdAt.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_double(statement, 5, project.updatedAt.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw LocalProjectStoreError.writeFailed
        }
    }

    /// Removes a team project and everything owned by it (profiles, team runs,
    /// tasks, dependencies). The mothx project itself is removed by the caller.
    func deleteTeamProject(projectID: String) throws {
        try execute("DELETE FROM team_task_dependencies WHERE task_id IN (SELECT id FROM team_tasks WHERE team_run_id IN (SELECT id FROM team_runs WHERE project_id = ?)) OR depends_on_task_id IN (SELECT id FROM team_tasks WHERE team_run_id IN (SELECT id FROM team_runs WHERE project_id = ?))", bindings: [projectID, projectID])
        try execute("DELETE FROM team_tasks WHERE team_run_id IN (SELECT id FROM team_runs WHERE project_id = ?)", bindings: [projectID])
        try execute("DELETE FROM team_runs WHERE project_id = ?", bindings: [projectID])
        try execute("DELETE FROM agent_profiles WHERE project_id = ?", bindings: [projectID])
        try execute("DELETE FROM team_projects WHERE id = ?", bindings: [projectID])
    }

    // MARK: - Team Runs

    func teamRuns() throws -> [MothxTeamRun] {
        let statement = try prepare("SELECT id, project_id, manager_agent_id, manager_session_id, manager_run_id, user_prompt, status, final_answer, error, started_at, finished_at, updated_at FROM team_runs ORDER BY started_at DESC")
        defer { sqlite3_finalize(statement) }
        var result: [MothxTeamRun] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(run(statement))
        }
        return result
    }

    func teamRuns(for projectID: String) throws -> [MothxTeamRun] {
        let statement = try prepare("SELECT id, project_id, manager_agent_id, manager_session_id, manager_run_id, user_prompt, status, final_answer, error, started_at, finished_at, updated_at FROM team_runs WHERE project_id = ? ORDER BY started_at DESC")
        defer { sqlite3_finalize(statement) }
        try bind(projectID, to: statement, index: 1)
        var result: [MothxTeamRun] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(run(statement))
        }
        return result
    }

    func activeTeamRuns() throws -> [MothxTeamRun] {
        try teamRuns().filter { !$0.status.isTerminal }
    }

    func saveTeamRun(_ run: MothxTeamRun) throws {
        let statement = try prepare("""
            INSERT INTO team_runs (id, project_id, manager_agent_id, manager_session_id, manager_run_id, user_prompt, status, final_answer, error, started_at, finished_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                manager_session_id = excluded.manager_session_id,
                manager_run_id = excluded.manager_run_id,
                status = excluded.status,
                final_answer = excluded.final_answer,
                error = excluded.error,
                finished_at = excluded.finished_at,
                updated_at = excluded.updated_at
        """)
        defer { sqlite3_finalize(statement) }
        try bind(run.id, to: statement, index: 1)
        try bind(run.projectID, to: statement, index: 2)
        try bind(run.managerAgentID, to: statement, index: 3)
        try bind(run.managerSessionID, to: statement, index: 4)
        try bind(run.managerRunID, to: statement, index: 5)
        try bind(run.userPrompt, to: statement, index: 6)
        try bind(run.status.rawValue, to: statement, index: 7)
        try bind(run.finalAnswer, to: statement, index: 8)
        try bind(run.error, to: statement, index: 9)
        guard sqlite3_bind_double(statement, 10, run.startedAt.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_double(statement, 12, run.updatedAt.timeIntervalSince1970) == SQLITE_OK else {
            throw LocalProjectStoreError.writeFailed
        }
        try bindDate(run.finishedAt, to: statement, index: 11)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw LocalProjectStoreError.writeFailed }
    }

    func deleteTeamRun(id: String) throws {
        try execute("DELETE FROM team_task_dependencies WHERE task_id IN (SELECT id FROM team_tasks WHERE team_run_id = ?) OR depends_on_task_id IN (SELECT id FROM team_tasks WHERE team_run_id = ?)", bindings: [id, id])
        try execute("DELETE FROM team_tasks WHERE team_run_id = ?", bindings: [id])
        try execute("DELETE FROM team_runs WHERE id = ?", bindings: [id])
    }

    // MARK: - Team Tasks

    func teamTasks(for runID: String) throws -> [MothxTeamTask] {
        let dependencies = try taskDependencies(for: runID)
        let statement = try prepare("SELECT id, team_run_id, agent_profile_id, session_id, run_id, retry_of, retry_count, title, prompt, status, execution_mode, result, error, started_at, finished_at FROM team_tasks WHERE team_run_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(runID, to: statement, index: 1)
        var result: [MothxTeamTask] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(task(statement, dependencies: dependencies))
        }
        return result
    }

    func saveTeamTask(_ task: MothxTeamTask) throws {
        let statement = try prepare("""
            INSERT INTO team_tasks (id, team_run_id, agent_profile_id, session_id, run_id, retry_of, retry_count, title, prompt, status, execution_mode, result, error, started_at, finished_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                session_id = excluded.session_id,
                run_id = excluded.run_id,
                retry_of = excluded.retry_of,
                retry_count = excluded.retry_count,
                status = excluded.status,
                result = excluded.result,
                error = excluded.error,
                started_at = excluded.started_at,
                finished_at = excluded.finished_at
        """)
        defer { sqlite3_finalize(statement) }
        try bind(task.id, to: statement, index: 1)
        try bind(task.teamRunID, to: statement, index: 2)
        try bind(task.agentProfileID, to: statement, index: 3)
        try bind(task.sessionID, to: statement, index: 4)
        try bind(task.runID, to: statement, index: 5)
        try bind(task.retryOf, to: statement, index: 6)
        guard sqlite3_bind_int(statement, 7, Int32(task.retryCount)) == SQLITE_OK else { throw LocalProjectStoreError.writeFailed }
        try bind(task.title, to: statement, index: 8)
        try bind(task.prompt, to: statement, index: 9)
        try bind(task.status.rawValue, to: statement, index: 10)
        try bind(task.executionMode, to: statement, index: 11)
        try bind(task.result, to: statement, index: 12)
        try bind(task.error, to: statement, index: 13)
        try bindDate(task.startedAt, to: statement, index: 14)
        try bindDate(task.finishedAt, to: statement, index: 15)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw LocalProjectStoreError.writeFailed }
        // Keep the dependency table in sync with the task's dependsOn list.
        try execute("DELETE FROM team_task_dependencies WHERE task_id = ?", bindings: [task.id])
        for dependency in task.dependsOn {
            try execute("INSERT OR IGNORE INTO team_task_dependencies (task_id, depends_on_task_id) VALUES (?, ?)", bindings: [task.id, dependency])
        }
    }

    // MARK: - Helpers

    private func taskDependencies(for runID: String) throws -> [String: [String]] {
        let statement = try prepare("""
            SELECT t.id, d.depends_on_task_id
            FROM team_tasks t
            JOIN team_task_dependencies d ON d.task_id = t.id
            WHERE t.team_run_id = ?
        """)
        defer { sqlite3_finalize(statement) }
        try bind(runID, to: statement, index: 1)
        var result: [String: [String]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let taskID = string(statement, column: 0)
            result[taskID, default: []].append(string(statement, column: 1))
        }
        return result
    }

    private func profile(_ statement: OpaquePointer?) -> MothxAgentProfile {
        MothxAgentProfile(
            id: string(statement, column: 0),
            projectID: string(statement, column: 1),
            name: string(statement, column: 2),
            role: MothxAgentRole(rawValue: string(statement, column: 3)) ?? .member,
            providerID: string(statement, column: 4),
            modelID: string(statement, column: 5),
            workDir: string(statement, column: 6),
            mode: string(statement, column: 7).isEmpty ? "agent" : string(statement, column: 7),
            tools: stringArray(statement, column: 8),
            skills: stringArray(statement, column: 9),
            maxIterations: Int(sqlite3_column_int(statement, 10)),
            enabled: sqlite3_column_int(statement, 11) != 0,
            summary: string(statement, column: 15),
            sessionID: nullableString(statement, column: 12),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 13)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 14))
        )
    }

    private func run(_ statement: OpaquePointer?) -> MothxTeamRun {
        let finished = sqlite3_column_type(statement, 10) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)) : nil
        return MothxTeamRun(
            id: string(statement, column: 0),
            projectID: string(statement, column: 1),
            managerAgentID: string(statement, column: 2),
            managerSessionID: nullableString(statement, column: 3),
            managerRunID: nullableString(statement, column: 4),
            userPrompt: string(statement, column: 5),
            status: MothxTeamRunStatus(rawValue: string(statement, column: 6)) ?? .failed,
            finalAnswer: string(statement, column: 7),
            error: string(statement, column: 8),
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
            finishedAt: finished,
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11))
        )
    }

    private func task(_ statement: OpaquePointer?, dependencies: [String: [String]]) -> MothxTeamTask {
        MothxTeamTask(
            id: string(statement, column: 0),
            teamRunID: string(statement, column: 1),
            agentProfileID: string(statement, column: 2),
            sessionID: nullableString(statement, column: 3),
            runID: nullableString(statement, column: 4),
            retryOf: nullableString(statement, column: 5),
            retryCount: Int(sqlite3_column_int(statement, 6)),
            title: string(statement, column: 7),
            prompt: string(statement, column: 8),
            status: MothxTeamTaskStatus(rawValue: string(statement, column: 9)) ?? .pending,
            executionMode: string(statement, column: 10),
            dependsOn: dependencies[string(statement, column: 0)] ?? [],
            result: string(statement, column: 11),
            error: string(statement, column: 12),
            startedAt: sqlite3_column_type(statement, 13) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(statement, 13)) : nil,
            finishedAt: sqlite3_column_type(statement, 14) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(statement, 14)) : nil
        )
    }

    private func jsonArray(_ values: [String]) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: values), encoding: .utf8)) ?? "[]"
    }

    private func stringArray(_ statement: OpaquePointer?, column: Int32) -> [String] {
        let raw = string(statement, column: column)
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return values
    }

    private func nullableString(_ statement: OpaquePointer?, column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : string(statement, column: column)
    }

    private func execute(_ sql: String, bindings: [String] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() { try bind(value, to: statement, index: Int32(offset + 1)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw LocalProjectStoreError.writeFailed }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw LocalProjectStoreError.prepareFailed }
        return statement
    }

    private func bind(_ value: String?, to statement: OpaquePointer?, index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else { throw LocalProjectStoreError.writeFailed }
    }

    /// Binds a date, storing NULL for nil so optional timestamps round-trip
    /// correctly (0.0 would read back as 1970-01-01).
    private func bindDate(_ date: Date?, to statement: OpaquePointer?, index: Int32) throws {
        if let date {
            guard sqlite3_bind_double(statement, index, date.timeIntervalSince1970) == SQLITE_OK else { throw LocalProjectStoreError.writeFailed }
        } else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else { throw LocalProjectStoreError.writeFailed }
        }
    }

    private func string(_ statement: OpaquePointer?, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }
}
