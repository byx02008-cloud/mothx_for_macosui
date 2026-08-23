import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    @EnvironmentObject private var terminalStore: TerminalSessionStore
    @Binding var prompt: String
    let sessionID: String?
    @State private var attachments: [ComposerAttachment] = []
    @State private var selectedMode = "agent"
    @State private var selectedProviderID = ""
    @State private var selectedModelID = ""
    @State private var selectedSkills: Set<String> = []
    @State private var selectedTools: Set<String> = []
    @State private var attachmentError: String?
    @State private var currentTurns: [Turn] = []
    @State private var expandedTurnIDs: Set<UUID> = []
    @State private var showAllHistory = false
    @State private var isConversationAtBottom = true

    private let conversationBottomID = "conversation-bottom"

    private var currentModels: [MothxModelConfig] {
        let provider = mothx.providers.first(where: { $0.id == selectedProviderID }) ?? mothx.providers.first(where: { $0.id == mothx.defaultProvider }) ?? mothx.providers.first
        return provider?.models ?? []
    }

    var body: some View {
        let c = languageStore.copy
        return VStack(spacing: 0) {
            if terminalStore.isOpen {
                TUIPanelHeader(store: terminalStore)
                Divider()
                TerminalPanelView(store: terminalStore)
                    .id(terminalStore.sessionID)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                HStack {
                    Text(mothx.sessions.first(where: { $0.id == sessionID })?.title ?? c.workspace)
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    if let sessionID {
                        Button {
                            mothx.requestSwitch(activeRunSessionID: sessionID) {
                                terminalStore.open(sessionID: sessionID, workDir: mothx.workDir(for: sessionID))
                            }
                        } label: {
                            Label(c.terminalMode, systemImage: "terminal")
                                .font(.callout)
                                .padding(.horizontal, 8)
                                .frame(minHeight: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight()
                        .foregroundStyle(.secondary)
                        .help(c.openTerminalHelp)
                    }
                    CurrentDirectoryMenu(path: currentWorkDir)
                }.padding(.horizontal, 24).frame(height: 54)
                Divider()

                if let sessionID {
                    GeometryReader { _ in
                        ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                let isRunActive = mothx.runSessionID == sessionID && mothx.isRunning
                                let visibleTurns = showAllHistory ? currentTurns : Array(currentTurns.suffix(3))

                                ForEach(visibleTurns) { turn in
                                    TurnBlock(
                                        turn: turn,
                                        sessionID: sessionID,
                                        isExpanded: expandedTurnIDs.contains(turn.id),
                                        onToggle: { toggleTurn(turn) }
                                    )
                                }

                                // Thinking indicator + status when running but no messages yet
                                if isRunActive, currentTurns.isEmpty {
                                    if mothx.runStatus == "queued" || mothx.runStatus == "running" {
                                        ThinkingIndicator(isActive: true)
                                    }
                                    if mothx.runStatus != nil,
                                       let status = mothx.runStatus {
                                        StatusInline(
                                            status: status,
                                            elapsed: mothx.runElapsed,
                                            error: mothx.runError
                                        )
                                    }
                                }

                                if isRunActive,
                                   let thinking = mothx.thinkingBySession[sessionID],
                                   !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    ThinkingContentView(text: thinking)
                                }

                                Color.clear
                                    .frame(height: 1)
                                    .id(conversationBottomID)
                            }
                            .frame(maxWidth: 760, alignment: .leading)
                            .padding(28)
                            .frame(maxWidth: .infinity)
                            .background(
                                ConversationScrollObserver { atBottom in
                                    isConversationAtBottom = atBottom
                                }
                            )
                        }
                        .coordinateSpace(name: "conversation-scroll")
                        .onChange(of: mothx.messagesBySession[sessionID] ?? []) { _, _ in
                            scrollToBottom(reader, animated: false)
                        }
                        .onChange(of: mothx.thinkingBySession[sessionID] ?? "") { _, _ in
                            if mothx.runSessionID == sessionID, mothx.isRunning {
                                scrollToBottom(reader, animated: true)
                            }
                        }
                        .onChange(of: mothx.runStatus) { _, _ in
                            if mothx.runSessionID == sessionID, mothx.isRunning {
                                scrollToBottom(reader, animated: true)
                            }
                        }
                        .onAppear {
                            scrollToBottom(reader, animated: false)
                        }
                        .overlay(alignment: .topTrailing) {
                            if currentTurns.count > 3 {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showAllHistory.toggle()
                                        if let lastID = currentTurns.last?.id {
                                            expandedTurnIDs = [lastID]
                                        }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 15, weight: .semibold))
                                        .frame(width: 34, height: 30)
                                        .contentShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                                .padding(.top, 10)
                                .padding(.trailing, 18)
                                .help(showAllHistory ? "隐藏历史对话 / Hide history" : "显示历史对话 / Show history")
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if !isConversationAtBottom {
                                ConversationScrollButton(isRunning: mothx.runSessionID == sessionID && mothx.isRunning) {
                                    scrollToBottom(reader, animated: true)
                                }
                                .padding(.bottom, 12)
                            }
                        }
                    }
                }

                } else {
                    Spacer(); Text(c.workspaceHint).foregroundStyle(.secondary); Spacer()
                }

                PromptComposer(
                    prompt: $prompt,
                attachments: $attachments,
                mode: $selectedMode,
                providerID: $selectedProviderID,
                modelID: $selectedModelID,
                providers: mothx.providers,
                skills: mothx.installedSkills,
                selectedSkills: $selectedSkills,
                selectedTools: $selectedTools,
                models: currentModels,
                isRunning: mothx.isSubmittingRun || mothx.isStreaming,
                cacheHitRate: mothx.runCacheHitRate,
                chooseFiles: chooseFiles,
                submit: submit,
                    stop: { Task { await mothx.cancelRun() } }
                ).frame(maxWidth: 760).padding(.horizontal, 25).padding(.bottom, 16)
            }
        }.padding(.top, 1)
        .alert(c.attach, isPresented: Binding(get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) {
            Button(c.ok) { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "")
        }
        .task(id: sessionID) {
            if let sessionID {
                selectedMode = ["plan", "agent", "yolo"].contains(mothx.defaultMode) ? mothx.defaultMode : "agent"
                selectedProviderID = mothx.providers.first(where: { $0.id == mothx.defaultProvider })?.id ?? mothx.providers.first?.id ?? ""
                let providerModels = mothx.providers.first(where: { $0.id == selectedProviderID })?.models ?? []
                let savedModel = mothx.modelForSession(sessionID) ?? mothx.defaultModel
                selectedModelID = providerModels.contains(where: { $0.id == savedModel }) ? savedModel : providerModels.first?.id ?? ""
                selectedSkills = mothx.activeSkillsBySession[sessionID] ?? []
                selectedTools = []
                await mothx.loadSkills(for: sessionID)
                selectedSkills = mothx.activeSkillsBySession[sessionID] ?? []
                await mothx.loadMessages(sessionID: sessionID)
                currentTurns = computeTurns(mothx.messagesBySession[sessionID] ?? [])
                showAllHistory = false
                expandedTurnIDs = currentTurns.last.map { [$0.id] } ?? []
            }
        }
        .onChange(of: mothx.messagesBySession) { _, _ in
            if let sessionID {
                currentTurns = computeTurns(mothx.messagesBySession[sessionID] ?? [])
                if currentTurns.count <= 3 { showAllHistory = false }
                // Keep last turn expanded, preserve other expanded
                if let lastID = currentTurns.last?.id {
                    expandedTurnIDs.insert(lastID)
                }
            }
        }
        .onChange(of: mothx.defaultProvider) { _, providerID in
            guard selectedProviderID.isEmpty else { return }
            selectedProviderID = providerID
            selectedModelID = mothx.providers.first(where: { $0.id == providerID })?.models.first?.id ?? ""
        }
        .onChange(of: mothx.providers) { _, providers in
            guard !providers.isEmpty else { return }
            guard selectedProviderID.isEmpty || !providers.contains(where: { $0.id == selectedProviderID }) else { return }
            let provider = providers.first(where: { $0.id == mothx.defaultProvider }) ?? providers.first
            selectedProviderID = provider?.id ?? ""
            selectedModelID = provider?.models.first?.id ?? ""
        }
        .onChange(of: terminalStore.isOpen) { _, isOpen in
            guard !isOpen, let sessionID else { return }
            // Returning from terminal mode: reload the conversation so any
            // messages added by the mothx TUI (same session) show up.
            Task { await mothx.loadMessages(sessionID: sessionID) }
        }
        .onChange(of: sessionID) { _, newSessionID in
            // While terminal mode is active, switching to another session in
            // the sidebar switches the terminal too: the previous mothx TUI
            // process is terminated and a new one resumes the new session
            // from its working directory.
            guard terminalStore.isOpen, let newSessionID,
                  terminalStore.sessionID != newSessionID else { return }
            terminalStore.open(sessionID: newSessionID, workDir: mothx.workDir(for: newSessionID))
        }
    }

    private func scrollToBottom(_ reader: ScrollViewProxy, animated: Bool) {
        let action = {
            reader.scrollTo(conversationBottomID, anchor: .bottom)
        }
        if animated {
            withAnimation(.easeOut(duration: 0.2), action)
        } else {
            action()
        }
        // ScrollViewReader can receive the request before LazyVStack has
        // committed its new document height. Repeat after the layout pass so
        // the native scrollbar and the SwiftUI target agree on the same bottom.
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2), action)
            } else {
                action()
            }
        }
    }

    // MARK: - Turn accordion

    private func toggleTurn(_ turn: Turn) {
        if expandedTurnIDs.contains(turn.id) {
            expandedTurnIDs.remove(turn.id)
        } else {
            // Expand this turn, collapse all other non-last turns
            var newIDs = expandedTurnIDs
            if let lastID = currentTurns.last?.id, turn.id != lastID {
                // Keep last turn expanded, remove other expanded turns
                newIDs = [lastID]
            }
            newIDs.insert(turn.id)
            expandedTurnIDs = newIDs
        }
    }

    // MARK: - Helpers

    private var currentWorkDir: String { mothx.workDir(for: sessionID ?? "") }

    private func submit() {
        guard let sessionID else { return }
        var question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty || !attachments.isEmpty else { return }
        let imageAttachments = attachments.compactMap(\.dataURL)
        if question.isEmpty, !attachments.isEmpty {
            let separator = languageStore.language == .zh ? "、" : ", "
            question = languageStore.copy.attachmentsInstruction(attachments.map(\.name).joined(separator: separator))
        }
        let selectedModel = selectedModelID
        let selectedMode = selectedMode
        let selectedTools = Array(selectedTools).sorted()
        let selectedSkills = Array(selectedSkills).sorted()
        prompt = ""; attachments = []
        mothx.setSessionModel(selectedModel, for: sessionID)
        Task {
            // The Run API resolves the provider from mothx's global default.
            // Persist the current selection before submitting the run.
            await mothx.saveDefaults(provider: selectedProviderID, model: selectedModel, thinkingLevel: mothx.defaultThinkingLevel, mode: selectedMode)
            if let runID = await mothx.submitRun(sessionID: sessionID, message: question, images: imageAttachments, workDir: mothx.workDir(for: sessionID), model: selectedModel, mode: selectedMode, tools: selectedTools, skills: selectedSkills) {
                await mothx.pollRun(runID: runID, sessionID: sessionID)
                await mothx.updateSessionTitle(id: sessionID, title: String((question.components(separatedBy: .newlines).first ?? question).prefix(48)))
                await mothx.loadMessages(sessionID: sessionID)
                mothx.clearCurrentPlan()
            }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let directory = mothx.workDir(for: sessionID ?? "")
        guard !directory.isEmpty else {
            attachmentError = languageStore.copy.noWorkDirForAttachment
            return
        }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for source in panel.urls {
                let destination = uniqueDestination(for: source, in: URL(fileURLWithPath: directory))
                if source.standardizedFileURL != destination.standardizedFileURL {
                    try FileManager.default.copyItem(at: source, to: destination)
                }
                let dataURL = try imageDataURL(for: destination)
                attachments.append(ComposerAttachment(name: destination.lastPathComponent, dataURL: dataURL))
            }
        } catch {
            attachmentError = languageStore.copy.addAttachmentFailedPrefix(error.localizedDescription)
        }
    }

    private func uniqueDestination(for source: URL, in directory: URL) -> URL {
        let base = directory.appendingPathComponent(source.lastPathComponent)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func imageDataURL(for url: URL) throws -> String? {
        let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff"]
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let mime = url.pathExtension.lowercased() == "jpg" ? "jpeg" : url.pathExtension.lowercased()
        return "data:image/\(mime);base64,\(try Data(contentsOf: url).base64EncodedString())"
    }
}

