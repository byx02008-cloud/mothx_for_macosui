import SwiftUI
import AppKit

/// 新建/编辑团队任务的配置对话框（侧边栏顶部「团队任务」+ 号或任务行齿轮触发）。
///
/// - 新建：输入任务名称，配置主 Agent 与成员 Agent；「创建并进入团队任务」会先在
///   mothx 中创建真实的 Project（团队任务相当于项目），再进入团队任务对话模式。
/// - 编辑：沿用已有团队任务，可改名称与成员配置。
struct TeamSetupSheet: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    /// nil = 新建团队任务；非 nil = 编辑已有任务。
    let teamProject: MothxTeamProject?
    @Binding var isPresented: Bool
    /// 创建成功后的回调（携带创建好的团队任务）。
    var onCreated: ((MothxTeamProject) -> Void)? = nil
    @State private var taskName = ""
    @State private var draftProjectID = UUID().uuidString.lowercased()
    @State private var editingAgent: MothxAgentProfile?
    @State private var creating = false

    private var c: Copy { languageStore.copy }
    private var team: TeamRunManager { mothx.teamManager }
    private var isCreating: Bool { teamProject == nil }
    /// Profile/运行的归属 id：新建时用草稿 id，创建成功后再固化为团队任务 id。
    private var activeProjectID: String { teamProject?.id ?? draftProjectID }
    private var manager: MothxAgentProfile? { team.managerProfile(for: activeProjectID) }
    private var members: [MothxAgentProfile] { team.profiles(for: activeProjectID).filter { $0.role == .member } }
    private var validName: String { taskName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isCreating ? c.newTeamTask : c.configureTeam).font(.title2.bold())
                    Text(c.teamQueueSubtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(c.cancel) { cancel() }.buttonStyle(.bordered)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsCard(title: c.taskName, subtitle: c.text("该任务在 mothx 中以项目形式存在，成员会话都归到它下面", "This task exists as a mothx project; all member sessions are grouped under it")) {
                        TextField(c.taskNamePlaceholder, text: $taskName)
                            .textFieldStyle(.roundedBorder)
                    }

                    // 主 Agent
                    SettingsCard(title: c.managerAgent, subtitle: c.oneManagerPerProject) {
                        if let manager {
                            AgentSummaryRow(profile: manager) {
                                editingAgent = manager
                            }
                        } else {
                            Text(c.noManagerConfigured).font(.callout).foregroundStyle(.secondary)
                        }
                        Button {
                            editingAgent = MothxAgentProfile.new(projectID: activeProjectID, role: .manager)
                        } label: {
                            Label(manager == nil ? c.addManager : c.editAgent, systemImage: manager == nil ? "person.fill.badge.plus" : "pencil")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }

                    // 成员 Agent
                    SettingsCard(title: c.memberAgent, subtitle: c.text("成员可并行/串行执行不同任务，配置独立", "Members can run tasks in parallel/serial with independent configurations")) {
                        if members.isEmpty {
                            Text(c.noMembersConfigured).font(.callout).foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 10) {
                                ForEach(members) { member in
                                    AgentSummaryRow(profile: member) {
                                        editingAgent = member
                                    }
                                }
                            }
                        }
                        AddMemberButton {
                            editingAgent = MothxAgentProfile.new(projectID: activeProjectID, role: .member)
                        }
                    }
                }
            }

            Divider()
            HStack {
                if let error = team.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text(isCreating ? c.finishAndEnterTeamHint : c.text("修改将立即保存", "Changes are saved immediately"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if creating { ProgressView().controlSize(.small) }
                Button(isCreating ? c.createAndEnterTeam : c.save) {
                    Task { await confirm() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(!canConfirm)
            }
        }
        .padding(24)
        .frame(width: 640, height: 620)
        .onAppear {
            taskName = teamProject?.name ?? ""
            editingAgent = nil
        }
        .sheet(isPresented: Binding(get: { editingAgent != nil }, set: { if !$0 { editingAgent = nil } })) {
            if let editingAgent {
                AgentEditorSheet(profile: editingAgent, projectID: activeProjectID, isPresented: Binding(get: { self.editingAgent != nil }, set: { if !$0 { self.editingAgent = nil } }))
            }
        }
    }

    private var canConfirm: Bool {
        guard !validName.isEmpty else { return false }
        guard manager != nil, !members.isEmpty else { return false }
        return true
    }

    private func confirm() async {
        if isCreating {
            creating = true
            let project = await team.createTeamProject(name: validName, id: draftProjectID)
            creating = false
            guard let project else { return }
            isPresented = false
            onCreated?(project)
        } else if let teamProject {
            await team.renameTeamProject(id: teamProject.id, name: validName)
            isPresented = false
        }
    }

    private func cancel() {
        // 仅显式取消时清理草稿（不依赖 onDisappear，避免 macOS 上误触发导致
        // 已创建的团队任务被草稿清理删除）；管理器层也有保护不会删真实任务。
        if isCreating { Task { await team.discardTeamProjectDraft(id: draftProjectID) } }
        isPresented = false
    }
}

/// 虚线边框的"新增成员"按钮
private struct AddMemberButton: View {
    @EnvironmentObject private var languageStore: LanguageStore
    @Environment(\.colorScheme) private var colorScheme
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let c = languageStore.copy
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 14))
                Text(c.addMember)
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(isHovered ? .orange : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .background(Color.white.opacity(colorScheme == .light ? 1.0 : 0.0))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundColor(isHovered ? .orange : Color.primary.opacity(colorScheme == .light ? 0.2 : 0.3))
        )
        .onHover { isHovered = $0 }
    }
}

