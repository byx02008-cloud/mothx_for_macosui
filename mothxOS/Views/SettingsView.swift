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
    @State private var imageGeneration = MothxImageGenerationConfig()
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
                    GeneralSection(language: $language)
                } else if section == "imageGeneration" {
                    ImageGenerationSection(config: $imageGeneration)
                } else if section == "skills" {
                    SkillsSection(skillsDir: $skillsDir)
                } else if section == "sessions" {
                    SessionsSection(sessionDir: $sessionDir, showSettings: $showSettings, selectedProjectID: $selectedProjectID, selectedSessionID: $selectedSessionID, pendingDeletion: $pendingDeletion)
                } else if section == "advanced" {
                    AdvancedSettingsSection()
                } else {
                    AboutSection()
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
        .task { await mothx.loadSettings(); defaultProviderID = mothx.defaultProvider; defaultModelID = mothx.defaultModel; defaultThinkingLevel = mothx.defaultThinkingLevel; defaultMode = mothx.defaultMode; language = languageStore.setting; skillsDir = mothx.skillsDir; sessionDir = mothx.sessionDir; imageGeneration = mothx.imageGeneration; providerID = "" }
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
    var body: some View { let c = languageStore.copy; return VStack(alignment: .leading, spacing: 8) { Text(c.settings.uppercased()).sectionLabel().padding(.bottom, 10); SettingsNavItem(title: c.general, icon: "gearshape", id: "general", section: $section); SettingsNavItem(title: c.providers, icon: "server.rack", id: "providers", section: $section); SettingsNavItem(title: c.imageGeneration, icon: "photo", id: "imageGeneration", section: $section); SettingsNavItem(title: c.skills, icon: "sparkles", id: "skills", section: $section); SettingsNavItem(title: c.sessions, icon: "clock", id: "sessions", section: $section); SettingsNavItem(title: c.advancedSettings, icon: "wrench.and.screwdriver", id: "advanced", section: $section); SettingsNavItem(title: c.about, icon: "info.circle", id: "about", section: $section); Spacer() }.padding(22).frame(width: 230).background(colorScheme == .light ? .white : .codexSidebar) }
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
    var body: some View {
        let c = languageStore.copy
        return SettingsCard(title: c.general, subtitle: c.text("常规设置，对应 settings.json 的 tuilang", "General settings, stored in settings.json as tuilang")) {
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
    }
}

struct ImageGenerationSection: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    @Binding var config: MothxImageGenerationConfig

    var body: some View {
        let c = languageStore.copy
        return SettingsCard(title: c.imageGeneration, subtitle: c.imageGenerationSubtitle) {
            Toggle(c.imageGenerationEnabled, isOn: $config.enabled)
            SettingsField(title: c.imageGenerationProvider, text: $config.provider, placeholder: "openai")
            HStack {
                Text(c.imageGenerationAPIType).frame(width: 150, alignment: .leading)
                Picker(c.imageGenerationAPIType, selection: $config.apiType) {
                    Text(c.imageGenerationAPIImages).tag("openai-images")
                    Text(c.imageGenerationAPIResponses).tag("openai-responses")
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            SettingsField(title: c.baseURL, text: $config.baseUrl, placeholder: "https://api.openai.com/v1")
            SettingsField(title: c.imageGenerationToken, text: $config.token, placeholder: "${OPENAI_API_KEY}", secure: true)
            SettingsField(title: c.imageGenerationModel, text: $config.model, placeholder: "gpt-image-1")
            Button(c.imageGenerationSave) {
                Task { await mothx.saveImageGeneration(config) }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
    }
}

struct SkillsSection: View { @EnvironmentObject private var mothx: MothxServiceManager; @EnvironmentObject private var languageStore: LanguageStore; @Binding var skillsDir: String
    var body: some View { let c = languageStore.copy; return SettingsCard(title: c.skills, subtitle: c.text("对应 settings.json 的 skillsDir 和 skillHub", "settings.json skillsDir and skillHub")) { SettingsField(title: c.skillsDirectory, text: $skillsDir, placeholder: c.defaultSkillsDir); Text(c.skillHubHint).font(.caption).foregroundStyle(.secondary); Button(c.saveSkills) { Task { await mothx.saveSkillsAndSession(skillsDir: skillsDir, sessionDir: mothx.sessionDir) } }.buttonStyle(.borderedProminent).tint(.orange) } }
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

    var body: some View {
        let c = languageStore.copy
        return SettingsCard(title: c.advancedSettings, subtitle: c.advancedSettingsSubtitle) {
            Button {
                NSWorkspace.shared.open(mothx.advancedTestURL)
            } label: {
                Label(c.openAdvancedSettings, systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
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
    var body: some View { let c = languageStore.copy; return SettingsCard(title: c.models, subtitle: c.text("对应 providers.<providerId>.models", "providers.<providerId>.models")) { HStack { Text(c.configuredModels).font(.headline); Spacer(); Button { provider.models.insert(MothxModelConfig(id: "new-model", name: "New model"), at: 0); selectedIndex = 0 } label: { Label(c.addModel, systemImage: "plus") }.buttonStyle(.bordered); Button { Task { discovering = true; let discovered = await mothx.discoverModels(provider: provider); let existingIDs = Set(provider.models.map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }); let newModels = discovered.filter { model in let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines); return !id.isEmpty && !existingIDs.contains(id) }; if !newModels.isEmpty { provider.models.append(contentsOf: newModels); await mothx.saveProvider(provider, asDefault: false); selectedIndex = provider.models.firstIndex(where: { $0.id == newModels.first?.id }) }; discovering = false } } label: { Label(discovering ? c.text("获取中…", "Discovering…") : c.discover, systemImage: "arrow.triangle.2.circlepath") }.buttonStyle(.bordered).disabled(provider.baseUrl.isEmpty) }; if provider.models.isEmpty { Text(c.noModelsHint).font(.callout).foregroundStyle(.secondary) } else { SearchField(text: $searchText, placeholder: c.searchModels); ForEach(filteredIndices, id: \.self) { index in ModelRow(model: $provider.models[index], selected: selectedIndex == index) { selectedIndex = index } delete: { if selectedIndex == index { selectedIndex = nil }; delete(provider.models[index].id, provider.models[index].displayName) } } } } }
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

    var body: some View { VStack(alignment: .leading, spacing: 12) { HStack { Image(systemName: selected ? "chevron.down" : "chevron.right").font(.caption); Text(model.displayName).font(.system(size: 14, weight: .medium)); Text(model.id).font(.caption).foregroundStyle(.secondary); Spacer(); if model.reasoning { Text("Reasoning").font(.caption2).foregroundStyle(.orange) }; Button(action: delete) { Image(systemName: "trash").foregroundStyle(.red.opacity(0.8)) }.buttonStyle(.plain) }.foregroundStyle(.primary); if selected { HStack { SettingsField(title: "Model ID", text: $model.id); SettingsField(title: "Name", text: $model.name) }; HStack { NumberField(title: "Context window", value: $model.contextWindow); NumberField(title: "Max tokens", value: $model.maxTokens) }; Toggle("Reasoning", isOn: $model.reasoning); Text("Input: \(model.input.isEmpty ? "text" : model.input.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) } }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(selected ? Color.primary.opacity(0.08) : (isHovered ? Color.primary.opacity(0.08) : (colorScheme == .light ? .white : .codexCard))).clipShape(RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle()).onHover { isHovered = $0 }.onTapGesture(perform: select) }
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