// MARK: - Supporting views (unchanged)

struct DirectoryApplication: Identifiable {
    let url: URL
    var id: String { url.path }
    var name: String { FileManager.default.displayName(atPath: url.path) }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

struct CurrentDirectoryMenu: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var languageStore: LanguageStore
    let path: String
    @State private var isPresented = false
    @State private var applications: [DirectoryApplication] = []
    @State private var applicationsReady = false

    private var directoryURL: URL { URL(fileURLWithPath: path, isDirectory: true) }
    private var directoryName: String {
        guard !path.isEmpty else { return languageStore.copy.noWorkDir }
        return directoryURL.lastPathComponent.isEmpty ? path : directoryURL.lastPathComponent
    }

    var body: some View {
        Button {
            guard !path.isEmpty, applicationsReady else { return }
            isPresented = true
        } label: {
            Group {
                if applicationsReady {
                    ZStack {
                        Color.clear
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill").foregroundStyle(.orange)
                            Text(directoryName).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        }.font(.callout).padding(.horizontal, 13)
                    }
                } else {
                    ProgressView().controlSize(.small).frame(width: 24, height: 24)
                }
            }
            .frame(width: 104, height: 34)
            .background(colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.10)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight()
        .foregroundStyle(path.isEmpty ? .secondary : .primary)
        .disabled(path.isEmpty || !applicationsReady)
        .task(id: path) {
            applicationsReady = false
            guard !path.isEmpty else { return }
            _ = discoverApplications()
            try? await Task.sleep(for: .milliseconds(250))
            applications = discoverApplications()
            applicationsReady = true
        }
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(directoryName).font(.headline)
                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Divider()
                if applications.isEmpty {
                    Text(languageStore.copy.noAppsForDirectory).foregroundStyle(.secondary).padding(.vertical, 10)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(applications) { application in
                                Button {
                                    open(application)
                                    isPresented = false
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(nsImage: application.icon).resizable().frame(width: 26, height: 26)
                                        Text(application.name)
                                        Spacer()
                                    }.padding(.horizontal, 6).padding(.vertical, 5)
                                }.buttonStyle(.plain).hoverHighlight().foregroundStyle(.primary)
                            }
                        }
                    }.frame(maxHeight: 360)
                }
            }.padding(14).frame(width: 270)
        }
    }

    private func discoverApplications() -> [DirectoryApplication] {
        var urls = NSWorkspace.shared.urlsForApplications(toOpen: directoryURL)
        let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        if !urls.contains(finderURL) { urls.append(finderURL) }
        var seen = Set<String>()
        return urls
            .filter { $0.pathExtension == "app" && seen.insert($0.path).inserted }
            .map(DirectoryApplication.init(url:))
            .sorted { lhs, rhs in
                if lhs.name == "Finder" { return true }
                if rhs.name == "Finder" { return false }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func open(_ application: DirectoryApplication) {
        NSWorkspace.shared.open([directoryURL], withApplicationAt: application.url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}

struct ComposerAttachment: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let dataURL: String?
}

struct PromptComposer: View {
    enum PlusSubmenu { case skills, tools }
    @EnvironmentObject private var mothx: MothxServiceManager
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var languageStore: LanguageStore
    @Binding var prompt: String
    @Binding var attachments: [ComposerAttachment]
    @Binding var mode: String
    @Binding var providerID: String
    @Binding var modelID: String
    let providers: [MothxProviderConfig]
    let skills: [MothxSkill]
    @Binding var selectedSkills: Set<String>
    @Binding var selectedTools: Set<String>
    let models: [MothxModelConfig]
    let isRunning: Bool
    let cacheHitRate: Double?
    let chooseFiles: () -> Void
    let submit: () -> Void
    let stop: () -> Void
    @State private var plusMenuOpen = false
    @State private var plusSubmenu: PlusSubmenu?
    @State private var showModeMenu = false
    @State private var showProviderMenu = false
    @State private var showModelMenu = false
    @State private var planPanelHeight: CGFloat = 0
    @State private var planPanelCollapsed = false
    @State private var planPanelOffset: CGSize = .zero
    @GestureState private var planPanelDragTranslation: CGSize = .zero
    @State private var providerSearchText = ""
    @State private var modelSearchText = ""

    private let toolOptions = [("browser", "browser"), ("delegate", "delegate"), ("multi-agent", "muti-agent"), ("workflow", "workflow")]

    private var selectedModelLabel: String {
        if let model = models.first(where: { $0.id == modelID }) { return model.displayName }
        return modelID.isEmpty ? languageStore.copy.selectModel : modelID
    }

    private var selectedProviderLabel: String {
        providerID.isEmpty ? languageStore.copy.selectProvider : providerID
    }

    private var cacheHitRateLabel: String {
        guard let cacheHitRate else { return "—" }
        return String(format: "%.0f%%", cacheHitRate * 100)
    }

    private var filteredProviders: [MothxProviderConfig] {
        let query = providerSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return providers }
        return providers.filter { $0.id.localizedCaseInsensitiveContains(query) || $0.vendor.localizedCaseInsensitiveContains(query) }
    }

    private var filteredModels: [MothxModelConfig] {
        let query = modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }
        return models.filter { $0.id.localizedCaseInsensitiveContains(query) || $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let c = languageStore.copy
        return VStack(spacing: 0) {
            if !attachments.isEmpty {
                HStack(spacing: 8) {
                    Text(c.attachmentsCountLabel(attachments.count)).font(.caption).foregroundStyle(.secondary)
                    Text(attachments.map(\.name).joined(separator: "、")).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    Spacer()
                    Button { attachments.removeAll() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).hoverHighlight()
                }.padding(.horizontal, 12).padding(.top, 10)
            }
            RetSubmitTextEditor(text: $prompt, placeholder: c.askAnything, isRunning: isRunning, onSubmit: submit)
                .frame(height: editorHeight)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text(c.askAnything)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 17)
                            .padding(.top, 11)
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: 10) {
                Button {
                    plusSubmenu = nil
                    plusMenuOpen.toggle()
                } label: {
                    Image(systemName: "plus").frame(width: 36, height: 36).foregroundStyle(.primary).contentShape(Rectangle())
                }.buttonStyle(.plain).hoverHighlight().help(c.moreOptionsHelp)
                .popover(isPresented: $plusMenuOpen, arrowEdge: .bottom) {
                    plusPopover
                }

                Button { showModeMenu.toggle() } label: {
                    Text(mode.capitalized).font(.callout).foregroundStyle(mode.lowercased() == "yolo" ? .red : .secondary)
                        .padding(.horizontal, 8).frame(minHeight: 42).contentShape(Rectangle())
                }.buttonStyle(.plain).hoverHighlight()
                    .popover(isPresented: $showModeMenu, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(["plan", "agent", "yolo"], id: \.self) { option in
                                Button {
                                    mode = option
                                    showModeMenu = false
                                } label: {
                                    HStack { Text(option.capitalized); Spacer(); if mode == option { Image(systemName: "checkmark") } }
                                        .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).hoverHighlight().foregroundStyle(option == "yolo" ? .red : .primary)
                            }
                        }.padding(10).frame(width: 130, alignment: .leading)
                    }

                Spacer()

                Button {
                    providerSearchText = ""
                    showProviderMenu.toggle()
                } label: {
                    Text(selectedProviderLabel).font(.callout).lineLimit(1).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).frame(minHeight: 42).contentShape(Rectangle())
                }.buttonStyle(.plain).hoverHighlight()
                    .popover(isPresented: $showProviderMenu, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 3) {
                            if providers.isEmpty {
                                Text(c.selectProvider).foregroundStyle(.secondary).padding(8)
                            } else {
                                TextField(c.searchProviders, text: $providerSearchText)
                                    .textFieldStyle(.roundedBorder)
                                    .padding(.bottom, 4)
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 3) {
                                        ForEach(filteredProviders) { provider in
                                            Button {
                                                providerID = provider.id
                                                let preferredModel = provider.models.first?.id ?? ""
                                                modelID = preferredModel
                                                showProviderMenu = false
                                                Task {
                                                    await mothx.saveDefaults(provider: provider.id, model: preferredModel, thinkingLevel: mothx.defaultThinkingLevel, mode: mode)
                                                }
                                            } label: {
                                                HStack {
                                                    Text(provider.id).lineLimit(1)
                                                    Spacer()
                                                    if providerID == provider.id { Image(systemName: "checkmark") }
                                                }
                                                .padding(.horizontal, 8)
                                                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .hoverHighlight()
                                            .foregroundStyle(.primary)
                                        }
                                        if filteredProviders.isEmpty {
                                            Text(c.noProvidersFound).foregroundStyle(.secondary).padding(8)
                                        }
                                    }
                                }
                                .frame(maxHeight: 300)
                            }
                        }.padding(10).frame(width: 220, alignment: .leading)
                    }

                Button {
                    modelSearchText = ""
                    showModelMenu.toggle()
                } label: {
                    Text(selectedModelLabel).font(.callout).lineLimit(1).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).frame(minHeight: 42).contentShape(Rectangle())
                }.buttonStyle(.plain).hoverHighlight()
                    .popover(isPresented: $showModelMenu, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 3) {
                            if models.isEmpty {
                                Text(c.noModelsForProvider).foregroundStyle(.secondary).padding(8)
                            } else {
                                TextField(c.searchModels, text: $modelSearchText)
                                    .textFieldStyle(.roundedBorder)
                                    .padding(.bottom, 4)
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 3) {
                                        ForEach(filteredModels) { model in
                                            Button {
                                                modelID = model.id
                                                showModelMenu = false
                                            } label: {
                                                HStack { Text(model.displayName).lineLimit(1); Spacer(); if modelID == model.id { Image(systemName: "checkmark") } }
                                                    .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
                                            }.buttonStyle(.plain).hoverHighlight().foregroundStyle(.primary)
                                        }
                                        if filteredModels.isEmpty {
                                            Text(c.noModelsFound).foregroundStyle(.secondary).padding(8)
                                        }
                                    }
                                }.frame(maxHeight: 300)
                            }
                        }.padding(10).frame(width: 260, alignment: .leading)
                    }
                Text("⌘ ↵").font(.caption2).foregroundStyle(.tertiary)
                Button(action: isRunning ? stop : submit) {
                    if isRunning {
                        ZStack {
                            Circle().fill(Color.black)
                            RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 9, height: 9)
                        }.frame(width: 25, height: 25)
                    } else {
                        Image(systemName: "arrow.up").frame(width: 25, height: 25).foregroundStyle(.white).background(Color.gray).clipShape(Circle())
                    }
                }.buttonStyle(.plain).hoverHighlight().help(isRunning ? c.stop : c.send)
            }.padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 8)
        }
        .background(composerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
        // Keep the metric outside the composer border, aligned to its upper-right corner.
        .overlay(alignment: .topTrailing) {
            if isRunning {
                Text("\(c.cacheHitRate)  \(cacheHitRateLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .offset(y: -22)
            }
        }
        .overlay(alignment: .topLeading) {
            if isRunning, let plan = mothx.currentPlan {
                PlanCard(plan: plan, isRunning: true, runStatus: mothx.runStatus ?? "running", isCollapsed: $planPanelCollapsed)
                    .frame(width: 380)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { planPanelHeight = proxy.size.height }
                                .onChange(of: proxy.size.height) { _, height in
                                    planPanelHeight = height
                                }
                        }
                    }
                    // Keep the card's bottom just above the composer. The
                    // measured height prevents an empty fixed-height tail.
                    .offset(
                        x: planPanelOffset.width + planPanelDragTranslation.width,
                        y: -(planPanelHeight > 0 ? planPanelHeight + 8 : 338)
                            + planPanelOffset.height + planPanelDragTranslation.height
                    )
                    // The card remains anchored to the composer by default,
                    // but can be freely repositioned anywhere in the
                    // conversation area with a drag.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 4)
                            .updating($planPanelDragTranslation) { value, state, _ in
                                state = value.translation
                            }
                            .onEnded { value in
                                planPanelOffset.width += value.translation.width
                                planPanelOffset.height += value.translation.height
                            }
                    )
                    .onChange(of: plan.id) { _, _ in
                        planPanelCollapsed = false
                        planPanelOffset = .zero
                    }
                    .onChange(of: isRunning) { _, running in
                        if !running {
                            planPanelCollapsed = false
                            planPanelOffset = .zero
                        }
                    }
                .zIndex(10)
            }
        }
    }

    private var composerBackground: Color {
        colorScheme == .light ? .white : .codexCard
    }

    private var editorHeight: CGFloat {
        let lines = max(2, min(8, prompt.split(separator: "\n", omittingEmptySubsequences: false).count))
        return CGFloat(lines) * 20
    }

    @ViewBuilder
    private var plusPopover: some View {
        let copy = languageStore.copy
        return VStack(alignment: .leading, spacing: 4) {
            if let plusSubmenu {
                HStack(spacing: 8) {
                    Button { self.plusSubmenu = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).hoverHighlight()
                    switch plusSubmenu {
                    case .skills: Text(copy.skillsActivatedLabel(selectedSkills.count)).font(.headline)
                    case .tools: Text(copy.toolsLabel).font(.headline)
                    }
                    Spacer()
                }.padding(.bottom, 6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        switch plusSubmenu {
                        case .skills:
                            if skills.isEmpty { Text(copy.noInstalledSkills).foregroundStyle(.secondary).padding(8) }
                            ForEach(skills) { skill in
                                let active = selectedSkills.contains(skill.name)
                                Button {
                                    if active { selectedSkills.remove(skill.name) } else { selectedSkills.insert(skill.name) }
                                } label: {
                                    HStack {
                                        Text(skill.name)
                                        Spacer()
                                        Text(active ? "active" : "pending").font(.caption).foregroundStyle(.secondary)
                                        Image(systemName: active ? "checkmark.square.fill" : "square").foregroundStyle(active ? .orange : .secondary)
                                    }.padding(.horizontal, 10).padding(.vertical, 9).frame(maxWidth: .infinity, minHeight: 42, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).hoverHighlight().foregroundStyle(.primary).frame(maxWidth: .infinity)
                            }
                        case .tools:
                            ForEach(toolOptions, id: \.0) { tool, label in
                                let active = selectedTools.contains(tool)
                                Button {
                                    if active { selectedTools.remove(tool) } else { selectedTools.insert(tool) }
                                } label: {
                                    HStack {
                                        Text(label)
                                        Spacer()
                                        Text(active ? "on" : "off").font(.caption).foregroundStyle(.secondary)
                                        Image(systemName: active ? "checkmark.square.fill" : "square").foregroundStyle(active ? .orange : .secondary)
                                    }.padding(.horizontal, 10).padding(.vertical, 9).frame(maxWidth: .infinity, minHeight: 42, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).hoverHighlight().foregroundStyle(.primary).frame(maxWidth: .infinity)
                            }
                        }
                    }
                }.frame(maxHeight: 300)
            } else {
                Text(copy.moreOptionsHelp).font(.headline).padding(.bottom, 6)
                Button { plusSubmenu = .skills } label: { HStack { Label(copy.skills, systemImage: "sparkles"); Spacer(); Image(systemName: "chevron.right") }.padding(.horizontal, 10).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).hoverHighlight().frame(maxWidth: .infinity)
                Button { plusSubmenu = .tools } label: { HStack { Label(copy.toolsLabel, systemImage: "wrench.and.screwdriver"); Spacer(); Image(systemName: "chevron.right") }.padding(.horizontal, 10).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).hoverHighlight().frame(maxWidth: .infinity)
                Button { plusMenuOpen = false; chooseFiles() } label: { Label(copy.attach, systemImage: "paperclip").padding(.horizontal, 10).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).hoverHighlight().frame(maxWidth: .infinity)
            }
        }.padding(12).frame(width: 300)
    }
}