private struct AgentSummaryRow: View {
    @EnvironmentObject private var languageStore: LanguageStore
    @Environment(\.colorScheme) private var colorScheme
    let profile: MothxAgentProfile
    let edit: () -> Void
    @State private var isHovered = false

    private var cardBackground: Color {
        colorScheme == .light ? .white : Color(nsColor: .underPageBackgroundColor)
    }

    var body: some View {
        let c = languageStore.copy
        return Button(action: edit) {
            HStack(spacing: 14) {
                // Circular icon with colored background
                ZStack {
                    Circle()
                        .fill(profile.role == .manager ? Color.orange.opacity(0.12) : Color.primary.opacity(0.08))
                        .frame(width: 40, height: 40)
                    Image(systemName: profile.role == .manager ? "person.crop.circle.fill" : "person.crop.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(profile.role == .manager ? .orange : .secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(summary(c: c))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Status badge
                Text(profile.enabled ? c.enabledBadge : c.disabledBadge)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(profile.enabled ? Color.green.opacity(0.14) : Color.primary.opacity(0.08))
                    .foregroundStyle(profile.enabled ? .green : .secondary)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(colorScheme == .light ? 0.12 : 0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private func summary(c: Copy) -> String {
        let model = profile.modelID.isEmpty ? c.defaultProviderLabel : profile.modelID
        let provider = profile.providerID.isEmpty ? "" : "\(profile.providerID)/"
        let workDir = profile.workDir.isEmpty ? "" : " · \(profile.workDir)"
        if !profile.summary.isEmpty {
            return "\(provider)\(model)\(workDir) · \(profile.summary)"
        }
        return "\(provider)\(model)\(workDir)"
    }
}

/// 单个 Agent 编辑：名称/角色/Provider/Model/工作目录/模式/工具/Skills/
/// 最大迭代次数/启用状态，以及针对该 Agent 的一次性测试运行。
struct AgentEditorSheet: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    @Environment(\.colorScheme) private var colorScheme
    @State var profile: MothxAgentProfile
    let projectID: String
    @Binding var isPresented: Bool
    @State private var selectedTools: Set<String> = []
    @State private var selectedSkills: Set<String> = []
    /// Skills scoped to the Agent's own working directory (like the workspace's
    /// project-local skill list) plus disk/global and server-known skills.
    @State private var agentSkillOptions: [MothxSkill] = []
    /// Skills that are not project-local and can be added into the Agent's workDir.
    @State private var addableSkillOptions: [MothxSkill] = []
    @State private var skillActionMessage: String?
    @State private var testResult: String?
    @State private var testError: String?
    @State private var isTesting = false
    @State private var saved = false

    private var providerIDs: [String] { mothx.providers.map(\.id).sorted() }
    private var models: [MothxModelConfig] {
        mothx.providers.first(where: { $0.id == profile.providerID })?.models ?? []
    }

    var body: some View {
        let c = languageStore.copy
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(profile.role == .manager ? c.managerAgent : c.memberAgent).font(.title2.bold())
                Spacer()
                if saved { Text(c.saved).font(.caption).foregroundStyle(.green) }
                Button(c.cancel) { isPresented = false }.buttonStyle(.bordered)
                Button(c.saveAgent) { save() }.buttonStyle(.borderedProminent).tint(.orange).disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profile.providerID.isEmpty || profile.modelID.isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // MARK: - 基本信息
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsField(title: c.agentName, text: $profile.name)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(c.agentSummary).font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $profile.summary)
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 54, maxHeight: 90)
                                .padding(8)
                                .background(colorScheme == .light ? .white : Color(nsColor: .underPageBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.primary.opacity(colorScheme == .light ? 0.14 : 0.1), lineWidth: 1)
                                )
                                .overlay(alignment: .topLeading) {
                                    if profile.summary.isEmpty {
                                        Text(c.agentSummaryPlaceholder).font(.system(size: 13)).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.vertical, 10).allowsHitTesting(false)
                                    }
                                }
                        }

                        HStack {
                            Text(c.agentRole).frame(width: 150, alignment: .leading)
                            Picker(c.agentRole, selection: $profile.role) {
                                Text(c.roleManager).tag(MothxAgentRole.manager)
                                Text(c.roleMember).tag(MothxAgentRole.member)
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(profile.role == .manager)
                        }
                        .padding(10)
                        .background(colorScheme == .light ? .white : Color(nsColor: .underPageBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(colorScheme == .light ? 0.14 : 0.1), lineWidth: 1)
                        )
                    }

                    // MARK: - Provider / Model
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(c.agentProvider).font(.caption).foregroundStyle(.secondary)
                                Picker(c.agentProvider, selection: $profile.providerID) {
                                    Text(c.defaultProviderLabel).tag("")
                                    ForEach(providerIDs, id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden()
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            VStack(alignment: .leading, spacing: 7) {
                                Text(c.agentModel).font(.caption).foregroundStyle(.secondary)
                                Picker(c.agentModel, selection: $profile.modelID) {
                                    Text(c.defaultProviderLabel).tag("")
                                    ForEach(models) { model in Text(model.displayName).tag(model.id) }
                                }
                                .labelsHidden()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .disabled(models.isEmpty || profile.providerID.isEmpty)
                            }
                        }
                        .onChange(of: profile.providerID) { _, newID in
                            guard let provider = mothx.providers.first(where: { $0.id == newID }) else {
                                profile.modelID = ""
                                return
                            }
                            if !provider.models.contains(where: { $0.id == profile.modelID }) {
                                profile.modelID = provider.models.first?.id ?? ""
                            }
                        }

                        HStack(spacing: 8) {
                            SettingsField(title: c.agentWorkDir, text: $profile.workDir)
                            Button(c.chooseDirectory) { chooseWorkDirectory() }.buttonStyle(.bordered)
                        }

                        HStack(spacing: 16) {
                            Text(c.agentMode).font(.caption).foregroundStyle(.secondary)
                            Picker(c.agentMode, selection: $profile.mode) {
                                Text(c.agent).tag("agent")
                                Text(c.plan).tag("plan")
                                Text(c.yolo).tag("yolo")
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 240)
                        }
                        .padding(10)
                        .background(colorScheme == .light ? .white : Color(nsColor: .underPageBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(colorScheme == .light ? 0.14 : 0.1), lineWidth: 1)
                        )
                    }
                    .padding(16)
                    .background(colorScheme == .light ? .white : Color(nsColor: .underPageBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.primary.opacity(colorScheme == .light ? 0.12 : 0.1), lineWidth: 1)
                    )

                    // MARK: - 工具与配置
                    VStack(alignment: .leading, spacing: 10) {
                        AgentMultiSelectField(
                            title: c.agentTools,
                            hint: c.agentToolsHint,
                            items: mothx.toolCatalog.filter(\.available).map { ($0.id, c.agentToolLabel($0.id)) },
                            selection: $selectedTools,
                            emptyText: c.noAvailableTools
                        )
                        AgentMultiSelectField(
                            title: c.agentSkills,
                            hint: c.agentSkillsHint,
                            items: agentSkillOptions.filter { $0.scope == .local }.map { ($0.name, $0.name) },
                            selection: $selectedSkills,
                            emptyText: c.noAvailableSkills
                        )
                        AgentSkillAddSection(
                            addable: addableSkillOptions,
                            workDir: profile.workDir,
                            action: { addSkill($0) }
                        )
                        if let skillActionMessage {
                            Text(skillActionMessage).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }

                        HStack {
                            Text(c.agentMaxIterations).frame(width: 150, alignment: .leading)
                            TextField("", value: $profile.maxIterations, format: .number)
                                .textFieldStyle(.plain)
                                .frame(width: 120)
                        }
                        .padding(10)
                        .background(colorScheme == .light ? .white : Color(nsColor: .underPageBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(colorScheme == .light ? 0.14 : 0.1), lineWidth: 1)
                        )

                        Toggle(c.agentEnabledTitle, isOn: $profile.enabled)
                        Text(c.agentEnabledHint).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(colorScheme == .light ? .white : Color(nsColor: .underPageBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.primary.opacity(colorScheme == .light ? 0.12 : 0.1), lineWidth: 1)
                    )

                    // MARK: - 测试运行
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(c.testRunAgent).font(.headline)
                            Spacer()
                            Button {
                                Task { await runTest() }
                            } label: {
                                Label(isTesting ? c.testRunInProgress : c.testRunAgent, systemImage: "play")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .disabled(isTesting || profile.providerID.isEmpty || profile.modelID.isEmpty)
                        }
                        if let testError {
                            Text(testError).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        }
                        if let testResult {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(c.testRunResultTitle).font(.caption).foregroundStyle(.secondary)
                                ScrollView {
                                    Text(testResult).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 180)
                                .padding(10)
                                .background(Color.primary.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .padding(16)
                    .background(colorScheme == .light ? .white : Color(nsColor: .underPageBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.primary.opacity(colorScheme == .light ? 0.12 : 0.1), lineWidth: 1)
                    )
                }
            }
        }
        .padding(24)
        .frame(width: 620, height: 680)
        .onAppear {
            selectedTools = Set(profile.tools)
            selectedSkills = Set(profile.skills)
            // Keep the multi-select backed by the live mothx catalog / skills.
            if mothx.toolCatalog.isEmpty {
                Task { await mothx.loadToolCatalog() }
            }
            Task {
                await mothx.loadInstalledSkills()
                reloadAgentSkills()
            }
        }
        .onChange(of: profile.workDir) { _, _ in
            reloadAgentSkills()
        }
    }

    private func save() {
        var profile = profile
        // Persist only tool names the runtime knows; unknown tools are
        // rejected by the run submit API and would fail the run. Skills keep
        // every selected name: the run path splits server-known skills into the
        // payload and the rest into /skill directives, mirroring the workspace.
        let knownTools = mothx.toolCatalog.filter(\.available).map(\.id)
        profile.tools = Array(selectedTools).sorted().filter { knownTools.isEmpty || knownTools.contains($0) }
        profile.skills = Array(selectedSkills).sorted()
        profile.updatedAt = Date()
        profile.providerID = profile.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.modelID = profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            let success = await mothx.teamManager.saveProfile(profile)
            saved = success
            if success {
                try? await Task.sleep(for: .seconds(0.6))
                isPresented = false
            }
        }
    }

