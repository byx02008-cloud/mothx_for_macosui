import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Charts

struct ContentView: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    @State private var selectedSessionID: String?
    @State private var prompt = ""
    @State private var showSettings = false
    @State private var selectedProjectID: String?
    @State private var showNewProject = false
    @State private var newProjectName = ""
    @State private var newProjectWorkDir = ""
    @State private var appearanceNow = Date()
    @AppStorage("appearanceMode") private var appearanceMode = "auto"

    private var languageStoreCopy: Copy { languageStore.copy }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selectedProjectID: $selectedProjectID, selectedSessionID: $selectedSessionID, showSettings: $showSettings, showNewProject: $showNewProject, appearanceMode: $appearanceMode)
            Divider()
            if showSettings {
                SettingsView(showSettings: $showSettings)
            } else {
                WorkspaceView(prompt: $prompt, sessionID: selectedSessionID)
            }
        }
        .frame(minWidth: 1050, minHeight: 700)
        .background(Color.codexBackground)
        .preferredColorScheme(effectiveColorScheme)
        .overlay(alignment: .top) { ConnectionBanner(state: mothx.state) }
        .sheet(isPresented: $showNewProject) {
            VStack(alignment: .leading, spacing: 16) {
                Text(languageStoreCopy.newProject).font(.title2.bold())
                TextField(languageStoreCopy.projectName, text: $newProjectName)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    TextField(languageStoreCopy.workDirectory, text: $newProjectWorkDir)
                        .textFieldStyle(.roundedBorder)
                    Button(languageStoreCopy.chooseDirectory) { chooseWorkDirectory() }
                }
                HStack {
                    Spacer()
                    Button(languageStoreCopy.cancel) { showNewProject = false }
                    Button(languageStoreCopy.create) {
                        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let workDir = newProjectWorkDir.trimmingCharacters(in: .whitespacesAndNewlines)
                        showNewProject = false; newProjectName = ""; newProjectWorkDir = ""
                        Task {
                            guard let project = await mothx.createProject(name: name, workDir: workDir) else { return }
                            selectedProjectID = project.id
                            selectedSessionID = nil
                            showSettings = false
                        }
                    }.buttonStyle(.borderedProminent).tint(.orange).disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newProjectWorkDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 520)
        }
        .task {
            await mothx.loadWorkspace()
            selectDefaultSessionIfNeeded()
        }
        .task {
            while !Task.isCancelled {
                appearanceNow = Date()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: mothx.activeSessions) { _, _ in
            selectDefaultSessionIfNeeded()
        }
    }

    private func selectDefaultSessionIfNeeded() {
        guard selectedSessionID == nil else { return }
        // The service identifies the current active session. Do not infer it
        // from the local history order, which can differ from the runtime.
        let session = mothx.activeSessions.first
        selectedSessionID = session?.id
        selectedProjectID = session?.projectID
    }

    private func chooseWorkDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { newProjectWorkDir = url.path }
    }

    private var effectiveColorScheme: ColorScheme {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default:
            // Calendar.current uses the Mac's current time zone. In automatic
            // mode the app is light from 07:00 through 18:59 and dark outside
            // that interval.
            let hour = Calendar.current.component(.hour, from: appearanceNow)
            return (7..<19).contains(hour) ? .light : .dark
        }
    }
}

private struct Sidebar: View {
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

private enum SidebarDelete { case project(String); case session(String) }

private struct StatsSummary: Codable {
    let totalRequests: Int
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
}

private struct StatsAggregate: Codable, Identifiable {
    let label: String
    let vendor: String
    let protocolName: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let requests: Int

    var id: String { "\(label)-\(vendor)-\(model)-\(protocolName)" }

    enum CodingKeys: String, CodingKey {
        case label, vendor, model, inputTokens, outputTokens, totalTokens, requests
        case protocolName = "protocol"
    }
}

private struct StatsEntry: Codable, Identifiable {
    let id: Int
    let timestamp: String
    let vendor: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let durationMs: Int
}

private struct StatsRecentPage: Codable {
    let items: [StatsEntry]
    let total: Int
    let page: Int
    let pageSize: Int
}

private enum StatsRange: String, CaseIterable, Identifiable {
    case seven = "最近 7 天"
    case thirty = "最近 30 天"
    case all = "全部时间"
    var id: String { rawValue }
    var days: Int? { self == .seven ? 7 : (self == .thirty ? 30 : nil) }
}

private struct StatsView: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var range: StatsRange = .seven
    @State private var summary = StatsSummary(totalRequests: 0, inputTokens: 0, outputTokens: 0, totalTokens: 0)
    @State private var allSummary = StatsSummary(totalRequests: 0, inputTokens: 0, outputTokens: 0, totalTokens: 0)
    @State private var timeseries: [StatsAggregate] = []
    @State private var providers: [StatsAggregate] = []
    @State private var models: [StatsAggregate] = []
    @State private var recent = StatsRecentPage(items: [], total: 0, page: 1, pageSize: 12)
    @State private var page = 1
    @State private var isLoading = false