struct Suggestion: View { let title: String; let icon: String
    var body: some View { Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8).background(Color.primary.opacity(0.06)).clipShape(Capsule()) }
}

private struct ThinkingContentView: View {
    @EnvironmentObject private var languageStore: LanguageStore
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(languageStore.copy.thinkingLabel, systemImage: "brain.head.profile")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ConversationScrollObserver: NSViewRepresentable {
    let onBottomChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onBottomChanged: onBottomChanged)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.postsFrameChangedNotifications = false
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onBottomChanged = onBottomChanged
        context.coordinator.attach(to: nsView)
    }

    final class Coordinator {
        var onBottomChanged: (Bool) -> Void
        weak var observedScrollView: NSScrollView?
        var boundsObserver: NSObjectProtocol?

        init(onBottomChanged: @escaping (Bool) -> Void) {
            self.onBottomChanged = onBottomChanged
        }

        func attach(to view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view,
                      let scrollView = Self.findScrollView(from: view) else { return }
                guard self.observedScrollView !== scrollView else {
                    self.updateBottomState()
                    return
                }
                if let boundsObserver = self.boundsObserver {
                    NotificationCenter.default.removeObserver(boundsObserver)
                }
                self.observedScrollView = scrollView
                scrollView.contentView.postsBoundsChangedNotifications = true
                self.boundsObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView,
                    queue: .main
                ) { [weak self] _ in
                    self?.updateBottomState()
                }
                self.updateBottomState()
            }
        }

        func updateBottomState() {
            guard let scrollView = observedScrollView,
                  let documentView = scrollView.documentView else { return }
            // Convert the visible rect into document coordinates. Comparing
            // contentView.bounds directly with documentView.bounds is wrong
            // when the scroll view is flipped or has a non-zero origin.
            let visibleRect = documentView.convert(
                scrollView.contentView.bounds,
                from: scrollView.contentView
            )
            let visibleBottom = visibleRect.maxY
            let documentBottom = documentView.bounds.maxY
            // Account for the bottom content inset and sub-pixel rounding.
            let atBottom = documentBottom - visibleBottom <= 50
            onBottomChanged(atBottom)
        }

        static func findScrollView(from view: NSView) -> NSScrollView? {
            var current: NSView? = view
            while let candidate = current {
                if let scrollView = candidate as? NSScrollView { return scrollView }
                current = candidate.superview
            }
            return nil
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }
    }
}

