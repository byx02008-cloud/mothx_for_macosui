import Foundation

/// Agent role: each project has exactly one `manager` (主 Agent) and any
/// number of `member` agents. First version only supports these two roles.
enum MothxAgentRole: String, Codable, Hashable, CaseIterable {
    case manager
    case member
}

/// Fixed Agent configuration for a project. An Agent Profile is NOT a run:
/// it references a Provider/Model and lazily binds to a mothx Session on the
/// first execution. mothx remains the source of truth for sessions and runs;
/// this model and its SQLite storage are client-owned (mothxOS layer).
struct MothxAgentProfile: Identifiable, Codable, Hashable {
    var id: String
    var projectID: String
    var name: String
    var role: MothxAgentRole
    var providerID: String
    var modelID: String
    var workDir: String
    var mode: String
    var tools: [String]
    var skills: [String]
    var maxIterations: Int
    var enabled: Bool
    /// Lazy-bound mothx session; saved after the first successful run.
    var sessionID: String?
    var createdAt: Date
    var updatedAt: Date

    static func new(projectID: String, role: MothxAgentRole, id: String = UUID().uuidString.lowercased()) -> MothxAgentProfile {
        let now = Date()
        return MothxAgentProfile(
            id: id,
            projectID: projectID,
            name: role == .manager ? "项目主 Agent" : "成员 Agent",
            role: role,
            providerID: "",
            modelID: "",
            workDir: "",
            mode: "agent",
            tools: ["read", "grep", "find"],
            skills: [],
            maxIterations: 50,
            enabled: true,
            sessionID: nil,
            createdAt: now,
            updatedAt: now
        )
    }
}