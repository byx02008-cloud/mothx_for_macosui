import Combine
import Foundation
import AppKit

struct MothxToolResultDetail: Decodable {
    let toolCallID: String
    let toolName: String?
    let content: String
    let isError: Bool
    let oldText: String?
    let newText: String?
    let imagePreviews: [MothxImagePreview]

    private struct DiffPayload: Decodable {
        let oldText: String?
        let newText: String?

        enum CodingKeys: String, CodingKey {
            case oldText, newText
            case oldTextSnake = "old_text"
            case newTextSnake = "new_text"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            oldText = try container.decodeIfPresent(String.self, forKey: .oldText)
                ?? container.decodeIfPresent(String.self, forKey: .oldTextSnake)
            newText = try container.decodeIfPresent(String.self, forKey: .newText)
                ?? container.decodeIfPresent(String.self, forKey: .newTextSnake)
        }
    }

    enum CodingKeys: String, CodingKey {
        case toolCallID = "toolCallId"
        case toolCallIDSnake = "tool_call_id"
        case toolName, content, isError, oldText, newText, diff, toolDiff
        case toolNameSnake = "tool_name"
        case isErrorSnake = "is_error"
        case oldTextSnake = "old_text"
        case newTextSnake = "new_text"
        case toolDiffSnake = "tool_diff"
    }

    init(toolCallID: String, toolName: String?, content: String, isError: Bool, oldText: String?, newText: String?, imagePreviews: [MothxImagePreview] = []) {
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.content = content
        self.isError = isError
        self.oldText = oldText
        self.newText = newText
        self.imagePreviews = imagePreviews
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
            ?? container.decode(String.self, forKey: .toolCallIDSnake)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
            ?? container.decodeIfPresent(String.self, forKey: .toolNameSnake)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        // Older mothx servers omit isError for successful tool results.
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
            ?? container.decodeIfPresent(Bool.self, forKey: .isErrorSnake)
            ?? false
        let diff = try container.decodeIfPresent(DiffPayload.self, forKey: .diff)
            ?? container.decodeIfPresent(DiffPayload.self, forKey: .toolDiff)
            ?? container.decodeIfPresent(DiffPayload.self, forKey: .toolDiffSnake)
        oldText = try container.decodeIfPresent(String.self, forKey: .oldText)
            ?? container.decodeIfPresent(String.self, forKey: .oldTextSnake)
            ?? diff?.oldText
        newText = try container.decodeIfPresent(String.self, forKey: .newText)
            ?? container.decodeIfPresent(String.self, forKey: .newTextSnake)
            ?? diff?.newText
        imagePreviews = []
    }
}

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

struct MothxSessionMetrics: Equatable, Sendable {
    var contextUsedTokens: Int?
    var contextWindowTokens: Int?
    var cacheHitRate: Double?

    var contextUsageRate: Double? {
        guard let contextUsedTokens,
              let contextWindowTokens,
              contextWindowTokens > 0 else { return nil }
        return min(1, max(0, Double(contextUsedTokens) / Double(contextWindowTokens)))
    }
}

struct MothxImageRecognitionProgress: Equatable, Sendable {
    var isVisible = false
    var sessionID = ""
    var provider = ""
    var model = ""
    var status = ""
    var result = ""
    var isError = false
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
    @Published private(set) var imageRecognition = MothxImageRecognitionConfig()
    @Published private(set) var imageRecognitionProgress = MothxImageRecognitionProgress()
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
    /// Last known context occupancy and cache hit rate for each session.
    /// Keeping this state per session lets a reopened historical conversation
    /// show the latest turn's metrics without borrowing data from another tab.
    @Published private(set) var metricsBySession: [String: MothxSessionMetrics] = [:]
    @Published private(set) var runSessionID: String?
    @Published private(set) var runReplyMessageID: String?
    @Published var settingsError: String?
    private var rawSettings: [String: Any] = [:]

    /// Thinking text is transient UI state. Keep only the tail so a long run
    /// cannot grow an unbounded string while ACP or Serve streams deltas.
    private static let maximumThinkingLines = 200

    private func appendThinking(_ text: String, for sessionID: String) {
        guard !text.isEmpty else { return }
        let combined = thinkingBySession[sessionID, default: ""] + text
        let lines = combined.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > Self.maximumThinkingLines {
            thinkingBySession[sessionID] = lines.suffix(Self.maximumThinkingLines).map(String.init).joined(separator: "\n")
        } else {
            thinkingBySession[sessionID] = combined
        }
    }
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
    private var runtimeHeartbeatTask: Task<Void, Never>?
    private var runElapsedTask: Task<Void, Never>?
    private var logSocket: URLSessionWebSocketTask?
    private var runStartedAt: Date?
    private var runExistingMessageIDs: Set<String> = []
    private var cancelRequested = false
    private var runEventTask: Task<Void, Never>?
    private var runEventStreamSessionID: String?
    private var runEventLastSeq: Int = 0
    private var monitoredRunIDs: Set<String> = []
    private let acpClient = MothxACPClient()
    private var activeAgentTransport: MothxAgentTransport = .serve
    private var acpToolInputs: [String: [String: Any]] = [:]
    private var acpToolNames: [String: String] = [:]
    private var acpDurableRunID: String?
    private let changeStore = MothxChangeStore()
    private var fileChangesByRun: [String: [String: MothxFileChange]] = [:]
    private var toolChangesByCall: [String: MothxToolChangeRecord] = [:]
    @Published private(set) var currentRunID: String?
    @Published private(set) var sessionModels: [String: String] = [:]
    @Published private(set) var sessionProviders: [String: String] = [:]
    @Published private(set) var serviceLog = ""
    @Published private(set) var currentPlan: MothxPlan?
    @Published private(set) var currentRunningMessageID: String?
    @Published private(set) var changesByRun: [String: MothxTurnChanges] = [:]
    @Published private(set) var latestChangesBySession: [String: MothxTurnChanges] = [:]
    @Published private(set) var changesByMessage: [String: [String: MothxTurnChanges]] = [:]
    @Published private(set) var isRunning: Bool = false
    /// Agent team orchestration layer (profiles, team runs, scheduling).
    /// Kept as a nested ObservableObject so views observe it via `mothx.teamManager`.
    @Published var teamManager = TeamRunManager()
    private let localProjectStore = try? LocalProjectStore()
    weak var languageStore: LanguageStore?

    private var copy: Copy { Copy(resolvedLanguage: languageStore?.language ?? AppLanguage.resolve(setting: "auto")) }

    private static let imageRecognitionDefaultsKey = "mothxOS.imageRecognition"
    private static let imageGenerationDefaultsKey = "mothxOS.imageGeneration"