private struct ConversationScrollButton: View {
    @EnvironmentObject private var languageStore: LanguageStore
    let isRunning: Bool
    let action: () -> Void
    @State private var animationPhase = false

    var body: some View {
        Button(action: action) {
            if isRunning {
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 6, height: 6)
                            .scaleEffect(animationPhase ? 1.0 : 0.62)
                            .opacity(animationPhase ? 1.0 : 0.45)
                            .animation(
                                .easeInOut(duration: 0.65)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.13),
                                value: animationPhase
                            )
                    }
                }
            } else {
                Image(systemName: "arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .background(.regularMaterial, in: Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .help(isRunning ? languageStore.copy.scrollRunningHelp : languageStore.copy.scrollBottomHelp)
        .onAppear {
            if isRunning { animationPhase = true }
        }
        .onChange(of: isRunning) { _, running in
            animationPhase = running
        }
    }
}
// MARK: - TextEditor that submits on Enter (Shift+Enter for newline)

private struct RetSubmitTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isRunning: Bool
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.drawsBackground = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RetSubmitTextEditor
        var isInternalUpdate = false

        init(_ parent: RetSubmitTextEditor) {
            self.parent = parent
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let commandName = NSStringFromSelector(commandSelector)
            if commandName == "insertNewline:" ||
                commandName == "insertNewlineIgnoringFieldEditor:" ||
                commandName == "insertLineBreak:" {
                // Shift+Enter → insert newline
                if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
                    return false
                }
                guard !parent.isRunning else { return true }
                parent.text = textView.string
                parent.onSubmit()
                return true
            }
            return false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !isInternalUpdate else { return }
            parent.text = textView.string
        }
    }
}
