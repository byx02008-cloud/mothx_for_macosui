import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    @Binding var showSettings: Bool
    @Binding var selectedProjectID: String?
    @Binding var selectedSessionID: String?
    @State private var providerID = ""
    @State private var draft = MothxProviderConfig()
    @State private var modelID = ""
    @State private var discovering = false
    @State private var saved = false
    @State private var defaultProviderID = ""
    @State private var defaultModelID = ""
    @State private var defaultThinkingLevel = ""
    @State private var defaultMode = "agent"
    @State private var skillsDir = ""
    @State private var sessionDir = ""
    @State private var imageRecognition = MothxImageRecognitionConfig()
    @State private var language = "auto"
    @State private var section = "providers"
    @State private var pendingDeletion: DeletionRequest?
    private var modelIndex: Int? { draft.models.firstIndex { $0.id == modelID } }

    var body: some View {
        HStack(spacing: 0) {
            SettingsNavigation(section: $section)
            Divider()
            ScrollView { VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text(languageStore.copy.settings).font(.system(size: 22, weight: .semibold))
                    Spacer()
                    Button { showSettings = false } label: {
                        Label(languageStore.copy.closeSettings, systemImage: "xmark")
                    }.buttonStyle(.plain).hoverHighlight().foregroundStyle(.secondary)
                }
                if section == "providers" {
                    if providerID.isEmpty {
                        GlobalDefaultsSection(providers: mothx.providers, providerID: $defaultProviderID, modelID: $defaultModelID, thinkingLevel: $defaultThinkingLevel, mode: $defaultMode) { p, m, thinking, mode in Task { await mothx.saveDefaults(provider: p, model: m, thinkingLevel: thinking, mode: mode) } }
                        ProviderList(providers: mothx.providers, defaultID: defaultProviderID) { select($0) } add: { draft = MothxProviderConfig(); providerID = "new-provider"; modelID = ""; saved = false } delete: { id in pendingDeletion = .provider(id) }
                    } else {
                        let c = languageStore.copy
                        HStack { Button { providerID = "" } label: { Label(c.backToProviders, systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(.secondary); Spacer(); if saved { Text(c.saved).font(.caption).foregroundStyle(.green) }; Button(c.saveProvider) { Task { await save() } }.buttonStyle(.borderedProminent).tint(.orange).disabled(draft.id.isEmpty) }
                        Text(draft.id).font(.system(size: 26, weight: .semibold))
                        ProviderSection(provider: $draft)
                        ModelSection(provider: $draft, selectedID: $modelID, discovering: $discovering) { id, name in pendingDeletion = .model(id: id, name: name) }
                    }
                } else if section == "general" {
                    GeneralSection(language: $language, imageRecognition: $imageRecognition)
                } else if section == "skills" {
                    SkillsSection(skillsDir: $skillsDir, sessionID: selectedSessionID)
                } else if section == "sessions" {
                    SessionsSection(sessionDir: $sessionDir, showSettings: $showSettings, selectedProjectID: $selectedProjectID, selectedSessionID: $selectedSessionID, pendingDeletion: $pendingDeletion)
                } else if section == "advanced" {
                    AdvancedSettingsSection()
                } else {
                    GeneralSection(language: $language, imageRecognition: $imageRecognition)
                }
                if let error = mothx.settingsError { Text(error).font(.callout).foregroundStyle(.red) }
            }.padding(38).frame(maxWidth: 900, alignment: .leading) }.frame(maxWidth: .infinity)
        }
        .background(settingsBackground)
        .onAppear { providerID = "" }
        .confirmationDialog(languageStore.copy.deleteTitle, isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
            Button(languageStore.copy.delete, role: .destructive) {
                guard let deletion = pendingDeletion else { return }
                pendingDeletion = nil
                switch deletion {
                case .provider(let id): Task { await mothx.deleteProvider(id: id) }
                case .model(let id, _):
                    if let index = draft.models.firstIndex(where: { $0.id == id }) { draft.models.remove(at: index); if modelID == id { modelID = "" } }
                case .session(let id):
                    Task {
                        await mothx.deleteSession(id: id)
                        if selectedSessionID == id {
                            selectedSessionID = nil
                            selectedProjectID = nil
                        }
                    }
                }
            }
            Button(languageStore.copy.cancel, role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(pendingDeletion?.message(using: languageStore.copy) ?? languageStore.copy.text("此操作无法撤销。", "This action cannot be undone."))
        }
        .task { await mothx.loadSettings(); defaultProviderID = mothx.defaultProvider; defaultModelID = mothx.defaultModel; defaultThinkingLevel = mothx.defaultThinkingLevel; defaultMode = mothx.defaultMode; language = languageStore.setting; skillsDir = mothx.skillsDir; sessionDir = mothx.sessionDir; imageRecognition = mothx.imageRecognition; providerID = ""; mothx.loadGlobalSkills() }
    }
    func select(_ provider: MothxProviderConfig) { providerID = provider.id; draft = provider; modelID = provider.models.first?.id ?? ""; saved = false }
    func save() async { await mothx.saveProvider(draft, asDefault: false); saved = true }

    private var settingsBackground: Color {
        colorScheme == .light ? .white : .codexBackground
    }
}

enum DeletionRequest: Identifiable {
    case provider(String); case model(id: String, name: String); case session(String)
    var id: String { switch self { case .provider(let id): return "provider-\(id)"; case .model(let id, _): return "model-\(id)"; case .session(let id): return "session-\(id)" } }
    func message(using copy: Copy) -> String { switch self { case .provider(let name): return copy.deleteProviderMessage(name); case .model(_, let name): return copy.deleteModelMessage(name); case .session(let id): return copy.deleteSessionMessage(id.isEmpty ? nil : id) } }
}

