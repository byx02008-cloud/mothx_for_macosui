import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Client-owned project metadata. mothx remains the source of truth for
/// sessions and runs; this database only stores the desktop grouping layer.
final class LocalProjectStore {
    private var database: OpaquePointer?

    init() throws {
        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("mothxOS", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let databaseURL = supportDirectory.appendingPathComponent("projects.sqlite")
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw LocalProjectStoreError.openFailed
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                work_dir TEXT NOT NULL,
                created_at REAL NOT NULL
            )
        """)
        try execute("""
            CREATE TABLE IF NOT EXISTS project_sessions (
                session_id TEXT PRIMARY KEY NOT NULL,
                project_id TEXT NOT NULL,
                FOREIGN KEY(project_id) REFERENCES projects(id) ON DELETE CASCADE
            )
        """)
        try execute("""
            CREATE TABLE IF NOT EXISTS session_preferences (
                session_id TEXT PRIMARY KEY NOT NULL,
                model_id TEXT NOT NULL
            )
        """)
    }

    deinit { sqlite3_close(database) }

    func projects() throws -> [MothxProject] {
        let statement = try prepare("SELECT id, name, work_dir FROM projects ORDER BY created_at ASC")
        defer { sqlite3_finalize(statement) }
        var result: [MothxProject] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(MothxProject(
                id: string(statement, column: 0),
                name: string(statement, column: 1),
                workDir: string(statement, column: 2)
            ))
        }
        return result
    }

    func createProject(name: String, workDir: String) throws -> MothxProject {
        let project = MothxProject(id: UUID().uuidString.lowercased(), name: name, workDir: workDir)
        let statement = try prepare("INSERT INTO projects (id, name, work_dir, created_at) VALUES (?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(project.id, to: statement, index: 1)
        try bind(project.name, to: statement, index: 2)
        try bind(project.workDir, to: statement, index: 3)
        guard sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { throw LocalProjectStoreError.writeFailed }
        return project
    }

    func updateProject(id: String, name: String, workDir: String) throws {
        let statement = try prepare("UPDATE projects SET name = ?, work_dir = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(name, to: statement, index: 1)
        try bind(workDir, to: statement, index: 2)
        try bind(id, to: statement, index: 3)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw LocalProjectStoreError.writeFailed }
    }

    func deleteProject(id: String) throws {
        try execute("DELETE FROM project_sessions WHERE project_id = ?", bindings: [id])
        try execute("DELETE FROM projects WHERE id = ?", bindings: [id])
    }

    func assign(sessionID: String, to projectID: String) throws {
        try execute("INSERT OR REPLACE INTO project_sessions (session_id, project_id) VALUES (?, ?)", bindings: [sessionID, projectID])
    }

    func removeSession(sessionID: String) throws {
        try execute("DELETE FROM project_sessions WHERE session_id = ?", bindings: [sessionID])
        try execute("DELETE FROM session_preferences WHERE session_id = ?", bindings: [sessionID])
    }

    func setModel(_ modelID: String, for sessionID: String) throws {
        try execute("INSERT OR REPLACE INTO session_preferences (session_id, model_id) VALUES (?, ?)", bindings: [sessionID, modelID])
    }

    func model(for sessionID: String) throws -> String? {
        let statement = try prepare("SELECT model_id FROM session_preferences WHERE session_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(sessionID, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return string(statement, column: 0)
    }

    func projectIDsBySession() throws -> [String: String] {
        let statement = try prepare("SELECT session_id, project_id FROM project_sessions")
        defer { sqlite3_finalize(statement) }
        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            result[string(statement, column: 0)] = string(statement, column: 1)
        }
        return result
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

    private func bind(_ value: String, to statement: OpaquePointer?, index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else { throw LocalProjectStoreError.writeFailed }
    }

    private func string(_ statement: OpaquePointer?, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }
}

enum LocalProjectStoreError: LocalizedError {
    case openFailed, prepareFailed, writeFailed
    var errorDescription: String? { "Local project database is unavailable" }
}

struct LocalProjectStoreUnavailable: LocalizedError {
    var errorDescription: String? { "Local project database is unavailable" }
}
