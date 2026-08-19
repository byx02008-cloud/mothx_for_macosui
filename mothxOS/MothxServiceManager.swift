import Combine
import Foundation


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
    @Published private(set) var projects: [MothxProject] = []
    @Published private(set) var sessions: [MothxSession] = []
    @Published private(set) var activeSessions: [MothxSession] = []
    @Published private(set) var messagesBySession: [String: [MothxMessage]] = [:]
    @Published private(set) var historicalRunsByMessage: [String: [String: MothxRunSummary]] = [:]
    @Published private(set) var pendingSessions: [String: MothxSession] = [:]
    @Published private(set) var isSubmittingRun = false
    @Published private(set) var runError: String?
    @Published private(set) var runStatus: String?
    @Published private(set) var runElapsed: TimeInterval = 0
    @Published private(set) var runSessionID: String?
    @Published private(set) var runReplyMessageID: String?
    @Published var settingsError: String?
    private var rawSettings: [String: Any] = [:]
    let baseURL = URL(string: "http://127.0.0.1:7872")!
    private var process: Process?
    private var startupPipe: Pipe?
    private var startupOutput = ""
    private var logStreamTask: Task<Void, Never>?
    private var logSocket: URLSessionWebSocketTask?
    private var runStartedAt: Date?
    private var runExistingMessageIDs: Set<String> = []
    private var cancelRequested = false
    @Published private(set) var currentRunID: String?
    @Published private(set) var sessionModels: [String: String] = [:]
    @Published private(set) var serviceLog = ""
    private let localProjectStore = try? LocalProjectStore()

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
        guard let executable = Bundle.main.url(forResource: "mothx", withExtension: nil) else {
            state = .failed("App bundle 中没有找到 mothx runtime")
            return
        }

        let workDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mothx", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        } catch {
            state = .failed("无法创建 mothx 工作目录：\(error.localizedDescription)")
            return
        }

        let child = Process()
        child.executableURL = executable
        // Do not let serve.json select a different port from the one the UI
        // probes. An explicit CLI override is applied by mothx at startup.
        child.arguments = ["serve", "--port", "127.0.0.1:7872"]
        child.currentDirectoryURL = workDirectory
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
            state = .failed("无法启动 mothx：\(error.localizedDescription)")
            return
        }
        await waitForHealth(process: child)
        if state == .connected {
            startLogStream()
            await loadSettings()
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
        if !output.isEmpty { return "mothx serve 启动失败：\\n\(output)" }
        if timedOut { return "mothx serve 启动超时（端口 127.0.0.1:7872）" }
        return "mothx serve 已退出（状态码 \(status)）"
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
            if providers.isEmpty && !providerObjects.isEmpty {
                throw SettingsLoadError.noProvidersDecoded
            }
            settingsError = nil
        } catch {
            settingsError = "读取配置失败：\(error.localizedDescription)"
        }
    }

    func loadWorkspace() async {
        guard state == .connected else { return }

        do {
            guard let localProjectStore else { throw LocalProjectStoreUnavailable() }
            projects = try localProjectStore.projects()
        } catch {
            settingsError = "读取本地项目失败：\(error.localizedDescription)"
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
            var projectIDsBySession = (try? localProjectStore?.projectIDsBySession()) ?? [:]
            let linkedProjectIDs = Set(projectIDsBySession.values)
            for project in projects where !project.workDir.isEmpty && !linkedProjectIDs.contains(project.id) {
                let candidates = loadedSessions.filter {
                    projectIDsBySession[$0.id] == nil && $0.workDir == project.workDir
                }
                // Repair only an unambiguous relationship that was created by
                // the earlier database schema bug. Do not guess when several
                // existing sessions share the same working directory.
                if candidates.count == 1, let session = candidates.first {
                    try? localProjectStore?.assign(sessionID: session.id, to: project.id)
                    projectIDsBySession[session.id] = project.id
                }
            }
            sessions = loadedSessions.map { session in
                var session = session
                session.projectID = projectIDsBySession[session.id]
                return session
            }
            if settingsError?.hasPrefix("读取本地项目失败") != true { settingsError = nil }
        } catch {
            settingsError = "读取会话失败：\(error.localizedDescription)"
        }

        do {
            let data = try await request(path: "api/sessions/active", method: "GET")
            activeSessions = decodeSessions(data)
        } catch {
            activeSessions = []
            if settingsError == nil { settingsError = "读取当前会话失败：\(error.localizedDescription)" }
        }

        await loadInstalledSkills()
    }

    func fetchStats(path: String) async -> Data? {
        do {
            return try await request(path: path, method: "GET")
        } catch {
            settingsError = "读取统计数据失败：\(error.localizedDescription)"
            return nil
        }
    }

    func createProject(name: String, workDir: String) async -> MothxProject? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !workDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            guard let localProjectStore else { throw LocalProjectStoreUnavailable() }
            let project = try localProjectStore.createProject(name: name, workDir: workDir)
            projects.append(project)
            return project
        } catch {
            settingsError = "创建本地项目失败：\(error.localizedDescription)"
            return nil
        }
    }

    func updateProject(id: String, name: String, workDir: String) async {
        do {
            guard let localProjectStore else { throw LocalProjectStoreUnavailable() }
            try localProjectStore.updateProject(id: id, name: name, workDir: workDir)
            guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
            projects[index].name = name
            projects[index].workDir = workDir
        } catch {
            settingsError = "更新本地项目失败：\(error.localizedDescription)"
        }
    }

    func deleteProject(id: String) async {
        do {
            guard let localProjectStore else { throw LocalProjectStoreUnavailable() }
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
            settingsError = "删除本地项目失败：\(error.localizedDescription)"
        }
    }

    func prepareSession(projectID: String?) -> MothxSession {
        // mothx has no empty-session endpoint. The returned ID is submitted
        // with the first real run and becomes persistent at that point.
        let session = MothxSession(id: UUID().uuidString.lowercased(), title: "New session", projectID: projectID, updatedAt: nil, workDir: nil)
        if let projectID {
            do { try localProjectStore?.assign(sessionID: session.id, to: projectID) }
            catch { settingsError = "保存会话项目关系失败：\(error.localizedDescription)" }
        }
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
        catch { settingsError = "删除会话项目关系失败：\(error.localizedDescription)" }
        do {
            _ = try await request(path: "api/sessions/\(id)", method: "DELETE")
            await loadWorkspace()
        } catch {
            if !(error is URLError) {
                settingsError = "删除会话失败：\(error.localizedDescription)"
            }
        }
    }

    func loadMessages(sessionID: String) async {
        do {
            let data = try await request(path: "api/sessions/\(sessionID)/messages?limit=200", method: "GET")
            let messages = decodeMessages(data)
            messagesBySession[sessionID] = messages
            await loadHistoricalRuns(sessionID: sessionID, messages: messages)
            if sessionID == runSessionID {
                runReplyMessageID = messages.first { message in
                    message.role != "user" && !runExistingMessageIDs.contains(message.id)
                }?.id
            }
        } catch {
            settingsError = "读取会话消息失败：\(error.localizedDescription)"
        }
    }

    func submitRun(sessionID: String, message: String, images: [String], workDir: String = "", model: String = "", mode: String = "agent", tools: [String] = [], skills: [String] = []) async -> String? {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return nil }
        isSubmittingRun = true
        cancelRequested = false
        runError = nil
        runStatus = "queued"
        runElapsed = 0
        runSessionID = sessionID
        runReplyMessageID = nil
        currentRunID = nil
        runExistingMessageIDs = Set((messagesBySession[sessionID] ?? []).map(\.id))
        runStartedAt = Date()
        do {
            var payload: [String: Any] = ["message": message, "mode": mode, "transcript": true]
            if !model.isEmpty { payload["model"] = model }
            if !tools.isEmpty { payload["tools"] = tools }
            if !skills.isEmpty { payload["skills"] = skills }
            if !workDir.isEmpty { payload["workDir"] = workDir }
            if !images.isEmpty { payload["images"] = images }
            // Show the submitted question immediately. The API returns 202 and
            // runs the agent in the background, so the assistant message is not
            // available in the first history response yet.
            let localMessage = MothxMessage(id: "local-\(UUID().uuidString)", role: "user", content: message, createdAt: nil)
            messagesBySession[sessionID, default: []].append(localMessage)
            let body = try jsonData(payload)
            let response = try await request(path: "api/sessions/\(sessionID)/runs", method: "POST", body: body, headers: ["Idempotency-Key": UUID().uuidString])
            pendingSessions.removeValue(forKey: sessionID)
            let responseObject = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any]
            let runID = responseObject?["runId"] as? String ?? responseObject?["runID"] as? String
            guard let runID else {
                isSubmittingRun = false
                runStatus = "failed"
                runError = "服务端未返回 run ID"
                return nil
            }
            currentRunID = runID
            if cancelRequested {
                await cancelRun()
            }
            return runID
        } catch {
            isSubmittingRun = false
            runStatus = "failed"
            runError = error.localizedDescription
            settingsError = "提交会话失败：\(error.localizedDescription)"
            return nil
        }
    }

    func cancelRun() async {
        cancelRequested = true
        guard let runID = currentRunID else { return }
        do {
            _ = try await request(path: "api/runs/\(runID)/cancel", method: "POST")
            runStatus = "cancelled"
        } catch {
            runError = "停止运行失败：\(error.localizedDescription)"
            settingsError = runError
        }
    }

    func pollRun(runID: String, sessionID: String) async {
        defer {
            runElapsed = elapsedSinceRunStart()
            isSubmittingRun = false
        }
        for _ in 0..<120 {
            runElapsed = elapsedSinceRunStart()
            do {
                let data = try await request(path: "api/runs/\(runID)", method: "GET")
                let object = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                let status = object["status"] as? String ?? object["state"] as? String ?? "running"
                runStatus = status
                await loadMessages(sessionID: sessionID)
                if ["completed", "succeeded", "failed", "error", "cancelled", "canceled"].contains(status.lowercased()) {
                    if ["failed", "error"].contains(status.lowercased()) { runError = object["error"] as? String ?? object["errorMessage"] as? String ?? "Agent run failed" }
                    await loadWorkspace()
                    return
                }
            } catch {
                runStatus = "failed"
                runError = error.localizedDescription
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        runStatus = "timeout"
        runError = "等待模型回复超时"
    }

    private func elapsedSinceRunStart() -> TimeInterval {
        guard let runStartedAt else { return runElapsed }
        return max(0, Date().timeIntervalSince(runStartedAt))
    }

    private func loadHistoricalRuns(sessionID: String, messages: [MothxMessage]) async {
        do {
            let data = try await request(path: "api/sessions/\(sessionID)/runs?limit=200", method: "GET")
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let values = object["runs"] as? [[String: Any]] else { return }

            let runs = values.compactMap(decodeRunSummary).sorted {
                ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast)
            }
            let assistantMessages = messages.filter { $0.role.lowercased() == "assistant" }
            guard runs.count == assistantMessages.count else {
                // Without a run/message identifier, an unequal count is not
                // safe to align; leave the historical status rows hidden.
                historicalRunsByMessage[sessionID] = [:]
                return
            }
            historicalRunsByMessage[sessionID] = Dictionary(uniqueKeysWithValues: zip(assistantMessages, runs).map { ($0.0.id, $0.1) })
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
            status: status,
            startedAt: parseDate(item["StartedAt"] ?? item["startedAt"]),
            finishedAt: parseDate(item["FinishedAt"] ?? item["finishedAt"]),
            updatedAt: parseDate(item["UpdatedAt"] ?? item["updatedAt"]),
            error: (item["Error"] as? String) ?? (item["error"] as? String)
        )
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
        if let direct = object as? [[String: Any] ] { values = direct }
        else { values = (object as? [String: Any])?["messages"] as? [[String: Any]] ?? [] }
        return values.enumerated().map { index, item in
            let id = item["id"] as? String ?? item["messageId"] as? String ?? "message-\(index)"
            let role = item["role"] as? String ?? item["author"] as? String ?? "assistant"
            let content: String
            if let text = item["content"] as? String { content = text }
            else if let text = item["text"] as? String { content = text }
            else {
                let blocks = item["contents"] as? [[String: Any]] ?? item["content"] as? [[String: Any]] ?? []
                content = blocks.compactMap { block in
                    if let text = block["text"] as? String { return text }
                    if let textObject = block["text"] as? [String: Any] { return textObject["value"] as? String }
                    return nil
                }.joined()
            }
            return MothxMessage(id: id, role: role, content: content, createdAt: item["createdAt"] as? String)
        }.filter { !$0.content.isEmpty || $0.role == "toolCall" || $0.role == "toolResult" }
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
            _ = try await request(path: "api/sessions/\\(id)/title", method: "POST", body: body)
            await loadWorkspace()
        } catch { settingsError = "更新会话失败：\\(error.localizedDescription)" }
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

    func saveLanguage(_ value: String) async {
        await saveGlobalSettings(["tuilang": value])
    }

    func saveGlobalSettings(_ values: [String: Any]) async {
        do {
            for (key, value) in values { rawSettings[key] = value }
            let data = try JSONSerialization.data(withJSONObject: rawSettings)
            _ = try await request(path: "api/settings", method: "PUT", body: data)
            await loadSettings()
        } catch {
            settingsError = "保存全局配置失败：\(error.localizedDescription)"
        }
    }

    func saveDefaults(provider: String, model: String, thinkingLevel: String, mode: String) async {
        await saveGlobalSettings(["defaultProvider": provider, "defaultModel": model, "defaultThinkingLevel": thinkingLevel, "defaultMode": mode])
    }

    func saveSkillsAndSession(skillsDir: String, sessionDir: String) async {
        await saveGlobalSettings(["skillsDir": skillsDir, "sessionDir": sessionDir])
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
        } catch { settingsError = "删除 Provider 失败：\(error.localizedDescription)" }
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
            settingsError = "保存配置失败：\(error.localizedDescription)"
        }
    }

    func discoverModels(provider: MothxProviderConfig) async -> [MothxModelConfig] {
        do {
            let body = try jsonData(["api": provider.api, "baseUrl": provider.baseUrl, "apiKey": provider.apiKey, "httpProxy": provider.httpProxy, "forceHTTP11": provider.forceHTTP11, "headers": provider.headers])
            let data = try await request(path: "api/provider/models", method: "POST", body: body)
            let result = try JSONDecoder().decode(DiscoveredModelsResponse.self, from: data)
            return result.data.map { MothxModelConfig(id: $0.id, name: $0.name, reasoning: $0.reasoning, contextWindow: $0.contextWindow, maxTokens: $0.maxTokens, input: $0.input) }
        } catch {
            settingsError = "获取模型失败：\(error.localizedDescription)"
            return []
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

    func restartService() async {
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
        await connect()
    }

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 1.0
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return false }
            return (200..<300).contains(status)
        } catch {
            return false
        }
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
