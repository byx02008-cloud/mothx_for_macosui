import SwiftUI

/// 团队任务对话界面（右侧工作区）——类会话的多轮对话：
/// - 底部常驻对话录入框（一个任务内可多次提问，如同会话）；
/// - 每一轮提问对应一次团队运行（轨迹 + 最终答案）；
/// - 只自动展开最新一轮；新一轮开始后，上一轮的轨迹与答案自动收起；
/// - 点击轨迹在当前页面打开只读会话 Tab，查看对应成员/主 Agent 的完整过程。
struct TeamWorkspaceView: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    let teamProjectID: String?
    @State private var showSetup = false
    @State private var prompt = ""
    @State private var readOnlySessionID: String?
    /// 当前展开的一轮运行 id（只展开一轮）。
    @State private var expandedRunID: String?
    /// 每秒刷新，用于执行动态里的实时耗时。
    @State private var now = Date()

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
    /// 展示顺序与聊天一致：从旧到新。
    private var chronologicalRuns: [MothxTeamRun] { runs.reversed() }
    private var newestRunID: String? { runs.first?.id }

    var body: some View {
        VStack(spacing: 0) {
            if let readOnlySessionID {
                readOnlyTabHeader(sessionID: readOnlySessionID)
            } else {
                header
            }
            Divider()

            if let readOnlySessionID {
                WorkspaceView(
                    prompt: .constant(""),
                    sessionID: readOnlySessionID,
                    readOnly: true
                )
            } else if runs.isEmpty {
                VStack {
                    Spacer()
                    Text(c.teamRunEmpty).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(chronologicalRuns) { run in
                                TeamRunCard(
                                    run: run,
                                    expanded: expandedRunID == run.id,
                                    now: now,
                                    taskProvider: { team.teamTasksByRun[run.id] ?? [] },
                                    onToggle: {
                                        withAnimation(.easeInOut(duration: 0.18)) {
                                            expandedRunID = expandedRunID == run.id ? nil : run.id
                                        }
                                    },
                                    onOpenSession: { sessionID in
                                        readOnlySessionID = sessionID
                                    },
                                    retryTask: { taskID in
                                        Task { await team.retryTask(runID: run.id, taskID: taskID) }
                                    },
                                    cancelRun: {
                                        Task { await team.cancelTeamRun(runID: run.id) }
                                    }
                                )
                                .id(run.id)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 16)
                        .frame(maxWidth: 820, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: expandedRunID) { _, newID in
                        guard let newID else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(newID, anchor: .bottom) }
                    }
                }
            }

            if readOnlySessionID == nil {
                // 常驻对话录入框（多轮对话入口）
                composer
                    .frame(maxWidth: 820)
                    .padding(.horizontal, 25)
                    .padding(.bottom, 16)
            }
        }
        .padding(.top, 1)
        .sheet(isPresented: $showSetup) {
            if let teamProject {
                TeamSetupSheet(teamProject: teamProject, isPresented: $showSetup)
            }
        }
        .onAppear {
            prompt = ""
            expandedRunID = newestRunID
        }
        .onChange(of: newestRunID) { _, newID in
            // 新一轮开始：自动展开最新一轮，上一轮随之收起。
            guard let newID else { return }
            expandedRunID = newID
        }
        .task {
            // 实时时钟：驱动执行动态的“已运行时长”。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $prompt)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 64, maxHeight: 110)
                .padding(10)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                }
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text(c.teamPromptPlaceholder).font(.system(size: 13)).foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.vertical, 14).allowsHitTesting(false)
                    }
                }
            HStack(spacing: 10) {
                TeamProfileSummary(manager: manager, members: members)
                Spacer()
                if let error = team.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                if team.isBusy { ProgressView().controlSize(.small) }
                Button {
                    guard let teamProjectID, let text = trimmedPrompt else { return }
                    prompt = ""
                    Task { await team.startTeamRun(projectID: teamProjectID, prompt: text) }
                } label: {
                    Label((team.isBusy || (teamProjectID.map { team.hasActiveRun(for: $0) } ?? false)) ? c.statusRunning : c.startTeamRunTitle, systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(team.isBusy || (teamProjectID.map { team.hasActiveRun(for: $0) } ?? false) || manager == nil || members.filter(\.enabled).isEmpty || trimmedPrompt == nil)
            }
            if manager == nil || members.isEmpty {
                Text(manager == nil ? c.teamNoManager : c.teamNoMembers)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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

    private func readOnlyTabHeader(sessionID: String) -> some View {
        HStack(spacing: 8) {
            Button {
                readOnlySessionID = nil
            } label: {
                Label(c.teamTask, systemImage: "person.3")
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .hoverHighlight()

            Divider().frame(height: 22)

            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.orange)
                Text(mothx.sessions.first(where: { $0.id == sessionID })?.title ?? c.teamTaskDetail)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Button {
                    readOnlySessionID = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .hoverHighlight()
                .help(c.close)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))

            Spacer()
        }
        .padding(.horizontal, 18)
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

/// 一轮团队运行的卡片：头部常驻；展开后展示轨迹（任务序列 + 主 Agent 汇总）
/// 与最终答案。点击轨迹跳转到对应会话查看详情。
private struct TeamRunCard: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    let run: MothxTeamRun
    let expanded: Bool
    let now: Date
    let taskProvider: () -> [MothxTeamTask]
    let onToggle: () -> Void
    let onOpenSession: (String) -> Void
    let retryTask: (String) -> Void
    let cancelRun: () -> Void

    private var c: Copy { languageStore.copy }
    private var team: TeamRunManager { mothx.teamManager }
    private var tasks: [MothxTeamTask] { taskProvider() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 头部：状态 + 问题 + 时间 + 展开/收起
            HStack(spacing: 10) {
                TeamStatusBadge(status: run.status, language: languageStore.language)
                Text(run.userPrompt).font(.system(size: 13, weight: .medium)).lineLimit(2)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                    if let finishedAt = run.finishedAt {
                        Text("\(Int(finishedAt.timeIntervalSince(run.startedAt)))s")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !run.status.isTerminal && run.status != .planningFailed && run.status != .failed {
                    Button(action: cancelRun) {
                        Image(systemName: "stop.circle").foregroundStyle(.red.opacity(0.85))
                    }.buttonStyle(.plain).help(c.cancelTeamRun)
                }
                Button(action: onToggle) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            if !run.error.isEmpty {
                Text("\(c.teamRunErrorLabel)：\(run.error)").font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            if expanded {
                // 执行动态：谁在做什么（实时）＋ 时间
                RunActivityList(run: run, tasks: tasks, profiles: team.agentProfiles, language: languageStore.language, now: now)

                // 轨迹：任务序列
                VStack(alignment: .leading, spacing: 6) {
                    Text(c.teamTrajectoryTitle).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(tasks) { task in
                        TaskTrajectoryRow(task: task, agentName: agentName(for: task)) {
                            if let sessionID = task.sessionID { onOpenSession(sessionID) }
                        } retry: {
                            retryTask(task.id)
                        }
                    }
                    // 主 Agent 汇总轨迹
                    if let managerSessionID = run.managerSessionID {
                        Button {
                            onOpenSession(managerSessionID)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "person.crop.circle.fill").foregroundStyle(.orange).font(.system(size: 12))
                                Text(c.managerSynthesis).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Circle().fill(runStatusColor).frame(width: 6, height: 6)
                                Image(systemName: "arrow.up.right.square").font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight()
                        .help(c.teamTaskDetail)
                    }
                }

                // 最终答案（与会话消息一致：Markdown 预览）
                if !run.finalAnswer.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(c.finalAnswer).font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                        MarkdownMessageText(markdown: run.finalAnswer)
                    }
                    .padding(10)
                }
            } else if !run.finalAnswer.isEmpty {
                // 收起状态：仅一行答案预览
                Text(run.finalAnswer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        }
    }

    private func agentName(for task: MothxTeamTask) -> String {
        team.agentProfiles.first { $0.id == task.agentProfileID }?.name ?? task.agentProfileID
    }

    private var runStatusColor: Color {
        switch run.status {
        case .planning, .planned: return .blue
        case .running, .synthesizing: return .orange
        case .completed: return .green
        case .partial: return .teal
        case .planningFailed, .failed: return .red
        case .canceling, .canceled: return .gray
        }
    }
}

/// 执行动态：把“谁正在做什么 + 时间”实时展示出来。
/// - 主 Agent：规划中 / 等待成员结果 / 汇总中 / 汇总完成；
/// - 成员：正在执行某任务（含开始时、实时耗时）/ 等待中 / 已完成 / 失败 / 已取消。
private struct RunActivityList: View {
    @EnvironmentObject private var languageStore: LanguageStore
    let run: MothxTeamRun
    let tasks: [MothxTeamTask]
    let profiles: [MothxAgentProfile]
    let language: AppLanguage
    let now: Date

    private var c: Copy { languageStore.copy }

    private struct ActivityRow: Identifiable {
        let id: String
        let name: String
        let statusText: String
        let timeText: String
        let color: Color
    }

    private var rows: [ActivityRow] {
        var result: [ActivityRow] = []
        let managerName = profiles.first { $0.id == run.managerAgentID }?.name ?? c.roleManager
        let manager = managerRow(name: managerName)
        result.append(manager)

        let tasksByAgent = Dictionary(grouping: tasks, by: { $0.agentProfileID })
        for agentID in tasksByAgent.keys.sorted() {
            guard let profile = profiles.first(where: { $0.id == agentID }) else { continue }
            result.append(memberRow(profile: profile, tasks: tasksByAgent[agentID] ?? []))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(c.teamActivityTitle).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Circle().fill(row.color).frame(width: 7, height: 7)
                    Text(row.name).fontWeight(.medium).lineLimit(1)
                    Text(row.statusText).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(row.timeText).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 主 Agent 动态

    private func managerRow(name: String) -> ActivityRow {
        switch run.status {
        case .planning:
            return ActivityRow(id: "manager", name: name, statusText: c.activityPlanning, timeText: activeTime(run.updatedAt), color: .orange)
        case .planned, .running:
            return ActivityRow(id: "manager", name: name, statusText: c.activityWaitingMembers, timeText: "", color: .gray)
        case .synthesizing:
            return ActivityRow(id: "manager", name: name, statusText: c.activitySynthesizing, timeText: activeTime(run.updatedAt), color: .orange)
        case .completed, .partial:
            return ActivityRow(id: "manager", name: name, statusText: c.activitySummaryDone, timeText: doneTime(run.finishedAt ?? run.updatedAt), color: .green)
        case .planningFailed:
            return ActivityRow(id: "manager", name: name, statusText: c.teamRunPlanningFailed, timeText: "", color: .red)
        case .failed:
            return ActivityRow(id: "manager", name: name, statusText: c.statusFailed, timeText: "", color: .red)
        case .canceling:
            return ActivityRow(id: "manager", name: name, statusText: c.activityCanceling, timeText: activeTime(run.updatedAt), color: .orange)
        case .canceled:
            return ActivityRow(id: "manager", name: name, statusText: c.statusCancelled, timeText: doneTime(run.finishedAt ?? run.updatedAt), color: .gray)
        }
    }

    // MARK: - 成员动态

    private func memberRow(profile: MothxAgentProfile, tasks: [MothxTeamTask]) -> ActivityRow {
        let id = profile.id
        if let running = tasks.first(where: { $0.status == .running }) {
            return ActivityRow(id: id, name: profile.name, statusText: c.activityRunning(running.title), timeText: activeTime(running.startedAt), color: .orange)
        }
        if tasks.contains(where: { $0.status == .pending || $0.status == .blocked || $0.status == .queued }) {
            return ActivityRow(id: id, name: profile.name, statusText: c.activityWaiting, timeText: "", color: .gray)
        }
        if tasks.contains(where: { $0.status == .failed }) {
            return ActivityRow(id: id, name: profile.name, statusText: c.statusFailed, timeText: finishedTime(tasks), color: .red)
        }
        if tasks.contains(where: { $0.status == .canceled || $0.status == .skipped }) {
            return ActivityRow(id: id, name: profile.name, statusText: c.statusCancelled, timeText: finishedTime(tasks), color: .gray)
        }
        return ActivityRow(id: id, name: profile.name, statusText: c.statusCompleted, timeText: finishedTime(tasks), color: .green)
    }

    // MARK: - 时间格式化

    /// “开始于 14:03 · 1m 20s”实时耗时。
    private func activeTime(_ start: Date?) -> String {
        guard let start else { return "" }
        let started = Self.timeFormatter.string(from: start)
        let elapsed = formatElapsedShort(max(0, now.timeIntervalSince(start)), language: language)
        return "\(c.activityStartedAt(started)) · \(elapsed)"
    }

    /// “完成于 14:05”。
    private func doneTime(_ end: Date) -> String {
        c.activityDoneAt(Self.timeFormatter.string(from: end))
    }

    private func finishedTime(_ tasks: [MothxTeamTask]) -> String {
        guard let latest = tasks.compactMap(\.finishedAt).max() else { return "" }
        return doneTime(latest)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// 轨迹中的单条任务：点击跳转到该任务的会话界面查看详情。
private struct TaskTrajectoryRow: View {
    @EnvironmentObject private var languageStore: LanguageStore
    let task: MothxTeamTask
    let agentName: String
    let open: () -> Void
    let retry: () -> Void
    @State private var isHovered = false

    private var c: Copy { languageStore.copy }
    private var hasSession: Bool { task.sessionID != nil }

    var body: some View {
        HStack(spacing: 8) {
            TrajectoryStatusDot(status: task.status, language: languageStore.language)
            Text(task.title).lineLimit(1)
            Text(agentName).foregroundStyle(.secondary)
            Spacer()
            if let startedAt = task.startedAt, let finishedAt = task.finishedAt {
                Text("\(Int(finishedAt.timeIntervalSince(startedAt)))s").foregroundStyle(.secondary)
            }
            if (task.status == .canceled || task.status == .skipped),
               task.retryCount < MothxTeamTask.maxRetries {
                Button(c.retryTaskTitle, action: retry)
                    .buttonStyle(.bordered).controlSize(.small)
            }
            if hasSession {
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(isHovered ? .orange : .secondary)
            }
        }
        .padding(7)
        .background(isHovered ? Color.primary.opacity(0.1) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { if hasSession { open() } }
        .help(hasSession ? c.teamTaskDetail : "")
    }
}

struct TrajectoryStatusDot: View {
    let status: MothxTeamTaskStatus
    let language: AppLanguage
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
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
    private var text: String {
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
