import SwiftUI

/// 团队任务对话模式（右侧工作区）：
/// 输入任务 → 主 Agent 规划 → 成员并行/串行执行 → 主 Agent 汇总。
/// 顶部可重新打开「配置团队」对话框调整主/子 Agent。
struct TeamWorkspaceView: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    let teamProjectID: String?
    @State private var prompt = ""
    @State private var showSetup = false

    private var c: Copy { languageStore.copy }
    private var team: TeamRunManager { mothx.teamManager }
    private var teamProject: MothxTeamProject? {
        teamProjectID.flatMap { team.teamProject(forTeamProjectID: $0) }
    }
    private var manager: MothxAgentProfile? {
        teamProjectID.flatMap { team.managerProfile(for: $0) }
    }
    private var members: [MothxAgentProfile] {
        guard let teamProjectID else { return [] }
        return team.profiles(for: teamProjectID).filter { $0.role == .member }
    }
    private var runs: [MothxTeamRun] {
        guard let teamProjectID else { return [] }
        return team.teamRuns.filter { $0.projectID == teamProjectID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                // Composer
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: $prompt)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 70, maxHeight: 110)
                        .padding(10)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topLeading) {
                            if prompt.isEmpty {
                                Text(c.teamPromptPlaceholder).font(.system(size: 13)).foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.vertical, 14).allowsHitTesting(false)
                            }
                        }
                    HStack(spacing: 10) {
                        TeamProfileSummary(manager: manager, members: members)
                        Spacer()
                        if let error = team.errorMessage {
                            Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                        }
                        if team.isBusy {
                            ProgressView().controlSize(.small)
                        }
                        Button {
                            guard let teamProjectID, let text = trimmedPrompt else { return }
                            prompt = ""
                            Task { await team.startTeamRun(projectID: teamProjectID, prompt: text) }
                        } label: {
                            Label(team.isBusy ? c.statusRunning : c.startTeamRunTitle, systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(team.isBusy || manager == nil || members.filter(\.enabled).isEmpty || trimmedPrompt == nil)
                    }
                    if manager == nil || members.isEmpty {
                        Text(manager == nil ? c.teamNoManager : c.teamNoMembers)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Run history
                Text(c.teamProjectRuns).sectionLabel()
                if runs.isEmpty {
                    Spacer()
                    Text(c.teamRunEmpty).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(runs) { run in
                                TeamRunCard(run: run, taskProvider: { team.teamTasksByRun[run.id] ?? [] }, retryTask: { taskID in
                                    Task { await team.retryTask(runID: run.id, taskID: taskID) }
                                }, cancelRun: {
                                    Task { await team.cancelTeamRun(runID: run.id) }
                                })
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
        }
        .padding(.top, 1)
        .sheet(isPresented: $showSetup) {
            if let teamProject {
                TeamSetupSheet(teamProject: teamProject, isPresented: $showSetup)
            }
        }
        .onAppear { prompt = "" }
    }

    private var header: some View {
        HStack {
            Label(c.teamTask, systemImage: "person.3")
                .font(.system(size: 14, weight: .medium))
            Text("· \(teamProject?.name ?? "")").font(.system(size: 14)).foregroundStyle(.secondary)
            Spacer()
            Button {
                showSetup = true
            } label: {
                Label(c.configureTeam, systemImage: "gearshape")
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight()
            .foregroundStyle(.secondary)
            .help(c.configureTeam)
        }
        .padding(.horizontal, 24)
        .frame(height: 54)
    }

    private var trimmedPrompt: String? {
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private struct TeamProfileSummary: View {
    @EnvironmentObject private var languageStore: LanguageStore
    let manager: MothxAgentProfile?
    let members: [MothxAgentProfile]

    var body: some View {
        let c = languageStore.copy
        return HStack(spacing: 8) {
            Label(manager?.name ?? c.teamNoManager, systemImage: "person.crop.circle.fill")
                .font(.caption).foregroundStyle(.orange)
            Label("\(members.count) \(c.roleMember)", systemImage: "person.2")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct TeamRunCard: View {
    @EnvironmentObject private var languageStore: LanguageStore
    let run: MothxTeamRun
    let taskProvider: () -> [MothxTeamTask]
    let retryTask: (String) -> Void
    let cancelRun: () -> Void
    @State private var expanded = false

    private var c: Copy { languageStore.copy }
    private var tasks: [MothxTeamTask] { taskProvider() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TeamStatusBadge(status: run.status, language: languageStore.language)
                Text(run.userPrompt).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer()
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
                if run.status.isTerminal, let finishedAt = run.finishedAt {
                    Text("· \(Int(finishedAt.timeIntervalSince(run.startedAt)))s")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !run.status.isTerminal && run.status != .planningFailed && run.status != .failed {
                    Button(action: cancelRun) {
                        Image(systemName: "stop.circle").foregroundStyle(.red.opacity(0.85))
                    }.buttonStyle(.plain).help(c.cancelTeamRun)
                }
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            if !run.error.isEmpty {
                Text("\(c.teamRunErrorLabel)：\(run.error)").font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tasks) { task in
                        TeamTaskRow(task: task, retry: { retryTask(task.id) })
                    }
                    if !run.finalAnswer.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text(c.finalAnswer).font(.system(size: 12, weight: .semibold))
                            Text(run.finalAnswer).font(.callout).textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct TeamTaskRow: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    let task: MothxTeamTask
    let retry: () -> Void
    @State private var expanded = false

    private var c: Copy { languageStore.copy }
    private var agentName: String {
        mothx.teamManager.agentProfiles.first { $0.id == task.agentProfileID }?.name ?? task.agentProfileID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TaskStatusBadge(status: task.status, language: languageStore.language)
                Text(task.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(agentName).font(.caption2).foregroundStyle(.secondary)
                Text("· \(task.executionMode)")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if let startedAt = task.startedAt, let finishedAt = task.finishedAt {
                    Text("\(Int(finishedAt.timeIntervalSince(startedAt)))s").font(.caption2).foregroundStyle(.secondary)
                }
                if !task.dependsOn.isEmpty {
                    Text("\(c.teamTaskDeps): \(task.dependsOn.count)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if task.status == .failed || task.status == .canceled || task.status == .skipped {
                    Button(c.retryTaskTitle, action: retry)
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !task.prompt.isEmpty {
                        Text("Prompt").font(.caption2).foregroundStyle(.tertiary)
                        Text(task.prompt).font(.caption).textSelection(.enabled)
                    }
                    if !task.result.isEmpty {
                        Text(c.taskResultTitle).font(.caption2).foregroundStyle(.tertiary)
                        Text(task.result).font(.caption).textSelection(.enabled)
                    }
                    if !task.error.isEmpty {
                        Text(c.taskErrorTitle).font(.caption2).foregroundStyle(.red)
                        Text(task.error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if let sessionID = task.sessionID, let runID = task.runID {
                        Text("session: \(sessionID) · run: \(runID)")
                            .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                }
                .padding(.leading, 12)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct TeamStatusBadge: View {
    let status: MothxTeamRunStatus
    let language: AppLanguage
    var body: some View {
        Text(runStatusText)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
    private var color: Color {
        switch status {
        case .planning, .planned: return .blue
        case .running, .synthesizing: return .orange
        case .completed: return .green
        case .partial: return .teal
        case .planningFailed, .failed: return .red
        case .canceling, .canceled: return .gray
        }
    }
    private var runStatusText: String {
        switch status {
        case .planning: return language == .zh ? "规划中" : "Planning"
        case .planned: return language == .zh ? "已计划" : "Planned"
        case .running: return language == .zh ? "执行中" : "Running"
        case .synthesizing: return language == .zh ? "汇总中" : "Synthesizing"
        case .completed: return language == .zh ? "已完成" : "Completed"
        case .partial: return language == .zh ? "部分完成" : "Partial"
        case .planningFailed: return language == .zh ? "规划失败" : "Planning failed"
        case .failed: return language == .zh ? "失败" : "Failed"
        case .canceling: return language == .zh ? "取消中" : "Canceling"
        case .canceled: return language == .zh ? "已取消" : "Canceled"
        }
    }
}

private struct TaskStatusBadge: View {
    let status: MothxTeamTaskStatus
    let language: AppLanguage
    var body: some View {
        Text(statusText)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
    private var color: Color {
        switch status {
        case .pending, .blocked, .queued: return .gray
        case .running: return .orange
        case .completed: return .green
        case .failed: return .red
        case .canceled, .skipped: return .gray
        }
    }
    private var statusText: String {
        switch status {
        case .pending: return language == .zh ? "待启动" : "Pending"
        case .blocked: return language == .zh ? "等待依赖" : "Blocked"
        case .queued: return language == .zh ? "排队中" : "Queued"
        case .running: return language == .zh ? "运行中" : "Running"
        case .completed: return language == .zh ? "完成" : "Done"
        case .failed: return language == .zh ? "失败" : "Failed"
        case .canceled: return language == .zh ? "已取消" : "Canceled"
        case .skipped: return language == .zh ? "跳过" : "Skipped"
        }
    }
}