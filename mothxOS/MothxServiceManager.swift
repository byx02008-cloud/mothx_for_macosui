import Combine
import Foundation

enum WorkspaceSyncState: Equatable {
    case pending
    case passed
    case failed
}

/// Phases of the in-app mothx update flow, shared by the About section and
/// the launch-time update prompt.
enum MothxUpdateStage: Equatable {
    case stoppingService
    case installing
    case restartingService
    case succeeded
    case failed
    case needsAdmin

    var isFinished: Bool { self == .succeeded || self == .failed }
    /// Stages where the progress sheet may be closed by the user (finished
    /// states plus the admin-rights prompt, which is parked awaiting input).
    var isDismissable: Bool { isFinished || self == .needsAdmin }
}

enum MothxUpdateResult {
    case succeeded(version: String?)
    case needsAdmin
    case canceled
    case failed(detail: String)
}


private struct MothxHealthResponse: Decodable {
    let status: String
}

private struct MothxLogEvent: Decodable {
    let type: String
    let message: String?
    let timestamp: String?
    let data: AnyCodableValue?
}

private struct AnyCodableValue: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self.value = value; return }
        if let value = try? container.decode([String: AnyCodableValue].self) { self.value = value.mapValues(\.value); return }
        if let value = try? container.decode([AnyCodableValue].self) { self.value = value.map(\.value); return }
        if let value = try? container.decode(Bool.self) { self.value = value; return }
        if let value = try? container.decode(Double.self) { self.value = value; return }
        self.value = NSNull()
    }
}

final class MothxServiceManager: ObservableObject {
    enum State: Equatable {
        case checking
        case starting
        case connected
        case needsInstall
        case failed(String)
    }

    @Published private(set) var state: State = .checking
    @Published private(set) var providers: [MothxProviderConfig] = []
    @Published private(set) var defaultProvider = ""
    @Published private(set) var defaultModel = ""
    @Published private(set) var defaultThinkingLevel = ""
    @Published private(set) var defaultMode = "agent"
    @Published private(set) var installedSkills: [MothxSkill] = []
    @Published private(set) var activeSkillsBySession: [String: Set<String>] = [:]
    @Published private(set) var tuilang = "auto"
    @Published private(set) var skillsDir = ""
    @Published private(set) var sessionDir = ""
    @Published private(set) var imageGeneration = MothxImageGenerationConfig()
    @Published private(set) var projects: [MothxProject] = []
    @Published private(set) var sessions: [MothxSession] = []
    @Published private(set) var workspaceSyncState: WorkspaceSyncState = .pending
    @Published private(set) var activeSessions: [MothxSession] = []
    @Published private(set) var messagesBySession: [String: [MothxMessage]] = [:]
    @Published private(set) var historicalRunsByMessage: [String: [String: MothxRunSummary]] = [:]
    @Published private(set) var thinkingBySession: [String: String] = [:]
    @Published private(set) var pendingSessions: [String: MothxSession] = [:]
    @Published private(set) var isSubmittingRun = false
    @Published private(set) var isStreaming = false
    @Published private(set) var runError: String?
    @Published private(set) var runStatus: String?
    @Published private(set) var runElapsed: TimeInterval = 0
    /// Portion of the current run's input context served from the provider cache.
    /// This is nil until the provider reports usage for the first turn.
    @Published private(set) var runCacheHitRate: Double?
    @Published private(set) var runSessionID: String?
    @Published private(set) var runReplyMessageID: String?
    @Published var settingsError: String?
    private var rawSettings: [String: Any] = [:]
    let baseURL = URL(string: "http://127.0.0.1:7872")!
    /// Browser links are derived from the same endpoint used for health checks
    /// and API requests, rather than maintaining a separate UI-only URL.
    var webUIURL: URL { baseURL.appendingPathComponent("/") }
    var advancedTestURL: URL { URL(string: baseURL.absoluteString + "/#/settings")! }
    private var process: Process?
    private var startupPipe: Pipe?
    private static var cachedLoginShellEnvironment: [String: String]?
    private var startupOutput = ""
    private var logStreamTask: Task<Void, Never>?
    private var logSocket: URLSessionWebSocketTask?
    private var runStartedAt: Date?
    private var runExistingMessageIDs: Set<String> = []
    private var cancelRequested = false
    private var runEventTask: Task<Void, Never>?
    private var runEventStreamSessionID: String?
    private var runEventLastSeq: Int = 0
    @Published private(set) var currentRunID: String?
    @Published private(set) var sessionModels: [String: String] = [:]
    @Published private(set) var sessionProviders: [String: String] = [:]
    @Published private(set) var serviceLog = ""
    @Published private(set) var currentPlan: MothxPlan?
    @Published private(set) var currentRunningMessageID: String?
    @Published private(set) var isRunning: Bool = false
    private let localProjectStore = try? LocalProjectStore()
    weak var languageStore: LanguageStore?

    private var copy: Copy { Copy(resolvedLanguage: languageStore?.language ?? AppLanguage.resolve(setting: "auto")) }

    /// Localized description for an error, using our own copy for errors we
    /// throw ourselves (LocalProjectStore, settings decoding); falls back to
    /// the system-localized description for network/Foundation errors.
    private func describe(_ error: Error) -> String {
        if error is LocalProjectStoreUnavailable || error is LocalProjectStoreError {
            return copy.localDatabaseUnavailable
        }
        if let settingsError = error as? SettingsLoadError {
            switch settingsError {
            case .invalidResponse: return copy.settingsInvalidResponse
            case .noProvidersDecoded: return copy.settingsNoProvidersDecoded
            }
        }
        return error.localizedDescription
    }

    func connect() async {
        state = .checking

        // Always probe first. This also connects to a server started outside
        // this app instead of launching a second mothx process.
        if await isHealthy() {
            state = .connected
            startLogStream()
            await loadSettings()
            return
        }

        // A previous connect attempt may still be booting. Wait for it rather
        // than spawning another server on the same port.
        if let process, process.isRunning {
            state = .starting
            await waitForHealth(process: process)
            if state == .connected {
                await loadSettings()
            }
            return
        }

        state = .starting
        guard let executable = await MothxServiceManager.resolveGlobalMothxExecutable() else {
            state = .needsInstall
            return
        }

        let workDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mothx", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        } catch {
            state = .failed(copy.workDirCreateFailedPrefix(describe(error)))
            return
        }