    private var query: String {
        guard let days = range.days else { return "" }
        let today = Calendar.current.startOfDay(for: Date())
        let from = Calendar.current.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        return "?from=\(dateString(from))&to=\(dateString(today))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("统计数据").font(.system(size: 25, weight: .bold))
                Text("查看请求、Token、模型和 Provider 使用情况").foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(.bordered)
            }.padding(.horizontal, 28).padding(.vertical, 22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Picker("时间范围", selection: $range) {
                            ForEach(StatsRange.allCases) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 150)
                        Button { Task { await load() } } label: {
                            Label(isLoading ? "加载中…" : "刷新", systemImage: "arrow.clockwise")
                        }.buttonStyle(.bordered).disabled(isLoading)
                        Spacer()
                    }
                    GeometryReader { proxy in
                        let cardWidth = (proxy.size.width - 42) / 4

                        HStack(spacing: 14) {
                            StatsMetricCard(title: "请求数", value: formatStatsNumber(summary.totalRequests)).frame(width: cardWidth)
                            StatsMetricCard(title: "总 Token", value: formatStatsNumber(summary.totalTokens)).frame(width: cardWidth)
                            StatsMetricCard(title: "输入 Token", value: formatStatsNumber(summary.inputTokens)).frame(width: cardWidth)
                            StatsMetricCard(title: "输出 Token", value: formatStatsNumber(summary.outputTokens)).frame(width: cardWidth)
                        }
                    }.frame(height: 112)
                    GeometryReader { proxy in
                        let rankingWidth = (proxy.size.width - 28) / 3.6
                        HStack(spacing: 14) {
                            StatsTrendCard(data: timeseries, total: summary.totalTokens).frame(width: rankingWidth * 1.6)
                            StatsRankingCard(title: "Provider 排行", rows: providers, label: { $0.label }).frame(width: rankingWidth)
                            StatsRankingCard(title: "模型排行", rows: models, label: { $0.model.isEmpty ? $0.label : $0.model }).frame(width: rankingWidth)
                        }
                    }.frame(height: 300)
                    StatsRecentCard(page: $page, data: recent, allTotal: allSummary.totalRequests, loadPage: { target in
                        page = target
                        Task { await loadRecent(page: target) }
                    })
                }.padding(28)
            }
        }
        .frame(minWidth: 1100, minHeight: 760)
        .background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
        .task { await load() }
        .onChange(of: range) { _, _ in Task { await load() } }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        page = 1
        let q = query
        let trendPath = q.isEmpty ? "api/stats/timeseries?groupBy=day" : "api/stats/timeseries\(q)&groupBy=day"
        async let summaryData = mothx.fetchStats(path: "api/stats/summary\(q)")
        async let allSummaryData = mothx.fetchStats(path: "api/stats/summary")
        async let trendData = mothx.fetchStats(path: trendPath)
        async let providerData = mothx.fetchStats(path: "api/stats/by-provider\(q)")
        async let modelData = mothx.fetchStats(path: "api/stats/by-model\(q)")
        async let recentData = mothx.fetchStats(path: "api/stats/recent\(q)\(q.isEmpty ? "?" : "&")page=1&pageSize=12")
        let values = await (summaryData, allSummaryData, trendData, providerData, modelData, recentData)
        if let data = values.0, let value = try? JSONDecoder().decode(StatsSummary.self, from: data) { summary = value }
        if let data = values.1, let value = try? JSONDecoder().decode(StatsSummary.self, from: data) { allSummary = value }
        if let data = values.2, let value = try? JSONDecoder().decode([StatsAggregate].self, from: data) { timeseries = value }
        if let data = values.3, let value = try? JSONDecoder().decode([StatsAggregate].self, from: data) { providers = value }
        if let data = values.4, let value = try? JSONDecoder().decode([StatsAggregate].self, from: data) { models = value }
        if let data = values.5, let value = try? JSONDecoder().decode(StatsRecentPage.self, from: data) { recent = value }
        isLoading = false
    }

    private func loadRecent(page: Int) async {
        let q = query
        guard let data = await mothx.fetchStats(path: "api/stats/recent\(q)\(q.isEmpty ? "?" : "&")page=\(page)&pageSize=12"),
              let value = try? JSONDecoder().decode(StatsRecentPage.self, from: data) else { return }
        recent = value
    }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

