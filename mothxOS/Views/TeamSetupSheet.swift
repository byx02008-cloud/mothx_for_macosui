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
                            ForEach(members) { member in
                                AgentSummaryRow(profile: member) {
                                    editingAgent = member
                                }
                            }
                        }
                        Button {
                            editingAgent = MothxAgentProfile.new(projectID: activeProjectID, role: .member)
                        } label: {
                            Label(c.addMember, systemImage: "person.badge.plus")
                        }
                        .buttonStyle(.bordered)
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

private struct AgentSummaryRow: View {
    @EnvironmentObject private var languageStore: LanguageStore
    let profile: MothxAgentProfile
    let edit: () -> Void
    @State private var isHovered = false

    var body: some View {
        let c = languageStore.copy
        return HStack(spacing: 10) {
            Image(systemName: profile.role == .manager ? "person.crop.circle.fill" : "person.crop.circle")
                .foregroundStyle(profile.role == .manager ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.system(size: 13, weight: .medium))
                Text(summary(c: c)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(profile.enabled ? c.enabledBadge : c.disabledBadge)
                .font(.caption2).foregroundStyle(profile.enabled ? .green : .secondary)
            if isHovered {
                Button(action: edit) {
                    Image(systemName: "pencil").foregroundStyle(.secondary)
                }.buttonStyle(.plain).hoverHighlight().help(c.editAgent)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(isHovered ? 0.22 : 0.16))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
    @State var profile: MothxAgentProfile
    let projectID: String
    @Binding var isPresented: Bool
    @State private var toolsText = ""
    @State private var skillsText = ""
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
                VStack(alignment: .leading, spacing: 14) {
                    SettingsField(title: c.agentName, text: $profile.name)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(c.agentSummary).font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $profile.summary)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 54, maxHeight: 90)
                            .padding(8)
                            .background(Color.primary.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
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
                    .background(Color.primary.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

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
                    .background(Color.primary.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    SettingsField(title: c.agentTools, text: $toolsText)
                    SettingsField(title: c.agentSkills, text: $skillsText)

                    HStack {
                        Text(c.agentMaxIterations).frame(width: 150, alignment: .leading)
                        TextField("", value: $profile.maxIterations, format: .number)
                            .textFieldStyle(.plain)
                            .frame(width: 120)
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    Toggle(c.agentEnabledTitle, isOn: $profile.enabled)
                    Text(c.agentEnabledHint).font(.caption).foregroundStyle(.secondary)

                    Divider()
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
            }
        }
        .padding(24)
        .frame(width: 620, height: 680)
        .onAppear {
            toolsText = profile.tools.joined(separator: ", ")
            skillsText = profile.skills.joined(separator: ", ")
        }
    }

    private func save() {
        var profile = profile
        profile.tools = toolsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        profile.skills = skillsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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
        profile.tools = toolsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        profile.skills = skillsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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
}