    private func runTest() async {
        isTesting = true
        testError = nil
        testResult = nil
        var profile = profile
        let knownTools = mothx.toolCatalog.filter(\.available).map(\.id)
        profile.tools = Array(selectedTools).sorted().filter { knownTools.isEmpty || knownTools.contains($0) }
        profile.skills = Array(selectedSkills).sorted()
        let testPrompt = languageStore.copy.testRunPrompt
        let result = await mothx.teamManager.testRunAgent(profile: profile, prompt: testPrompt)
        isTesting = false
        switch result {
        case .success(let text): testResult = text
        case .failure(let error): testError = "\(languageStore.copy.testRunResultTitle) 失败：\(error.localizedDescription)"
        }
    }

    private func chooseWorkDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { profile.workDir = url.path }
    }

    /// Refreshes the Agent-scoped skill options after the server list or the
    /// working directory changes, mirroring the workspace skill UI.
    private func reloadAgentSkills() {
        agentSkillOptions = mothx.skillsForAgent(workDirs: [profile.workDir])
        let localNames = Set(agentSkillOptions.filter { $0.scope == .local }.map(\.name))
        addableSkillOptions = agentSkillOptions.filter { $0.scope != .local && !localNames.contains($0.name) }
    }

    private func addSkill(_ skill: MothxSkill) {
        if let error = mothx.installSkillToProject(skill, workDir: profile.workDir) {
            skillActionMessage = error
        } else {
            skillActionMessage = languageStore.copy.addSkillSuccess(skill.name)
            reloadAgentSkills()
            selectedSkills.insert(skill.name)
        }
    }
}