private struct StatsMetricCard: View {
    let title: String
    let value: String
    var body: some View {
        StatsCard { VStack(alignment: .leading, spacing: 10) { Text(title).font(.headline).foregroundStyle(.secondary); Text(value).font(.system(size: 28, weight: .bold, design: .rounded)) } }.frame(maxWidth: .infinity).frame(minHeight: 112, alignment: .leading)
    }
}

private struct StatsTrendCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let data: [StatsAggregate]
    let total: Int
    var body: some View {
        StatsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("使用趋势").font(.headline); Spacer(); Text("总 Token: \(formatStatsNumber(total))").foregroundStyle(.secondary) }
                if data.isEmpty { ContentUnavailableView("暂无数据", systemImage: "chart.bar") .frame(maxWidth: .infinity, minHeight: 210) }
                else {
                    Chart(data) { item in
                        BarMark(x: .value("日期", shortDate(item.label)), y: .value("Token", item.totalTokens)).foregroundStyle(.linearGradient(colors: colorScheme == .light ? [.black.opacity(0.9), .green] : [.green.opacity(0.55), .green], startPoint: .top, endPoint: .bottom))
                    }.chartYAxis { AxisMarks(position: .leading) }.chartLegend(.hidden).frame(height: 230)
                }
            }
        }.frame(maxWidth: .infinity).frame(height: 300)
    }
}

private struct StatsRankingCard: View {
    let title: String
    let rows: [StatsAggregate]
    let label: (StatsAggregate) -> String
    var body: some View {
        StatsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text(title).font(.headline); Spacer(); Text("\(rows.count) 个").foregroundStyle(.secondary) }
                if rows.isEmpty { Text("暂无数据").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 215, alignment: .center) }
                else { VStack(alignment: .leading, spacing: 15) { ForEach(Array(rows.prefix(6))) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(label(row)).lineLimit(1); Spacer(); Text(formatStatsNumber(row.totalTokens)).foregroundStyle(.secondary) }
                        GeometryReader { proxy in RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)).overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 4).fill(.green).frame(width: proxy.size.width * CGFloat(row.totalTokens) / CGFloat(max(1, rows[0].totalTokens))) } }.frame(height: 8)
                    }
                } }.frame(minHeight: 215, alignment: .top) }
            }
        }.frame(maxWidth: .infinity).frame(height: 300)
    }
}

private struct StatsRecentCard: View {
    @Binding var page: Int
    let data: StatsRecentPage
    let allTotal: Int
    let loadPage: (Int) -> Void
    var body: some View {
        StatsCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack { Text("最近请求").font(.headline); Spacer(); Text("\(allTotal) 个").foregroundStyle(.secondary) }.padding(.bottom, 14)
                HStack { Text("时间").frame(width: 145, alignment: .leading); Text("模型").frame(maxWidth: .infinity, alignment: .leading); Text("Provider").frame(width: 150, alignment: .leading); Text("输入").frame(width: 80, alignment: .trailing); Text("输出").frame(width: 80, alignment: .trailing); Text("耗时").frame(width: 70, alignment: .trailing) }.font(.caption.bold()).foregroundStyle(.secondary).padding(.vertical, 10).background(Color.primary.opacity(0.05))
                ForEach(data.items) { item in
                    HStack { Text(formatStatsTime(item.timestamp)).frame(width: 145, alignment: .leading); Text(item.model).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading); Text(item.vendor).frame(width: 150, alignment: .leading); Text(formatStatsNumber(item.inputTokens)).frame(width: 80, alignment: .trailing); Text(formatStatsNumber(item.outputTokens)).frame(width: 80, alignment: .trailing); Text(String(format: "%.1fs", Double(item.durationMs) / 1000)).frame(width: 70, alignment: .trailing) }.padding(.vertical, 10).overlay(alignment: .bottom) { Divider().opacity(0.35) }
                }
                HStack(spacing: 5) {
                    Spacer()
                    Button { if page > 1 { loadPage(page - 1) } } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless).disabled(page <= 1)
                    ForEach(visiblePages, id: \.self) { pageNumber in
                        Button { if pageNumber != page { loadPage(pageNumber) } } label: {
                            Text("\(pageNumber)").frame(width: 26, height: 24)
                        }.buttonStyle(.plain).background(pageNumber == page ? Color.accentColor.opacity(0.16) : .clear).clipShape(RoundedRectangle(cornerRadius: 5)).foregroundStyle(pageNumber == page ? Color.accentColor : .primary)
                    }
                    Text("第 \(page) / \(totalPages) 页").font(.caption).foregroundStyle(.secondary).padding(.leading, 5)
                    Button { if page * data.pageSize < data.total { loadPage(page + 1) } } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless).disabled(page * data.pageSize >= data.total)
                }.padding(.top, 14)
            }
        }
    }

    private var totalPages: Int { max(1, Int(ceil(Double(data.total) / Double(max(1, data.pageSize))))) }

    private var visiblePages: [Int] {
        let first = max(1, min(page - 2, totalPages - 4))
        let last = min(totalPages, first + 4)
        return Array(first...last)
    }
}

