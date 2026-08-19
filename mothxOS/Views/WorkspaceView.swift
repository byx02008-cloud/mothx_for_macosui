import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    @Binding var prompt: String
    let sessionID: String?
    @State private var attachments: [ComposerAttachment] = []
    @State private var selectedMode = "agent"
    @State private var selectedModelID = ""
    @State private var selectedSkills: Set<String> = []
    @State private var selectedTools: Set<String> = []
    @State private var attachmentError: String?
    @State private var currentTurns: [Turn] = []
    @State private var expandedTurnIDs: Set<UUID> = []

    private var currentModels: [MothxModelConfig] {
        let provider = mothx.providers.first(where: { $0.id == mothx.defaultProvider }) ?? mothx.providers.first
        return provider?.models ?? []
    }

    var body: some View {
        let c = languageStore.copy
        return VStack(spacing: 0) {
            HStack {
                Text(mothx.sessions.first(where: { $0.id == sessionID })?.title ?? c.workspace)
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                CurrentDirectoryMenu(path: currentWorkDir)
            }.padding(.horizontal, 24).frame(height: 54)
            Divider()

            if let sessionID {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        let isRunActive = mothx.runSessionID == sessionID && mothx.isRunning

                        ForEach(currentTurns) { turn in
                            TurnBlock(
                                turn: turn,
                                sessionID: sessionID,
                                isExpanded: expandedTurnIDs.contains(turn.id),
                                onToggle: { toggleTurn(turn) }
                            )
                        }

                        // Thinking indicator + status when running but no messages yet
                        if isRunActive, currentTurns.isEmpty {
                            if mothx.runReplyMessageID == nil, mothx.runStatus == "running" {
                                ThinkingIndicator(isActive: true)
                            }
                            if mothx.runStatus != nil, mothx.runReplyMessageID == nil,
                               let status = mothx.runStatus {
                                StatusInline(
                                    status: status,
                                    elapsed: mothx.runElapsed,
                                    error: mothx.runError
                                )
                            }
                        }

                        // Status when run active but no reply in last turn
                        if isRunActive,
                           mothx.runStatus != nil,
                           mothx.runReplyMessageID == nil,
                           !currentTurns.isEmpty {
                            StatusInline(
                                status: mothx.runStatus ?? "",
                                elapsed: mothx.runElapsed,
                                error: mothx.runError
                            )
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(28)
                    .frame(maxWidth: .infinity)
                }

                // PlanCard pinned above composer (conditionally shown)
                if mothx.runSessionID == sessionID,
                   mothx.isRunning,
                   let plan = mothx.currentPlan {
                    PlanCard(plan: plan, isRunning: true)
                        .padding(.horizontal, 25)
                        .frame(maxWidth: 760)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            } else {
                Spacer(); Text(c.workspaceHint).foregroundStyle(.secondary); Spacer()
            }

            PromptComposer(
                prompt: $prompt,
                attachments: $attachments,
                mode: $selectedMode,
                modelID: $selectedModelID,
                skills: mothx.installedSkills,
                selectedSkills: $selectedSkills,
                selectedTools: $selectedTools,
                models: currentModels,
                isRunning: mothx.isSubmittingRun,
                chooseFiles: chooseFiles,
                submit: submit,
                stop: { Task { await mothx.cancelRun() } }
            ).frame(maxWidth: 760).padding(.horizontal, 25).padding(.bottom, 16)
        }.padding(.top, 1)
        .alert("附件", isPresented: Binding(get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) {
            Button("确定") { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "")
        }
        .task(id: sessionID) {
            if let sessionID {
                selectedMode = ["plan", "agent", "yolo"].contains(mothx.defaultMode) ? mothx.defaultMode : "agent"
                selectedModelID = mothx.modelForSession(sessionID) ?? mothx.defaultModel
                selectedSkills = mothx.activeSkillsBySession[sessionID] ?? []
                selectedTools = []
                await mothx.loadSkills(for: sessionID)
                selectedSkills = mothx.activeSkillsBySession[sessionID] ?? []
                await mothx.loadMessages(sessionID: sessionID)
                currentTurns = computeTurns(mothx.messagesBySession[sessionID] ?? [])
                expandedTurnIDs = currentTurns.last.map { [$0.id] } ?? []
            }
        }
        .onChange(of: mothx.messagesBySession) { _, _ in
            if let sessionID {
                currentTurns = computeTurns(mothx.messagesBySession[sessionID] ?? [])
                // Keep last turn expanded, preserve other expanded
                if let lastID = currentTurns.last?.id {
                    expandedTurnIDs.insert(lastID)
                }
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

    private func workDir(for sessionID: String) -> String {
        let session = mothx.sessions.first(where: { $0.id == sessionID }) ?? mothx.pendingSessions[sessionID]
        if let sessionWorkDir = session?.workDir, !sessionWorkDir.isEmpty { return sessionWorkDir }
        guard let projectID = session?.projectID else { return "" }
        return mothx.projects.first(where: { $0.id == projectID })?.workDir ?? ""
    }

    private var currentWorkDir: String { workDir(for: sessionID ?? "") }

    private func submit() {
        guard let sessionID else { return }
        var question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty || !attachments.isEmpty else { return }
        let imageAttachments = attachments.compactMap(\.dataURL)
        if question.isEmpty, !attachments.isEmpty {
            question = "请处理工作目录中的附件：" + attachments.map(\.name).joined(separator: "、")
        }
        let selectedModel = selectedModelID
        let selectedMode = selectedMode
        let selectedTools = Array(selectedTools).sorted()
        let selectedSkills = Array(selectedSkills).sorted()
        prompt = ""; attachments = []
        mothx.setSessionModel(selectedModel, for: sessionID)
        Task {
            if let runID = await mothx.submitRun(sessionID: sessionID, message: question, images: imageAttachments, workDir: workDir(for: sessionID), model: selectedModel, mode: selectedMode, tools: selectedTools, skills: selectedSkills) {
                await mothx.pollRun(runID: runID, sessionID: sessionID)
                await mothx.updateSessionTitle(id: sessionID, title: String((question.components(separatedBy: .newlines).first ?? question).prefix(48)))
                await mothx.loadMessages(sessionID: sessionID)
            }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let directory = workDir(for: sessionID ?? "")
        guard !directory.isEmpty else {
            attachmentError = "当前会话没有可用的项目工作目录"
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
            attachmentError = "添加附件失败：\(error.localizedDescription)"
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
    let path: String
    @State private var isPresented = false
    @State private var applications: [DirectoryApplication] = []
    @State private var applicationsReady = false

    private var directoryURL: URL { URL(fileURLWithPath: path, isDirectory: true) }
    private var directoryName: String {
        guard !path.isEmpty else { return "无工作目录" }
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
                    Text("没有找到可打开此目录的应用").foregroundStyle(.secondary).padding(.vertical, 10)
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
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var languageStore: LanguageStore
    @Binding var prompt: String
    @Binding var attachments: [ComposerAttachment]
    @Binding var mode: String
    @Binding var modelID: String
    let skills: [MothxSkill]
    @Binding var selectedSkills: Set<String>
    @Binding var selectedTools: Set<String>
    let models: [MothxModelConfig]
    let isRunning: Bool
    let chooseFiles: () -> Void
    let submit: () -> Void
    let stop: () -> Void
    @State private var plusMenuOpen = false
    @State private var plusSubmenu: PlusSubmenu?
    @State private var showModeMenu = false
    @State private var showModelMenu = false

    private let toolOptions = [("browser", "browser"), ("delegate", "delegate"), ("multi-agent", "muti-agent"), ("workflow", "workflow")]

    private var selectedModelLabel: String {
        if let model = models.first(where: { $0.id == modelID }) { return model.displayName }
        return modelID.isEmpty ? "选择模型" : modelID
    }

    var body: some View {
        let c = languageStore.copy
        return VStack(spacing: 0) {
            if !attachments.isEmpty {
                HStack(spacing: 8) {
                    Text("附件 \(attachments.count) 个").font(.caption).foregroundStyle(.secondary)
                    Text(attachments.map(\.name).joined(separator: "、")).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    Spacer()
                    Button { attachments.removeAll() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).hoverHighlight()
                }.padding(.horizontal, 12).padding(.top, 10)
            }
            TextEditor(text: $prompt)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(height: editorHeight)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .onKeyPress(.return, phases: .down) { keyPress in
                    guard keyPress.modifiers.isEmpty else { return .ignored }
                    guard !isRunning else { return .handled }
                    submit()
                    return .handled
                }
                .overlay(alignment: .topLeading) { if prompt.isEmpty { Text(c.askAnything).foregroundStyle(.tertiary).padding(.leading, 17).padding(.top, 11).allowsHitTesting(false) } }
            HStack(spacing: 10) {
                Button {
                    plusSubmenu = nil
                    plusMenuOpen.toggle()
                } label: {
                    Image(systemName: "plus").frame(width: 36, height: 36).foregroundStyle(.primary).contentShape(Rectangle())
                }.buttonStyle(.plain).hoverHighlight().help("更多选项")
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
                Button { showModelMenu.toggle() } label: {
                    Text(selectedModelLabel).font(.callout).lineLimit(1).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).frame(minHeight: 42).contentShape(Rectangle())
                }.buttonStyle(.plain).hoverHighlight()
                    .popover(isPresented: $showModelMenu, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 3) {
                            if models.isEmpty {
                                Text("当前运营商没有可用模型").foregroundStyle(.secondary).padding(8)
                            } else {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 3) {
                                        ForEach(models) { model in
                                            Button {
                                                modelID = model.id
                                                showModelMenu = false
                                            } label: {
                                                HStack { Text(model.displayName).lineLimit(1); Spacer(); if modelID == model.id { Image(systemName: "checkmark") } }
                                                    .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
                                            }.buttonStyle(.plain).hoverHighlight().foregroundStyle(.primary)
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
                }.buttonStyle(.plain).hoverHighlight().help(isRunning ? "停止" : "发送")
            }.padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 8)
        }.background(composerBackground).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
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
        VStack(alignment: .leading, spacing: 4) {
            if let plusSubmenu {
                HStack(spacing: 8) {
                    Button { self.plusSubmenu = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).hoverHighlight()
                    switch plusSubmenu {
                    case .skills: Text("技能（已激活 \(selectedSkills.count) 个）").font(.headline)
                    case .tools: Text("工具").font(.headline)
                    }
                    Spacer()
                }.padding(.bottom, 6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        switch plusSubmenu {
                        case .skills:
                            if skills.isEmpty { Text("暂无已安装技能").foregroundStyle(.secondary).padding(8) }
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
                Text("更多选项").font(.headline).padding(.bottom, 6)
                Button { plusSubmenu = .skills } label: { HStack { Label("技能", systemImage: "sparkles"); Spacer(); Image(systemName: "chevron.right") }.padding(.horizontal, 10).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).hoverHighlight().frame(maxWidth: .infinity)
                Button { plusSubmenu = .tools } label: { HStack { Label("工具", systemImage: "wrench.and.screwdriver"); Spacer(); Image(systemName: "chevron.right") }.padding(.horizontal, 10).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).hoverHighlight().frame(maxWidth: .infinity)
                Button { plusMenuOpen = false; chooseFiles() } label: { Label("附件", systemImage: "paperclip").padding(.horizontal, 10).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).hoverHighlight().frame(maxWidth: .infinity)
            }
        }.padding(12).frame(width: 300)
    }
}

struct Suggestion: View { let title: String; let icon: String
    var body: some View { Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8).background(Color.primary.opacity(0.06)).clipShape(Capsule()) }
}