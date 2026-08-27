import SwiftUI

struct Sidebar: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    @EnvironmentObject private var terminalStore: TerminalSessionStore
    @ObservedObject var teamManager: TeamRunManager
    @Binding var selectedProjectID: String?
    @Binding var selectedSessionID: String?
    @Binding var selectedTeamProjectID: String?
    @Binding var showSettings: Bool
    @Binding var showNewProject: Bool
    @Binding var appearanceMode: String
    @State private var expandedProjects: Set<String> = []
    @State private var pendingDelete: SidebarDelete?
    @State private var showServiceLogs = false
    @State private var showStats = false
    @State private var showConnectionMenu = false
    @State private var showAppearanceMenu = false
    @State private var isRefreshing = false
    @State private var showNewTeamTask = false

    /// Regular projects the user created in the UI. Team tasks are real mothx
    /// projects too, but they are owned by the 团队任务 section.
    private var visibleProjects: [MothxProject] {
        mothx.projects.filter { !teamManager.isTeamProject($0.id) }
    }

    var body: some View {
        let c = languageStore.copy
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image("MothxLogo").resizable().scaledToFit().frame(width: 24, height: 24)
                Text("mothx").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button {
                    guard !isRefreshing else { return }
                    isRefreshing = true
                    Task {
                        await mothx.loadWorkspace()
                        isRefreshing = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(isRefreshing ? 180 : 0))
                }
                .buttonStyle(.plain)
                .hoverHighlight()
                .foregroundStyle(.secondary)
                .help(c.refreshProjectsHelp)
                .disabled(isRefreshing || mothx.state != .connected)
            }.padding(.bottom, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    // ---- 团队任务（与项目并列，置于上方）----
                    HStack(spacing: 6) {
                        Text(c.teamTask.uppercased()).sectionLabel()
                        Spacer()
                        Button {
                            showNewTeamTask = true
                        } label: {
                            Image(systemName: "plus").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight()
                        .help(c.newTeamTask)
                    }
                    .padding(.bottom, 6)
                    if teamManager.teamProjects.isEmpty {
                        Text(c.noTeamTasksHint)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 4)
                            .padding(.bottom, 8)
                    }
                    ForEach(teamManager.teamProjects) { teamProject in
                        TeamProjectTreeRow(
                            teamProject: teamProject,
                            selected: selectedTeamProjectID == teamProject.id,
                            selectedTeamProjectID: $selectedTeamProjectID,
                            showSettings: $showSettings,
                            delete: { pendingDelete = .teamProject(teamProject.id) }
                        )
                    }

                    Divider().padding(.vertical, 6)

                    // ---- 项目 ----
                    HStack {
                        Text(c.projects.uppercased()).sectionLabel()
                        Spacer()
                        Button { showNewProject = true } label: { Image(systemName: "plus") }.buttonStyle(.plain).hoverHighlight().help(c.addProject)
                    }.padding(.bottom, 8)
                    ForEach(visibleProjects) { project in
                        ProjectTreeRow(project: project, expanded: expandedProjects.contains(project.id), selectedProjectID: $selectedProjectID, selectedSessionID: $selectedSessionID, selectedTeamProjectID: $selectedTeamProjectID, showSettings: $showSettings, toggle: { toggle(project.id) }, addSession: { let session = mothx.prepareSession(projectID: project.id); selectedTeamProjectID = nil; selectedSessionID = session.id; selectedProjectID = project.id; showSettings = false }, delete: { pendingDelete = .project(project.id) }, requestDeleteSession: { pendingDelete = .session($0) }, openInTUI: { session in
                            mothx.requestSwitch(activeRunSessionID: selectedSessionID) {
                                showSettings = false
                                selectedTeamProjectID = nil
                                selectedSessionID = session.id
                                selectedProjectID = session.projectID
                                terminalStore.open(sessionID: session.id, workDir: mothx.workDir(for: session.id))
                            }
                        })
                    }
                    UnassignedProjectTreeRow(selectedSessionID: $selectedSessionID, selectedTeamProjectID: $selectedTeamProjectID, showSettings: $showSettings, requestDelete: { pendingDelete = .session($0) }, moveToProject: { sessionID, projectID in
                        Task {
                            await mothx.moveSessionToProject(sessionID: sessionID, projectID: projectID)
                            selectedProjectID = projectID
                            expandedProjects.insert(projectID)
                        }
                    }, openInTUI: { session in
                        mothx.requestSwitch(activeRunSessionID: selectedSessionID) {
                            showSettings = false
                            selectedTeamProjectID = nil
                            selectedSessionID = session.id
                            selectedProjectID = session.projectID
                            terminalStore.open(sessionID: session.id, workDir: mothx.workDir(for: session.id))
                        }
                    })
                }
            }
            Spacer()
            HStack(spacing: 10) {
                Button { showSettings.toggle() } label: {
                    Label(c.settingsLabel, systemImage: "gearshape")
                        .font(.callout)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 34)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).hoverHighlight().foregroundStyle(showSettings ? .primary : .secondary)

                Button { showConnectionMenu.toggle() } label: {
                    ZStack {
                        Color.clear
                        HStack(spacing: 7) {
                            Circle().fill(mothx.state == .connected ? .green : .orange).frame(width: 7, height: 7)
                            Text(mothx.state == .connected ? c.connected : c.connecting).font(.callout)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }.padding(.horizontal, 6).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(width: 140, height: 42).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .hoverHighlight()
                .foregroundStyle(.secondary)
                .popover(isPresented: $showConnectionMenu, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Button { showConnectionMenu = false; Task { await mothx.restartService() } } label: {
                            Label(mothx.state == .connected ? c.restartService : c.startService, systemImage: mothx.state == .connected ? "arrow.clockwise" : "play.fill")
                                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).hoverHighlight().frame(maxWidth: .infinity)
                        Button { showConnectionMenu = false; NSWorkspace.shared.open(mothx.webUIURL) } label: {
                            Label(c.openWebUI, systemImage: "safari")
                                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).hoverHighlight().frame(maxWidth: .infinity)
                        Button { showConnectionMenu = false; showServiceLogs = true } label: {
                            Label(c.serviceLogTitle, systemImage: "doc.text.magnifyingglass")
                                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).hoverHighlight().frame(maxWidth: .infinity)
                        Button { showConnectionMenu = false; showStats = true } label: {
                            Label(c.statsTitle, systemImage: "chart.bar.xaxis")
                                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).hoverHighlight().frame(maxWidth: .infinity)
                    }
                    .padding(10)
                    .frame(width: 190, alignment: .leading)
                }

                Button { showAppearanceMenu.toggle() } label: {
                    ZStack {
                        Color.clear
                        Image(systemName: appearanceMode == "light" ? "sun.max" : appearanceMode == "dark" ? "moon" : "circle.lefthalf.filled")
                    }.frame(width: 42, height: 42).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .hoverHighlight()
                .help(c.appearanceHelp)
                .popover(isPresented: $showAppearanceMenu, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        appearanceButton(c.appearanceLight, value: "light")
                        appearanceButton(c.appearanceDark, value: "dark")
                        appearanceButton(c.appearanceAuto, value: "auto")
                    }.padding(10).frame(width: 120, alignment: .leading)
                }
            }.padding(.top, 12)
        }.padding(18).frame(width: 260).background(Color.codexSidebar)
        .onChange(of: selectedProjectID) { _, projectID in
            if let projectID { expandedProjects.insert(projectID) }
        }
        .confirmationDialog(c.deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button(c.delete, role: .destructive) { if let pendingDelete { Task { await delete(pendingDelete) } }; pendingDelete = nil }
            Button(c.cancel, role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.message(using: c) ?? c.text("此操作无法撤销。", "This action cannot be undone."))
        }
        .sheet(isPresented: $showNewTeamTask) {
            TeamSetupSheet(
                teamProject: nil,
                isPresented: $showNewTeamTask,
                onCreated: { teamProject in
                    selectedTeamProjectID = teamProject.id
                    selectedSessionID = nil
                    selectedProjectID = nil
                    showSettings = false
                }
            )
        }
        .sheet(isPresented: $showServiceLogs) {
            ServiceLogView()
        }
        .sheet(isPresented: $showStats) {
            StatsView()
        }
    }
    private func toggle(_ id: String) { if expandedProjects.contains(id) { expandedProjects.remove(id) } else { expandedProjects.insert(id) } }
    private func appearanceButton(_ title: String, value: String) -> some View {
        Button {
            appearanceMode = value
            showAppearanceMenu = false
        } label: {
            HStack { Text(title); Spacer(); if appearanceMode == value { Image(systemName: "checkmark") } }
                .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).hoverHighlight().foregroundStyle(.primary)
    }
    private func delete(_ item: SidebarDelete) async {
        switch item {
        case .project(let id):
            await mothx.deleteProject(id: id)
            if selectedProjectID == id { selectedProjectID = nil; selectedSessionID = nil; selectedTeamProjectID = nil }
        case .teamProject(let id):
            let sessionIDs = mothx.sessions
                .filter { $0.projectID == mothx.teamManager.teamProject(forTeamProjectID: id)?.mothxProjectID }
                .map(\.id)
            let pendingSessionIDs = mothx.pendingSessions.values
                .filter { $0.projectID == mothx.teamManager.teamProject(forTeamProjectID: id)?.mothxProjectID }
                .map(\.id)
            for sessionID in Set(sessionIDs + pendingSessionIDs) {
                await mothx.deleteSession(id: sessionID)
            }
            await mothx.teamManager.deleteTeamProject(id: id)
            if selectedTeamProjectID == id { selectedTeamProjectID = nil }
        case .session(let id):
            await mothx.deleteSession(id: id)
            if selectedSessionID == id { selectedSessionID = nil; selectedProjectID = nil }
        }
    }
}