private struct StatsCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(18)
            // Apply the flexible size before drawing the background and border.
            // The border must belong to the complete outer card, not only to
            // the intrinsic size of its contents.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(colorScheme == .dark ? Color(nsColor: .underPageBackgroundColor).opacity(0.35) : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(colorScheme == .dark ? Color.primary.opacity(0.16) : Color.gray.opacity(0.28)))
    }
}

private func formatStatsNumber(_ value: Int) -> String {
    let number = Double(value)
    if value >= 100_000_000 { return String(format: "%.1f亿", number / 100_000_000) }
    if value >= 10_000_000 { return String(format: "%.1f千万", number / 10_000_000) }
    if value >= 1_000_000 { return String(format: "%.1f百万", number / 1_000_000) }
    if value >= 10_000 { return String(format: "%.1f万", number / 10_000) }
    return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
}

private func shortDate(_ value: String) -> String { String(value.split(separator: " ").first?.suffix(5) ?? value.suffix(5)) }
private func formatStatsTime(_ value: String) -> String { value.replacingOccurrences(of: "T", with: " ").prefix(16).description }

private struct ProjectTreeRow: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    let project: MothxProject; let expanded: Bool
    @Binding var selectedProjectID: String?; @Binding var selectedSessionID: String?; @Binding var showSettings: Bool
    let toggle: () -> Void; let addSession: () -> Void; let delete: () -> Void
    @State private var showEditor = false
    @State private var editedName = ""
    @State private var editedWorkDir = ""
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
                Spacer()
                Button(action: addSession) { Image(systemName: "plus") }.buttonStyle(.plain).hoverHighlight().help(languageStore.copy.addSession)
                Button {
                    editedName = project.name
                    editedWorkDir = project.workDir
                    showEditor = true
                } label: { Image(systemName: "pencil") }.buttonStyle(.plain).hoverHighlight().help(languageStore.copy.text("编辑项目", "Edit project"))
                Button(action: delete) { Image(systemName: "trash") }.buttonStyle(.plain).hoverHighlight().foregroundStyle(.red.opacity(0.75))
            }.padding(.vertical, 6).foregroundStyle(.primary)
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

private struct SessionTreeRow: View {
    let session: MothxSession; let selected: Bool; let select: () -> Void; let delete: () -> Void
    var body: some View { HStack { Button(action: select) { Label(session.title, systemImage: "bubble.left").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).hoverHighlight(); Button(action: delete) { Image(systemName: "trash").font(.caption).foregroundStyle(.red.opacity(0.7)) }.buttonStyle(.plain).hoverHighlight() }.padding(.leading, 24).padding(.vertical, 5).padding(.horizontal, 7).background(selected ? Color.primary.opacity(0.1) : .clear).clipShape(RoundedRectangle(cornerRadius: 6)).foregroundStyle(selected ? .primary : .secondary) }
}

private struct SidebarItem: View { let title: String; let icon: String; let selected: Bool; let action: () -> Void
    var body: some View { Button(action: action) { Label(title, systemImage: icon).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).padding(.horizontal, 10).background(selected ? Color.primary.opacity(0.1) : .clear).clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle()) }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading).hoverHighlight().foregroundStyle(selected ? .primary : .secondary) }
}

private struct WorkspaceView: View {
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

    private var currentModels: [MothxModelConfig] {
        let provider = mothx.providers.first(where: { $0.id == mothx.defaultProvider }) ?? mothx.providers.first
        return provider?.models ?? []
    }