    init() {
        imageGeneration = Self.loadImageGenerationConfig()
        imageRecognition = Self.loadImageRecognitionConfig()
        let stored = changeStore.load()
        changesByRun = stored.turns
        fileChangesByRun = stored.turns.mapValues { turn in
            Dictionary(uniqueKeysWithValues: turn.files.map { ($0.path, $0) })
        }
        toolChangesByCall = stored.toolChanges
        // Rewrite legacy files into the versioned format. Legacy records remain
        // preview-only because they have no stable ACP tool-call key.
        persistChanges()
        recordRuntimeLog("lifecycle", "client initialized; runtimeLog=\(RuntimeLog.shared.fileURL.path)")
        runtimeHeartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                RuntimeLog.shared.write("heartbeat", "main actor alive")
            }
        }
    }

    deinit {
        runtimeHeartbeatTask?.cancel()
        runElapsedTask?.cancel()
        let client = acpClient
        Task { await client.stop() }
    }

    /// Records client-side diagnostics alongside the mothx service log and in
    /// a persistent file. Callers should pass metadata only.
    func recordRuntimeLog(_ category: String, _ message: String) {
        RuntimeLog.shared.write(category, message)
        let stamp = ISO8601DateFormatter().string(from: Date())
        serviceLog += "[\(stamp)] [client/\(category)] \(message)\n"
        if serviceLog.count > 60_000 { serviceLog = String(serviceLog.suffix(60_000)) }
    }

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
        if await isHealthy(), !UserDefaults.standard.bool(forKey: "mothxOS.reuseExistingService") {
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
            // Image generation routing is app-owned, just like image
            // recognition routing. The server's legacy imageGeneration
            // object may still be present in rawSettings and is deliberately
            // left untouched, but it no longer supplies credentials or a
            // second model selection UI.
            if !Self.hasStoredImageGenerationConfig,
               let legacy = decodeLegacyImageGeneration(object: root["imageGeneration"] as? [String: Any]),
               !legacy.providerID.isEmpty,
               !legacy.modelID.isEmpty {
                imageGeneration = legacy
                persistImageGeneration(legacy)
            }
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

        // Team projects are represented as ordinary mothx Projects on the
        // server. Load the client-owned mapping before publishing projects so
        // the sidebar never classifies team projects as regular projects on
        // startup.
        await teamManager.loadData()

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
            await teamManager.repairSessionProjectLinks()
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
        // Agent team layer: resume any active runs after sessions/projects are
        // available. The mapping itself was loaded before project publication.
        await teamManager.recoverActiveRuns()
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

    /// Creates a real ACP session up front when ACP is selected. Serve runs
    /// keep their existing lazy-session behavior because that API creates the
    /// session together with the first Run.
    func prepareSessionForSelectedTransport(projectID: String?) async -> MothxSession {
        guard preferredAgentTransport == .acp,
              let projectID,
              let project = projects.first(where: { $0.id == projectID }),
              !project.workDir.isEmpty else {
            return prepareSession(projectID: projectID)
        }
        do {
            try await ensureACPClient(tools: [])
            let sessionID = try await acpClient.createSession(cwd: project.workDir)
            let session = MothxSession(
                id: sessionID,
                title: "New session",
                projectID: projectID,
                updatedAt: ISO8601DateFormatter().string(from: Date()),
                workDir: project.workDir
            )
            sessions.removeAll { $0.id == sessionID }
            sessions.insert(session, at: 0)
            do {
                _ = try await setSessionProject(sessionID: sessionID, projectID: projectID)
            } catch {
                settingsError = copy.saveSessionProjectLinkFailedPrefix(describe(error))
            }
            recordRuntimeLog("acp", "created session=\(sessionID)")
            return session
        } catch {
            settingsError = copy.text("ACP 会话创建失败，已回退到 Serve：\(describe(error))", "ACP session creation failed; falling back to Serve: \(describe(error))")
            recordRuntimeLog("acp", "session creation failed error=\(describe(error))")
            return prepareSession(projectID: projectID)
        }
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

    /// v1.2.92+: create a child session at a server-validated message boundary.
    ///
    /// This deliberately does not mutate any published state. The view owns
    /// committing the result after the current SwiftUI update transaction has
    /// completed; publishing `sessions` while a message-button action is being
    /// reconciled causes SwiftUI's "Modifying state during view update" warning.
    @MainActor
    func forkSession(sessionID: String, atSeq: Int, idempotencyKey: String) async -> Result<MothxSession, Error> {
        recordRuntimeLog("fork", "request start session=\(sessionID) atSeq=\(atSeq)")
        guard !sessionID.isEmpty,
              !idempotencyKey.isEmpty,
              let parent = sessions.first(where: { $0.id == sessionID }) else {
            return .failure(SettingsLoadError.invalidResponse)
        }
        do {
            let body = try jsonData(["atSeq": atSeq])
            let data = try await request(
                path: "api/sessions/\(sessionID)/fork",
                method: "POST",
                body: body,
                headers: ["Idempotency-Key": idempotencyKey]
            )
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let childID = (object["sessionId"] as? String) ?? (object["sessionID"] as? String),
                  !childID.isEmpty else {
                return .failure(SettingsLoadError.invalidResponse)
            }

            // The server already atomically copies project ownership and writes
            // the incremented title. Its fork response does not include that
            // title, so retain the parent title until the next normal refresh.
            let child = MothxSession(
                id: childID,
                title: object["title"] as? String ?? parent.title,
                projectID: parent.projectID,
                updatedAt: ISO8601DateFormatter().string(from: Date()),
                workDir: parent.workDir,
                parentSessionId: (object["parentSessionId"] as? String) ?? sessionID,
                forkBoundarySeq: (object["boundarySeq"] as? Int) ?? atSeq,
                seedLength: object["seedLength"] as? Int,
                forkKind: object["forkKind"] as? String
            )
            return .success(child)
        } catch {
            recordRuntimeLog("fork", "request failed session=\(sessionID) atSeq=\(atSeq) error=\(describe(error))")
            return .failure(error)
        }
    }

    /// Apply the completed fork after the originating SwiftUI interaction has
    /// yielded. Keeping this separate from `forkSession` prevents published
    /// state changes during the source message view's update.
    @MainActor
    func integrateForkedSession(_ child: MothxSession) {
        sessions.removeAll { $0.id == child.id }
        sessions.insert(child, at: 0)
    }

    @MainActor
    func reportForkFailure(_ error: Error) {
        settingsError = copy.forkSessionFailedPrefix(describe(error))
    }

    func forkFailureMessage(_ error: Error) -> String {
        if let apiError = error as? MothxAPIError,
           apiError.statusCode == 409,
           apiError.detail.contains("fork_unavailable") {
            return copy.forkUnavailable
        }
        return copy.forkSessionFailedPrefix(describe(error))
    }

    func metrics(for sessionID: String) -> MothxSessionMetrics {
        metricsBySession[sessionID] ?? MothxSessionMetrics()
    }

    @discardableResult
    func loadMessages(sessionID: String) async -> [MothxMessage] {
        let started = Date()
        recordRuntimeLog("messages", "load start session=\(sessionID)")
        do {
            let data = try await request(path: "api/sessions/\(sessionID)/messages?limit=200", method: "GET")
            let messages = decodeMessages(data, sessionID: sessionID)
            recordRuntimeLog("messages", "load complete session=\(sessionID) count=\(messages.count) bytes=\(data.count) elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000))")
            messagesBySession[sessionID] = messages
            await loadHistoricalRuns(sessionID: sessionID, messages: messages)
            await rebuildHistoricalChanges(sessionID: sessionID, messages: messages)
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
            recordRuntimeLog("messages", "load failed session=\(sessionID) elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000)) error=\(describe(error))")
            settingsError = copy.loadMessagesFailedPrefix(describe(error))
            return []
        }
    }

    /// Loads one tool result only when the user opens its process page. The
    /// server response is bounded before it reaches a SwiftUI Text tree.
    func loadToolResultDetail(sessionID: String, toolCallID: String) async -> MothxToolResultDetail? {
        let started = Date()
        let escapedSession = pathEscaped(sessionID)
        let escapedCall = pathEscaped(toolCallID)
        do {
            let data = try await request(path: "api/sessions/\(escapedSession)/tool-results/\(escapedCall)", method: "GET")
            let decoded = try JSONDecoder().decode(MothxToolResultDetail.self, from: data)
            let rawObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            recordRuntimeLog("tool-detail", "load complete session=\(sessionID) call=\(toolCallID) bytes=\(data.count) elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000))")
            return MothxToolResultDetail(
                toolCallID: decoded.toolCallID,
                toolName: decoded.toolName,
                content: boundedToolDetail(decoded.content),
                isError: decoded.isError,
                oldText: decoded.oldText,
                newText: decoded.newText,
                imagePreviews: decodeImagePreviews(rawObject, sessionID: sessionID)
            )
        } catch {
            recordRuntimeLog("tool-detail", "load failed session=\(sessionID) call=\(toolCallID) elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000)) error=\(describe(error))")
            return nil
        }
    }

    private func pathEscaped(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func boundedToolDetail(_ value: String) -> String {
        let lines = value.components(separatedBy: .newlines)
        let limitedLines = lines.prefix(240)
        var result = limitedLines.joined(separator: "\n")
        if result.count > 12_000 { result = String(result.prefix(12_000)) + "\n…" }
        if lines.count > limitedLines.count { result += "\n…（结果过长，已截断）" }
        return result
    }

    var preferredAgentTransport: MothxAgentTransport {
        let raw = UserDefaults.standard.string(forKey: MothxAgentTransport.defaultsKey)
            ?? MothxAgentTransport.acp.rawValue
        return MothxAgentTransport(rawValue: raw) ?? .acp
    }

    private func ensureACPClient(tools: [String]) async throws {
        guard let executable = await Self.resolveGlobalMothxExecutable() else {
            throw MothxACPError.invalidResponse("mothx executable was not found")
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mothx", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await acpClient.setHandlers(
            message: { [weak self] data in
                Task { @MainActor [weak self] in
                    await self?.handleACPFrame(data)
                }
            },
            log: { [weak self] output in
                Task { @MainActor [weak self] in
                    self?.recordRuntimeLog("acp", output.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        )
        try await acpClient.start(
            executable: executable,
            workingDirectory: directory,
            environment: await Self.loginShellEnvironment(),
            options: MothxACPLaunchOptions(tools: tools)
        )
    }

    private func submitACPRun(
        sessionID: String,
        message: String,
        workDir: String,
        provider: String,
        model: String,
        mode: String,
        tools: [String]
    ) async -> String? {
        let runID = "acp-client-\(UUID().uuidString)"
        activeAgentTransport = .acp
        isSubmittingRun = true
        isStreaming = true
        isRunning = true
        cancelRequested = false
        runError = nil
        runStatus = "queued"
        runElapsed = 0
        resetRunMetrics(sessionID: sessionID)
        runSessionID = sessionID
        runReplyMessageID = nil
        currentRunID = runID
        currentPlan = nil
        currentRunningMessageID = nil
        acpToolInputs.removeAll(keepingCapacity: true)
        acpToolNames.removeAll(keepingCapacity: true)
        acpDurableRunID = nil
        thinkingBySession[sessionID] = ""
        // Do not let a previous turn's session-level fallback appear on the
        // new last turn before this Run captures its own file changes.
        latestChangesBySession.removeValue(forKey: sessionID)
        runExistingMessageIDs = Set((messagesBySession[sessionID] ?? []).map(\.id))
        runStartedAt = Date()
        startRunElapsedTimer()

        let localMessage = MothxMessage(
            id: "local-\(UUID().uuidString)", seq: nil, role: "user", content: message,
            toolCallId: nil, toolName: nil, arguments: "", plan: nil, summary: nil,
            hasDetail: false, createdAt: ISO8601DateFormatter().string(from: Date())
        )
        messagesBySession[sessionID, default: []].append(localMessage)

        do {
            try await ensureACPClient(tools: tools)
            let cwd = workDir.isEmpty ? self.workDir(for: sessionID) : workDir
            try await acpClient.resumeSession(id: sessionID, cwd: cwd)
            let resolvedProvider = provider.isEmpty
                ? (sessionProviders[sessionID] ?? defaultProvider)
                : provider
            let resolvedModel = model.isEmpty
                ? (sessionModels[sessionID] ?? defaultModel)
                : model
            if !resolvedProvider.isEmpty {
                try await acpClient.setConfig(sessionID: sessionID, id: "provider", value: resolvedProvider)
            }
            if !resolvedModel.isEmpty {
                let qualifiedModel = resolvedProvider.isEmpty || resolvedModel.hasPrefix("\(resolvedProvider)/")
                    ? resolvedModel
                    : "\(resolvedProvider)/\(resolvedModel)"
                try await acpClient.setConfig(sessionID: sessionID, id: "model", value: qualifiedModel)
            }
            if !mode.isEmpty {
                try await acpClient.setConfig(sessionID: sessionID, id: "mode", value: mode)
            }
            startRunEventStream(sessionID: sessionID)
            runStatus = "running"
            isSubmittingRun = false
            let stopReason = try await acpClient.prompt(sessionID: sessionID, text: message)
            await refreshACPUsage(sessionID: sessionID)
            runElapsed = elapsedSinceRunStart()
            stopRunElapsedTimer()
            isSubmittingRun = false
            isStreaming = false
            isRunning = false
            currentRunningMessageID = nil
            currentPlan = nil
            if cancelRequested || stopReason.lowercased() == "cancelled" {
                runStatus = "cancelled"
            } else if ["end_turn", "stop", "completed", "success"].contains(stopReason.lowercased()) {
                runStatus = "completed"
            } else {
                runStatus = "incomplete"
                runError = copy.text("ACP 运行未完整结束：\(stopReason)", "ACP run ended incompletely: \(stopReason)")
            }
            return runID
        } catch {
            runElapsed = elapsedSinceRunStart()
            stopRunElapsedTimer()
            isSubmittingRun = false
            isStreaming = false
            isRunning = false
            currentRunningMessageID = nil
            currentPlan = nil
            runStatus = cancelRequested ? "cancelled" : "failed"
            if !cancelRequested {
                runError = describe(error)
                settingsError = copy.text("ACP 运行失败：\(describe(error))", "ACP run failed: \(describe(error))")
            }
            recordRuntimeLog("acp", "run failed session=\(sessionID) error=\(describe(error))")
            return nil
        }
    }

    func stopACPClient() async {
        await acpClient.stop()
        if activeAgentTransport == .acp {
            activeAgentTransport = .serve
        }
    }

    private func handleACPFrame(_ data: Data) async {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else {
            recordRuntimeLog("acp", "ignored malformed JSON-RPC message")
            return
        }
        if let id = rpcStringID(object["id"]) {
            await handleACPRequest(id: id, method: method, params: object["params"] as? [String: Any] ?? [:])
            return
        }
        let params = object["params"] as? [String: Any] ?? [:]
        switch method {
        case "session/update":
            handleACPSessionUpdate(params)
        case "_mothx/session_event":
            handleACPSessionEvent(params)
        default:
            break
        }
    }

    private func handleACPSessionUpdate(_ params: [String: Any]) {
        guard let sessionID = params["sessionId"] as? String,
              let update = params["update"] as? [String: Any],
              let kind = update["sessionUpdate"] as? String else { return }
        switch kind {
        case "user_message_chunk":
            guard let messageID = update["messageId"] as? String,
                  let text = acpText(from: update["content"]), !text.isEmpty else { return }
            upsertACPTextMessage(sessionID: sessionID, id: messageID, role: "user", chunk: text)
            if sessionID == runSessionID, activeAgentTransport == .acp, acpDurableRunID == nil {
                Task { @MainActor [weak self] in
                    await self?.refreshACPUsage(sessionID: sessionID)
                }
            }
        case "agent_message_chunk":
            guard let messageID = update["messageId"] as? String,
                  let text = acpText(from: update["content"]), !text.isEmpty else { return }
            upsertACPTextMessage(sessionID: sessionID, id: messageID, role: "assistant", chunk: text)
            runReplyMessageID = messageID
            currentRunningMessageID = messageID
        case "agent_thought_chunk":
            if let text = acpText(from: update["content"]), !text.isEmpty {
                appendThinking(text, for: sessionID)
            }
        case "tool_call":
            upsertACPToolCall(sessionID: sessionID, update: update)
        case "tool_call_update":
            handleACPToolUpdate(sessionID: sessionID, update: update)
        case "plan":
            handleACPPlan(update)
        case "usage_update":
            if sessionID == runSessionID {
                updateRunContextUsage(used: update["used"], size: update["size"])
                Task { @MainActor [weak self] in
                    await self?.refreshACPUsage(sessionID: sessionID)
                }
            }
        default:
            break
        }
    }

    private func handleACPSessionEvent(_ params: [String: Any]) {
        guard (params["sessionId"] as? String) == runSessionID else { return }
        let event = (params["event"] as? String ?? "").lowercased()
        if event == "terminal" {
            let status = (params["status"] as? String ?? "completed").lowercased()
            runStatus = status
            runElapsed = elapsedSinceRunStart()
            if ["failed", "error", "incomplete", "timed_out", "timeout"].contains(status) {
                runError = (params["error"] as? String) ?? copy.runFailedFallback
            }
            if ["completed", "cancelled", "canceled", "failed", "error", "incomplete", "timed_out", "timeout"].contains(status) {
                currentPlan = nil
            }
        } else if event == "status", let message = params["message"] as? String, !message.isEmpty {
            recordRuntimeLog("acp", "session status: \(message)")
        }
    }

    private func upsertACPTextMessage(sessionID: String, id: String, role: String, chunk: String) {
        var messages = messagesBySession[sessionID] ?? []
        if let index = messages.firstIndex(where: { $0.id == id }) {
            let old = messages[index]
            messages[index] = MothxMessage(
                id: old.id, seq: old.seq, role: old.role, content: old.content + chunk,
                toolCallId: old.toolCallId, toolName: old.toolName, arguments: old.arguments,
                plan: old.plan, summary: old.summary, hasDetail: old.hasDetail, createdAt: old.createdAt
            )
        } else if role == "user",
                  let index = messages.lastIndex(where: { $0.id.hasPrefix("local-") && $0.role == "user" && $0.content == chunk }) {
            let old = messages[index]
            messages[index] = MothxMessage(
                id: id, seq: old.seq, role: role, content: chunk,
                toolCallId: nil, toolName: nil, arguments: "", plan: nil,
                summary: nil, hasDetail: false, createdAt: old.createdAt
            )
        } else {
            messages.append(MothxMessage(
                id: id, seq: nil, role: role, content: chunk,
                toolCallId: nil, toolName: nil, arguments: "", plan: nil,
                summary: nil, hasDetail: false, createdAt: ISO8601DateFormatter().string(from: Date())
            ))
        }
        messagesBySession[sessionID] = messages
    }

    private func upsertACPToolCall(sessionID: String, update: [String: Any]) {
        guard let callID = update["toolCallId"] as? String, !callID.isEmpty else { return }
        if let input = update["rawInput"] as? [String: Any] { acpToolInputs[callID] = input }
        let title = update["title"] as? String ?? ""
        if !title.isEmpty {
            let candidate = title.split(separator: ":", maxSplits: 1).first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let candidate, !candidate.isEmpty, !candidate.contains(" ") {
                acpToolNames[callID] = candidate
            }
        }
        if acpToolNames[callID] == nil, let kind = update["kind"] as? String {
            acpToolNames[callID] = kind
        }
        let toolName = acpToolNames[callID] ?? "tool"
        let message = MothxMessage(
            id: "acp-call-\(callID)", seq: nil, role: "toolCall", content: title.isEmpty ? toolName : title,
            toolCallId: callID, toolName: toolName, arguments: acpJSONString(acpToolInputs[callID] ?? [:]),
            plan: nil, summary: nil, hasDetail: false,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        var messages = messagesBySession[sessionID] ?? []
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        messagesBySession[sessionID] = messages
    }

    private func handleACPToolUpdate(sessionID: String, update: [String: Any]) {
        guard let callID = update["toolCallId"] as? String, !callID.isEmpty else { return }
        upsertACPToolCall(sessionID: sessionID, update: update)
        let status = (update["status"] as? String ?? "").lowercased()
        let text = acpToolOutputText(update)
        if ["completed", "failed"].contains(status) || !text.isEmpty {
            let resultID = "acp-result-\(callID)"
            let bounded = boundedToolDetail(text)
            let result = MothxMessage(
                id: resultID, seq: nil, role: "toolResult", content: bounded,
                toolCallId: callID, toolName: acpToolNames[callID],
                arguments: "", plan: nil, summary: text.isEmpty ? status : bounded,
                hasDetail: !text.isEmpty,
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            var messages = messagesBySession[sessionID] ?? []
            if let index = messages.firstIndex(where: { $0.id == resultID }) {
                messages[index] = result
            } else {
                messages.append(result)
            }
            messagesBySession[sessionID] = messages
        }
        captureACPChanges(sessionID: sessionID, update: update, summary: text, toolCallID: callID)
    }

    private func captureACPChanges(sessionID: String, update: [String: Any], summary: String, toolCallID: String) {
        guard let runID = currentRunID, runID.hasPrefix("acp-client-"),
              let contents = update["content"] as? [[String: Any]] else { return }
        for content in contents where content["type"] as? String == "diff" {
            guard let rawPath = content["path"] as? String,
                  let target = captureTarget(rawPath, sessionID: sessionID) else { continue }
            let change: MothxFileChange
            if let oldText = content["oldText"] as? String,
               let newText = content["newText"] as? String {
                change = MothxDiffBuilder.make(path: target.relativePath, oldText: oldText, newText: newText)
            } else {
                let preview = summary.isEmpty
                    ? copy.text("ACP 返回了文件变更，但缺少完整的 oldText/newText。", "ACP returned a file change without a complete oldText/newText pair.")
                    : summary
                change = MothxFileChange(previewPath: target.relativePath, unifiedDiff: preview, added: 0, deleted: 0)
            }
            mergeServerChange(change, sessionID: sessionID, runID: runID, toolCallID: toolCallID)
        }
    }

    private func handleACPPlan(_ update: [String: Any]) {
        guard let entries = update["entries"] as? [[String: Any]], !entries.isEmpty else {
            currentPlan = nil
            return
        }
        let rawMetadata = update["_meta"] as? [String: Any]
        let metadata = (rawMetadata?["mothx.dev"] as? [String: Any])
            ?? (rawMetadata?["mothx"] as? [String: Any])
        let title = metadata?["title"] as? String ?? ""
        let note = metadata?["note"] as? String
        let steps = entries.enumerated().compactMap { index, entry -> MothxPlanStep? in
            guard let content = entry["content"] as? String, !content.isEmpty else { return nil }
            let rawStatus = (entry["status"] as? String ?? "pending").lowercased()
            let status = rawStatus == "in_progress" ? "running" : (rawStatus == "completed" ? "done" : "pending")
            return MothxPlanStep(id: "\(index)-\(content)", title: content, status: status)
        }
        guard !steps.isEmpty else { currentPlan = nil; return }
        currentPlan = MothxPlan(
            id: title + "|" + steps.map(\.title).joined(separator: "|"),
            title: title, steps: steps, note: note
        )
    }

    private func handleACPRequest(id: String, method: String, params: [String: Any]) async {
        let result: [String: Any]
        switch method {
        case "session/request_permission":
            runStatus = "waiting_for_approval"
            result = presentACPPermission(params)
        case "elicitation/create":
            runStatus = "waiting_for_question"
            result = presentACPQuestion(params, standardElicitation: true)
        case "mothx/requestQuestion", "_mothx/request_question":
            runStatus = "waiting_for_question"
            result = presentACPQuestion(params, standardElicitation: false)
        default:
            recordRuntimeLog("acp", "unsupported server request method=\(method)")
            result = [:]
        }
        do {
            try await acpClient.respond(id: id, result: result)
            if isRunning { runStatus = "running" }
        } catch {
            runError = describe(error)
        }
    }

    private func presentACPPermission(_ params: [String: Any]) -> [String: Any] {
        let tool = params["toolCall"] as? [String: Any] ?? [:]
        let title = tool["title"] as? String ?? copy.text("工具调用", "Tool call")
        let input = tool["rawInput"] as? [String: Any] ?? [:]
        let options = params["options"] as? [[String: Any]] ?? []
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = copy.text("允许 mothx 执行“\(title)”吗？", "Allow mothx to run “\(title)”?")
        alert.informativeText = input.isEmpty ? "" : acpJSONString(input)
        for option in options { alert.addButton(withTitle: option["name"] as? String ?? "Option") }
        alert.addButton(withTitle: copy.text("取消", "Cancel"))
        let selected = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard selected >= 0, selected < options.count,
              let optionID = options[selected]["optionId"] as? String else {
            return ["outcome": ["outcome": "cancelled"]]
        }
        return ["outcome": ["outcome": "selected", "optionId": optionID]]
    }

    private func presentACPQuestion(_ params: [String: Any], standardElicitation: Bool) -> [String: Any] {
        let prompt = (params["message"] as? String)
            ?? (params["prompt"] as? String)
            ?? copy.text("mothx 需要你的输入", "mothx needs your input")
        var options = (params["options"] as? [[String: Any]] ?? []).compactMap { option in
            (option["label"] as? String) ?? (option["id"] as? String)
        }
        if standardElicitation,
           let schema = params["requestedSchema"] as? [String: Any],
           let properties = schema["properties"] as? [String: Any],
           let answer = properties["answer"] as? [String: Any],
           let values = answer["enum"] as? [String] {
            options = values
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = params["title"] as? String ?? "MothX"
        alert.informativeText = prompt
        let answer: String?
        if options.isEmpty {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            field.placeholderString = params["placeholder"] as? String
            alert.accessoryView = field
            alert.addButton(withTitle: copy.text("确定", "OK"))
            alert.addButton(withTitle: copy.text("取消", "Cancel"))
            answer = alert.runModal() == .alertFirstButtonReturn
                ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
        } else {
            for option in options { alert.addButton(withTitle: option) }
            alert.addButton(withTitle: copy.text("取消", "Cancel"))
            let selected = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            answer = selected >= 0 && selected < options.count ? options[selected] : nil
        }
        if standardElicitation {
            guard let answer, !answer.isEmpty else { return ["action": "cancel"] }
            return ["action": "accept", "content": ["answer": answer]]
        }
        guard let answer, !answer.isEmpty else { return ["cancelled": true] }
        return ["answer": answer]
    }

    private func acpText(from value: Any?) -> String? {
        guard let content = value as? [String: Any], content["type"] as? String == "text" else { return nil }
        return content["text"] as? String
    }

    private func acpToolOutputText(_ update: [String: Any]) -> String {
        if let contents = update["content"] as? [[String: Any]] {
            let text = contents.compactMap { item -> String? in
                guard item["type"] as? String == "content" else { return nil }
                return acpText(from: item["content"])
            }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        if let output = update["rawOutput"] as? [String: Any],
           let content = output["content"] as? String {
            return content
        }
        return ""
    }

    private func acpJSONString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    private func rpcStringID(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    func submitRun(sessionID: String, message: String, images: [String], workDir: String = "", provider: String = "", model: String = "", mode: String = "agent", tools: [String] = [], skills: [String] = [], forceServe: Bool = false) async -> String? {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return nil }
        clearImageRecognitionProgress()
        if preferredAgentTransport == .acp,
           !forceServe,
           pendingSessions[sessionID] == nil,
           images.isEmpty,
           skills.isEmpty {
            return await submitACPRun(
                sessionID: sessionID,
                message: message,
                workDir: workDir,
                provider: provider,
                model: model,
                mode: mode,
                tools: tools
            )
        }
        if preferredAgentTransport == .acp {
            let reason = !images.isEmpty ? "image input" : (!skills.isEmpty ? "explicit skills" : "pending Serve session")
            recordRuntimeLog("acp", "falling back to Serve session=\(sessionID) reason=\(reason)")
        }
        activeAgentTransport = .serve
        isSubmittingRun = true
        isStreaming = true
        cancelRequested = false
        runError = nil
        runStatus = "queued"
        runElapsed = 0
        resetRunMetrics(sessionID: sessionID)
        runSessionID = sessionID
        runReplyMessageID = nil
        currentRunID = nil
        currentPlan = nil
        currentRunningMessageID = nil
        thinkingBySession[sessionID] = ""
        latestChangesBySession.removeValue(forKey: sessionID)
        isRunning = true
        runExistingMessageIDs = Set((messagesBySession[sessionID] ?? []).map(\.id))
        runStartedAt = Date()
        startRunElapsedTimer()
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
                runElapsed = elapsedSinceRunStart()
                stopRunElapsedTimer()
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
            runElapsed = elapsedSinceRunStart()
            stopRunElapsedTimer()
            isSubmittingRun = false
            runStatus = "failed"
            currentPlan = nil
            runError = describe(error)
            settingsError = copy.submitRunFailedPrefix(describe(error))
            return nil
        }
    }

    /// Runs the configured vision model in an isolated, disposable Serve
    /// session. This deliberately does not use submitRun/pollRun because
    /// those methods publish state for the visible conversation.
    func recognizeImages(images: [String], provider: String, model: String, workDir: String, sessionID: String = "") async throws -> String {
        guard !images.isEmpty else { throw ImageRecognitionError.noImages }
        guard !provider.isEmpty, !model.isEmpty else { throw ImageRecognitionError.notConfigured }

        imageRecognitionProgress = MothxImageRecognitionProgress(
            isVisible: true,
            sessionID: sessionID,
            provider: provider,
            model: model,
            status: "正在准备图片识别 Agent…",
            result: "",
            isError: false
        )

        // The Serve admission check uses the model's persisted `input` list,
        // while many provider model catalogs omit or misreport image support.
        // A model explicitly selected by the user as the vision model is an
        // intentional capability override. Persist `image` for that model so
        // the vision Run is not rejected before the provider is contacted.
        do {
            imageRecognitionProgress.status = "正在确认识别模型配置…"
            try await ensureVisionModelAcceptsImages(providerID: provider, modelID: model)
        } catch {
            updateImageRecognitionFailure(error)
            throw error
        }

        let temporarySessionID: String
        do {
            let sessionData = try await request(path: "api/session-id", method: "POST")
            guard let sessionObject = try JSONSerialization.jsonObject(with: sessionData) as? [String: Any],
                  let sessionID = sessionObject["sessionId"] as? String,
                  !sessionID.isEmpty else {
                throw ImageRecognitionError.invalidSessionResponse
            }
            temporarySessionID = sessionID
        } catch {
            updateImageRecognitionFailure(error)
            throw error
        }

        imageRecognitionProgress.status = "正在调用 \(provider)/\(model) 识别图片…"
        recordRuntimeLog("image-recognition", "start provider=\(provider) model=\(model) images=\(images.count)")
        do {
            defer {
                Task { [weak self] in
                    guard let self else { return }
                    try? await self.request(path: "api/sessions/\(temporarySessionID)", method: "DELETE")
                }
            }

            let payload: [String: Any] = [
                "message": "请详细识别图片内容，包括文字（OCR）、布局、关键对象、图表/代码结构、可执行信息和不确定之处。只返回供另一个 Agent 使用的客观识别结果。",
                "provider": provider,
                "model": model,
                "mode": "yolo",
                "tools": [],
                "skills": [],
                "images": images,
                "transcript": false,
                "workDir": workDir
            ]
            let body = try jsonData(payload)
            let response = try await request(
                path: "api/sessions/\(temporarySessionID)/runs",
                method: "POST",
                body: body,
                headers: ["Idempotency-Key": UUID().uuidString]
            )
            guard let responseObject = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let runID = (responseObject["runId"] as? String) ?? (responseObject["runID"] as? String),
                  !runID.isEmpty else {
                throw ImageRecognitionError.noRunID
            }

            imageRecognitionProgress.status = "识别 Agent 运行中（Run \(runID.prefix(12))…）"

            var terminalStatus = ""
            var lastRunObject: [String: Any] = [:]
            while !Task.isCancelled {
                let runData = try await request(path: "api/runs/\(runID)", method: "GET")
                let runObject = (try JSONSerialization.jsonObject(with: runData) as? [String: Any]) ?? [:]
                lastRunObject = runObject
                terminalStatus = (runObject["status"] as? String) ?? (runObject["state"] as? String) ?? "running"
                imageRecognitionProgress.status = "识别 Agent：\(terminalStatus)"
                let normalized = terminalStatus.lowercased()
                if ["completed", "succeeded", "failed", "error", "cancelled", "canceled", "timed_out", "timeout", "expired", "incomplete"].contains(normalized) {
                    if ["failed", "error", "timed_out", "timeout", "expired", "incomplete", "cancelled", "canceled"].contains(normalized) {
                        let detail = (runObject["error"] as? String) ?? (runObject["errorMessage"] as? String) ?? terminalStatus
                        throw ImageRecognitionError.runFailed(detail)
                    }
                    break
                }
                try await Task.sleep(for: .milliseconds(500))
            }

            let messagesData = try await request(path: "api/sessions/\(temporarySessionID)/messages?limit=200", method: "GET")
            let object = try JSONSerialization.jsonObject(with: messagesData)
            let values: [[String: Any]]
            if let direct = object as? [[String: Any]] {
                values = direct
            } else {
                values = (object as? [String: Any])?["messages"] as? [[String: Any]] ?? []
            }
            let texts = values.compactMap { item -> String? in
                guard (item["role"] as? String) == "assistant" else { return nil }
                let text = (item["content"] as? String) ?? (item["text"] as? String) ?? ""
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            guard !texts.isEmpty else {
                let status = terminalStatus.isEmpty ? ((lastRunObject["status"] as? String) ?? "completed") : terminalStatus
                throw ImageRecognitionError.emptyResult(status)
            }
            let result = texts.joined(separator: "\n\n")
            imageRecognitionProgress.status = "识别完成，正在启动主会话…"
            imageRecognitionProgress.result = result
            recordRuntimeLog("image-recognition", "completed provider=\(provider) model=\(model) chars=\(result.count)")
            return result
        } catch {
            updateImageRecognitionFailure(error)
            recordRuntimeLog("image-recognition", "failed provider=\(provider) model=\(model) error=\(error.localizedDescription)")
            throw error
        }
    }

    func clearImageRecognitionProgress() {
        imageRecognitionProgress = MothxImageRecognitionProgress()
    }

    private func updateImageRecognitionFailure(_ error: Error) {
        imageRecognitionProgress.status = "图片识别失败"
        imageRecognitionProgress.result = error.localizedDescription
        imageRecognitionProgress.isError = true
    }

    private func ensureVisionModelAcceptsImages(providerID: String, modelID: String) async throws {
        guard let provider = providers.first(where: { $0.id == providerID }),
              let model = provider.models.first(where: { $0.id == modelID }) else {
            throw ImageRecognitionError.modelNotFound(providerID, modelID)
        }
        guard !model.input.contains(where: { $0.caseInsensitiveCompare("image") == .orderedSame }) else { return }

        // Start from the raw settings object so provider fields not modeled by
        // the client survive the capability correction.
        var providerJSON = ((rawSettings["providers"] as? [String: Any])?[providerID] as? [String: Any]) ?? [:]
        if providerJSON.isEmpty {
            providerJSON = try jsonDictionary(provider)
        }
        guard var modelObjects = providerJSON["models"] as? [[String: Any]],
              let index = modelObjects.firstIndex(where: { ($0["id"] as? String) == modelID }) else {
            throw ImageRecognitionError.modelNotFound(providerID, modelID)
        }
        var modelJSON = modelObjects[index]
        var input = (modelJSON["input"] as? [String]) ?? ["text"]
        if !input.contains(where: { $0.caseInsensitiveCompare("image") == .orderedSame }) {
            input.append("image")
        }
        modelJSON["input"] = input
        modelObjects[index] = modelJSON
        providerJSON["models"] = modelObjects

        var providersJSON = (rawSettings["providers"] as? [String: Any]) ?? [:]
        providersJSON[providerID] = providerJSON
        rawSettings["providers"] = providersJSON
        let data = try JSONSerialization.data(withJSONObject: rawSettings)
        _ = try await request(path: "api/settings", method: "PUT", body: data)
        await loadSettings()
        recordRuntimeLog("image-recognition", "marked provider=\(providerID) model=\(modelID) input=image")
    }

    func cancelRun() async {
        cancelRequested = true
        isSubmittingRun = false
        isStreaming = false
        if activeAgentTransport == .acp, let sessionID = runSessionID {
            do {
                try await acpClient.cancel(sessionID: sessionID)
                runStatus = "cancelled"
                currentPlan = nil
                runElapsed = elapsedSinceRunStart()
                stopRunElapsedTimer()
            } catch {
                runError = copy.stopRunFailedPrefix(describe(error))
                settingsError = runError
            }
            return
        }
        guard let runID = currentRunID else { return }
        do {
            _ = try await request(path: "api/runs/\(runID)/cancel", method: "POST")
            runStatus = "cancelled"
            currentPlan = nil
            runElapsed = elapsedSinceRunStart()
            stopRunElapsedTimer()
        } catch {
            runError = copy.stopRunFailedPrefix(describe(error))
            settingsError = runError
        }
    }

    /// Returns whether mothx has a durable Agent Run currently active for a
    /// session. An open TUI process is not itself an active Agent Run: the TUI
    /// stays alive while waiting for the next user command.
    func sessionHasActiveRun(_ sessionID: String) async -> Bool {
        guard !sessionID.isEmpty else { return false }
        do {
            let data = try await request(path: "api/sessions/\(sessionID)/runtime", method: "GET")
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return object["activeRun"] is [String: Any]
        } catch {
            return false
        }
    }

    /// Waits briefly for the server-side session lock to be released after a
    /// confirmed UI-to-TUI stop. The cancel endpoint is asynchronous and may
    /// return before the runtime has finished terminalizing the Run.
    func waitForSessionIdle(_ sessionID: String) async {
        guard !sessionID.isEmpty else { return }
        for _ in 0..<20 {
            do {
                let data = try await request(path: "api/sessions/\(sessionID)/runtime", method: "GET")
                if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object["activeRun"] is [String: Any] {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
            } catch {
                // A transient probe failure should not block the mode switch;
                // the TUI will report a genuine startup error if needed.
            }
            return
        }
    }

    // MARK: - Session switching

    private(set) var pendingSwitchAction: (() -> Void)?
    @Published private(set) var showSwitchConfirmation = false

    /// Requests a UI/TUI mode change. Mode changes while the current mode is
    /// actively executing are destructive, so defer them until confirmation.
    /// Plain session navigation deliberately does not use this method.
    func requestModeSwitch(isRunning: Bool, _ action: @escaping () -> Void) {
        requestModeSwitch(isRunning: isRunning, continueAction: nil, action)
    }

    private(set) var pendingContinueSwitchAction: (() -> Void)?
    @Published private(set) var canContinueModeSwitch = false

    /// Requests a mode switch with an optional detach path. The detach path
    /// is used by TUI → UI: the TUI keeps running while UI observes its Run.
    func requestModeSwitch(isRunning: Bool, continueAction: (() -> Void)?, _ action: @escaping () -> Void) {
        guard isRunning else {
            (continueAction ?? action)()
            return
        }
        pendingContinueSwitchAction = continueAction
        canContinueModeSwitch = continueAction != nil
        pendingSwitchAction = action
        showSwitchConfirmation = true
    }

    func confirmSwitch() {
        showSwitchConfirmation = false
        let action = pendingSwitchAction
        pendingSwitchAction = nil
        pendingContinueSwitchAction = nil
        canContinueModeSwitch = false
        action?()
    }

    func continueSwitch() {
        showSwitchConfirmation = false
        let action = pendingContinueSwitchAction
        pendingSwitchAction = nil
        pendingContinueSwitchAction = nil
        canContinueModeSwitch = false
        action?()
    }

    func cancelSwitch() {
        showSwitchConfirmation = false
        pendingSwitchAction = nil
        pendingContinueSwitchAction = nil
        canContinueModeSwitch = false
    }

    /// Switch sessions immediately without changing the active Run. Runs are
    /// durable server-side tasks, so a UI selection change must not cancel the
    /// run or block navigation.
    /// `activeRunSessionID` is retained for source compatibility with callers
    /// that also use this helper for terminal-mode switches.
    func requestSwitch(activeRunSessionID: String? = nil, _ action: @escaping () -> Void) {
        _ = activeRunSessionID
        action()
    }

    /// Plans are transient run UI state and must not be restored from history
    /// after a run reaches any terminal state.
    func clearCurrentPlan() {
        currentPlan = nil
    }

    func pollRun(runID: String, sessionID: String) async {
        // ACP `session/prompt` completes only after the turn is terminal, so
        // there is no HTTP Run to poll for client-side ACP correlation IDs.
        if runID.hasPrefix("acp-client-") { return }
        guard monitoredRunIDs.insert(runID).inserted else { return }
        defer {
            monitoredRunIDs.remove(runID)
            runElapsed = elapsedSinceRunStart()
            stopRunElapsedTimer()
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
                updateRunContextUsage(from: object["contextUsage"] ?? object["ContextUsage"] ?? object["context_usage"])
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

    /// Attaches the UI to a Run that was started by the TUI (or another
    /// client). The durable runtime snapshot provides the Run identity; the
    /// existing poller and WebSocket stream then handle the rest.
    func attachToActiveRun(sessionID: String) async {
        guard !sessionID.isEmpty else { return }
        do {
            let data = try await request(path: "api/sessions/\(sessionID)/runtime", method: "GET")
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let active = object["activeRun"] as? [String: Any],
                  let runID = (active["runId"] as? String) ?? (active["runID"] as? String) ?? (active["id"] as? String),
                  !runID.isEmpty else { return }

            runSessionID = sessionID
            currentRunID = runID
            runStatus = (active["status"] as? String) ?? (active["state"] as? String) ?? "running"
            resetRunMetrics(sessionID: sessionID)
            isSubmittingRun = false
            isStreaming = true
            isRunning = true
            cancelRequested = false
            runExistingMessageIDs = Set((messagesBySession[sessionID] ?? []).map(\.id))
            runStartedAt = parseDate(active["startedAt"] ?? active["started_at"]) ?? Date()
            runElapsed = elapsedSinceRunStart()
            startRunElapsedTimer()
            startRunEventStream(sessionID: sessionID)
            if !monitoredRunIDs.contains(runID) {
                Task { @MainActor in await self.pollRun(runID: runID, sessionID: sessionID) }
            }
        } catch {
            // Runtime attachment is best-effort; the normal message history
            // remains available if the service is temporarily unavailable.
        }
    }

    private func elapsedSinceRunStart() -> TimeInterval {
        guard let runStartedAt else { return runElapsed }
        return max(0, Date().timeIntervalSince(runStartedAt))
    }

    /// Publishes a live elapsed value once per second while a Run is active.
    /// The value is derived from the start Date rather than incremented so
    /// scheduling delays cannot make the displayed duration drift.
    private func startRunElapsedTimer() {
        runElapsedTask?.cancel()
        runElapsedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRunning else { return }
                self.runElapsed = self.elapsedSinceRunStart()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopRunElapsedTimer() {
        runElapsedTask?.cancel()
        runElapsedTask = nil
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
    @discardableResult
    private func updateRunCacheHitRate(from rawUsage: Any?, sessionID: String? = nil) -> Bool {
        guard let usage = rawUsage as? [String: Any] else { return false }
        let input = integerValue(usage["input"] ?? usage["Input"] ?? usage["inputTokens"] ?? usage["input_tokens"] ?? usage["prompt_tokens"])
        let output = integerValue(usage["output"] ?? usage["Output"] ?? usage["outputTokens"] ?? usage["completion_tokens"])
        let total = integerValue(usage["totalTokens"] ?? usage["TotalTokens"] ?? usage["total_tokens"])
        let cacheRead = integerValue(usage["cacheRead"] ?? usage["CacheRead"] ?? usage["cache_read_tokens"] ?? usage["cached_tokens"])
        let cacheWrite = integerValue(usage["cacheWrite"] ?? usage["CacheWrite"] ?? usage["cache_write_tokens"])
        return updateRunCacheHitRate(
            input: input,
            output: output,
            total: total,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            sessionID: sessionID
        )
    }

    @discardableResult
    private func updateRunCacheHitRate(
        input: Int,
        output: Int,
        total: Int,
        cacheRead: Int,
        cacheWrite: Int,
        sessionID: String? = nil
    ) -> Bool {
        let totalInput: Int
        if total > 0 {
            totalInput = max(0, total - output)
        } else {
            totalInput = input + cacheRead + cacheWrite
        }
        guard totalInput > 0,
              let sessionID = sessionID ?? runSessionID else { return false }
        var metrics = metricsBySession[sessionID] ?? MothxSessionMetrics()
        metrics.cacheHitRate = min(1, max(0, Double(cacheRead) / Double(totalInput)))
        metricsBySession[sessionID] = metrics
        return true
    }

    @discardableResult
    private func updateRunContextUsage(
        from rawUsage: Any?,
        fallbackSize: Int? = nil,
        sessionID: String? = nil
    ) -> Bool {
        guard let usage = rawUsage as? [String: Any] else { return false }
        let used = usage["total_tokens"] ?? usage["totalTokens"] ?? usage["tokens"] ?? usage["used"]
        let size = usage["context_window"]
            ?? usage["contextWindow"]
            ?? usage["size"]
            ?? fallbackSize.map { $0 as Any }
        return updateRunContextUsage(used: used, size: size, sessionID: sessionID)
    }

    @discardableResult
    private func updateRunContextUsage(
        used rawUsed: Any?,
        size rawSize: Any?,
        sessionID: String? = nil
    ) -> Bool {
        guard let used = optionalIntegerValue(rawUsed), used >= 0,
              let size = optionalIntegerValue(rawSize), size > 0,
              let sessionID = sessionID ?? runSessionID else { return false }
        var metrics = metricsBySession[sessionID] ?? MothxSessionMetrics()
        metrics.contextUsedTokens = used
        metrics.contextWindowTokens = size
        metricsBySession[sessionID] = metrics
        return true
    }

    private func resetRunMetrics(sessionID: String) {
        metricsBySession[sessionID] = MothxSessionMetrics()
    }

    /// Fetches the latest persisted usage for the active run from
    /// `GET /api/sessions/{sessionID}/runs` (newest-first). The row matching
    /// the active run ID is preferred so a retry or another attempt for the
    /// same intent cannot shadow the active run. If the active run is not
    /// present or has no usage yet, return nil rather than borrowing another
    /// run's usage and displaying an incorrect cache hit rate.
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
            return nil
        } catch {
            return nil
        }
    }

    /// ACP's standard `usage_update` reports context occupancy (`used/size`),
    /// not provider cache tokens. Resolve the exact durable run and prefer its
    /// authoritative Usage object. Current mothx ACP builds can leave that
    /// object empty while persisting provider usage on assistant entries, so
    /// use a read-only, exact-turn fallback in that case.
    private func refreshACPUsage(sessionID: String) async {
        guard activeAgentTransport == .acp,
              runSessionID == sessionID,
              currentRunID?.hasPrefix("acp-client-") == true else { return }
        do {
            let data = try await request(path: "api/sessions/\(sessionID)/runs?limit=5", method: "GET")
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let runs = object["runs"] as? [[String: Any]] else { return }
            let selected: [String: Any]?
            if let acpDurableRunID {
                selected = runs.first { row in
                    (row["ID"] as? String) == acpDurableRunID || (row["id"] as? String) == acpDurableRunID
                }
            } else if let started = runStartedAt {
                selected = runs.first { row in
                    guard let candidateStart = parseDate(row["StartedAt"] ?? row["startedAt"]) else { return false }
                    return candidateStart >= started.addingTimeInterval(-2)
                }
            } else {
                selected = nil
            }
            guard let selected else { return }
            if acpDurableRunID == nil {
                acpDurableRunID = (selected["ID"] as? String) ?? (selected["id"] as? String)
            }
            updateRunContextUsage(from: selected["ContextUsage"] ?? selected["contextUsage"] ?? selected["context_usage"])
            let usage = (selected["Usage"] as? [String: Any]) ?? (selected["usage"] as? [String: Any])
            if !updateRunCacheHitRate(from: usage),
               let durableRunID = acpDurableRunID {
                await refreshACPStoredUsage(sessionID: sessionID, runID: durableRunID)
            }
        } catch {
            // Cache information is optional UI metadata. ACP text streaming
            // and the run lifecycle must continue if Serve is unavailable.
            if let durableRunID = acpDurableRunID {
                await refreshACPStoredUsage(sessionID: sessionID, runID: durableRunID)
            }
        }
    }

    private func refreshACPStoredUsage(sessionID: String, runID: String) async {
        guard !sessionDir.isEmpty else { return }
        let configuredSessionDirectory = sessionDir
        let usage = await Task.detached(priority: .utility) {
            MothxACPUsageReader.usage(
                sessionDirectory: configuredSessionDirectory,
                sessionID: sessionID,
                runID: runID
            )
        }.value
        guard let usage else { return }
        updateRunCacheHitRate(
            input: usage.input,
            output: usage.output,
            total: usage.totalTokens,
            cacheRead: usage.cacheRead,
            cacheWrite: usage.cacheWrite,
            sessionID: sessionID
        )
    }

    private func optionalIntegerValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private func integerValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }

    // MARK: - Server-provided file changes

    private func handleToolEvent(sessionID: String, runID: String, data: [String: Any]) {
        guard runID != "",
              let tool = data["tool"] as? String,
              isWriteLikeTool(tool) else { return }

        let status = ((data["status"] as? String) ?? (data["state"] as? String) ?? "").lowercased()
        guard ["completed", "succeeded", "success", "done"].contains(status) else { return }

        let args = toolArguments(from: data) ?? [:]
        let diff = (data["diff"] as? [String: Any])
            ?? (data["toolDiff"] as? [String: Any])
            ?? (data["tool_diff"] as? [String: Any])
        guard let rawPath = toolPath(from: diff ?? [:]) ?? toolPath(from: args),
              let target = captureTarget(rawPath, sessionID: sessionID) else { return }
        let pair = serverBeforeAfter(from: data)
        let summary = data["summary"] as? String ?? ""
        let counts = serverDiffCounts(from: data) ?? historicalDiffCounts(summary) ?? (0, 0)
        let change: MothxFileChange
        if let pair {
            change = MothxDiffBuilder.make(path: target.relativePath, oldText: pair.oldText, newText: pair.newText)
        } else {
            change = MothxFileChange(
                previewPath: target.relativePath,
                unifiedDiff: summary,
                added: counts.added,
                deleted: counts.deleted
            )
        }
        let toolCallID = (data["toolCallId"] as? String) ?? (data["tool_call_id"] as? String)
        mergeServerChange(change, sessionID: sessionID, runID: runID, toolCallID: toolCallID)
    }

    /// Tool names have changed across mothx releases and adapters. The
    /// session stream is the source of truth, so accept the canonical names
    /// as well as the common editor-facing aliases without treating shell
    /// commands as file edits.
    private func isWriteLikeTool(_ name: String) -> Bool {
        let normalized = name.lowercased().replacingOccurrences(of: "-", with: "_")
        return ["edit", "write", "insert", "edit_file", "write_file", "insert_file", "insert_text"].contains(normalized)
    }

    private func toolArguments(from data: [String: Any]) -> [String: Any]? {
        if let args = data["args"] as? [String: Any] { return args }
        if let args = data["arguments"] as? [String: Any] { return args }
        if let input = data["input"] as? [String: Any] { return input }
        return nil
    }

    private func toolPath(from args: [String: Any]) -> String? {
        for key in ["path", "file", "filePath", "file_path"] {
            if let path = args[key] as? String, !path.isEmpty { return path }
        }
        return nil
    }

    private func serverBeforeAfter(from data: [String: Any]) -> (oldText: String, newText: String)? {
        let diff = (data["diff"] as? [String: Any])
            ?? (data["toolDiff"] as? [String: Any])
            ?? (data["tool_diff"] as? [String: Any])
        let oldText = data["oldText"] as? String ?? data["old_text"] as? String
            ?? diff?["oldText"] as? String ?? diff?["old_text"] as? String
        let newText = data["newText"] as? String ?? data["new_text"] as? String
            ?? diff?["newText"] as? String ?? diff?["new_text"] as? String
        guard let oldText, let newText else { return nil }
        return (oldText, newText)
    }

    private func serverDiffCounts(from data: [String: Any]) -> (added: Int, deleted: Int)? {
        let diff = (data["diff"] as? [String: Any])
            ?? (data["toolDiff"] as? [String: Any])
            ?? (data["tool_diff"] as? [String: Any])
        let addedValue = data["added"] ?? diff?["added"]
        let deletedValue = data["deleted"] ?? diff?["deleted"]
        guard addedValue != nil || deletedValue != nil else { return nil }
        return (integerValue(addedValue), integerValue(deletedValue))
    }

    private func mergeServerChange(_ change: MothxFileChange, sessionID: String, runID: String, toolCallID: String? = nil) {
        var changes = fileChangesByRun[runID] ?? [:]
        changes[change.path] = combinedServerChange(previous: changes[change.path], next: change)
        fileChangesByRun[runID] = changes
        let turnChanges = MothxTurnChanges(
            id: runID,
            runID: runID,
            files: changes.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
            capturedAt: Date()
        )
        changesByRun[runID] = turnChanges
        latestChangesBySession[sessionID] = turnChanges

        if let toolCallID, !toolCallID.isEmpty {
            let key = toolChangeKey(sessionID: sessionID, toolCallID: toolCallID)
            var callFiles = Dictionary(uniqueKeysWithValues: (toolChangesByCall[key]?.files ?? []).map { ($0.path, $0) })
            callFiles[change.path] = combinedServerChange(previous: callFiles[change.path], next: change)
            toolChangesByCall[key] = MothxToolChangeRecord(
                sessionID: sessionID,
                toolCallID: toolCallID,
                files: callFiles.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
                capturedAt: Date()
            )
        }
        persistChanges()
    }

    private func toolChangeKey(sessionID: String, toolCallID: String) -> String {
        "\(sessionID)\u{0}\(toolCallID)"
    }

    private func localChange(sessionID: String, toolCallID: String, path: String) -> MothxFileChange? {
        let key = toolChangeKey(sessionID: sessionID, toolCallID: toolCallID)
        return toolChangesByCall[key]?.files.first { $0.path == path }
    }

    private func persistChanges() {
        changeStore.save(turns: changesByRun, toolChanges: toolChangesByCall)
    }

    private func combinedServerChange(previous: MothxFileChange?, next: MothxFileChange) -> MothxFileChange {
        guard let previous,
              let firstOldText = previous.oldText,
              next.isReviewable,
              let finalNewText = next.newText else {
            return next
        }
        return MothxDiffBuilder.make(path: next.path, oldText: firstOldText, newText: finalNewText)
    }

    private func captureTarget(_ rawPath: String, sessionID: String) -> (url: URL, relativePath: String)? {
        let workDir = mothxWorkDirectory(for: sessionID)
        guard !workDir.isEmpty else { return nil }
        let root = URL(fileURLWithPath: workDir).standardizedFileURL
        let url = (rawPath.hasPrefix("/") ? URL(fileURLWithPath: rawPath) : root.appendingPathComponent(rawPath)).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path == root.path || url.path.hasPrefix(rootPath) else { return nil }
        return (url, String(url.path.dropFirst(rootPath.count)))
    }

    private func mothxWorkDirectory(for sessionID: String) -> String {
        workDir(for: sessionID)
    }

    /// Rebuilds the change card for runs that happened while the app was
    /// closed. Complete ACP captures come from the local tool-call store;
    /// Server tool details remain the compatibility fallback for old turns.
    private func rebuildHistoricalChanges(sessionID: String, messages: [MothxMessage]) async {
        guard let runMapping = historicalRunsByMessage[sessionID], !runMapping.isEmpty else { return }
        recordRuntimeLog("changes", "historical rebuild session=\(sessionID) runs=\(runMapping.count) messages=\(messages.count)")
        changesByMessage[sessionID] = [:]
        var currentUserID: String?
        var calls: [(MothxMessage, [String: Any], (url: URL, relativePath: String), MothxMessage?)] = []
        var resultsByCallID: [String: MothxMessage] = [:]

        func flush() async {
            guard let currentUserID,
                  let run = runMapping[currentUserID],
                  !calls.isEmpty else {
                calls.removeAll()
                resultsByCallID.removeAll()
                return
            }
            var files = fileChangesByRun[run.id] ?? [:]
            for (call, _, target, result) in calls {
                var summary = result?.summary ?? ""
                let local = call.toolCallId.flatMap {
                    localChange(sessionID: sessionID, toolCallID: $0, path: target.relativePath)
                }
                let change: MothxFileChange?
                if let local, local.isReviewable {
                    // ACP is the authoritative source for complete before /
                    // after content. Server history is only a fallback for
                    // conversations that predate local ACP persistence.
                    change = local
                } else {
                    let detail: MothxToolResultDetail?
                    if let callID = call.toolCallId {
                        detail = await loadToolResultDetail(sessionID: sessionID, toolCallID: callID)
                    } else {
                        detail = nil
                    }
                    if !summary.contains("Diff:"), let detail {
                        summary = detail.content
                    }
                    change = historicalChange(target: target, summary: summary, detail: detail)
                }
                guard let change else { continue }
                files[change.path] = combinedServerChange(previous: files[change.path], next: change)
            }
            guard !files.isEmpty else {
                calls.removeAll()
                resultsByCallID.removeAll()
                return
            }
            fileChangesByRun[run.id] = files
            let turnChanges = MothxTurnChanges(
                id: run.id,
                runID: run.id,
                files: files.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
                capturedAt: Date()
            )
            changesByRun[run.id] = turnChanges
            // Bind the reconstructed changes directly to the user message
            // that started this turn. This is stable even for legacy tui_*
            // runs without an intent ID or assistant result message.
            changesByMessage[sessionID, default: [:]][currentUserID] = turnChanges
            latestChangesBySession[sessionID] = turnChanges
            recordRuntimeLog("changes", "historical rebuild complete run=\(run.id) files=\(files.count)")
            calls.removeAll()
            resultsByCallID.removeAll()
        }

        for message in messages {
            if message.isUser {
                await flush()
                currentUserID = message.id
                continue
            }
            guard currentUserID != nil else { continue }
            if message.isToolCall,
               let toolName = message.toolName,
               isWriteLikeTool(toolName),
               let argsData = message.arguments.data(using: .utf8),
               let args = (try? JSONSerialization.jsonObject(with: argsData)) as? [String: Any],
               let path = toolPath(from: args),
               let target = captureTarget(path, sessionID: sessionID) {
                let result = message.toolCallId.flatMap { resultsByCallID[$0] }
                calls.append((message, args, target, result))
            } else if message.isToolResult, let callID = message.toolCallId {
                resultsByCallID[callID] = message
                if let index = calls.firstIndex(where: { $0.0.toolCallId == callID }) {
                    calls[index].3 = message
                }
            }
        }
        await flush()
        persistChanges()
    }

    private func historicalChange(target: (url: URL, relativePath: String), summary: String, detail: MothxToolResultDetail?) -> MothxFileChange? {
        guard detail?.isError != true else { return nil }
        if let oldText = detail?.oldText,
           let newText = detail?.newText {
            return MothxDiffBuilder.make(path: target.relativePath, oldText: oldText, newText: newText)
        }
        guard detail != nil || !summary.isEmpty else { return nil }
        let counts = historicalDiffCounts(summary) ?? (0, 0)
        return MothxFileChange(
            previewPath: target.relativePath,
            unifiedDiff: summary,
            added: counts.added,
            deleted: counts.deleted
        )
    }

    private func historicalDiffCounts(_ summary: String) -> (added: Int, deleted: Int)? {
        let pattern = #"Diff:\s*\+(\d+)\s*-(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: summary, range: NSRange(summary.startIndex..., in: summary)),
              let addedRange = Range(match.range(at: 1), in: summary),
              let deletedRange = Range(match.range(at: 2), in: summary),
              let added = Int(summary[addedRange]),
              let deleted = Int(summary[deletedRange]) else { return nil }
        return (added, deleted)
    }

    /// UI fallback for historical turns. It is intentionally idempotent and
    /// scoped to one displayed turn, so a missing historical reconstruction
    /// cannot hide a Diff summary just because the app was restarted.
    func ensureHistoricalChanges(sessionID: String, runID: String?, toolCalls: [MothxMessage]) async {
        // Never attach an unmapped historical turn to the session's latest
        // run. If mothx cannot identify this turn's run, leave it without a
        // change card instead of showing another turn's files.
        guard let resolvedRunID = runID else { return }
        var files = fileChangesByRun[resolvedRunID] ?? [:]
        for call in toolCalls {
            guard let argsData = call.arguments.data(using: .utf8),
                  let args = (try? JSONSerialization.jsonObject(with: argsData)) as? [String: Any],
                  let path = toolPath(from: args),
                  let target = captureTarget(path, sessionID: sessionID),
                  let callID = call.toolCallId else { continue }
            let change: MothxFileChange?
            if let local = localChange(sessionID: sessionID, toolCallID: callID, path: target.relativePath),
               local.isReviewable {
                change = local
            } else if let detail = await loadToolResultDetail(sessionID: sessionID, toolCallID: callID) {
                // Compatibility path for conversations created before ACP
                // file changes were persisted locally.
                change = historicalChange(target: target, summary: detail.content, detail: detail)
            } else {
                change = nil
            }
            guard let change else { continue }
            files[change.path] = combinedServerChange(previous: files[change.path], next: change)
        }
        guard !files.isEmpty else { return }
        fileChangesByRun[resolvedRunID] = files
        changesByRun[resolvedRunID] = MothxTurnChanges(
            id: resolvedRunID,
            runID: resolvedRunID,
            files: files.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
            capturedAt: Date()
        )
        latestChangesBySession[sessionID] = changesByRun[resolvedRunID]
        persistChanges()
    }

    private func loadHistoricalRuns(sessionID: String, messages: [MothxMessage]) async {
        do {
            let data = try await request(path: "api/sessions/\(sessionID)/runs?limit=200", method: "GET")
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let values = object["runs"] as? [[String: Any]] else { return }

            // Historical Runs are newest-first. When no turn is currently
            // executing in this session, restore the metric row from the
            // latest turn so reopening a conversation does not show dashes.
            if runSessionID != sessionID || !isRunning {
                await restoreLatestRunMetrics(sessionID: sessionID, runs: values)
            }

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

    private func restoreLatestRunMetrics(sessionID: String, runs: [[String: Any]]) async {
        guard let latest = runs.first else {
            metricsBySession[sessionID] = MothxSessionMetrics()
            return
        }

        metricsBySession[sessionID] = MothxSessionMetrics()
        let modelWindow = contextWindow(for: latest, sessionID: sessionID)
        let restoredContext = updateRunContextUsage(
            from: latest["ContextUsage"] ?? latest["contextUsage"] ?? latest["context_usage"],
            fallbackSize: modelWindow,
            sessionID: sessionID
        )
        let restoredCache = updateRunCacheHitRate(
            from: latest["Usage"] ?? latest["usage"],
            sessionID: sessionID
        )
        guard !restoredContext || !restoredCache,
              !sessionDir.isEmpty,
              let runID = (latest["ID"] as? String) ?? (latest["id"] as? String),
              !runID.isEmpty else { return }

        let configuredSessionDirectory = sessionDir
        let storedUsage = await Task.detached(priority: .utility) {
            MothxACPUsageReader.usage(
                sessionDirectory: configuredSessionDirectory,
                sessionID: sessionID,
                runID: runID
            )
        }.value
        guard let storedUsage,
              runSessionID != sessionID || !isRunning else { return }

        if !restoredCache {
            updateRunCacheHitRate(
                input: storedUsage.input,
                output: storedUsage.output,
                total: storedUsage.totalTokens,
                cacheRead: storedUsage.cacheRead,
                cacheWrite: storedUsage.cacheWrite,
                sessionID: sessionID
            )
        }
        if !restoredContext, let modelWindow {
            updateRunContextUsage(
                used: storedUsage.lastTotalTokens,
                size: modelWindow,
                sessionID: sessionID
            )
        }
    }

    private func contextWindow(for run: [String: Any], sessionID: String) -> Int? {
        let runModel = ((run["Model"] as? String) ?? (run["model"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let savedModel = modelForSession(sessionID) ?? defaultModel
        let rawModel = runModel.isEmpty ? savedModel : runModel
        guard !rawModel.isEmpty else { return nil }

        let runProvider = ((run["Provider"] as? String) ?? (run["provider"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let savedProvider = providerForSession(sessionID) ?? defaultProvider
        let providerID = runProvider.isEmpty ? savedProvider : runProvider
        let unqualifiedModel: String
        if !providerID.isEmpty, rawModel.hasPrefix("\(providerID)/") {
            unqualifiedModel = String(rawModel.dropFirst(providerID.count + 1))
        } else {
            unqualifiedModel = rawModel
        }

        if let provider = providers.first(where: { $0.id == providerID }),
           let model = provider.models.first(where: { $0.id == rawModel || $0.id == unqualifiedModel }),
           model.contextWindow > 0 {
            return model.contextWindow
        }
        return providers.lazy
            .flatMap(\.models)
            .first { model in
                model.contextWindow > 0
                    && (model.id == rawModel
                        || model.id == unqualifiedModel
                        || rawModel.hasSuffix("/\(model.id)"))
            }?
            .contextWindow
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
                    if object["stream"] as? String == "run",
                       object["event"] as? String == "usage",
                       let eventRunID = object["runId"] as? String,
                       let eventData = object["data"] as? [String: Any],
                       let usage = eventData["usage"] as? [String: Any] {
                        let shouldApply = await MainActor.run {
                            eventRunID == self.currentRunID
                                || (self.activeAgentTransport == .acp
                                    && self.runSessionID == sessionID
                                    && self.acpDurableRunID == eventRunID)
                        }
                        if shouldApply {
                            await MainActor.run {
                                self.updateRunCacheHitRate(from: usage)
                                self.updateRunContextUsage(from: eventData["contextUsage"] ?? eventData["ContextUsage"] ?? eventData["context_usage"])
                            }
                        }
                        continue
                    }
                    if object["stream"] as? String == "tool",
                       object["event"] as? String == "tool_event",
                       let eventData = object["data"] as? [String: Any],
                       let eventRunID = (object["runId"] as? String) ?? (eventData["runId"] as? String) {
                        await MainActor.run {
                            self.handleToolEvent(sessionID: sessionID, runID: eventRunID, data: eventData)
                        }
                        continue
                    }
                    guard object["stream"] as? String == "transcript",
                          let eventData = object["data"] as? [String: Any],
                          let messageObject = eventData["message"] as? [String: Any] else { continue }
                    if eventData["type"] as? String == "thinking_delta",
                       let delta = messageObject["content"] as? String {
                        await MainActor.run {
                            self.appendThinking(delta, for: sessionID)
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

    private func decodeMessages(_ data: Data, sessionID: String = "") -> [MothxMessage] {
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
            let imagePreviews = decodeImagePreviews(item, sessionID: sessionID)

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

            var combinedPreviews = imagePreviews
            // `publish_artifact` stores its tool name separately from the
            // JSON arguments. Resolve the relative `path` against this
            // session's work directory while the session context is known.
            if role == "toolCall" {
                for candidate in MothxImagePreview.publishArtifactPreviews(
                    toolName: toolName,
                    arguments: arguments,
                    workDirectory: workDir(for: sessionID)
                ) where !combinedPreviews.contains(where: { $0.source == candidate.source }) {
                    combinedPreviews.append(candidate)
                }
            }
            // Assistant/user replies frequently reference locally generated
            // images as Markdown, e.g. `![图表](outputs/chart.png)`, or as
            // `publish_artifact <path>` lines. Surface those as clickable
            // previews too, deduplicated against the structured attachment
            // previews above.
            if role != "toolCall", role != "toolResult",
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                for candidates in [markdownImagePreviews(from: content, sessionID: sessionID),
                                   publishArtifactImagePreviews(from: content, sessionID: sessionID)] {
                    for candidate in candidates where !combinedPreviews.contains(where: { $0.source == candidate.source }) {
                        combinedPreviews.append(candidate)
                    }
                }
            }
            // Tool results publish generated files with the same notation, e.g.
            // `publish_artifact uploadimg/midautumn/20260830_200215_1.png`; keep
            // those visible in the process area of the same turn.
            if role == "toolResult", let summary, !summary.isEmpty {
                for candidate in publishArtifactImagePreviews(from: summary, sessionID: sessionID)
                    where !combinedPreviews.contains(where: { $0.source == candidate.source }) {
                    combinedPreviews.append(candidate)
                }
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
                    ?? (item["createdAt"] as? NSNumber).map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0.doubleValue)) },
                imagePreviews: combinedPreviews
            )
        }.filter { msg in
            if msg.isToolCall || msg.isToolResult { return true }
            return !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !msg.imagePreviews.isEmpty
        }
    }

    /// Extracts local image references written as Markdown images
    /// (`![alt](path)`) from message text so they appear as clickable
    /// previews in the conversation. Only sources that resolve to an existing
    /// file on disk are included; remote URLs and data URLs are not treated
    /// as locally generated images here.
    private func markdownImagePreviews(from text: String, sessionID: String) -> [MothxImagePreview] {
        let pattern = #"!\[[^\]]*\]\(\s*([^)\s]+)\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let workDir = workDir(for: sessionID)
        var previews: [MothxImagePreview] = []
        var index = 0
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges > 1,
                  let urlRange = Range(match.range(at: 1), in: text) else { continue }
            let raw = String(text[urlRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty,
                  let url = MothxImagePreview.resolvedFileURL(for: raw, workDirectory: workDir) else { continue }
            previews.append(MothxImagePreview(
                id: "markdown-\(index)-\(UUID().uuidString)",
                source: url.path,
                mediaType: "image/png",
                name: url.lastPathComponent
            ))
            index += 1
        }
        return previews
    }

    /// Extracts locally published image files (`publish_artifact <path>`)
    /// from text, resolving relative paths against the session work
    /// directory. Only existing image files are included.
    private func publishArtifactImagePreviews(from text: String, sessionID: String) -> [MothxImagePreview] {
        MothxImagePreview.publishArtifactPreviews(from: text, workDirectory: workDir(for: sessionID))
    }

    private func decodeImagePreviews(_ item: [String: Any], sessionID: String = "") -> [MothxImagePreview] {
        var previews: [MothxImagePreview] = []
        var index = 0

        if let contents = item["contents"] as? [[String: Any]] {
            for block in contents where (block["type"] as? String)?.lowercased() == "image" {
                let image = (block["image"] as? [String: Any]) ?? block
                let mimeType = (image["mimeType"] as? String) ?? (image["mediaType"] as? String) ?? "image/png"
                if let data = image["data"] as? String, !data.isEmpty {
                    previews.append(MothxImagePreview(
                        id: "content-\(index)-\(item["id"] as? String ?? UUID().uuidString)",
                        source: data.hasPrefix("data:") ? data : "data:\(mimeType);base64,\(data)",
                        mediaType: mimeType,
                        name: image["filename"] as? String
                    ))
                    index += 1
                } else if let url = (image["url"] as? String) ?? (image["source"] as? String), !url.isEmpty {
                    previews.append(MothxImagePreview(
                        id: "content-\(index)-\(item["id"] as? String ?? UUID().uuidString)",
                        source: normalizedImageSource(url, sessionID: sessionID),
                        mediaType: mimeType,
                        name: image["filename"] as? String
                    ))
                    index += 1
                }
            }
        }

        if let attachments = item["attachments"] as? [[String: Any]] {
            for attachment in attachments where (attachment["kind"] as? String)?.lowercased() == "image" {
                guard let url = attachment["url"] as? String, !url.isEmpty else { continue }
                let normalized = normalizedImageSource(url, sessionID: sessionID)
                if previews.contains(where: { $0.source == normalized }) { continue }
                previews.append(MothxImagePreview(
                    id: "attachment-\(index)-\(item["id"] as? String ?? UUID().uuidString)",
                    source: normalized,
                    mediaType: attachment["mediaType"] as? String ?? "image/png",
                    name: attachment["name"] as? String
                ))
                index += 1
            }
        }
        return previews
    }

    /// Normalizes an image preview URL/path returned by the server into a
    /// form the preview UI can load directly:
    /// - `file://` URLs become absolute file paths;
    /// - relative paths are resolved against the session's working directory;
    /// - `data:` and `http(s)` sources pass through unchanged.
    private func normalizedImageSource(_ source: String, sessionID: String) -> String {
        if source.hasPrefix("data:") || source.hasPrefix("http://") || source.hasPrefix("https://") {
            return source
        }
        var path = source
        if path.hasPrefix("file://"), let url = URL(string: path) {
            path = url.path
        }
        if path.hasPrefix("/") { return path }
        let workDir = workDir(for: sessionID)
        guard !workDir.isEmpty else { return source }
        return URL(fileURLWithPath: workDir).appendingPathComponent(path).path
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
            return MothxSession(
                id: id,
                title: item["title"] as? String ?? item["preview"] as? String ?? "New session",
                projectID: item["projectId"] as? String ?? item["projectID"] as? String,
                updatedAt: item["updatedAt"] as? String ?? item["lastUsed"] as? String,
                workDir: item["workDir"] as? String ?? item["workdir"] as? String,
                parentSessionId: item["parentSessionId"] as? String,
                forkBoundarySeq: item["forkBoundarySeq"] as? Int,
                seedLength: item["seedLength"] as? Int,
                forkKind: item["forkKind"] as? String
            )
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

    func saveImageGeneration(_ config: MothxImageGenerationConfig) {
        imageGeneration = config
        persistImageGeneration(config)
    }

    /// Persists only the selected provider/model locally. The credentials and
    /// provider definition continue to be owned by mothx's settings document.
    func saveImageRecognition(_ config: MothxImageRecognitionConfig) {
        imageRecognition = config
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.imageRecognitionDefaultsKey)
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
            let discovered = decodeDiscoveredModels(data)
            // Most OpenAI-compatible /models endpoints only return IDs and
            // names. Keep the values already configured for matching models
            // when the probe cannot provide context/output limits, otherwise
            // a refresh silently turns known values into zero.
            return mergeDiscoveredModels(discovered, with: provider.models)
        } catch {
            settingsError = copy.discoverModelsFailedPrefix(describe(error))
            return []
        }
    }

    private func mergeDiscoveredModels(
        _ discovered: [MothxModelConfig],
        with existing: [MothxModelConfig]
    ) -> [MothxModelConfig] {
        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return discovered.map { remote in
            guard let previous = existingByID[remote.id] else { return remote }

            var merged = remote
            if merged.contextWindow <= 0 {
                merged.contextWindow = previous.contextWindow
            }
            if merged.maxTokens <= 0 {
                merged.maxTokens = previous.maxTokens
            }
            // The probe schema has no presence bit for optional capability
            // flags. Preserve a previously enabled flag when the upstream
            // response omits it, while still accepting an explicit true.
            if !merged.reasoning, previous.reasoning {
                merged.reasoning = true
            }
            if merged.input == ["text"], !previous.input.isEmpty {
                merged.input = previous.input
            }
            if merged.name == merged.id, !previous.name.isEmpty {
                merged.name = previous.name
            }
            return merged
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

    private func decodeLegacyImageGeneration(object: [String: Any]?) -> MothxImageGenerationConfig? {
        guard let object else { return nil }
        return MothxImageGenerationConfig(
            enabled: object["enabled"] as? Bool ?? false,
            providerID: object["provider"] as? String ?? "",
            modelID: object["model"] as? String ?? ""
        )
    }

    private static var hasStoredImageGenerationConfig: Bool {
        UserDefaults.standard.data(forKey: imageGenerationDefaultsKey) != nil
    }

    private static func loadImageGenerationConfig() -> MothxImageGenerationConfig {
        guard let data = UserDefaults.standard.data(forKey: imageGenerationDefaultsKey),
              let config = try? JSONDecoder().decode(MothxImageGenerationConfig.self, from: data) else {
            return MothxImageGenerationConfig()
        }
        return config
    }

    private func persistImageGeneration(_ config: MothxImageGenerationConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.imageGenerationDefaultsKey)
    }

    private static func loadImageRecognitionConfig() -> MothxImageRecognitionConfig {
        guard let data = UserDefaults.standard.data(forKey: imageRecognitionDefaultsKey),
              let config = try? JSONDecoder().decode(MothxImageRecognitionConfig.self, from: data) else {
            return MothxImageRecognitionConfig()
        }
        return config
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

private enum ImageRecognitionError: LocalizedError {
    case noImages
    case notConfigured
    case invalidSessionResponse
    case noRunID
    case invalidMessagesResponse
    case modelNotFound(String, String)
    case emptyResult(String)
    case runFailed(String)

    var errorDescription: String? {
        switch self {
        case .noImages: return "没有可识别的图片"
        case .notConfigured: return "尚未配置图片识别 Provider 和模型"
        case .invalidSessionResponse: return "图片识别临时会话创建失败"
        case .noRunID: return "图片识别接口没有返回 Run ID"
        case .invalidMessagesResponse: return "图片识别结果格式无效"
        case .modelNotFound(let provider, let model): return "图片识别模型不存在：\(provider)/\(model)"
        case .emptyResult(let status): return "图片识别没有返回文字结果（状态：\(status)）"
        case .runFailed(let detail): return "图片识别运行失败：\(detail)"
        }
    }
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