        let child = Process()
        child.executableURL = executable
        // Do not let serve.json select a different port from the one the UI
        // probes. An explicit CLI override is applied by mothx at startup.
        child.arguments = ["serve", "--port", "127.0.0.1:7872"]
        child.currentDirectoryURL = workDirectory
        // Without this, mothx serve inherits the GUI app's bare environment
        // (no PATH beyond /usr/bin, no shell-exported provider API keys),
        // and provider requests referencing ${SOME_API_KEY} fail even though
        // the same command works fine from a Terminal.
        child.environment = await MothxServiceManager.loginShellEnvironment()
        let output = Pipe()
        startupPipe = output
        startupOutput = ""
        serviceLog = ""
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.startupOutput += text
            }
        }
        child.standardOutput = output
        child.standardError = output
        child.terminationHandler = { [weak self] process in
            guard let self else { return }
            Task { @MainActor in
                if process.terminationStatus != 0, self.state != .connected {
                    self.state = .failed(self.failureMessage(status: process.terminationStatus))
                }
            }
        }

        do {
            try child.run()
            process = child
        } catch {
            state = .failed(copy.mothxLaunchFailedPrefix(describe(error)))
            return
        }
        await waitForHealth(process: child)
        if state == .connected {
            startLogStream()
            await loadSettings()
        }
    }

    /// App-launch-only entry point. Unlike connect(), which adopts any
    /// already healthy server, this kills whatever mothx instance is already
    /// listening on the default port first, then always starts a fresh
    /// app-owned process. isHealthy()'s response-body check confirms what's
    /// listening is actually mothx before terminating it, so this never
    /// kills an unrelated process that happens to occupy the port.
    func connectAtLaunch() async {
        state = .checking
        if await isHealthy() {
            await killExistingMothxOnDefaultPort()
        }
        await connect()
    }

    private func killExistingMothxOnDefaultPort() async {
        await MothxServiceManager.runShellFireAndForget("lsof -ti tcp:7872 | xargs kill 2>/dev/null")
        for _ in 0..<20 {
            if !(await isHealthy()) { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        await MothxServiceManager.runShellFireAndForget("lsof -ti tcp:7872 | xargs kill -9 2>/dev/null")
        for _ in 0..<8 {
            if !(await isHealthy()) { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func runShellFireAndForget(_ command: String) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { continuation.resume(); return }
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }

    private func waitForHealth(process: Process) async {
        for _ in 0..<80 {
            if await isHealthy() {
                state = .connected
                return
            }
            if !process.isRunning {
                state = .failed(failureMessage(status: process.terminationStatus))
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        state = .failed(failureMessage(status: process.terminationStatus, timedOut: true))
    }

    private func failureMessage(status: Int32, timedOut: Bool = false) -> String {
        let output = readStartupOutput()
        if !output.isEmpty { return copy.serveStartFailedWithOutput(output) }
        if timedOut { return copy.serveStartTimeout }
        return copy.serveExited(status)
    }

    private func readStartupOutput() -> String {
        startupOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startLogStream() {
        logStreamTask?.cancel()
        logSocket?.cancel(with: .goingAway, reason: nil)
        serviceLog = ""

        logStreamTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                var request = URLRequest(url: URL(string: "ws://127.0.0.1:7872/ws/logs")!)
                // mothx's WebSocket origin check rejects requests without a
                // local WebUI origin, even though the service itself is local.
                request.setValue("http://127.0.0.1:7872/", forHTTPHeaderField: "Origin")
                let socket = URLSession.shared.webSocketTask(with: request)
                socket.resume()
                self.logSocket = socket
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        self.consumeLogMessage(message)
                    }
                } catch {
                    // Reconnect after a transient disconnect while mothx is up.
                }
                socket.cancel(with: .goingAway, reason: nil)
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(1))
            }
            self.logSocket = nil
        }
    }

    private func consumeLogMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: return
        }
        guard let event = try? JSONDecoder().decode(MothxLogEvent.self, from: data) else { return }
        guard event.type != "heartbeat" && event.type != "connected" else { return }

        let timestamp = event.timestamp.map { String($0.prefix(19)).replacingOccurrences(of: "T", with: " ") }
        let body: String
        if let message = event.message, !message.isEmpty {
            body = message
        } else if let value = event.data?.value,
                  JSONSerialization.isValidJSONObject(value),
                  let encoded = try? JSONSerialization.data(withJSONObject: value),
                  let text = String(data: encoded, encoding: .utf8) {
            body = text
        } else {
            body = event.type
        }
        let prefix = timestamp.map { "[\($0)] " } ?? ""
        serviceLog += "\(prefix)[\(event.type)] \(body)\n"
    }

    func loadSettings() async {
        guard state == .connected else { return }
        do {
            let data = try await request(path: "api/settings", method: "GET")
            rawSettings = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            guard let root = rawSettings as? [String: Any] else { throw SettingsLoadError.invalidResponse }
            let providerObjects = root["providers"] as? [String: Any] ?? [:]
            providers = providerObjects.compactMap { key, value in
                guard let object = value as? [String: Any] else { return nil }
                return decodeProvider(id: key, object: object)
            }.sorted { $0.id < $1.id }
            defaultProvider = root["defaultProvider"] as? String ?? ""
            defaultModel = root["defaultModel"] as? String ?? ""
            defaultThinkingLevel = root["defaultThinkingLevel"] as? String ?? ""
            defaultMode = root["defaultMode"] as? String ?? "agent"
            tuilang = root["tuilang"] as? String ?? "auto"
            skillsDir = root["skillsDir"] as? String ?? ""
            sessionDir = root["sessionDir"] as? String ?? ""
            imageGeneration = decodeImageGeneration(object: root["imageGeneration"] as? [String: Any])
            if providers.isEmpty && !providerObjects.isEmpty {
                throw SettingsLoadError.noProvidersDecoded
            }
            settingsError = nil
        } catch {
            settingsError = copy.loadSettingsFailedPrefix(describe(error))
        }
    }

    func loadWorkspace() async {
        guard state == .connected else { return }
        workspaceSyncState = .pending
        var syncSucceeded = true

        var hadLocalProjectLoadError = false
        var localProjects: [MothxProject] = []
        do {
            guard let localProjectStore else { throw LocalProjectStoreUnavailable() }
            localProjects = try localProjectStore.projects()
        } catch {
            syncSucceeded = false
            hadLocalProjectLoadError = true
            settingsError = copy.loadLocalProjectsFailedPrefix(describe(error))
        }

        do {
            projects = try await synchronizeProjects(localProjects: localProjects)
        } catch {
            if !hadLocalProjectLoadError {
                settingsError = copy.loadLocalProjectsFailedPrefix(describe(error))
            }
            projects = localProjects
        }

        do {
            // MOTHX_API.md 3.2: the limit/offset form reads persisted sessions.
            var loadedSessions: [MothxSession] = []
            var offset = 0
            while true {
                let data = try await request(path: "api/sessions?limit=200&offset=\(offset)", method: "GET")
                let page = decodeSessions(data)
                loadedSessions.append(contentsOf: page)
                let total = decodeTotal(data)
                if page.isEmpty || page.count < 200 || (total > 0 && loadedSessions.count >= total) { break }
                offset += page.count
            }
            // Migrate the old desktop-only links once by projecting them into
            // mothx metadata. From this point on, the server response is the
            // only source of session/project membership.
            if let localProjectStore {
                let legacyLinks = (try? localProjectStore.projectIDsBySession()) ?? [:]
                for (sessionID, projectID) in legacyLinks where projects.contains(where: { $0.id == projectID }) {
                    _ = try? await setSessionProject(sessionID: sessionID, projectID: projectID)
                }
            }
            sessions = loadedSessions
            if !hadLocalProjectLoadError { settingsError = nil }
        } catch {
            syncSucceeded = false
            settingsError = copy.loadSessionsFailedPrefix(describe(error))
        }

        do {
            let data = try await request(path: "api/sessions/active", method: "GET")
            activeSessions = decodeSessions(data)
        } catch {
            syncSucceeded = false
            activeSessions = []
            if settingsError == nil { settingsError = copy.loadActiveSessionFailedPrefix(describe(error)) }
        }

        await loadInstalledSkills()
        workspaceSyncState = syncSucceeded ? .passed : .failed
    }

    private func synchronizeProjects(localProjects: [MothxProject]) async throws -> [MothxProject] {
        guard let localProjectStore else { throw LocalProjectStoreUnavailable() }
        let remoteData = try await request(path: "api/projects", method: "GET")
        var remoteProjects = decodeProjects(remoteData)
        let remoteIDs = Set(remoteProjects.map(\.id))

        // Legacy desktop projects have UUIDs that mothx does not know. Create
        // their remote counterparts and retain their existing work directory.
        for localProject in localProjects where !remoteIDs.contains(localProject.id) {
            let body = try jsonData(["name": localProject.name])
            let createdData = try await request(path: "api/projects", method: "POST", body: body)
            guard let created = decodeProject(createdData) else { throw SettingsLoadError.invalidResponse }
            try localProjectStore.replaceProjectID(oldID: localProject.id, newID: created.id)
            remoteProjects.append(MothxProject(id: created.id, name: created.name, workDir: localProject.workDir))
        }

        // The previous loop changed IDs in SQLite; rebuild the map using the
        // persisted rows so imported and migrated projects share one shape.
        let localByID = Dictionary(uniqueKeysWithValues: try localProjectStore.projects().map { ($0.id, $0) })
        for remoteProject in remoteProjects where localByID[remoteProject.id] == nil {
            _ = try localProjectStore.createProject(id: remoteProject.id, name: remoteProject.name, workDir: "")
        }

        let persisted = try localProjectStore.projects()
        for remoteProject in remoteProjects {
            if let local = persisted.first(where: { $0.id == remoteProject.id }), local.name != remoteProject.name {
                try localProjectStore.updateProjectName(id: remoteProject.id, name: remoteProject.name)
            }
        }
        return remoteProjects.map { remote in
            let local = persisted.first(where: { $0.id == remote.id })
            return MothxProject(id: remote.id, name: remote.name, workDir: local?.workDir ?? "")
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    private func setSessionProject(sessionID: String, projectID: String?) async throws -> Data {
        let body = try jsonData(["projectId": projectID ?? ""])
        return try await request(path: "api/sessions/\(sessionID)/metadata", method: "PATCH", body: body)
    }

    func moveSessionToProject(sessionID: String, projectID: String) async {
        do {
            _ = try await setSessionProject(sessionID: sessionID, projectID: projectID)
            sessions = sessions.map { session in
                var session = session
                if session.id == sessionID { session.projectID = projectID }
                return session
            }
            if let pending = pendingSessions[sessionID] {
                var pending = pending
                pending.projectID = projectID
                pendingSessions[sessionID] = pending
            }
        } catch {
            settingsError = copy.saveSessionProjectLinkFailedPrefix(describe(error))
        }
    }

    func fetchStats(path: String) async -> Data? {
        do {
            return try await request(path: path, method: "GET")
        } catch {
            settingsError = copy.loadStatsFailedPrefix(describe(error))
            return nil
        }
    }

    func createProject(name: String, workDir: String) async -> MothxProject? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !workDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            guard let localProjectStore else { throw LocalProjectStoreUnavailable() }
            let body = try jsonData(["name": name])
            let data = try await request(path: "api/projects", method: "POST", body: body)
            guard let remoteProject = decodeProject(data) else { throw SettingsLoadError.invalidResponse }
            let project = try localProjectStore.createProject(id: remoteProject.id, name: remoteProject.name, workDir: workDir)
            projects.append(project)
            return project
        } catch {
            settingsError = copy.createProjectFailedPrefix(describe(error))
            return nil
        }
    }

    func updateProject(id: String, name: String, workDir: String) async {
        do {
            guard let localProjectStore else { throw LocalProjectStoreUnavailable() }
            let body = try jsonData(["name": name])
            _ = try await request(path: "api/projects/\(id)", method: "PATCH", body: body)
            try localProjectStore.updateProject(id: id, name: name, workDir: workDir)
            guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
            projects[index].name = name
            projects[index].workDir = workDir
        } catch {
            settingsError = copy.updateProjectFailedPrefix(describe(error))
        }
    }

    func deleteProject(id: String) async {
        do {
            guard let localProjectStore else { throw LocalProjectStoreUnavailable() }
            _ = try await request(path: "api/projects/\(id)", method: "DELETE")
            try localProjectStore.deleteProject(id: id)
            projects.removeAll { $0.id == id }
            sessions = sessions.map { session in
                var session = session
                if session.projectID == id { session.projectID = nil }
                return session
            }
            for (sessionID, session) in pendingSessions where session.projectID == id {
                var unassigned = session
                unassigned.projectID = nil
                pendingSessions[sessionID] = unassigned
            }
        } catch {
            settingsError = copy.deleteProjectFailedPrefix(describe(error))
        }
    }

    /// Resolves the working directory for a session: the session's own workDir
    /// when present, otherwise its project's workDir. Shared by the workspace
    /// header, the run submission path, and the embedded TUI terminal panel.
    func workDir(for sessionID: String) -> String {
        let session = sessions.first(where: { $0.id == sessionID }) ?? pendingSessions[sessionID]
        if let sessionWorkDir = session?.workDir, !sessionWorkDir.isEmpty { return sessionWorkDir }
        guard let projectID = session?.projectID else { return "" }
        return projects.first(where: { $0.id == projectID })?.workDir ?? ""
    }

    func prepareSession(projectID: String?) -> MothxSession {
        // mothx has no empty-session endpoint. The returned ID is submitted
        // with the first real run and becomes persistent at that point.
        let session = MothxSession(id: UUID().uuidString.lowercased(), title: "New session", projectID: projectID, updatedAt: nil, workDir: nil)
        pendingSessions[session.id] = session
        return session
    }


    func deleteSession(id: String) async {
        // New sessions are local drafts until their first run. They have no
        // server record yet, so always remove the row locally even if DELETE
        // returns 404 or another server error.
        sessions.removeAll { $0.id == id }
        pendingSessions.removeValue(forKey: id)
        messagesBySession.removeValue(forKey: id)
        historicalRunsByMessage.removeValue(forKey: id)
        do { try localProjectStore?.removeSession(sessionID: id) }
        catch { settingsError = copy.deleteSessionProjectLinkFailedPrefix(describe(error)) }
        do {
            _ = try await request(path: "api/sessions/\(id)", method: "DELETE")
            await loadWorkspace()
        } catch {
            if !(error is URLError) {
                settingsError = copy.deleteSessionFailedPrefix(describe(error))
            }
        }
    }

    @discardableResult
    func loadMessages(sessionID: String) async -> [MothxMessage] {
        do {
            let data = try await request(path: "api/sessions/\(sessionID)/messages?limit=200", method: "GET")
            let messages = decodeMessages(data)
            messagesBySession[sessionID] = messages
            await loadHistoricalRuns(sessionID: sessionID, messages: messages)
            startRunEventStream(sessionID: sessionID)
            if sessionID == runSessionID {
                runReplyMessageID = messages.first { message in
                    message.role != "user" && !runExistingMessageIDs.contains(message.id)
                }?.id
            }
            // Plans are transient run UI state. Do not restore a historical
            // plan after the server has reported a terminal Run state.
            let terminalStatuses = ["completed", "succeeded", "failed", "error", "cancelled", "canceled", "timed_out", "timeout", "expired", "incomplete"]
            if sessionID == runSessionID, isRunning, !terminalStatuses.contains((runStatus ?? "").lowercased()),
               let plan = messages.last(where: { $0.isPlan && !runExistingMessageIDs.contains($0.id) })?.plan {
                currentPlan = plan
            } else if sessionID == runSessionID, terminalStatuses.contains((runStatus ?? "").lowercased()) {
                currentPlan = nil
            }
            return messages
        } catch {
            settingsError = copy.loadMessagesFailedPrefix(describe(error))
            return []
        }
    }

    func submitRun(sessionID: String, message: String, images: [String], workDir: String = "", provider: String = "", model: String = "", mode: String = "agent", tools: [String] = [], skills: [String] = []) async -> String? {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return nil }
        isSubmittingRun = true
        isStreaming = true
        cancelRequested = false
        runError = nil
        runStatus = "queued"
        runElapsed = 0
        runCacheHitRate = nil
        runSessionID = sessionID
        runReplyMessageID = nil
        currentRunID = nil
        currentPlan = nil
        currentRunningMessageID = nil
        thinkingBySession[sessionID] = ""
        isRunning = true
        runExistingMessageIDs = Set((messagesBySession[sessionID] ?? []).map(\.id))
        runStartedAt = Date()
        let pendingProjectID = pendingSessions[sessionID]?.projectID
        do {
            var payload: [String: Any] = ["message": message, "mode": mode, "transcript": true]
            // v1.2.95+: the run API accepts provider/model directly per run,
            // so the global defaults no longer need to be rewritten on submit.
            if !provider.isEmpty { payload["provider"] = provider }
            if !model.isEmpty { payload["model"] = model }
            if !tools.isEmpty { payload["tools"] = tools }
            if !skills.isEmpty { payload["skills"] = skills }
            if !workDir.isEmpty { payload["workDir"] = workDir }
            if !images.isEmpty { payload["images"] = images }
            // Show the submitted question immediately. The API returns 202 and
            // runs the agent in the background, so the assistant message is not
            // available in the first history response yet.
            let localMessage = MothxMessage(id: "local-\(UUID().uuidString)", seq: nil, role: "user", content: message, toolCallId: nil, toolName: nil, arguments: "", plan: nil, summary: nil, hasDetail: false, createdAt: ISO8601DateFormatter().string(from: Date()))
            messagesBySession[sessionID, default: []].append(localMessage)
            let body = try jsonData(payload)
            let response = try await request(path: "api/sessions/\(sessionID)/runs", method: "POST", body: body, headers: ["Idempotency-Key": UUID().uuidString])
            pendingSessions.removeValue(forKey: sessionID)
            let responseObject = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any]
            let runID = responseObject?["runId"] as? String ?? responseObject?["runID"] as? String
            guard let runID else {
                isSubmittingRun = false
                runStatus = "failed"
                currentPlan = nil
                runError = copy.noRunIDReturned
                return nil
            }
            if let projectID = pendingProjectID {
                do {
                    _ = try await setSessionProject(sessionID: sessionID, projectID: projectID)
                } catch {
                    settingsError = copy.saveSessionProjectLinkFailedPrefix(describe(error))
                }
            }
            currentRunID = runID
            if cancelRequested {
                await cancelRun()
            }
            return runID
        } catch {
            isSubmittingRun = false
            runStatus = "failed"
            currentPlan = nil
            runError = describe(error)
            settingsError = copy.submitRunFailedPrefix(describe(error))
            return nil
        }
    }

    func cancelRun() async {
        cancelRequested = true
        isSubmittingRun = false
        isStreaming = false
        guard let runID = currentRunID else { return }
        do {
            _ = try await request(path: "api/runs/\(runID)/cancel", method: "POST")
            runStatus = "cancelled"
            currentPlan = nil
            runElapsed = elapsedSinceRunStart()
        } catch {
            runError = copy.stopRunFailedPrefix(describe(error))
            settingsError = runError
        }
    }

    // MARK: - Interrupted-switch guard

    /// Switch action deferred until the user confirms stopping the current
    /// task (session/mode switches during a running task would stop it).
    private(set) var pendingSwitchAction: (() -> Void)?
    @Published private(set) var showSwitchConfirmation = false

    /// True when the serve API reports an active run for the session. Backed
    /// by the durable `session_runs` table (statuses created/queued/running/
    /// waiting_for_approval/waiting_for_question/cancelling/terminalizing), so
    /// it also sees runs started by the terminal-mode TUI process, not just
    /// runs submitted from this UI. Returns false on any error (offline, etc.).
    func sessionHasActiveRun(_ sessionID: String) async -> Bool {
        guard !sessionID.isEmpty else { return false }
        do {
            let data = try await request(path: "api/sessions/\(sessionID)/runtime", method: "GET")
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return object["activeRun"] is [String: Any]
        } catch {
            return false
        }
    }

    /// Runs `action` (a session/mode switch) immediately, or defers it behind
    /// a confirmation dialog while a task is running: either this UI's own run
    /// (`isRunning`) or an active run the serve API reports for
    /// `activeRunSessionID` (which includes runs started inside the mothx TUI).
    /// Idle states switch without any dialog.
    func requestSwitch(activeRunSessionID: String? = nil, _ action: @escaping () -> Void) {
        if isRunning {
            pendingSwitchAction = action
            showSwitchConfirmation = true
            return
        }
        guard let sessionID = activeRunSessionID else {
            action()
            return
        }
        Task { @MainActor in
            let busy = await sessionHasActiveRun(sessionID)
            if busy {
                pendingSwitchAction = action
                showSwitchConfirmation = true
            } else {
                action()
            }
        }
    }

    /// User confirmed: stop the current run first, then perform the switch.
    func confirmSwitch() {
        showSwitchConfirmation = false
        let action = pendingSwitchAction
        pendingSwitchAction = nil
        guard let action else { return }
        Task { @MainActor in
            await cancelRun()
            action()
        }
    }

    /// User declined: keep the current session/mode and the running task.
    func cancelSwitch() {
        showSwitchConfirmation = false
        pendingSwitchAction = nil
    }

    /// Plans are transient run UI state and must not be restored from history
    /// after a run reaches any terminal state.
    func clearCurrentPlan() {
        currentPlan = nil
    }

    func pollRun(runID: String, sessionID: String) async {
        defer {
            runElapsed = elapsedSinceRunStart()
            isSubmittingRun = false
            currentRunningMessageID = nil
            // Keep isRunning and isStreaming for a grace period so the stop
            // button and status indicators remain visible while the final
            // response text appears via typewriter.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                isRunning = false
                isStreaming = false
            }
        }
        // The server owns the run deadline. Keep polling until the server
        // reports a terminal state instead of applying a shorter client-side
        // timeout that can mislabel a still-running Agent Run.
        while !Task.isCancelled {
            runElapsed = elapsedSinceRunStart()
            do {
                let data = try await request(path: "api/runs/\(runID)", method: "GET")
                let object = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                let status = object["status"] as? String ?? object["state"] as? String ?? "running"
                runStatus = status
                // Usage is served by GET /api/sessions/{sessionID}/runs: each
                // run row carries `Usage` with prompt_tokens / cache_read_tokens.
                // Read the latest run row directly to compute the cache hit rate.
                if let usage = await latestRunUsage(sessionID: sessionID, runID: runID) {
                    updateRunCacheHitRate(from: usage)
                }
                let messages = await loadMessages(sessionID: sessionID)
                // Track current running message for typewriter effect
                if let replyID = runReplyMessageID {
                    currentRunningMessageID = replyID
                }
                // Also track the last assistant message explicitly
                if let lastAssistant = messages.last(where: { $0.isAssistant }) {
                    currentRunningMessageID = lastAssistant.id
                }
                if ["completed", "succeeded", "failed", "error", "cancelled", "canceled", "timed_out", "timeout", "expired", "incomplete"].contains(status.lowercased()) {
                    currentPlan = nil
                    if ["failed", "error", "timed_out", "timeout", "expired", "incomplete"].contains(status.lowercased()) {
                        runError = object["error"] as? String ?? object["errorMessage"] as? String ?? (status.lowercased() == "incomplete" ? copy.runFailedFallback : copy.waitReplyTimeout)
                    }
                    await loadWorkspace()
                    return
                }
            } catch {
                // A transient polling failure is not a Run failure. The
                // server remains the source of truth, so retry on the next
                // tick and let the server's terminal status decide the UI.
                settingsError = describe(error)
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func elapsedSinceRunStart() -> TimeInterval {
        guard let runStartedAt else { return runElapsed }
        return max(0, Date().timeIntervalSince(runStartedAt))
    }

    /// Usage may arrive in mothx's OpenAI `CompletionUsage` shape
    /// (prompt_tokens / completion_tokens / total_tokens / cache_read_tokens /
    /// cache_write_tokens) or the normalized provider shape (input / output /
    /// totalTokens / cacheRead / cacheWrite). Both are handled here.
    ///
    /// The denominator mirrors mothx's `Usage.TotalInputTokens()`: use
    /// `total - output` when a total is reported (so `prompt_tokens` already
    /// includes the cached portion and must NOT be inflated again), otherwise
    /// fall back to `input + cacheRead + cacheWrite`. The ratio therefore means
    /// "what portion of this turn's full prompt came from cache", matching the
    /// TUI's `CacheInfo` display.
    private func updateRunCacheHitRate(from rawUsage: Any?) {
        guard let usage = rawUsage as? [String: Any] else { return }
        let input = integerValue(usage["input"] ?? usage["Input"] ?? usage["inputTokens"] ?? usage["input_tokens"] ?? usage["prompt_tokens"])
        let output = integerValue(usage["output"] ?? usage["Output"] ?? usage["outputTokens"] ?? usage["completion_tokens"])
        let total = integerValue(usage["totalTokens"] ?? usage["TotalTokens"] ?? usage["total_tokens"])
        let cacheRead = integerValue(usage["cacheRead"] ?? usage["CacheRead"] ?? usage["cache_read_tokens"] ?? usage["cached_tokens"])
        let cacheWrite = integerValue(usage["cacheWrite"] ?? usage["CacheWrite"] ?? usage["cache_write_tokens"])
        let totalInput: Int
        if total > 0 {
            totalInput = max(0, total - output)
        } else {
            totalInput = input + cacheRead + cacheWrite
        }
        guard totalInput > 0 else { return }
        runCacheHitRate = min(1, max(0, Double(cacheRead) / Double(totalInput)))
    }

    /// Fetches the latest persisted usage for the active run from
    /// `GET /api/sessions/{sessionID}/runs` (newest-first). The row matching
    /// the active run ID is preferred so a retry or another attempt for the
    /// same intent cannot shadow the active run; otherwise the newest row is
    /// used. Returns nil when the endpoint is unavailable or the run has no
    /// usage yet — mothx only persists usage once the run terminalizes.
    private func latestRunUsage(sessionID: String, runID: String) async -> [String: Any]? {
        do {
            let data = try await request(path: "api/sessions/\(sessionID)/runs?limit=3", method: "GET")
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let runs = object["runs"] as? [[String: Any]] else { return nil }
            let usageFor: ([String: Any]) -> [String: Any]? = { row in
                (row["Usage"] as? [String: Any]) ?? (row["usage"] as? [String: Any])
            }
            if let matched = runs.first(where: { ($0["ID"] as? String) == runID || ($0["id"] as? String) == runID }),
               let usage = usageFor(matched) {
                return usage
            }
            if let newest = runs.first, let usage = usageFor(newest) {
                return usage
            }
            return nil
        } catch {
            return nil
        }
    }

    private func integerValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }

    private func loadHistoricalRuns(sessionID: String, messages: [MothxMessage]) async {
        do {
            let data = try await request(path: "api/sessions/\(sessionID)/runs?limit=200", method: "GET")
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let values = object["runs"] as? [[String: Any]] else { return }

            // The API returns newest-first and may contain multiple attempts
            // for one user turn. Keep only the latest attempt per intent, then
            // restore chronological order before pairing with transcript turns.
            let decodedRuns = values.compactMap(decodeRunSummary)
            var latestByIntent: [String: MothxRunSummary] = [:]
            var noIntentRuns: [MothxRunSummary] = []
            for run in decodedRuns {
                guard let intentID = run.intentID, !intentID.isEmpty else {
                    noIntentRuns.append(run)
                    continue
                }
                if latestByIntent[intentID] == nil { latestByIntent[intentID] = run }
            }
            let runs = (Array(latestByIntent.values) + noIntentRuns).sorted {
                ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast)
            }
            // A run maps to a user turn, not necessarily to an assistant
            // message: cancelled/tool-only turns have no assistant result.
            var turnMessageIDs: [String] = []
            var seenUser = false
            for message in messages {
                if message.isUser {
                    // The user entry is the stable anchor for every turn,
                    // including cancelled runs with no assistant message.
                    turnMessageIDs.append(message.id)
                    seenUser = true
                    continue
                }
                guard seenUser else { continue }
            }
            let pairCount = min(runs.count, turnMessageIDs.count)
            guard pairCount > 0 else { return }
            var mapping: [String: MothxRunSummary] = [:]
            for i in 0..<pairCount {
                mapping[turnMessageIDs[i]] = runs[i]
            }
            historicalRunsByMessage[sessionID] = mapping
        } catch {
            // Historical metadata is optional and must not prevent messages
            // from being displayed when an older server lacks this endpoint.
            historicalRunsByMessage[sessionID] = [:]
        }
    }

    private func decodeRunSummary(_ item: [String: Any]) -> MothxRunSummary? {
        guard let id = (item["ID"] as? String) ?? (item["id"] as? String),
              let status = (item["Status"] as? String) ?? (item["status"] as? String) else { return nil }
        return MothxRunSummary(
            id: id,
            intentID: (item["IntentID"] as? String) ?? (item["intentId"] as? String) ?? (item["intentID"] as? String),
            status: status,
            startedAt: parseDate(item["StartedAt"] ?? item["startedAt"]),
            finishedAt: parseDate(item["FinishedAt"] ?? item["finishedAt"]),
            updatedAt: parseDate(item["UpdatedAt"] ?? item["updatedAt"]),
            error: (item["Error"] as? String) ?? (item["error"] as? String)
        )
    }

    private func startRunEventStream(sessionID: String) {
        // Called on every polling tick (every ~500ms while a run is active),
        // not just once. Reconnecting the WebSocket that often tears down the
        // stream mid-generation, so short-lived reasoning content emitted
        // during the handshake gap never reaches thinkingBySession. Keep the
        // existing connection alive as long as it's already serving this
        // session; only (re)connect on session switch or genuine drop.
        if runEventStreamSessionID == sessionID, runEventTask != nil { return }
        runEventTask?.cancel()
        if runEventStreamSessionID != sessionID { runEventLastSeq = 0 }
        runEventStreamSessionID = sessionID
        runEventTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    if self.runEventStreamSessionID == sessionID {
                        self.runEventStreamSessionID = nil
                    }
                }
            }
            var request = URLRequest(url: URL(string: "ws://127.0.0.1:7872/ws/runs")!)
            request.setValue("http://127.0.0.1:7872/", forHTTPHeaderField: "Origin")
            let socket = URLSession.shared.webSocketTask(with: request)
            socket.resume()
            defer { socket.cancel(with: .goingAway, reason: nil) }
            do {
                try await socket.send(.string("{\"type\":\"hello\",\"clientId\":\"mothxOS\"}"))
                let startSeq = await MainActor.run { self.runEventLastSeq }
                let subscription = "{\"type\":\"subscribe\",\"subscriptions\":[{\"sessionId\":\"\(sessionID)\",\"cursor\":{\"seq\":\(startSeq)}}]}"
                try await socket.send(.string(subscription))
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard case .string(let text) = message,
                          let data = text.data(using: .utf8),
                          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if let seq = object["seq"] as? Int {
                        await MainActor.run { self.runEventLastSeq = max(self.runEventLastSeq, seq) }
                    }
                    guard object["stream"] as? String == "transcript",
                          let eventData = object["data"] as? [String: Any],
                          let messageObject = eventData["message"] as? [String: Any] else { continue }
                    if eventData["type"] as? String == "thinking_delta",
                       let delta = messageObject["content"] as? String {
                        await MainActor.run {
                            self.thinkingBySession[sessionID, default: ""] += delta
                        }
                    } else if eventData["type"] as? String == "plan_update",
                              let planObject = messageObject["plan"],
                              let plan = MothxPlan.parse(from: planObject) {
                        await MainActor.run {
                            if self.runSessionID == sessionID, self.isRunning {
                                self.currentPlan = plan
                            }
                        }
                    }
                }
            } catch { }
        }
    }

    private func parseDate(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func decodeMessages(_ data: Data) -> [MothxMessage] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let values: [[String: Any]]
        if let direct = object as? [[String: Any]] { values = direct }
        else { values = (object as? [String: Any])?["messages"] as? [[String: Any]] ?? [] }
        return values.enumerated().map { index, item in
            let id = item["id"] as? String ?? item["messageId"] as? String ?? "message-\(index)"
            let role = (item["role"] as? String) ?? "assistant"
            let seq = item["seq"] as? Int

            let content: String
            let toolCallId: String?
            let toolName: String?
            let arguments: String
            var plan: MothxPlan?
            let summary: String?
            let hasDetail: Bool

            switch role {
            case "toolCall":
                content = ""
                toolCallId = item["toolCallId"] as? String
                toolName = item["toolName"] as? String
                summary = nil
                hasDetail = false
                // arguments is a JSON object -> serialize to string
                if let args = item["arguments"] {
                    if let argsStr = args as? String { arguments = argsStr }
                    else if JSONSerialization.isValidJSONObject(args),
                            let argsData = try? JSONSerialization.data(withJSONObject: args),
                            let argsStr = String(data: argsData, encoding: .utf8) { arguments = argsStr }
                    else { arguments = "\(args)" }
                } else { arguments = "" }
                plan = MothxPlan.parse(from: item["plan"] ?? arguments)

            case "toolResult":
                content = ""
                toolCallId = item["toolCallId"] as? String
                toolName = item["toolName"] as? String
                arguments = ""
                plan = nil
                summary = item["summary"] as? String
                hasDetail = item["hasDetail"] as? Bool ?? false

            default:
                // user, assistant
                content = (item["content"] as? String) ?? (item["text"] as? String) ?? ""
                toolCallId = nil
                toolName = nil
                arguments = ""
                plan = nil
                summary = nil
                hasDetail = false
            }

            return MothxMessage(
                id: id, seq: seq, role: role,
                content: content, toolCallId: toolCallId,
                toolName: toolName, arguments: arguments,
                plan: plan,
                summary: summary, hasDetail: hasDetail,
                createdAt: (item["createdAt"] as? String)
                    ?? (item["created_at"] as? String)
                    ?? (item["timestamp"] as? String)
                    ?? (item["createdAt"] as? NSNumber).map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0.doubleValue)) }
            )
        }.filter { msg in
            if msg.isToolCall || msg.isToolResult { return true }
            return !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func setSessionProvider(_ provider: String, for sessionID: String) {
        if provider.isEmpty {
            sessionProviders.removeValue(forKey: sessionID)
        } else {
            sessionProviders[sessionID] = provider
            try? localProjectStore?.setProvider(provider, for: sessionID)
        }
    }

    func providerForSession(_ sessionID: String) -> String? {
        if let provider = sessionProviders[sessionID], !provider.isEmpty { return provider }
        let provider = try? localProjectStore?.provider(for: sessionID)
        if let provider = provider ?? nil {
            sessionProviders[sessionID] = provider
            return provider
        }
        return nil
    }

    func setSessionModel(_ model: String, for sessionID: String) {
        if model.isEmpty {
            sessionModels.removeValue(forKey: sessionID)
        } else {
            sessionModels[sessionID] = model
            try? localProjectStore?.setModel(model, for: sessionID)
        }
    }

    func modelForSession(_ sessionID: String) -> String? {
        if let model = sessionModels[sessionID] { return model }
        let model = try? localProjectStore?.model(for: sessionID)
        if let model = model ?? nil { sessionModels[sessionID] = model }
        return model ?? nil
    }

    private func loadInstalledSkills() async {
        do {
            let data = try await request(path: "api/skillhub/installed", method: "GET")
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let values = object["installed"] as? [[String: Any]] else { return }
            installedSkills = values.compactMap { item in
                guard let name = item["name"] as? String else { return nil }
                return MothxSkill(id: name, name: name, directory: item["dir"] as? String ?? "")
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            installedSkills = []
        }
    }

    func loadSkills(for sessionID: String) async {
        do {
            let data = try await request(path: "api/skillhub/installed?sessionId=\(sessionID)", method: "GET")
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let values = object["installed"] as? [[String: Any]] {
                installedSkills = values.compactMap { item in
                    guard let name = item["name"] as? String else { return nil }
                    return MothxSkill(id: name, name: name, directory: item["dir"] as? String ?? "")
                }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            let active = ((object["session"] as? [String: Any])?["activeSkills"] as? [String]) ?? []
            activeSkillsBySession[sessionID] = Set(active)
        } catch {
            activeSkillsBySession[sessionID] = []
        }
    }

    func updateSessionTitle(id: String, title: String) async {
        do {
            let body = try jsonData(["title": title])
            _ = try await request(path: "api/sessions/\(id)/title", method: "POST", body: body)
            await loadWorkspace()
        } catch { settingsError = copy.updateSessionFailedPrefix(describe(error)) }
    }

    private func decodeProject(_ data: Data) -> MothxProject? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String else { return nil }
        return MothxProject(id: id, name: object["name"] as? String ?? id, workDir: object["workDir"] as? String ?? object["workdir"] as? String ?? "")
    }

    private func decodeProjects(_ data: Data) -> [MothxProject] {
        guard let array = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let values: [[String: Any]]
        if let direct = array as? [[String: Any]] { values = direct }
        else { values = (array as? [String: Any])?["projects"] as? [[String: Any]] ?? [] }
        return values.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return MothxProject(id: id, name: item["name"] as? String ?? id, workDir: item["workDir"] as? String ?? item["workdir"] as? String ?? "")
        }
    }

    private func decodeTotal(_ data: Data) -> Int {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return object["total"] as? Int ?? 0
    }

    private func decodeSessions(_ data: Data) -> [MothxSession] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let values: [[String: Any]]
        if let direct = object as? [[String: Any]] { values = direct }
        else { values = (object as? [String: Any])?["sessions"] as? [[String: Any]] ?? [] }
        return values.compactMap { item in
            guard let id = item["id"] as? String ?? item["sessionId"] as? String else { return nil }
            return MothxSession(id: id, title: item["title"] as? String ?? item["preview"] as? String ?? "New session", projectID: item["projectId"] as? String ?? item["projectID"] as? String, updatedAt: item["updatedAt"] as? String ?? item["lastUsed"] as? String, workDir: item["workDir"] as? String ?? item["workdir"] as? String)
        }
    }

    @discardableResult
    func saveLanguage(_ value: String) async -> Bool {
        await saveGlobalSettings(["tuilang": value])
    }

    @discardableResult
    func saveGlobalSettings(_ values: [String: Any]) async -> Bool {
        do {
            for (key, value) in values { rawSettings[key] = value }
            let data = try JSONSerialization.data(withJSONObject: rawSettings)
            _ = try await request(path: "api/settings", method: "PUT", body: data)
            await loadSettings()
            return true
        } catch {
            settingsError = copy.saveGlobalSettingsFailedPrefix(describe(error))
            return false
        }
    }

    func saveDefaults(provider: String, model: String, thinkingLevel: String, mode: String) async {
        await saveGlobalSettings(["defaultProvider": provider, "defaultModel": model, "defaultThinkingLevel": thinkingLevel, "defaultMode": mode])
    }

    func saveSkillsAndSession(skillsDir: String, sessionDir: String) async {
        await saveGlobalSettings(["skillsDir": skillsDir, "sessionDir": sessionDir])
    }

    func saveImageGeneration(_ config: MothxImageGenerationConfig) async {
        var imageJSON = (rawSettings["imageGeneration"] as? [String: Any]) ?? [:]
        imageJSON["enabled"] = config.enabled
        imageJSON["provider"] = config.provider
        imageJSON["apiType"] = config.apiType
        imageJSON["baseUrl"] = config.baseUrl
        imageJSON["token"] = config.token
        imageJSON["model"] = config.model
        await saveGlobalSettings(["imageGeneration": imageJSON])
    }

    func deleteProvider(id: String) async {
        var providersJSON = (rawSettings["providers"] as? [String: Any]) ?? [:]
        providersJSON.removeValue(forKey: id)
        rawSettings["providers"] = providersJSON
        if rawSettings["defaultProvider"] as? String == id {
            rawSettings["defaultProvider"] = ""
            rawSettings["defaultModel"] = ""
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: rawSettings)
            _ = try await request(path: "api/settings", method: "PUT", body: data)
            await loadSettings()
        } catch { settingsError = copy.deleteProviderFailedPrefix(describe(error)) }
    }

    func saveProvider(_ provider: MothxProviderConfig, asDefault: Bool) async {
        do {
            var providerJSON = try jsonDictionary(provider)
            providerJSON.removeValue(forKey: "id")
            var providersJSON = (rawSettings["providers"] as? [String: Any]) ?? [:]
            providersJSON[provider.id] = providerJSON
            rawSettings["providers"] = providersJSON
            if asDefault {
                rawSettings["defaultProvider"] = provider.id
                rawSettings["defaultModel"] = provider.models.first?.id ?? ""
            }
            let data = try JSONSerialization.data(withJSONObject: rawSettings)
            _ = try await request(path: "api/settings", method: "PUT", body: data)
            await loadSettings()
        } catch {
            settingsError = copy.saveProviderFailedPrefix(describe(error))
        }
    }

    func discoverModels(provider: MothxProviderConfig) async -> [MothxModelConfig] {
        do {
            let body = try jsonData(["api": provider.api, "baseUrl": provider.baseUrl, "apiKey": provider.apiKey, "httpProxy": provider.httpProxy, "forceHTTP11": provider.forceHTTP11, "headers": provider.headers])
            let data = try await request(path: "api/provider/models", method: "POST", body: body)
            return decodeDiscoveredModels(data)
        } catch {
            settingsError = copy.discoverModelsFailedPrefix(describe(error))
            return []
        }
    }

    private func decodeDiscoveredModels(_ data: Data) -> [MothxModelConfig] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let items: [[String: Any]?]
        if let array = object as? [[String: Any]] {
            items = array.map(Optional.some)
        } else if let envelope = object as? [String: Any],
                  let values = (envelope["data"] as? [[String: Any]]) ?? (envelope["models"] as? [[String: Any]]) {
            items = values.map(Optional.some)
        } else {
            return []
        }

        var seen = Set<String>()
        return items.compactMap { item in
            guard let item else { return nil }
            let rawID = (item["id"] as? String) ?? (item["name"] as? String) ?? (item["model"] as? String) ?? ""
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            let name = ((item["name"] as? String) ?? (item["displayName"] as? String) ?? id).trimmingCharacters(in: .whitespacesAndNewlines)
            let contextWindow = (item["contextWindow"] as? Int) ?? (item["context_length"] as? Int) ?? 0
            let maxTokens = (item["maxTokens"] as? Int) ?? (item["max_output_tokens"] as? Int) ?? (item["max_tokens"] as? Int) ?? 0
            let input = (item["input"] as? [String]) ?? (item["input_modalities"] as? [String]) ?? ["text"]
            return MothxModelConfig(id: id, name: name.isEmpty ? id : name, reasoning: item["reasoning"] as? Bool ?? false, contextWindow: contextWindow, maxTokens: maxTokens, input: input)
        }
    }

    private func request(path: String, method: String, body: Data? = nil, headers: [String: String] = [:]) async throws -> Data {
        // Keep query parameters separate from the path. appendingPathComponent
        // percent-encodes '?' when the caller passes a path such as
        // "api/sessions?limit=200", turning the query into part of the route.
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw MothxAPIError(statusCode: http.statusCode, detail: detail)
        }
        return data
    }

    private func decodeImageGeneration(object: [String: Any]?) -> MothxImageGenerationConfig {
        guard let object else { return MothxImageGenerationConfig() }
        return MothxImageGenerationConfig(
            enabled: object["enabled"] as? Bool ?? false,
            provider: object["provider"] as? String ?? "openai",
            apiType: object["apiType"] as? String ?? "openai-images",
            baseUrl: object["baseUrl"] as? String ?? "https://api.openai.com/v1",
            token: object["token"] as? String ?? "",
            model: object["model"] as? String ?? "gpt-image-1"
        )
    }

    private func decodeProvider(id: String, object: [String: Any]) -> MothxProviderConfig? {
        let models = (object["models"] as? [[String: Any]] ?? []).compactMap { item -> MothxModelConfig? in
            guard let modelID = item["id"] as? String else { return nil }
            return MothxModelConfig(
                id: modelID,
                name: item["name"] as? String ?? modelID,
                reasoning: item["reasoning"] as? Bool ?? false,
                contextWindow: item["contextWindow"] as? Int ?? 0,
                maxTokens: item["maxTokens"] as? Int ?? 0,
                temperature: item["temperature"] as? Double,
                topP: item["top_p"] as? Double,
                input: item["input"] as? [String] ?? []
            )
        }
        let headers = object["headers"] as? [String: String] ?? [:]
        return MothxProviderConfig(
            id: id,
            vendor: object["vendor"] as? String ?? "",
            apiKey: object["apiKey"] as? String ?? "",
            baseUrl: object["baseUrl"] as? String ?? "",
            httpProxy: object["httpProxy"] as? String ?? "",
            forceHTTP11: object["forceHTTP11"] as? Bool ?? false,
            headers: headers,
            api: object["api"] as? String ?? "openai-chat",
            thinkingFormat: object["thinkingFormat"] as? String ?? "",
            models: models
        )
    }

    private func jsonData(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func jsonDictionary(_ value: MothxProviderConfig) throws -> [String: Any] { try (JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]) ?? [:] }

    /// Whether this app instance currently owns a running mothx process (as
    /// opposed to being connected to a server started outside the app).
    var ownsRunningProcess: Bool { process?.isRunning ?? false }

    /// Terminates the process this app itself started, if any. Safe to call
    /// when connected to an externally-started server: does nothing in that
    /// case, per the invariant that we never kill a foreign mothx process.
    func stopOwnedService() async {
        logStreamTask?.cancel()
        logSocket?.cancel(with: .goingAway, reason: nil)
        if let process, process.isRunning {
            process.terminate()
            for _ in 0..<20 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        self.process = nil
        state = .checking
    }

    func restartService() async {
        await stopOwnedService()
        await connect()
    }

    /// Runs the full update dance: stop the owned mothx service, run
    /// `npm install -g mothx-installer` (admin-elevated when `asAdmin`),
    /// restart the service, and report the outcome. Progress is delivered via
    /// `onStage` (phase transitions) and `onLog` (raw install output, already
    /// on the main actor).
    func performMothxUpdate(
        asAdmin: Bool = false,
        onStage: @escaping (MothxUpdateStage) -> Void,
        onLog: @escaping (String) -> Void
    ) async -> MothxUpdateResult {
        var logText = ""
        let append: (String) -> Void = { chunk in
            logText += chunk
            onLog(chunk)
        }

        onStage(.stoppingService)
        if ownsRunningProcess {
            await stopOwnedService()
        }

        onStage(.installing)
        #if DEBUG
        let simulatedEACCES = ProcessInfo.processInfo.environment["MOTHXOS_SIMULATE_UPDATE_EACCES"] == "1"
        #else
        let simulatedEACCES = false
        #endif
        let exitCode: Int32
        if asAdmin {
            exitCode = await RuntimeInstall.installGloballyAsAdmin { append($0) }
        } else if simulatedEACCES {
            append("\nnpm error code EACCES")
            exitCode = 1
        } else {
            exitCode = await RuntimeInstall.runShellStreaming("npm install -g mothx-installer") { append($0) }
        }

        onStage(.restartingService)
        await connect()

        if exitCode == 0 {
            return .succeeded(version: await RuntimeInstall.latestNpmVersion())
        }
        let lower = logText.lowercased()
        if lower.contains("cancel") || lower.contains("取消") {
            return .canceled
        }
        if RuntimeInstall.isPermissionError(lower) {
            return .needsAdmin
        }
        let detail = String(logText.suffix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(detail: detail.isEmpty ? "exit \(exitCode)" : detail)
    }

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 1.0
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return false }
            // Confirm the response body actually looks like mothx's /health
            // payload, not just any 2xx from whatever happens to be
            // listening on the port — callers rely on this to decide
            // whether it's safe to terminate the process.
            guard let health = try? JSONDecoder().decode(MothxHealthResponse.self, from: data) else { return false }
            return health.status.lowercased() == "ok"
        } catch {
            return false
        }
    }

    /// Resolves the native mothx binary managed by `npm install -g
    /// mothx-installer`. The global `mothx` command on PATH is a Node.js
    /// wrapper script (`#!/usr/bin/env node`) that shells out to the real,
    /// platform-specific compiled binary — launching the wrapper directly
    /// would require `node` to be on this app's (non-login-shell) PATH, and
    /// even then the wrapper's child process wouldn't be reliably
    /// terminated by our `terminate()` calls, risking an orphaned `mothx
    /// serve` holding the port after a stop/restart. So this resolves the
    /// real binary inside the platform optional-dependency package instead,
    /// which behaves like any other directly-launched executable.
    /// Presence-only check used by the launch-time environment checklist,
    /// which needs to know whether mothx is installed without needing the
    /// resolved executable URL itself.
    static func isMothxInstalled() async -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MOTHXOS_SIMULATE_MOTHX_MISSING"] == "1" { return false }
        #endif
        return await resolveGlobalMothxExecutable() != nil
    }

    static func resolveGlobalMothxExecutable() async -> URL? {
        guard let npmRoot = await shellCapturedPath("npm root -g") else { return nil }
        #if arch(arm64)
        let platformPackage = "mothx-installer-darwin-arm64"
        #else
        let platformPackage = "mothx-installer-darwin-x64"
        #endif
        let candidates = [
            "\(npmRoot)/mothx-installer/node_modules/\(platformPackage)/bin/mothx",
            "\(npmRoot)/\(platformPackage)/bin/mothx",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// Runs `command` in an interactive login shell (so nvm/homebrew PATH
    /// entries are honored) and returns the last absolute-path-looking line
    /// of its combined stdout+stderr output, or nil on failure. Stderr is
    /// merged into the drained pipe rather than left in a separate unread
    /// pipe — an interactive shell's rc-file output can otherwise fill an
    /// unread pipe's buffer and hang the child process indefinitely.
    private static func shellCapturedPath(_ command: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-i", "-l", "-c", command]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let text = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: nil)
                    return
                }
                let path = text
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .last(where: { $0.hasPrefix("/") })
                continuation.resume(returning: path)
            }
        }
    }

    /// GUI apps on macOS are launched by launchd/LaunchServices with a bare
    /// environment (`PATH=/usr/bin:/bin:/usr/sbin:/sbin`, no `.zshrc`/`.zprofile`
    /// exports) — provider API keys referenced from settings as `${SOME_KEY}`
    /// only exist in the user's login shell environment, so `mothx serve`
    /// launched with `Process`'s default (inherited) environment can fail to
    /// resolve them, causing provider calls to fail. This captures the login
    /// shell's full environment once and merges it over the app's own, so the
    /// child process sees the same variables the user's Terminal would.
    static func loginShellEnvironment() async -> [String: String] {
        if let cachedLoginShellEnvironment { return cachedLoginShellEnvironment }
        let env = await withCheckedContinuation { (continuation: CheckedContinuation<[String: String], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-i", "-l", "-c", "env -0"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ProcessInfo.processInfo.environment)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let text = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: ProcessInfo.processInfo.environment)
                    return
                }
                var merged = ProcessInfo.processInfo.environment
                for entry in text.split(separator: "\0") {
                    guard let separator = entry.firstIndex(of: "=") else { continue }
                    let key = String(entry[entry.startIndex..<separator])
                    let value = String(entry[entry.index(after: separator)...])
                    merged[key] = value
                }
                continuation.resume(returning: merged)
            }
        }
        cachedLoginShellEnvironment = env
        return env
    }
}


private struct MothxAPIError: LocalizedError {
    let statusCode: Int
    let detail: String
    var errorDescription: String? { "HTTP \(statusCode)：\(detail)" }
}

private enum WorkspaceError: LocalizedError {
    case projectResponseInvalid
    var errorDescription: String? { "项目创建接口返回的数据无效" }
}

private enum SettingsLoadError: LocalizedError {
    case invalidResponse
    case noProvidersDecoded
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "mothx /api/settings 返回格式无效"
        case .noProvidersDecoded: return "mothx /api/settings 中存在 providers，但客户端无法解析"
        }
    }
}

private struct SettingsEnvelope: Codable {
    var providers: [String: MothxProviderConfig] = [:]
    var defaultProvider: String = ""
    var defaultModel: String = ""
}

private struct DiscoveredModel: Codable {
    var id: String
    var name: String = ""
    var contextWindow: Int = 0
    var maxTokens: Int = 0
    var input: [String] = []
    var reasoning: Bool = false
}

private struct DiscoveredModelsResponse: Codable {
    var data: [DiscoveredModel]
}