    var body: some View {
        let c = languageStore.copy
        return VStack(spacing: 0) {
            HStack {
                Text(mothx.sessions.first(where: { $0.id == sessionID })?.title ?? c.workspace).font(.system(size: 14, weight: .medium))
                Spacer()
                CurrentDirectoryMenu(path: currentWorkDir)
            }.padding(.horizontal, 24).frame(height: 54)
            Divider()
            if let sessionID {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        let messages = mothx.messagesBySession[sessionID] ?? []
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            if message.role.lowercased() == "assistant",
                               let historicalRun = mothx.historicalRunsByMessage[sessionID]?[message.id],
                               historicalRun.id != mothx.currentRunID {
                                RunStatusRow(status: historicalRun.status, elapsed: historicalRun.elapsed, error: historicalRun.error)
                            }
                            if mothx.runReplyMessageID == message.id {
                                RunStatusRow(status: mothx.runStatus ?? "", elapsed: mothx.runElapsed, error: mothx.runError)
                            }
                            MessageBubble(message: message)
                        }
                        if mothx.runSessionID == sessionID, mothx.runStatus != nil, mothx.runReplyMessageID == nil, let status = mothx.runStatus {
                            RunStatusRow(status: status, elapsed: mothx.runElapsed, error: mothx.runError)
                        }
                    }.frame(maxWidth: 760, alignment: .leading).padding(28).frame(maxWidth: .infinity)
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
            }
        }
    }

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

private struct DirectoryApplication: Identifiable {
    let url: URL
    var id: String { url.path }
    var name: String { FileManager.default.displayName(atPath: url.path) }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

private struct CurrentDirectoryMenu: View {
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

private struct MessageBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: MothxMessage
    private var isUser: Bool { message.role == "user" }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 70) }
            HStack(alignment: .top, spacing: 10) {
                if !isUser { Image("MothxLogo").resizable().scaledToFit().frame(width: 18, height: 18) }
                Text(message.content.isEmpty ? (isUser ? "…" : "Thinking…") : message.content)
                    .textSelection(.enabled)
                    .frame(maxWidth: 560, alignment: .leading)
                if isUser { Image(systemName: "person.circle").foregroundStyle(Color.secondary) }
            }
            .padding(14)
            .background(isUser ? userBackground : assistantBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if !isUser { Spacer(minLength: 70) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .id(message.id)
    }

    private var assistantBackground: Color {
        colorScheme == .light ? .white : .codexCard
    }

    private var userBackground: Color {
        colorScheme == .light ? Color(red: 0.94, green: 0.94, blue: 0.95) : Color.orange.opacity(0.18)
    }
}

private struct RunStatusRow: View {
    let status: String
    let elapsed: TimeInterval
    let error: String?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Text("\(statusLabel) \(formattedElapsed)")
                        .font(.caption)
                        .foregroundStyle(isErrorStatus || !(error ?? "").isEmpty ? Color.red : Color.primary.opacity(0.68))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            if expanded, let error, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.bottom, 5)
            }
            Divider()
        }
    }

    private var statusLabel: String {
        switch status.lowercased() {
        case "queued": return "排队中"
        case "running", "in_progress": return "模型处理中"
        case "completed", "succeeded": return "已完成"
        case "failed", "error": return "处理失败"
        case "cancelled", "canceled": return "已取消"
        case "timeout": return "等待超时"
        default: return status
        }
    }

    private var isErrorStatus: Bool {
        switch status.lowercased() {
        case "failed", "error", "timeout", "cancelled", "canceled": return true
        default: return false
        }
    }

    private var formattedElapsed: String {
        if elapsed < 60 { return String(format: "%.1f 秒", elapsed) }
        return String(format: "%.0f 分 %.0f 秒", floor(elapsed / 60), elapsed.truncatingRemainder(dividingBy: 60))
    }
}

private struct ComposerAttachment: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let dataURL: String?
}

private struct PromptComposer: View {
    private enum PlusSubmenu { case skills, tools }
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
                    // Return sends; Shift-Return and Command-Return retain the
                    // native TextEditor behavior and insert a blank line.
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

private struct Suggestion: View { let title: String; let icon: String
    var body: some View { Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8).background(Color.primary.opacity(0.06)).clipShape(Capsule()) }
}

private struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    @Binding var showSettings: Bool
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
                        Label("关闭设置", systemImage: "xmark")
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
                        ModelSection(provider: $draft, selectedID: $modelID, discovering: $discovering) { id in pendingDeletion = .model(id) }
                    }
                } else if section == "general" {
                    GeneralSection(language: $language)
                } else if section == "skills" {
                    SkillsSection(skillsDir: $skillsDir)
                } else {
                    SessionsSection(sessionDir: $sessionDir)
                }
                if let error = mothx.settingsError { Text(error).font(.callout).foregroundStyle(.red) }
            }.padding(38).frame(maxWidth: 900, alignment: .leading) }.frame(maxWidth: .infinity)
        }
        .background(settingsBackground)
        .onAppear { providerID = "" }
        .confirmationDialog("Confirm deletion", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
            Button(languageStore.copy.delete, role: .destructive) {
                guard let deletion = pendingDeletion else { return }
                pendingDeletion = nil
                switch deletion {
                case .provider(let id): Task { await mothx.deleteProvider(id: id) }
                case .model(let id):
                    if let index = draft.models.firstIndex(where: { $0.id == id }) { draft.models.remove(at: index); if modelID == id { modelID = "" } }
                }
            }
            Button(languageStore.copy.cancel, role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(pendingDeletion?.message ?? "This action cannot be undone.")
        }
        .task { await mothx.loadSettings(); defaultProviderID = mothx.defaultProvider; defaultModelID = mothx.defaultModel; defaultThinkingLevel = mothx.defaultThinkingLevel; defaultMode = mothx.defaultMode; language = mothx.tuilang; skillsDir = mothx.skillsDir; sessionDir = mothx.sessionDir; providerID = "" }
    }
    private func select(_ provider: MothxProviderConfig) { providerID = provider.id; draft = provider; modelID = provider.models.first?.id ?? ""; saved = false }
    private func save() async { await mothx.saveProvider(draft, asDefault: false); saved = true }

    private var settingsBackground: Color {
        colorScheme == .light ? .white : .codexBackground
    }
}

private enum DeletionRequest: Identifiable {
    case provider(String)
    case model(String)
    var id: String { switch self { case .provider(let id): return "provider-\(id)"; case .model(let id): return "model-\(id)" } }
    var message: String { switch self { case .provider(let id): return "Delete provider \(id)? Its configuration will be removed after confirmation."; case .model(let id): return "Delete model \(id)? It will be removed from the current provider after confirmation." } }
}

private struct ProviderList: View {
    @EnvironmentObject private var languageStore: LanguageStore
    let providers: [MothxProviderConfig]
    let defaultID: String
    let select: (MothxProviderConfig) -> Void
    let add: () -> Void
    let delete: (String) -> Void

    var body: some View {
        let c = languageStore.copy
        return SettingsCard(title: c.providers, subtitle: c.providerListSubtitle) {
            HStack { Text(c.allProviders).font(.headline); Spacer(); Button(action: add) { Label(c.addProvider, systemImage: "plus") }.buttonStyle(.borderedProminent).tint(.orange) }
            ForEach(providers) { provider in
                Button { select(provider) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: provider.id == defaultID ? "star.circle.fill" : "server.rack").font(.title3).foregroundStyle(provider.id == defaultID ? .orange : .secondary)
                        VStack(alignment: .leading, spacing: 4) { Text(provider.id).font(.system(size: 14, weight: .medium)); Text(provider.vendor.isEmpty ? provider.api : provider.vendor).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text("\(provider.models.count) models").font(.caption).foregroundStyle(.secondary)
                        Button { delete(provider.id) } label: { Image(systemName: "trash").foregroundStyle(.red.opacity(0.8)) }.buttonStyle(.plain)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }.padding(12).background(Color.primary.opacity(0.16)).clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).foregroundStyle(.primary)
            }
        }
    }
}

