import SwiftUI

struct Sidebar: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    @Binding var selectedProjectID: String?
    @Binding var selectedSessionID: String?
    @Binding var showSettings: Bool
    @Binding var showNewProject: Bool
    @Binding var appearanceMode: String
    @State private var expandedProjects: Set<String> = []
    @State private var pendingDelete: SidebarDelete?
    @State private var showAllSessions = false
    @State private var showServiceLogs = false
    @State private var showStats = false
    @State private var showConnectionMenu = false
    @State private var showAppearanceMenu = false
    @State private var isRefreshing = false

    private var allSessions: [MothxSession] {
        (mothx.sessions + Array(mothx.pendingSessions.values)).sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
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
                .help("刷新项目和会话列表")
                .disabled(isRefreshing || mothx.state != .connected)
            }.padding(.bottom, 22)
            HStack {
                Text(c.projects.uppercased()).sectionLabel()
                Spacer()
                Button { showNewProject = true } label: { Image(systemName: "plus") }.buttonStyle(.plain).hoverHighlight().help(c.addProject)
            }.padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(mothx.projects) { project in
                        ProjectTreeRow(project: project, expanded: expandedProjects.contains(project.id), selectedProjectID: $selectedProjectID, selectedSessionID: $selectedSessionID, showSettings: $showSettings, toggle: { toggle(project.id) }, addSession: { let session = mothx.prepareSession(projectID: project.id); selectedSessionID = session.id; selectedProjectID = project.id; showSettings = false }, delete: { pendingDelete = .project(project.id) })
                    }
                    Divider().padding(.vertical, 12)
                    HStack {
                        Text(c.sessions.uppercased()).sectionLabel()
                        Spacer()
                        if allSessions.count > 10 { Button(showAllSessions ? c.showRecent : c.showMore) { showAllSessions.toggle() }.font(.caption).buttonStyle(.plain).hoverHighlight().foregroundStyle(.orange) }
                    }
                    ForEach(showAllSessions ? allSessions : Array(allSessions.prefix(10))) { session in
                        SessionTreeRow(session: session, selected: selectedSessionID == session.id) {
                            selectedSessionID = session.id
                            selectedProjectID = session.projectID
                            showSettings = false
                        } delete: { pendingDelete = .session(session.id) }
                    }
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
                            Label(mothx.state == .connected ? "重启服务" : "启动服务", systemImage: mothx.state == .connected ? "arrow.clockwise" : "play.fill")
                                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).hoverHighlight().frame(maxWidth: .infinity)
                        Button { showConnectionMenu = false; NSWorkspace.shared.open(URL(string: "http://127.0.0.1:7872/")!) } label: {
                            Label("打开 WebUI", systemImage: "safari")
                                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).hoverHighlight().frame(maxWidth: .infinity)
                        Button { showConnectionMenu = false; showServiceLogs = true } label: {
                            Label("运行日志", systemImage: "doc.text.magnifyingglass")
                                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).hoverHighlight().frame(maxWidth: .infinity)
                        Button { showConnectionMenu = false; showStats = true } label: {
                            Label("统计数据", systemImage: "chart.bar.xaxis")
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
                .help("界面主题")
                .popover(isPresented: $showAppearanceMenu, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        appearanceButton("日间", value: "light")
                        appearanceButton("夜间", value: "dark")
                        appearanceButton("自动", value: "auto")
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
            if selectedProjectID == id { selectedProjectID = nil; selectedSessionID = nil }
        case .session(let id):
            await mothx.deleteSession(id: id)
            if selectedSessionID == id { selectedSessionID = nil }
        }
    }
}

enum SidebarDelete { case project(String); case session(String) }


struct ProjectTreeRow: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    let project: MothxProject; let expanded: Bool
    @Binding var selectedProjectID: String?; @Binding var selectedSessionID: String?; @Binding var showSettings: Bool
    let toggle: () -> Void; let addSession: () -> Void; let delete: () -> Void
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
                }.buttonStyle(.plain).hoverHighlight()
                if isHovered {
                    Spacer()
                    Button(action: addSession) { Image(systemName: "plus") }.buttonStyle(.plain).hoverHighlight().help(languageStore.copy.addSession)
                    Button {
                        editedName = project.name
                        editedWorkDir = project.workDir
                        showEditor = true
                    } label: { Image(systemName: "pencil") }.buttonStyle(.plain).hoverHighlight().help(languageStore.copy.text("编辑项目", "Edit project"))
                    Button(action: delete) { Image(systemName: "trash") }.buttonStyle(.plain).hoverHighlight().foregroundStyle(.red.opacity(0.75))
                }
            }
            .padding(.vertical, 6)
            .foregroundStyle(.primary)
            .onHover { isHovered = $0 }
            if expanded {
                ForEach(projectSessions) { session in
                    SessionTreeRow(session: session, selected: selectedSessionID == session.id, select: {
                        selectedProjectID = project.id
                        selectedSessionID = session.id
                        showSettings = false
                    }, delete: { Task { await mothx.deleteSession(id: session.id) } })
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
    let session: MothxSession; let selected: Bool; let select: () -> Void; let delete: () -> Void
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
            .hoverHighlight()
            if isHovered {
                Button(action: delete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .hoverHighlight()
            }
        }
        .padding(.leading, 24)
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .background(selected ? Color.primary.opacity(0.1) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(selected ? .primary : .secondary)
        .onHover { isHovered = $0 }
    }
}

struct SidebarItem: View { let title: String; let icon: String; let selected: Bool; let action: () -> Void
    var body: some View { Button(action: action) { Label(title, systemImage: icon).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).padding(.horizontal, 10).background(selected ? Color.primary.opacity(0.1) : .clear).clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle()) }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading).hoverHighlight().foregroundStyle(selected ? .primary : .secondary) }
}
