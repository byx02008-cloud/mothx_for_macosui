import Foundation

/// One entry of the mothx tool catalog surfaced by `GET /api/capabilities`.
///
/// The `tools` array accepted by `POST /api/sessions/{sessionID}/runs` only
/// toggles the local capability tools (`browser`, `a2aMaster`, `delegate`,
/// `multiAgent`, `workflows`); hosted tools such as `webSearch` are ignored by
/// the server. This model mirrors exactly that set so the Agent 工具 multi-select
/// always offers names mothx can actually call.
struct MothxAgentTool: Identifiable, Hashable {
    /// API tool id used in the run submission `tools` array.
    let id: String
    /// Whether the serve runtime currently supports the tool.
    var available: Bool
    /// Whether the tool is enabled by default for new sessions.
    var isDefault: Bool
}