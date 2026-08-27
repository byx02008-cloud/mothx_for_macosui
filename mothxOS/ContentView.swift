import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Charts

struct ContentView: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    @Binding var showEnvironmentCheck: Bool
    @State private var selectedSessionID: String?
    @State private var selectedTeamProjectID: String?
    @State private var prompt = ""
    @State private var showSettings = false
    @State private var selectedProjectID: String?
    @State private var showNewProject = false
    @State private var newProjectName = ""
    @State private var newProjectWorkDir = ""
    @State private var appearanceNow = Date()
    @AppStorage("appearanceMode") private var appearanceMode = "auto"
    @AppStorage("ignoredMothxUpdateVersion") private var ignoredUpdateVersion = ""
    @State private var showUpdatePrompt = false
    @State private var pendingUpdateVersion: String?
    @State private var showUpdateProgress = false
    @State private var updateStage: MothxUpdateStage = .stoppingService
    @State private var updateLog = ""
    @State private var skipUpdatePromptThisLaunch = false

    @ViewBuilder
    private var workspaceContent: some View {
        if let teamProjectID = selectedTeamProjectID {
            TeamWorkspaceView(teamProjectID: teamProjectID)
        } else {
            WorkspaceView(
                prompt: $prompt,
                sessionID: selectedSessionID,
                onSessionActivated: { session in
                    // A successful server-side fork is only possible when
                    // the source has no active run. WorkspaceView invokes
                    // this after yielding out of the originating button's
                    // update transaction, so switch directly instead of
                    // starting the general switch-confirmation flow.
                    selectedTeamProjectID = nil
                    selectedSessionID = session.id
                    if let projectID = session.projectID { selectedProjectID = projectID }
                }
            )
        }
    }

    private var languageStoreCopy: Copy { languageStore.copy }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(teamManager: mothx.teamManager, selectedProjectID: $selectedProjectID, selectedSessionID: $selectedSessionID, selectedTeamProjectID: $selectedTeamProjectID, showSettings: $showSettings, showNewProject: $showNewProject, appearanceMode: $appearanceMode)
            Divider()
            if showSettings {
                SettingsView(showSettings: $showSettings, selectedProjectID: $selectedProjectID, selectedSessionID: $selectedSessionID)
            } else {
                workspaceContent
            }
        }
        .frame(minWidth: 1050, minHeight: 700)
        .background(Color.codexBackground)
        .preferredColorScheme(effectiveColorScheme)
        .overlay(alignment: .top) { ConnectionBanner(state: mothx.state) }
        .sheet(isPresented: $showEnvironmentCheck) {
            EnvironmentCheckSheet(isPresented: $showEnvironmentCheck)
        }
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
        .confirmationDialog(languageStoreCopy.switchStopTaskTitle, isPresented: Binding(get: { mothx.showSwitchConfirmation }, set: { if !$0 { mothx.cancelSwitch() } }), titleVisibility: .visible) {
            if mothx.canContinueModeSwitch {
                Button(languageStoreCopy.continueAndSwitch) { mothx.continueSwitch() }
            }
            Button(languageStoreCopy.stopAndSwitch, role: .destructive) { mothx.confirmSwitch() }
            Button(languageStoreCopy.cancel, role: .cancel) { mothx.cancelSwitch() }
        } message: {
            Text(languageStoreCopy.switchStopTaskMessage)
        }
        .confirmationDialog(languageStoreCopy.updatePromptTitle(pendingUpdateVersion ?? ""), isPresented: $showUpdatePrompt, titleVisibility: .visible) {
            Button(languageStoreCopy.updatePromptNow) {
                let version = pendingUpdateVersion ?? ""
                pendingUpdateVersion = nil
                skipUpdatePromptThisLaunch = true
                Task { await runUpdate(asAdmin: false) }
            }
            Button(languageStoreCopy.updatePromptIgnore) {
                if let version = pendingUpdateVersion { ignoredUpdateVersion = version }
                pendingUpdateVersion = nil
                skipUpdatePromptThisLaunch = true
            }
            Button(languageStoreCopy.updatePromptLater, role: .cancel) {
                pendingUpdateVersion = nil
                skipUpdatePromptThisLaunch = true
            }
        } message: {
            Text(languageStoreCopy.updatePromptMessage)
        }
        .sheet(isPresented: $showUpdateProgress) {
            UpdateProgressSheet(
                stage: updateStage,
                log: updateLog,
                onClose: { showUpdateProgress = false },
                onInstallAsAdmin: { Task { await runUpdate(asAdmin: true) } }
            )
        }
        .onChange(of: showEnvironmentCheck) { _, shown in
            // The environment check sheet closed — check once for a mothx update.
            guard !shown else { return }
            Task { await checkMothxUpdateAtLaunch() }
        }
        .task {
            await mothx.loadWorkspace()
            // Team layer safety net: make sure team projects are always loaded
            // even if loadWorkspace bailed early (e.g. offline at first paint).
            await mothx.teamManager.loadData()
            await mothx.teamManager.recoverActiveRuns()
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
        .onChange(of: mothx.sessions) { _, _ in
            // The active-session endpoint can legitimately be empty while
            // persisted sessions are available. Re-evaluate after the full
            // session list finishes loading so the workspace is not blank.
            selectDefaultSessionIfNeeded()
        }
    }

    /// After the environment check sheet closes, prompt once when a newer
    /// mothx version is published — unless the user skipped this launch or
    /// already ignored this exact version.
    private func checkMothxUpdateAtLaunch() async {
        guard !skipUpdatePromptThisLaunch else { return }
        #if DEBUG
        if ProcessInfo.processInfo.environment["MOTHXOS_SIMULATE_UPDATE_PROMPT"] == "1" {
            pendingUpdateVersion = "1.2.96"
            showUpdatePrompt = true
            return
        }
        #endif
        guard let latest = await RuntimeInstall.checkMothxUpdate() else { return }
        guard latest != ignoredUpdateVersion else { return }
        pendingUpdateVersion = latest
        showUpdatePrompt = true
    }

    /// Runs the shared update flow in the progress sheet (stop service → npm
    /// install → restart). `asAdmin` retries through the system authorization
    /// prompt.
    private func runUpdate(asAdmin: Bool) async {
        let c = languageStoreCopy
        updateLog = ""
        updateStage = .stoppingService
        showUpdateProgress = true
        let result = await mothx.performMothxUpdate(asAdmin: asAdmin, onStage: { stage in
            updateStage = stage
            let line = UpdateFlowSupport.stageLogLine(stage, c: c)
            if !line.isEmpty { updateLog += (updateLog.isEmpty ? "" : "\n") + line }
        }, onLog: { chunk in
            updateLog += chunk
        })
        updateStage = UpdateFlowSupport.terminalStage(for: result)
    }

    func selectDefaultSessionIfNeeded() {
        guard selectedSessionID == nil else { return }
        // Team task mode keeps its own selection; do not override it with a
        // default session while the user is configuring/running a team task.
        guard selectedTeamProjectID == nil else { return }
        // Prefer the service's active session. If none is active, restore the
        // most recently updated persisted session instead.
        let session = mothx.activeSessions.first ?? mostRecentSession
        selectedSessionID = session?.id
        selectedProjectID = session?.projectID
    }

    private var mostRecentSession: MothxSession? {
        mothx.sessions.max { lhs, rhs in
            sessionDate(lhs) < sessionDate(rhs)
        }
    }

    private func sessionDate(_ session: MothxSession) -> Date {
        guard let value = session.updatedAt else { return .distantPast }
        return ISO8601DateFormatter().date(from: value) ?? .distantPast
    }

    func chooseWorkDirectory() {
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