enum SidebarDelete {
    case project(String); case teamProject(String); case session(String)

    func message(using copy: Copy) -> String {
        switch self {
        case .project(let id): return copy.deleteProjectMessage(id)
        case .teamProject: return copy.deleteTeamTaskMessage
        case .session(let id): return copy.deleteSessionMessage(id)
        }
    }
}

/// 侧边栏顶部「团队任务」下的一个任务（mothx 中对应真实 Project）。
/// 点击进入团队任务对话模式。团队任务产生的会话由任务统一管理，
/// 不在侧边栏中作为任务的子节点展示。
struct TeamProjectTreeRow: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    let teamProject: MothxTeamProject
    let selected: Bool
    @Binding var selectedTeamProjectID: String?
    @Binding var showSettings: Bool
    let delete: () -> Void
    @State private var isHovered = false
    @State private var showSetup = false

    private var hasActiveRun: Bool {
        mothx.teamManager.teamRuns.contains { $0.projectID == teamProject.id && !$0.status.isTerminal }
    }
    var body: some View {
        let c = languageStore.copy
        return HStack(spacing: 6) {
            Button {
                selectedTeamProjectID = teamProject.id
                showSettings = false
            } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.3")
                            .foregroundStyle(.orange)
                            .font(.system(size: 11))
                        Text(teamProject.name).lineLimit(1)
                        if hasActiveRun {
                            Circle().fill(.orange).frame(width: 6, height: 6)
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            if isHovered {
                Spacer()
                Menu {
                    Button {
                        showSetup = true
                    } label: {
                        Label(c.configureTeam, systemImage: "gearshape")
                    }
                    Divider()
                    Button(role: .destructive, action: delete) {
                        Label(c.delete, systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption)
                        .foregroundStyle(.white)
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
                .hoverHighlight()
                .help(c.showMore)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered || selected ? Color.primary.opacity(0.1) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(.primary)
        .onHover { isHovered = $0 }
        .sheet(isPresented: $showSetup) {
            TeamSetupSheet(teamProject: teamProject, isPresented: $showSetup)
        }
    }
}

struct UnassignedProjectTreeRow: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    @EnvironmentObject private var terminalStore: TerminalSessionStore
    @Binding var selectedSessionID: String?
    @Binding var selectedTeamProjectID: String?
    @Binding var showSettings: Bool
    let requestDelete: (String) -> Void
    let moveToProject: (String, String) -> Void
    let openInTUI: (MothxSession) -> Void
    @State private var expanded = true
    @State private var isHovered = false

    private var sessions: [MothxSession] {
        (mothx.sessions + Array(mothx.pendingSessions.values))
            .filter { $0.projectID == nil }
            .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            .prefix(10).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 14)
                    Label(languageStore.copy.unassignedProject, systemImage: "tray")
                    Spacer()
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Color.primary.opacity(0.1) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onHover { isHovered = $0 }
            if expanded {
                ForEach(sessions) { session in
                    SessionTreeRow(session: session, selected: selectedSessionID == session.id, select: {
                        guard selectedSessionID != session.id else { return }
                        mothx.requestSwitch(activeRunSessionID: selectedSessionID) {
                            selectedTeamProjectID = nil
                            selectedSessionID = session.id
                            showSettings = false
                        }
                    }, delete: { requestDelete(session.id) }, moveToProject: { projectID in
                        moveToProject(session.id, projectID)
                    }, openInTUI: openInTUI)
                }
                if sessions.isEmpty { Text(languageStore.copy.noSessions).font(.caption).foregroundStyle(.tertiary).padding(.leading, 27).padding(.vertical, 4) }
            }
        }
    }
}


struct ProjectTreeRow: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    @EnvironmentObject private var terminalStore: TerminalSessionStore
    let project: MothxProject; let expanded: Bool
    @Binding var selectedProjectID: String?; @Binding var selectedSessionID: String?; @Binding var selectedTeamProjectID: String?; @Binding var showSettings: Bool
    let toggle: () -> Void; let addSession: () -> Void; let delete: () -> Void; let requestDeleteSession: (String) -> Void
    let openInTUI: (MothxSession) -> Void
    @State private var showEditor = false
    @State private var editedName = ""
    @State private var editedWorkDir = ""
    @State private var isHovered = false
    private var projectSessions: [MothxSession] {
        let pending = Array(mothx.pendingSessions.values)
        return (mothx.sessions + pending)
            .filter { $0.projectID == project.id }
            .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    selectedProjectID = project.id
                    showSettings = false
                    toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 14)
                        Label(project.name, systemImage: "folder").lineLimit(1)
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if isHovered {
                    Spacer()
                    Button(action: addSession) { Image(systemName: "plus") }.buttonStyle(.plain).hoverHighlight().help(languageStore.copy.addSession)
                    Menu {
                        Button {
                            editedName = project.name
                            editedWorkDir = project.workDir
                            showEditor = true
                        } label: {
                            Label(languageStore.copy.editProject, systemImage: "pencil")
                        }
                        Button(role: .destructive, action: delete) {
                            Label(languageStore.copy.delete, systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.caption)
                            .foregroundStyle(.white)
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.plain)
                    .hoverHighlight()
                    .help(languageStore.copy.showMore)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Color.primary.opacity(0.1) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.primary)
            .onHover { isHovered = $0 }
            if expanded {
                ForEach(projectSessions) { session in
                    SessionTreeRow(session: session, selected: selectedSessionID == session.id, select: {
                        guard selectedSessionID != session.id else { return }
                        mothx.requestSwitch(activeRunSessionID: selectedSessionID) {
                            selectedTeamProjectID = nil
                            selectedProjectID = project.id
                            selectedSessionID = session.id
                            showSettings = false
                        }
                    }, delete: { requestDeleteSession(session.id) }, moveToProject: nil, openInTUI: openInTUI)
                }
                if projectSessions.isEmpty {
                    Text(languageStore.copy.text("暂无会话", "No sessions yet"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 27)
                        .padding(.vertical, 4)
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            VStack(alignment: .leading, spacing: 16) {
                Text(languageStore.copy.text("编辑项目", "Edit project")).font(.title2.bold())
                TextField(languageStore.copy.projectName, text: $editedName).textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    TextField(languageStore.copy.workDirectory, text: $editedWorkDir).textFieldStyle(.roundedBorder)
                    Button(languageStore.copy.chooseDirectory) { chooseWorkDirectory() }
                }
                HStack {
                    Spacer()
                    Button(languageStore.copy.cancel) { showEditor = false }
                    Button(languageStore.copy.save) {
                        let name = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let workDir = editedWorkDir.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty, !workDir.isEmpty else { return }
                        showEditor = false
                        Task { await mothx.updateProject(id: project.id, name: name, workDir: workDir) }
                    }.buttonStyle(.borderedProminent).tint(.orange)
                        .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editedWorkDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 520)
        }
    }

    private func chooseWorkDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { editedWorkDir = url.path }
    }
}

struct SessionTreeRow: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    let session: MothxSession; let selected: Bool; let select: () -> Void; let delete: () -> Void
    let moveToProject: ((String) -> Void)?
    let openInTUI: (MothxSession) -> Void
    @State private var isHovered = false

    var body: some View {
        HStack {
            Button(action: select) {
                Label(session.title, systemImage: "bubble.left")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isHovered {
                Menu {
                    if let moveToProject {
                        Menu {
                            ForEach(mothx.projects.filter { !mothx.teamManager.isTeamProject($0.id) }) { project in
                                Button {
                                    moveToProject(project.id)
                                } label: {
                                    Label(project.name, systemImage: "folder")
                                }
                            }
                        } label: {
                            Label(languageStore.copy.moveToProject, systemImage: "folder.badge.plus")
                        }
                        Divider()
                    }
                    Button {
                        openInTUI(session)
                    } label: {
                        Label(languageStore.copy.openInTUI, systemImage: "terminal")
                    }
                    Divider()
                    Button(role: .destructive, action: delete) {
                        Label(languageStore.copy.delete, systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption)
                        .foregroundStyle(.white)
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
                .hoverHighlight()
                .help(languageStore.copy.showMore)
            }
        }
        .padding(.leading, 24)
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected || isHovered ? Color.primary.opacity(0.1) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(selected ? .primary : .secondary)
        .onHover { isHovered = $0 }
    }
}

struct SidebarItem: View { let title: String; let icon: String; let selected: Bool; let action: () -> Void
    var body: some View { Button(action: action) { Label(title, systemImage: icon).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).padding(.horizontal, 10).background(selected ? Color.primary.opacity(0.1) : .clear).clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle()) }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading).hoverHighlight().foregroundStyle(selected ? .primary : .secondary) }
}
