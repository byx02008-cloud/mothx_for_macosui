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