private struct ProviderNavigation: View {
    let providers: [MothxProviderConfig]; @Binding var selectedID: String; let defaultID: String; let select: (MothxProviderConfig) -> Void; let add: () -> Void
    var body: some View { VStack(alignment: .leading, spacing: 10) { Text("CONFIGURATION").sectionLabel().padding(.bottom, 8); Text("Providers").font(.headline); ForEach(providers) { p in Button { select(p) } label: { HStack { Image(systemName: selectedID == p.id ? "checkmark.circle.fill" : "circle").foregroundStyle(selectedID == p.id ? .orange : .secondary); VStack(alignment: .leading) { Text(p.id); Text(p.id == defaultID ? "Default provider" : (p.vendor.isEmpty ? p.api : p.vendor)).font(.caption).foregroundStyle(p.id == defaultID ? .orange : .secondary) }; Spacer() }.padding(9).background(selectedID == p.id ? Color.primary.opacity(0.1) : .clear).clipShape(RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain) }; Spacer(); Button(action: add) { Label("Add provider", systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(.orange) }.padding(22).frame(width: 230).background(Color.codexSidebar) }
}

private struct SettingsNavigation: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var languageStore: LanguageStore
    @Binding var section: String
    var body: some View { let c = languageStore.copy; return VStack(alignment: .leading, spacing: 8) { Text(c.settings.uppercased()).sectionLabel().padding(.bottom, 10); SettingsNavItem(title: c.general, icon: "gearshape", id: "general", section: $section); SettingsNavItem(title: c.providers, icon: "server.rack", id: "providers", section: $section); SettingsNavItem(title: c.skills, icon: "sparkles", id: "skills", section: $section); SettingsNavItem(title: c.sessions, icon: "clock", id: "sessions", section: $section); Spacer() }.padding(22).frame(width: 230).background(colorScheme == .light ? .white : .codexSidebar) }
}

private struct SettingsNavItem: View { let title: String; let icon: String; let id: String; @Binding var section: String
    var body: some View { Button { section = id } label: { Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(section == id ? Color.primary.opacity(0.1) : .clear).clipShape(RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle()) }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading).hoverHighlight().foregroundStyle(section == id ? .primary : .secondary) }
}

private struct GlobalDefaultsSection: View {
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

private struct GeneralSection: View {
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
                Button(c.save) { Task { await mothx.saveLanguage(language); languageStore.update(setting: language) } }.buttonStyle(.borderedProminent).tint(.orange)
            }
            Text(c.text("语言值会保存到 mothx settings.json 的 tuilang 字段。", "The language value is saved to mothx settings.json as tuilang.")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SkillsSection: View { @EnvironmentObject private var mothx: MothxServiceManager; @EnvironmentObject private var languageStore: LanguageStore; @Binding var skillsDir: String
    var body: some View { let c = languageStore.copy; return SettingsCard(title: c.skills, subtitle: c.text("对应 settings.json 的 skillsDir 和 skillHub", "settings.json skillsDir and skillHub")) { SettingsField(title: c.skillsDirectory, text: $skillsDir, placeholder: c.defaultSkillsDir); Text(c.skillHubHint).font(.caption).foregroundStyle(.secondary); Button(c.saveSkills) { Task { await mothx.saveSkillsAndSession(skillsDir: skillsDir, sessionDir: mothx.sessionDir) } }.buttonStyle(.borderedProminent).tint(.orange) } }
}

private struct SessionsSection: View { @EnvironmentObject private var mothx: MothxServiceManager; @EnvironmentObject private var languageStore: LanguageStore; @Binding var sessionDir: String
    var body: some View { let c = languageStore.copy; return SettingsCard(title: c.sessions, subtitle: c.text("对应 settings.json 的 sessionDir", "settings.json sessionDir")) { SettingsField(title: c.sessionDirectory, text: $sessionDir, placeholder: c.defaultSessionDir); Button(c.saveSessions) { Task { await mothx.saveSkillsAndSession(skillsDir: mothx.skillsDir, sessionDir: sessionDir) } }.buttonStyle(.borderedProminent).tint(.orange) } }
}

private struct ProviderSection: View { @EnvironmentObject private var languageStore: LanguageStore; @Binding var provider: MothxProviderConfig
    var body: some View { let c = languageStore.copy; return SettingsCard(title: c.provider, subtitle: c.text("对应 providers.<providerId>", "providers.<providerId>")) { SettingsField(title: c.providerID, text: $provider.id, placeholder: "openai"); SettingsField(title: c.vendor, text: $provider.vendor, placeholder: "optional adapter name"); SettingsField(title: c.apiProtocol, text: $provider.api, placeholder: "openai-chat"); SettingsField(title: c.baseURL, text: $provider.baseUrl, placeholder: "https://api.example.com/v1"); SettingsField(title: c.apiKey, text: $provider.apiKey, placeholder: "${PROVIDER_API_KEY}", secure: true); SettingsField(title: c.httpProxy, text: $provider.httpProxy, placeholder: "optional"); Toggle(c.forceHTTP11, isOn: $provider.forceHTTP11); SettingsField(title: c.thinkingFormat, text: $provider.thinkingFormat, placeholder: "optional") } }
}

private struct ModelSection: View { @EnvironmentObject private var mothx: MothxServiceManager; @EnvironmentObject private var languageStore: LanguageStore; @Binding var provider: MothxProviderConfig; @Binding var selectedID: String; @Binding var discovering: Bool; let delete: (String) -> Void
    var body: some View { let c = languageStore.copy; return SettingsCard(title: c.models, subtitle: c.text("对应 providers.<providerId>.models", "providers.<providerId>.models")) { HStack { Text(c.configuredModels).font(.headline); Spacer(); Button { provider.models.insert(MothxModelConfig(id: "new-model", name: "New model"), at: 0); selectedID = "new-model" } label: { Label(c.addModel, systemImage: "plus") }.buttonStyle(.bordered); Button { Task { discovering = true; let models = await mothx.discoverModels(provider: provider); if !models.isEmpty { provider.models = models; selectedID = models[0].id }; discovering = false } } label: { Label(discovering ? c.text("获取中…", "Discovering…") : c.discover, systemImage: "arrow.triangle.2.circlepath") }.buttonStyle(.bordered).disabled(provider.baseUrl.isEmpty) }; if provider.models.isEmpty { Text(c.noModelsHint).font(.callout).foregroundStyle(.secondary) } else { ForEach(provider.models.indices, id: \.self) { index in ModelRow(model: $provider.models[index], selected: selectedID == provider.models[index].id) { selectedID = provider.models[index].id } delete: { delete(provider.models[index].id) } } } } }
}

private struct ModelRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var model: MothxModelConfig
    let selected: Bool
    let select: () -> Void
    let delete: () -> Void

    var body: some View { VStack(alignment: .leading, spacing: 12) { Button(action: select) { HStack { Image(systemName: selected ? "chevron.down" : "chevron.right").font(.caption); Text(model.displayName).font(.system(size: 14, weight: .medium)); Text(model.id).font(.caption).foregroundStyle(.secondary); Spacer(); if model.reasoning { Text("Reasoning").font(.caption2).foregroundStyle(.orange) }; Button(action: delete) { Image(systemName: "trash").foregroundStyle(.red.opacity(0.8)) }.buttonStyle(.plain) }.foregroundStyle(.primary) }.buttonStyle(.plain); if selected { HStack { SettingsField(title: "Model ID", text: $model.id); SettingsField(title: "Name", text: $model.name) }; HStack { NumberField(title: "Context window", value: $model.contextWindow); NumberField(title: "Max tokens", value: $model.maxTokens) }; Toggle("Reasoning", isOn: $model.reasoning); Text("Input: \(model.input.isEmpty ? "text" : model.input.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) } }.padding(14).background(selected ? Color.primary.opacity(0.08) : (colorScheme == .light ? .white : .codexCard)).clipShape(RoundedRectangle(cornerRadius: 9)) }
}

private struct NumberField: View { let title: String; @Binding var value: Int
    var body: some View { HStack { Text(title); Spacer(); TextField("0", value: $value, format: .number).textFieldStyle(.plain).frame(width: 100).multilineTextAlignment(.trailing) }.padding(10).background(Color.primary.opacity(0.18)).clipShape(RoundedRectangle(cornerRadius: 6)) }
}

private struct SettingsCard<Content: View>: View {
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

private struct SettingsField: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    @Binding var text: String
    var placeholder = ""
    var secure = false

    var body: some View { HStack { Text(title).frame(width: 150, alignment: .leading); if secure { SecureField(placeholder, text: $text).textFieldStyle(.plain) } else { TextField(placeholder, text: $text).textFieldStyle(.plain) } }.padding(10).background(colorScheme == .light ? .white : Color.primary.opacity(0.18)).clipShape(RoundedRectangle(cornerRadius: 6)) }
}

private struct ServiceLogView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var mothx: MothxServiceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("运行日志", systemImage: "doc.text.magnifyingglass")
                    .font(.title2.bold())
                Spacer()
                Button("关闭") { dismiss() }
            }

            if mothx.serviceLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("暂无运行日志", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(mothx.serviceLog)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(24)
        .frame(width: 720, height: 480)
    }
}

private struct ConnectionBanner: View { let state: MothxServiceManager.State
    var body: some View { Group { switch state { case .checking: status("Checking mothx server…", .orange); case .starting: status("Starting mothx server…", .orange); case .failed(let message): status(message, .red); case .connected: EmptyView() } }.padding(.top, 8) }
    private func status(_ title: String, _ color: Color) -> some View { Label(title, systemImage: "circle.fill").font(.caption).foregroundStyle(color).padding(.horizontal, 12).padding(.vertical, 6).background(Color.codexCard).clipShape(Capsule()).shadow(radius: 8) }
}

private struct HoverHighlight: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(isHovered ? Color.primary.opacity(0.09) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onHover { isHovered = $0 }
    }
}

private extension View {
    func sectionLabel() -> some View { font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(1.1) }
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}
private extension Color {
    static let codexBackground = Color(nsColor: .windowBackgroundColor)
    static let codexSidebar = Color(nsColor: .controlBackgroundColor)
    static let codexCard = Color(nsColor: .underPageBackgroundColor)
}

#Preview { ContentView().environmentObject(MothxServiceManager()) }