struct ProviderList: View {
    @EnvironmentObject private var languageStore: LanguageStore
    let providers: [MothxProviderConfig]
    let defaultID: String
    let select: (MothxProviderConfig) -> Void
    let add: () -> Void
    let delete: (String) -> Void
    @State private var searchText = ""

    private var filteredProviders: [MothxProviderConfig] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return providers }
        return providers.filter { provider in
            [provider.id, provider.vendor, provider.api].contains { $0.lowercased().contains(query) }
        }
    }

    var body: some View {
        let c = languageStore.copy
        return SettingsCard(title: c.providers, subtitle: c.providerListSubtitle) {
            HStack { Text(c.allProviders).font(.headline); Spacer(); Button(action: add) { Label(c.addProvider, systemImage: "plus") }.buttonStyle(.borderedProminent).tint(.orange) }
            SearchField(text: $searchText, placeholder: c.searchProviders)
            ForEach(filteredProviders) { provider in
                ProviderRow(provider: provider, defaultID: defaultID, select: { select(provider) }, delete: { delete(provider.id) })
            }
        }
    }
}

private struct ProviderRow: View {
    let provider: MothxProviderConfig
    let defaultID: String
    let select: () -> Void
    let delete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: provider.id == defaultID ? "star.circle.fill" : "server.rack")
                .font(.title3)
                .foregroundStyle(provider.id == defaultID ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.id).font(.system(size: 14, weight: .medium))
                Text(provider.vendor.isEmpty ? provider.api : provider.vendor).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(provider.models.count) models").font(.caption).foregroundStyle(.secondary)
            if isHovered {
                Button(action: delete) {
                    Image(systemName: "trash").foregroundStyle(.red.opacity(0.8))
                }.buttonStyle(.plain).hoverHighlight()
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? Color.primary.opacity(0.22) : Color.primary.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .foregroundStyle(.primary)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: select)
    }
}

struct ProviderNavigation: View {
    let providers: [MothxProviderConfig]; @Binding var selectedID: String; let defaultID: String; let select: (MothxProviderConfig) -> Void; let add: () -> Void
    var body: some View { VStack(alignment: .leading, spacing: 10) { Text("CONFIGURATION").sectionLabel().padding(.bottom, 8); Text("Providers").font(.headline); ForEach(providers) { p in Button { select(p) } label: { HStack { Image(systemName: selectedID == p.id ? "checkmark.circle.fill" : "circle").foregroundStyle(selectedID == p.id ? .orange : .secondary); VStack(alignment: .leading) { Text(p.id); Text(p.id == defaultID ? "Default provider" : (p.vendor.isEmpty ? p.api : p.vendor)).font(.caption).foregroundStyle(p.id == defaultID ? .orange : .secondary) }; Spacer() }.padding(9).background(selectedID == p.id ? Color.primary.opacity(0.1) : .clear).clipShape(RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain) }; Spacer(); Button(action: add) { Label("Add provider", systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(.orange) }.padding(22).frame(width: 230).background(Color.codexSidebar) }
}

struct SettingsNavigation: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var languageStore: LanguageStore
    @Binding var section: String
    var body: some View { let c = languageStore.copy; return VStack(alignment: .leading, spacing: 8) { Text(c.settings.uppercased()).sectionLabel().padding(.bottom, 10); SettingsNavItem(title: c.general, icon: "gearshape", id: "general", section: $section); SettingsNavItem(title: c.providers, icon: "server.rack", id: "providers", section: $section); SettingsNavItem(title: c.skills, icon: "sparkles", id: "skills", section: $section); SettingsNavItem(title: c.sessions, icon: "clock", id: "sessions", section: $section); SettingsNavItem(title: c.advancedSettings, icon: "wrench.and.screwdriver", id: "advanced", section: $section); Spacer() }.padding(22).frame(width: 230).background(colorScheme == .light ? .white : .codexSidebar) }
}

struct SettingsNavItem: View { let title: String; let icon: String; let id: String; @Binding var section: String
    var body: some View { Button { section = id } label: { Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(section == id ? Color.primary.opacity(0.1) : .clear).clipShape(RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle()) }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading).hoverHighlight().foregroundStyle(section == id ? .primary : .secondary) }
}

struct GlobalDefaultsSection: View {
    @EnvironmentObject private var languageStore: LanguageStore
    let providers: [MothxProviderConfig]
    @Binding var providerID: String
    @Binding var modelID: String
    @Binding var thinkingLevel: String
    @Binding var mode: String
    let save: (String, String, String, String) -> Void

    private var selectedProvider: MothxProviderConfig? { providers.first { $0.id == providerID } }
    private var models: [MothxModelConfig] { selectedProvider?.models ?? [] }

