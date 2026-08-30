import Foundation
import SQLite3

/// Aggregated provider usage for one exact ACP run.
///
/// mothx currently persists provider usage on the assistant message entries
/// produced inside an ACP turn, while the corresponding durable Run Usage can
/// remain empty. This reader is a read-only client fallback for that schema;
/// callers must still resolve the exact durable run ID before using it.
struct MothxACPStoredUsage: Sendable {
    let input: Int
    let output: Int
    let totalTokens: Int
    let cacheRead: Int
    let cacheWrite: Int
    /// Total tokens reported by the last assistant entry in this exact turn.
    /// Unlike the aggregate above, this represents the final request context.
    let lastTotalTokens: Int
}

enum MothxACPUsageReader {
    nonisolated static func usage(sessionDirectory: String, sessionID: String, runID: String) -> MothxACPStoredUsage? {
        guard !sessionDirectory.isEmpty, !sessionID.isEmpty, !runID.isEmpty else { return nil }
        let databaseURL = URL(fileURLWithPath: sessionDirectory, isDirectory: true)
            .appendingPathComponent("sessions.db")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }

        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        guard let startSeq = turnStartSequence(database: database, sessionID: sessionID, runID: runID) else {
            return nil
        }

        let sql = """
            SELECT data
            FROM entries
            WHERE session_id = ?
              AND type = 'message'
              AND seq > ?
              AND seq < COALESCE(
                  (SELECT MIN(seq)
                   FROM entries
                   WHERE session_id = ?
                     AND type = 'turn_start'
                     AND seq > ?),
                  9223372036854775807
              )
            ORDER BY seq ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard bind(sessionID, to: statement, index: 1),
              sqlite3_bind_int64(statement, 2, startSeq) == SQLITE_OK,
              bind(sessionID, to: statement, index: 3),
              sqlite3_bind_int64(statement, 4, startSeq) == SQLITE_OK else { return nil }

        var input = 0
        var output = 0
        var totalTokens = 0
        var cacheRead = 0
        var cacheWrite = 0
        var lastTotalTokens = 0
        var foundUsage = false

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            let data = Data(String(cString: raw).utf8)
            guard let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = entry["message"] as? [String: Any],
                  (message["role"] as? String) == "assistant",
                  let usage = (message["usage"] as? [String: Any]) ?? (message["Usage"] as? [String: Any]) else {
                continue
            }
            foundUsage = true
            input += integer(usage, keys: ["input", "Input", "inputTokens", "input_tokens", "prompt_tokens"])
            output += integer(usage, keys: ["output", "Output", "outputTokens", "completion_tokens"])
            let entryTotalTokens = integer(usage, keys: ["totalTokens", "TotalTokens", "total_tokens"])
            totalTokens += entryTotalTokens
            cacheRead += integer(usage, keys: ["cacheRead", "CacheRead", "cache_read_tokens", "cached_tokens"])
            cacheWrite += integer(usage, keys: ["cacheWrite", "CacheWrite", "cache_write_tokens"])
            if entryTotalTokens > 0 { lastTotalTokens = entryTotalTokens }
        }

        guard foundUsage else { return nil }
        return MothxACPStoredUsage(
            input: input,
            output: output,
            totalTokens: totalTokens,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            lastTotalTokens: lastTotalTokens
        )
    }

    nonisolated private static func turnStartSequence(database: OpaquePointer, sessionID: String, runID: String) -> Int64? {
        let sql = """
            SELECT seq, data
            FROM entries
            WHERE session_id = ?
              AND type = 'turn_start'
            ORDER BY seq DESC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard bind(sessionID, to: statement, index: 1) else { return nil }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 1),
                  let object = try? JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as? [String: Any],
                  (object["runId"] as? String) == runID else { continue }
            return sqlite3_column_int64(statement, 0)
        }
        return nil
    }

    nonisolated private static func bind(_ value: String, to statement: OpaquePointer?, index: Int32) -> Bool {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        return sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK
    }

    nonisolated private static func integer(_ object: [String: Any], keys: [String]) -> Int {
        for key in keys {
            if let value = object[key] as? Int { return value }
            if let value = object[key] as? NSNumber { return value.intValue }
        }
        return 0
    }
}