/// 多选项（工具 / Skills）选择器：选项来自 mothx 接口目录，勾选式多选。
private struct AgentMultiSelectField: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let hint: String
    let items: [(id: String, label: String)]
    @Binding var selection: Set<String>
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(hint).font(.caption2).foregroundStyle(.tertiary)
            if items.isEmpty {
                Text(emptyText).font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(items, id: \.id) { item in
                            Toggle(isOn: Binding(
                                get: { selection.contains(item.id) },
                                set: { on in
                                    if on { selection.insert(item.id) } else { selection.remove(item.id) }
                                }
                            )) {
                                Text(item.label).font(.system(size: 13))
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 3)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
                .background(colorScheme == .light ? .white : Color(nsColor: .underPageBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(colorScheme == .light ? 0.14 : 0.1), lineWidth: 1)
                )
            }
        }
    }
}
/// 「添加技能」区域：与项目会话的添加技能一致，把全局/可发现的技能复制到
/// Agent 自己的工作目录（workDir/.skills 等），之后即可在勾选列表中使用。
private struct AgentSkillAddSection: View {
    @EnvironmentObject private var languageStore: LanguageStore
    @Environment(\.colorScheme) private var colorScheme
    let addable: [MothxSkill]
    let workDir: String
    let action: (MothxSkill) -> Void

    private var c: Copy { languageStore.copy }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(c.addSkill).font(.caption).foregroundStyle(.secondary)
            if addable.isEmpty {
                Text(c.noAddableSkills).font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(addable) { skill in
                            let canAdd = !workDir.isEmpty && !skill.directory.isEmpty
                            HStack(spacing: 4) {
                                Image(systemName: skill.scope == .global ? "globe" : "server.rack")
                                    .font(.system(size: 11))
                                    .foregroundStyle(skill.scope == .global ? .blue : .secondary)
                                Text(skill.name).lineLimit(1)
                                Spacer()
                                if skill.directory.isEmpty {
                                    Text(c.addSkillServerOnly).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                } else {
                                    Button { action(skill) } label: {
                                        Text(c.addSkill).font(.caption)
                                            .padding(.horizontal, 8).padding(.vertical, 4)
                                    }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    .disabled(!canAdd)
                                    .help(canAdd ? c.addSkill : c.addSkillNoWorkDir)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .background(colorScheme == .light ? .white : Color(nsColor: .underPageBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(colorScheme == .light ? 0.14 : 0.1), lineWidth: 1)
                )
                if workDir.isEmpty {
                    Text(c.addSkillNoWorkDir).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}