    var body: some View {
        let c = languageStore.copy
        return SettingsCard(title: c.globalDefaults, subtitle: c.text("对应 settings.json 的 defaultProvider / defaultModel", "settings.json defaultProvider / defaultModel")) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(c.defaultProvider).font(.caption).foregroundStyle(.secondary)
                    Picker(c.defaultProvider, selection: $providerID) {
                        Text(c.selectProvider).tag("")
                        ForEach(providers) { provider in Text(provider.id).tag(provider.id) }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(c.defaultModel).font(.caption).foregroundStyle(.secondary)
                    Picker(c.defaultModel, selection: $modelID) {
                        Text(c.selectModel).tag("")
                        ForEach(models) { model in Text(model.displayName).tag(model.id) }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading).disabled(models.isEmpty)
                }
                Button(c.saveDefaults) { save(providerID, modelID, thinkingLevel, mode) }.buttonStyle(.borderedProminent).tint(.orange).disabled(providerID.isEmpty || modelID.isEmpty)
            }
            .onChange(of: providerID) { _, newProviderID in
                guard let first = providers.first(where: { $0.id == newProviderID })?.models.first else { modelID = ""; return }
                if !providers.first(where: { $0.id == newProviderID })!.models.contains(where: { $0.id == modelID }) { modelID = first.id }
            }
            HStack(spacing: 12) {
                Text(c.thinkingLevel).font(.caption).foregroundStyle(.secondary)
                Picker("Thinking level", selection: $thinkingLevel) {
                    Text(c.defaultThinkingLevelLabel).tag("")
                    Text(c.off).tag("off")
                    Text(c.minimal).tag("minimal")
                    Text(c.low).tag("low")
                    Text(c.medium).tag("medium")
                    Text(c.high).tag("high")
                    Text(c.xhigh).tag("xhigh")
                }.labelsHidden().frame(width: 150)
                Text(c.mode).font(.caption).foregroundStyle(.secondary)
                Picker(c.mode, selection: $mode) { Text(c.agent).tag("agent"); Text(c.plan).tag("plan"); Text(c.yolo).tag("yolo") }.pickerStyle(.segmented).frame(width: 220)
            }
            Text(c.text("选择 Provider 后，Model 列表会自动切换为该 Provider 的 models 配置。", "The model list follows the selected provider.")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct GeneralSection: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    @Binding var language: String
    @Binding var imageRecognition: MothxImageRecognitionConfig

    var body: some View {
        let c = languageStore.copy
        return VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: c.general, subtitle: c.text("常规设置，对应 settings.json 的 tuilang", "General settings, stored in settings.json as tuilang")) {
                HStack {
                    Text(c.language)
                    Spacer()
                    Picker(c.language, selection: $language) {
                        Text("中文").tag("zh")
                        Text("English").tag("en")
                        Text("Auto").tag("auto")
                        Text("Global").tag("global")
                    }.frame(width: 180)
                    Button(c.save) {
                        Task {
                            if await mothx.saveLanguage(language) {
                                languageStore.update(setting: language)
                            }
                        }
                    }.buttonStyle(.borderedProminent).tint(.orange)
                }
                Text(c.text("语言值会同时保存到本地配置和 mothx settings.json 的 tuilang 字段。", "The language value is saved to the local app settings and mothx settings.json as tuilang.")).font(.caption).foregroundStyle(.secondary)
            }

            ImageRecognitionSection(config: $imageRecognition)
            AboutSection()
        }
    }
}

