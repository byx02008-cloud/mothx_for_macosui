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
    @State private var showEnvironmentCheck = true
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
                SettingsView(showSettings: $showSettings, selectedProjectID: $selectedProjectID, selectedSessionID: $selectedSessionID)
            } else {
                WorkspaceView(prompt: $prompt, sessionID: selectedSessionID)
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
        .onChange(of: mothx.sessions) { _, _ in
            // The active-session endpoint can legitimately be empty while
            // persisted sessions are available. Re-evaluate after the full
            // session list finishes loading so the workspace is not blank.
            selectDefaultSessionIfNeeded()
        }
    }

    func selectDefaultSessionIfNeeded() {
        guard selectedSessionID == nil else { return }
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