struct ImageRecognitionSection: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    @Binding var config: MothxImageRecognitionConfig

    private var selectedProvider: MothxProviderConfig? {
        mothx.providers.first { $0.id == config.providerID }
    }

    private var models: [MothxModelConfig] {
        selectedProvider?.models ?? []
    }

    var body: some View {
        let c = languageStore.copy
        return SettingsCard(
            title: c.text("图片识别", "Image Recognition"),
            subtitle: c.text(
                "配置后优先使用这里选择的模型识别图片，再把识别结果交给当前工作模型；未配置时才尝试当前多模态模型直传。",
                "When configured, this model is used first to describe images and its result is passed to the active model; without it, a multimodal active model is used directly."
            )
        ) {
            Toggle(c.text("启用独立图片识别模型", "Enable dedicated image recognition model"), isOn: $config.enabled)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(c.text("识别 Provider", "Recognition Provider")).font(.caption).foregroundStyle(.secondary)
                    Picker(c.text("识别 Provider", "Recognition Provider"), selection: $config.providerID) {
                        Text(c.selectProvider).tag("")
                        ForEach(mothx.providers) { provider in
                            Text(provider.id).tag(provider.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(c.text("识别模型", "Recognition Model")).font(.caption).foregroundStyle(.secondary)
                    Picker(c.text("识别模型", "Recognition Model"), selection: $config.modelID) {
                        Text(c.selectModel).tag("")
                        ForEach(models) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(models.isEmpty)
                }
            }
            .onChange(of: config.providerID) { _, newProviderID in
                let providerModels = mothx.providers.first(where: { $0.id == newProviderID })?.models ?? []
                if !providerModels.contains(where: { $0.id == config.modelID }) {
                    config.modelID = providerModels.first?.id ?? ""
                }
            }
            Text(c.text(
                "只保存 Provider/Model 的选择，不复制或保存 API Key。首次使用时，如果服务端没有把所选识别模型标记为 image，客户端会自动补齐该能力标记，然后再提交图片。",
                "Only the Provider/Model selection is stored; API keys are not copied. On first use, the app adds the image capability to the selected recognition model if the server catalog omitted it, then submits the image."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            Button(c.text("保存图片识别设置", "Save image recognition settings")) {
                mothx.saveImageRecognition(config)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(config.enabled && (config.providerID.isEmpty || config.modelID.isEmpty))
        }
    }
}

private enum GlobalSkillTab: Hashable {
    case system
    case custom
}

struct SkillsSection: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    @Binding var skillsDir: String
    let sessionID: String?
    @State private var selectedSkillKey: String?
    @State private var selectedTab: GlobalSkillTab = .system
    @State private var content = ""
    @State private var isLoadingContent = false
    @State private var isSaving = false
    @State private var saved = false
    @State private var errorMessage: String?
    @State private var showSkillMarket = false

    private var visibleSkills: [MothxSkill] {
        selectedTab == .system ? mothx.systemSkills : mothx.customSkills
    }

    var body: some View {
        let c = languageStore.copy
        return VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: c.skills, subtitle: c.text("管理全局 SKILL.md；项目技能仍在对应项目目录中维护。", "Manage global SKILL.md files; project skills remain in their project directories.")) {
                SettingsField(title: c.skillsDirectory, text: $skillsDir, placeholder: c.defaultSkillsDir)
                Text(c.skillHubHint).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(c.saveSkills) {
                        Task {
                            await mothx.saveSkillsAndSession(skillsDir: skillsDir, sessionDir: mothx.sessionDir)
                            mothx.loadGlobalSkills()
                        }
                    }.buttonStyle(.borderedProminent).tint(.orange)
                    Button {
                        mothx.loadGlobalSkills()
                    } label: { Label(c.text("刷新全局技能", "Refresh global skills"), systemImage: "arrow.clockwise") }.buttonStyle(.bordered)
                    Spacer()
                    Button {
                        showSkillMarket = true
                    } label: {
                        Label(c.text("安装技能", "Install skill"), systemImage: "plus.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
            }

            SettingsCard(title: c.text("技能列表", "Skill list"), subtitle: c.text("系统技能来自 ~/.agents/skills，自定义技能来自 ~/.mothx/skills。点击技能可查看和编辑 SKILL.md。", "System skills are loaded from ~/.agents/skills; custom skills are loaded from ~/.mothx/skills. Select a skill to inspect and edit its SKILL.md.")) {
                Picker("", selection: $selectedTab) {
                    Text(c.text("系统技能", "System skills")).tag(GlobalSkillTab.system)
                    Text(c.text("自定义技能", "Custom skills")).tag(GlobalSkillTab.custom)
                }
                .pickerStyle(.segmented)

                Divider()

                if visibleSkills.isEmpty {
                    Text(selectedTab == .system
                         ? c.text("暂无系统技能", "No system skills found")
                         : c.text("暂无自定义技能", "No custom skills found"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleSkills) { skill in
                        VStack(alignment: .leading, spacing: 8) {
                            GlobalSkillRow(skill: skill, selected: selectedSkillKey == skill.directory) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedSkillKey = selectedSkillKey == skill.directory ? nil : skill.directory
                                }
                            }
                            if selectedSkillKey == skill.directory {
                                GlobalSkillDetail(
                                    skill: skill,
                                    content: $content,
                                    isLoadingContent: $isLoadingContent,
                                    isSaving: $isSaving,
                                    saved: $saved,
                                    errorMessage: $errorMessage,
                                    loadContent: loadContent,
                                    canUninstall: selectedTab == .custom,
                                    uninstall: uninstallCustomSkill
                                )
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                }
            }
        }
        .task {
            mothx.loadGlobalSkills()
        }
        .onChange(of: selectedTab) { _, _ in
            selectedSkillKey = nil
            content = ""
            errorMessage = nil
            saved = false
        }
        .sheet(isPresented: $showSkillMarket) {
            SkillMarketSheet(sessionID: sessionID)
                .environmentObject(mothx)
                .environmentObject(languageStore)
        }
    }

    private func loadContent(_ skill: MothxSkill) {
        isLoadingContent = true
        saved = false
        errorMessage = nil
        content = mothx.skillContent(skill) ?? ""
        if content.isEmpty {
            errorMessage = languageStore.copy.text("无法读取 SKILL.md。", "Unable to read SKILL.md.")
        }
        isLoadingContent = false
    }

    private func uninstallCustomSkill(_ skill: MothxSkill) {
        let error = mothx.uninstallCustomSkill(skill)
        if let error {
            errorMessage = error
            return
        }
        selectedSkillKey = nil
        content = ""
        errorMessage = nil
        saved = false
    }
}

private struct GlobalSkillDetail: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    let skill: MothxSkill
    @Binding var content: String
    @Binding var isLoadingContent: Bool
    @Binding var isSaving: Bool
    @Binding var saved: Bool
    @Binding var errorMessage: String?
    let loadContent: (MothxSkill) -> Void
    let canUninstall: Bool
    let uninstall: (MothxSkill) -> Void
    @State private var showUninstallConfirmation = false

    var body: some View {
        let c = languageStore.copy
        VStack(alignment: .leading, spacing: 10) {
            if isLoadingContent {
                ProgressView(c.text("正在读取技能…", "Loading skill…"))
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text(c.text("描述", "Description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(mothx.skillDescription(from: content) ?? c.text("未定义描述", "No description defined"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.primary.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                Text(c.text("SKILL.md 内容", "SKILL.md content"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120, maxHeight: 200)
                    .padding(6)
                    .background(Color.primary.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12)))
                HStack {
                    if saved { Text(c.saved).font(.caption).foregroundStyle(.green) }
                    if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
                    Spacer()
                    if canUninstall {
                        Button(role: .destructive) {
                            showUninstallConfirmation = true
                        } label: {
                            Label(c.text("卸载", "Uninstall"), systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSaving)
                    }
                    Button(c.save) {
                        isSaving = true
                        saved = false
                        errorMessage = nil
                        Task {
                            let error = mothx.saveGlobalSkillContent(skill, content: content)
                            await MainActor.run {
                                isSaving = false
                                errorMessage = error
                                saved = error == nil
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(isSaving || content.isEmpty)
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.1)))
        .task(id: skill.id) {
            loadContent(skill)
        }
        .confirmationDialog(
            c.text("卸载技能？", "Uninstall skill?"),
            isPresented: $showUninstallConfirmation,
            titleVisibility: .visible
        ) {
            Button(c.text("卸载", "Uninstall"), role: .destructive) {
                uninstall(skill)
            }
            Button(c.cancel, role: .cancel) { }
        } message: {
            Text(c.text(
                "将删除该技能目录及其中的文件，此操作无法撤销。",
                "The skill directory and its files will be deleted. This action cannot be undone."
            ))
        }
    }
}

private struct GlobalSkillRow: View {
    let skill: MothxSkill
    let selected: Bool
    let select: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack")
                .foregroundStyle(selected ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.name).font(.system(size: 14, weight: .medium))
                Text(skill.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.orange.opacity(0.12) : (isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: select)
    }
}

struct SessionsSection: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    @Binding var sessionDir: String
    @Binding var showSettings: Bool
    @Binding var selectedProjectID: String?
    @Binding var selectedSessionID: String?
    @Binding var pendingDeletion: DeletionRequest?

    private var allSessions: [MothxSession] { (mothx.sessions + Array(mothx.pendingSessions.values)).sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") } }

    var body: some View {
        let c = languageStore.copy
        return VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: c.sessions, subtitle: c.text("对应 settings.json 的 sessionDir", "settings.json sessionDir")) {
                SettingsField(title: c.sessionDirectory, text: $sessionDir, placeholder: c.defaultSessionDir)
                Button(c.saveSessions) { Task { await mothx.saveSkillsAndSession(skillsDir: mothx.skillsDir, sessionDir: sessionDir) } }.buttonStyle(.borderedProminent).tint(.orange)
            }
            SettingsCard(title: c.allSessions, subtitle: c.allSessionsSubtitle) {
                if allSessions.isEmpty { Text(c.noSessions).font(.callout).foregroundStyle(.secondary) }
                ForEach(allSessions) { session in
                    SessionRecordRow(
                        session: session,
                        subtitle: session.projectID == nil ? c.unassignedSession : c.projectSession,
                        viewTitle: c.text("查看", "View"),
                        deleteTitle: c.delete
                    ) {
                        selectedSessionID = session.id
                        selectedProjectID = session.projectID
                        showSettings = false
                    } delete: { pendingDeletion = .session(session.id) }
                }
            }
        }
    }
}

private struct SessionRecordRow: View {
    let session: MothxSession
    let subtitle: String
    let viewTitle: String
    let deleteTitle: String
    let view: () -> Void
    let delete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)

            if isHovered {
                Button(action: view) {
                    Image(systemName: "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .hoverHighlight()
                .help(viewTitle)

                Button(action: delete) {
                    Image(systemName: "trash").foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .hoverHighlight()
                .help(deleteTitle)
                .transition(.opacity)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

private struct AdvancedSettingsSection: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    @AppStorage("mothxOS.reuseExistingService") private var reuseExistingService = false
    @AppStorage(MothxAgentTransport.defaultsKey) private var agentTransport = MothxAgentTransport.acp.rawValue

    var body: some View {
        let c = languageStore.copy
        return VStack(alignment: .leading, spacing: 16) {
            SettingsCard(
                title: c.text("Agent 连接方式", "Agent transport"),
                subtitle: c.text("ACP 直接承载对话运行；Serve API 继续负责设置、项目、历史与统计。", "ACP carries agent runs directly; the Serve API still manages settings, projects, history, and statistics.")
            ) {
                Picker(c.text("连接方式", "Transport"), selection: $agentTransport) {
                    Text(c.text("ACP（实验性）", "ACP (Experimental)"))
                        .tag(MothxAgentTransport.acp.rawValue)
                    Text("Serve API")
                        .tag(MothxAgentTransport.serve.rawValue)
                }
                .pickerStyle(.segmented)
                Text(c.text("ACP 为此分支的默认方式。图片或显式选择 Skill 时会自动回退 Serve API。", "ACP is the default on this branch. Image input or explicitly selected Skills automatically fall back to the Serve API."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: agentTransport) { _, value in
                if value == MothxAgentTransport.serve.rawValue {
                    Task { await mothx.stopACPClient() }
                }
            }
            SettingsCard(title: c.advancedSettings, subtitle: c.advancedSettingsSubtitle) {
            Button {
                NSWorkspace.shared.open(mothx.advancedTestURL)
            } label: {
                Label(c.openAdvancedSettings, systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            }
            SettingsCard(title: c.reuseExistingService, subtitle: c.reuseExistingServiceSubtitle) {
                Toggle(c.reuseExistingServiceToggle, isOn: $reuseExistingService)
            }
        }
    }
}

struct ProviderSection: View { @EnvironmentObject private var languageStore: LanguageStore; @Binding var provider: MothxProviderConfig
    var body: some View { let c = languageStore.copy; return SettingsCard(title: c.provider, subtitle: c.text("对应 providers.<providerId>", "providers.<providerId>")) { SettingsField(title: c.providerID, text: $provider.id, placeholder: "openai"); SettingsField(title: c.vendor, text: $provider.vendor, placeholder: "optional adapter name"); SettingsField(title: c.apiProtocol, text: $provider.api, placeholder: "openai-chat"); SettingsField(title: c.baseURL, text: $provider.baseUrl, placeholder: "https://api.example.com/v1"); SettingsField(title: c.apiKey, text: $provider.apiKey, placeholder: "${PROVIDER_API_KEY}", secure: true); SettingsField(title: c.httpProxy, text: $provider.httpProxy, placeholder: "optional"); Toggle(c.forceHTTP11, isOn: $provider.forceHTTP11); SettingsField(title: c.thinkingFormat, text: $provider.thinkingFormat, placeholder: "optional") } }
}

struct ModelSection: View { @EnvironmentObject private var mothx: MothxServiceManager; @EnvironmentObject private var languageStore: LanguageStore; @Binding var provider: MothxProviderConfig; @Binding var selectedID: String; @Binding var discovering: Bool; let delete: (String, String) -> Void
    @State private var selectedIndex: Int?
    @State private var searchText = ""
    private var filteredIndices: [Int] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return Array(provider.models.indices) }
        return provider.models.indices.filter { index in
            let model = provider.models[index]
            return model.id.lowercased().contains(query) || model.displayName.lowercased().contains(query)
        }
    }
    var body: some View { let c = languageStore.copy; return SettingsCard(title: c.models, subtitle: c.text("对应 providers.<providerId>.models", "providers.<providerId>.models")) { HStack { Text(c.configuredModels).font(.headline); Spacer(); Button { provider.models.insert(MothxModelConfig(id: "new-model", name: "New model"), at: 0); selectedIndex = 0 } label: { Label(c.addModel, systemImage: "plus") }.buttonStyle(.bordered); Button { Task { discovering = true; let discovered = await mothx.discoverModels(provider: provider); /* Full sync: replace the stored catalog with the models the API actually reports, dropping stale/discontinued ones. Keep the local catalog untouched when discovery returns nothing. */ if !discovered.isEmpty { let previousID = selectedIndex.flatMap { index in provider.models.indices.contains(index) ? provider.models[index].id : nil }; provider.models = discovered; await mothx.saveProvider(provider, asDefault: false); if let previousID = previousID, let index = provider.models.firstIndex(where: { $0.id == previousID }) { selectedIndex = index } else { selectedIndex = provider.models.isEmpty ? nil : 0 } }; discovering = false } } label: { Label(discovering ? c.text("获取中…", "Discovering…") : c.discover, systemImage: "arrow.triangle.2.circlepath") }.buttonStyle(.bordered).disabled(provider.baseUrl.isEmpty) }; if provider.models.isEmpty { Text(c.noModelsHint).font(.callout).foregroundStyle(.secondary) } else { SearchField(text: $searchText, placeholder: c.searchModels); ForEach(filteredIndices, id: \.self) { index in ModelRow(model: $provider.models[index], selected: selectedIndex == index) { selectedIndex = index } delete: { if selectedIndex == index { selectedIndex = nil }; delete(provider.models[index].id, provider.models[index].displayName) } } } } }
}

private struct SearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct ModelRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var model: MothxModelConfig
    let selected: Bool
    let select: () -> Void
    let delete: () -> Void
    @State private var isHovered = false

    var body: some View { VStack(alignment: .leading, spacing: 12) { HStack { Image(systemName: selected ? "chevron.down" : "chevron.right").font(.caption); Text(model.displayName).font(.system(size: 14, weight: .medium)); Text(model.id).font(.caption).foregroundStyle(.secondary); Spacer(); if model.reasoning { Text("Reasoning").font(.caption2).foregroundStyle(.orange) }; Button(action: delete) { Image(systemName: "trash").foregroundStyle(.red.opacity(0.8)) }.buttonStyle(.plain) }.foregroundStyle(.primary); if selected { HStack { SettingsField(title: "Model ID", text: $model.id); SettingsField(title: "Name", text: $model.name) }; HStack { NumberField(title: "Context window", value: $model.contextWindow); NumberField(title: "Max tokens", value: $model.maxTokens) }; if model.contextWindow <= 0 { Text("API 未提供该模型的上下文上限，请根据运营商文档手动填写。\nThe API did not provide this model's context limit; enter it from the provider documentation.").font(.caption).foregroundStyle(.orange) }; Toggle("Reasoning", isOn: $model.reasoning); Text("Input: \(model.input.isEmpty ? "text" : model.input.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) } }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(selected ? Color.primary.opacity(0.08) : (isHovered ? Color.primary.opacity(0.08) : (colorScheme == .light ? .white : .codexCard))).clipShape(RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle()).onHover { isHovered = $0 }.onTapGesture(perform: select) }
}

struct NumberField: View { let title: String; @Binding var value: Int
    var body: some View { HStack { Text(title); Spacer(); TextField("0", value: $value, format: .number).textFieldStyle(.plain).frame(width: 100).multilineTextAlignment(.trailing) }.padding(10).background(Color.primary.opacity(0.18)).clipShape(RoundedRectangle(cornerRadius: 6)) }
}

struct SettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content
        }
        .padding(18)
        .background(colorScheme == .light ? .white : .codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(colorScheme == .light ? 0.14 : 0.1), lineWidth: 1)
        }
    }
}

struct SettingsField: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    @Binding var text: String
    var placeholder = ""
    var secure = false

    var body: some View { HStack { Text(title).frame(width: 150, alignment: .leading); if secure { SecureField(placeholder, text: $text).textFieldStyle(.plain) } else { TextField(placeholder, text: $text).textFieldStyle(.plain) } }.padding(10).background(colorScheme == .light ? .white : Color.primary.opacity(0.18)).clipShape(RoundedRectangle(cornerRadius: 6)) }
}

// MARK: - SkillHub marketplace sheet

private struct SkillMarketViewError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private enum SkillMarketTab: Hashable {
    case official
    case community
}

private struct SkillMarketSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    let sessionID: String?

    @State private var query = ""
    @State private var selectedTab: SkillMarketTab = .official
    @State private var items: [MothxSkillHubSummary] = []
    @State private var selectedItem: MothxSkillHubSummary?
    @State private var detail: MothxSkillHubDetail?
    @State private var page = 1
    @State private var total = 0
    @State private var pageSize = 20
    @State private var isLoading = false
    @State private var isLoadingDetail = false
    @State private var actionKey: String?
    @State private var errorMessage: String?
    @State private var listRequestID = 0

    private var totalPages: Int { max(1, Int(ceil(Double(total) / Double(max(pageSize, 1))))) }
    private var currentSummary: MothxSkillHubSummary? {
        guard let selectedItem else { return nil }
        return items.first(where: { $0.key == selectedItem.key }) ?? selectedItem
    }
    private var installedState: MothxSkillHubInstalledState? {
        detail?.summary.installed ?? currentSummary?.installed
    }

    var body: some View {
        let c = languageStore.copy
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.text("技能市场", "Skill marketplace"))
                        .font(.system(size: 20, weight: .semibold))
                    Text("skillhub.cn")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("", selection: $selectedTab) {
                    Text(c.text("官方技能", "Official")).tag(SkillMarketTab.official)
                    Text(c.text("社区技能", "Community")).tag(SkillMarketTab.community)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                Spacer()
                TextField(c.text("搜索技能", "Search skills"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit { startSearch() }
                Button(c.text("搜索", "Search")) { startSearch() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                Button(c.cancel) { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(20)
            Divider()

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(c.text("技能列表", "Skills"))
                            .font(.headline)
                        Spacer()
                        if isLoading { ProgressView().controlSize(.small) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider()
                    if items.isEmpty && !isLoading {
                        VStack(spacing: 8) {
                            Image(systemName: "shippingbox")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text(c.text("暂无技能", "No skills found"))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(items, id: \.key) { item in
                                    SkillMarketRow(
                                        item: item,
                                        selected: selectedItem?.key == item.key,
                                        select: { select(item) }
                                    )
                                    Divider().padding(.leading, 16)
                                }
                            }
                        }
                    }

                    Divider()
                    HStack(spacing: 10) {
                        Button {
                            changePage(page - 1)
                        } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.bordered)
                        .disabled(isLoading || page <= 1)
                        Text(c.text("第 \(page) / \(totalPages) 页", "Page \(page) of \(totalPages)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            changePage(page + 1)
                        } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.bordered)
                        .disabled(isLoading || page >= totalPages)
                        Spacer()
                        Text(c.text("共 \(total) 个", "\(total) total"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
                .frame(width: 360)
                .background(Color.primary.opacity(0.025))

                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    if isLoadingDetail {
                        Spacer()
                        ProgressView(c.text("正在读取技能详情…", "Loading skill details…"))
                        Spacer()
                    } else if let detail {
                        SkillMarketDetail(
                            detail: detail,
                            installedState: installedState,
                            isActing: actionKey == detail.summary.key,
                            canInstall: !(sessionID?.isEmpty ?? true),
                            install: { install(detail.summary) },
                            uninstall: { uninstall(detail.summary) }
                        )
                    } else {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "sidebar.right")
                                .font(.system(size: 30))
                                .foregroundStyle(.secondary)
                            Text(c.text("选择一个技能查看详情", "Select a skill to view details"))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(errorMessage).lineLimit(2)
                    Spacer()
                    Button { self.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                }
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.red.opacity(0.08))
            }
        }
        .frame(minWidth: 1060, minHeight: 680)
        .task { beginListLoad() }
        .onChange(of: selectedTab) { _, _ in
            page = 1
            selectedItem = nil
            detail = nil
            beginListLoad()
        }
    }

    private func startSearch() {
        page = 1
        beginListLoad()
    }

    private func changePage(_ newPage: Int) {
        guard newPage >= 1, newPage <= totalPages else { return }
        page = newPage
        beginListLoad()
    }

    private func beginListLoad() {
        listRequestID += 1
        let requestID = listRequestID
        Task { await loadList(requestID: requestID) }
    }

    private func select(_ item: MothxSkillHubSummary) {
        selectedItem = item
        detail = nil
        Task { await loadDetail(item) }
    }

    private func loadList(requestID: Int) async {
        isLoading = true
        errorMessage = nil
        do {
            let response: MothxSkillHubListResponse
            switch selectedTab {
            case .official:
                response = try await mothx.loadSkillHubOfficial(query: query, page: page, limit: 20, sessionID: sessionID)
            case .community:
                response = try await mothx.loadSkillHubCommunity(query: query, page: page, limit: 20, sessionID: sessionID)
            }
            guard requestID == listRequestID else { return }
            items = response.items
            page = response.page
            pageSize = max(response.pageSize, 1)
            total = response.total
            if let selectedItem,
               let refreshed = response.items.first(where: { $0.key == selectedItem.key }) {
                self.selectedItem = refreshed
                await loadDetail(refreshed)
            } else if let first = response.items.first {
                selectedItem = first
                await loadDetail(first)
            } else {
                selectedItem = nil
                detail = nil
            }
        } catch {
            guard requestID == listRequestID else { return }
            errorMessage = error.localizedDescription
        }
        if requestID == listRequestID {
            isLoading = false
        }
    }

    private func loadDetail(_ item: MothxSkillHubSummary) async {
        guard selectedItem?.key == item.key else { return }
        isLoadingDetail = true
        do {
            let loadedDetail = try await mothx.loadSkillHubDetail(market: item.market, skillID: item.id)
            if selectedItem?.key == item.key {
                detail = loadedDetail
            }
        } catch {
            if selectedItem?.key == item.key {
                errorMessage = error.localizedDescription
            }
        }
        isLoadingDetail = false
    }

    private func install(_ item: MothxSkillHubSummary) {
        guard let sessionID, !sessionID.isEmpty else {
            errorMessage = MothxSkillHubClientError.sessionRequired.localizedDescription
            return
        }
        guard actionKey == nil else { return }
        actionKey = item.key
        errorMessage = nil
        Task {
            do {
                let targets = try await mothx.loadSkillHubTargets(sessionID: sessionID)
                guard let target = targets.targets.first(where: { $0.scope == "global" }) else {
                    throw SkillMarketViewError(message: languageStore.copy.text("服务端没有可用的全局技能目录。", "The server did not provide a global skills directory."))
                }
                try await mothx.installSkillHubSkill(
                    market: item.market,
                    skillID: item.id,
                    version: item.version,
                    scope: target.scope,
                    targetDir: target.path,
                    sessionID: sessionID,
                    activate: false
                )
                mothx.loadGlobalSkills()
                beginListLoad()
            } catch {
                errorMessage = error.localizedDescription
            }
            actionKey = nil
        }
    }

    private func uninstall(_ item: MothxSkillHubSummary) {
        guard let installedState, !installedState.scope.isEmpty else { return }
        guard actionKey == nil else { return }
        actionKey = item.key
        errorMessage = nil
        Task {
            do {
                try await mothx.uninstallSkillHubSkill(
                    market: item.market,
                    skillID: item.id,
                    scope: installedState.scope,
                    sessionID: sessionID
                )
                mothx.loadGlobalSkills()
                beginListLoad()
            } catch {
                errorMessage = error.localizedDescription
            }
            actionKey = nil
        }
    }
}

private struct SkillMarketRow: View {
    let item: MothxSkillHubSummary
    let selected: Bool
    let select: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.installed?.installed == true ? "checkmark.circle.fill" : "sparkles")
                .foregroundStyle(item.installed?.installed == true ? .green : (selected ? .orange : .secondary))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(item.id).lineLimit(1)
                    if !item.version.isEmpty { Text("v\(item.version)") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if item.installed?.installed == true {
                Text("已安装")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.orange.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

private struct SkillMarketDetail: View {
    @EnvironmentObject private var languageStore: LanguageStore
    let detail: MothxSkillHubDetail
    let installedState: MothxSkillHubInstalledState?
    let isActing: Bool
    let canInstall: Bool
    let install: () -> Void
    let uninstall: () -> Void

    private var c: Copy { languageStore.copy }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(detail.summary.title)
                            .font(.system(size: 21, weight: .semibold))
                            .textSelection(.enabled)
                        Text(detail.summary.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        HStack(spacing: 10) {
                            if !detail.summary.version.isEmpty { Text("v\(detail.summary.version)") }
                            if !detail.summary.category.isEmpty { Text(detail.summary.category) }
                            if !detail.summary.author.isEmpty { Text(detail.summary.author) }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if installedState?.installed == true {
                        VStack(alignment: .trailing, spacing: 6) {
                            Label(c.text("已安装", "Installed"), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            if let scope = installedState?.scope, !scope.isEmpty {
                                Text(scope)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Button(role: .destructive, action: uninstall) {
                                if isActing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label(c.text("卸载", "Uninstall"), systemImage: "trash")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isActing)
                        }
                    } else {
                        VStack(alignment: .trailing, spacing: 6) {
                            Button(action: install) {
                                if isActing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label(c.text("安装", "Install"), systemImage: "arrow.down.circle")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .disabled(isActing || !canInstall)
                            if !canInstall {
                                Text(c.text("请先打开一个会话", "Open a session before installing"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !detail.summary.description.isEmpty {
                    SkillMarketTextSection(title: c.text("描述", "Description"), text: detail.summary.description)
                }
                if !detail.readme.isEmpty {
                    SkillMarketTextSection(title: c.text("使用说明", "Usage"), text: detail.readme)
                }
                if let evaluation = detail.evaluation {
                    SkillMarketMarkdownSection(
                        title: c.text("评估 / 使用说明", "Evaluation / usage notes"),
                        markdown: evaluation.markdownDocument()
                    )
                }
                if let reports = detail.securityReports {
                    SkillMarketMarkdownSection(
                        title: c.text("安全说明", "Security reports"),
                        markdown: reports.markdownDocument()
                    )
                }
                if !detail.downloadSources.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(c.text("下载源", "Download sources"))
                            .font(.headline)
                        ForEach(Array(detail.downloadSources.enumerated()), id: \.offset) { _, source in
                            HStack(spacing: 8) {
                                Image(systemName: source.fallback ? "arrow.triangle.2.circlepath" : "arrow.down.circle")
                                    .foregroundStyle(.secondary)
                                if let url = URL(string: source.url) {
                                    Link(source.kind.isEmpty ? source.url : source.kind, destination: url)
                                        .lineLimit(1)
                                } else {
                                    Text(source.url).lineLimit(1)
                                }
                                if source.fallback { Text(c.text("备用", "fallback")).font(.caption2).foregroundStyle(.secondary) }
                            }
                            .font(.caption)
                        }
                    }
                }
                if !detail.files.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(c.text("文件列表", "Files"))
                            .font(.headline)
                        ForEach(detail.files, id: \.path) { file in
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                Text(file.path)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                if file.size > 0 {
                                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

private struct SkillMarketMarkdownSection: View {
    let title: String
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            MarkdownMessageText(markdown: markdown)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.primary.opacity(0.045))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct SkillMarketTextSection: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(text)
                .font(.system(.body, design: .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.primary.opacity(0.045))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
