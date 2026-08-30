import Foundation

enum MothxAgentTransport: String, CaseIterable, Identifiable {
    case acp
    case serve

    static let defaultsKey = "mothxOS.agentTransport"

    var id: String { rawValue }
}

struct MothxACPLaunchOptions: Hashable, Sendable {
    let browser: Bool
    let delegate: Bool
    let multiAgent: Bool
    let workflows: Bool

    init(tools: [String]) {
        let selected = Set(tools)
        browser = selected.contains("browser")
        delegate = selected.contains("delegate")
        multiAgent = selected.contains("multi-agent")
        workflows = selected.contains("workflow")
    }

    nonisolated var arguments: [String] {
        var result = ["acp"]
        if browser { result.append("--browser") }
        if delegate { result.append("--delegate") }
        if multiAgent { result.append("--multi-agent") }
        if workflows { result.append("--workflows") }
        return result
    }
}

enum MothxACPError: LocalizedError {
    case notRunning
    case invalidResponse(String)
    case rpc(code: Int, message: String)
    case processExited(Int32)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "ACP process is not running."
        case .invalidResponse(let detail):
            return "Invalid ACP response: \(detail)"
        case .rpc(let code, let message):
            return "ACP error \(code): \(message)"
        case .processExited(let status):
            return "ACP process exited with status \(status)."
        }
    }
}

/// One shared `mothx acp` subprocess and its newline-delimited JSON-RPC
/// connection. stdout is protocol-only; stderr is drained independently so
/// diagnostics can never corrupt an ACP frame.
actor MothxACPClient {
    typealias MessageHandler = @Sendable (Data) -> Void
    typealias LogHandler = @Sendable (String) -> Void

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputBuffer = Data()
    private var nextID = 0
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var loadedSessions: Set<String> = []
    private var sessionConfigs: [String: [String: String]] = [:]
    private var launchOptions: MothxACPLaunchOptions?
    private var processGeneration = UUID()
    private var messageHandler: MessageHandler?
    private var logHandler: LogHandler?

    func setHandlers(message: MessageHandler?, log: LogHandler?) {
        messageHandler = message
        logHandler = log
    }

    func start(
        executable: URL,
        workingDirectory: URL,
        environment: [String: String],
        options: MothxACPLaunchOptions
    ) async throws {
        if process?.isRunning == true, launchOptions == options { return }
        stop()

        let child = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        child.executableURL = executable
        child.arguments = options.arguments
        child.currentDirectoryURL = workingDirectory
        child.environment = environment
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe
        let generation = UUID()
        processGeneration = generation

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.receive(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.emitLog(text) }
        }
        child.terminationHandler = { [weak self] process in
            Task { await self?.didExit(status: process.terminationStatus, generation: generation) }
        }

        do {
            try child.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        process = child
        inputHandle = stdinPipe.fileHandleForWriting
        outputHandle = stdoutPipe.fileHandleForReading
        errorHandle = stderrPipe.fileHandleForReading
        launchOptions = options
        outputBuffer.removeAll(keepingCapacity: true)
        loadedSessions.removeAll()
        sessionConfigs.removeAll()

        do {
            _ = try await request(method: "initialize", params: [
                "protocolVersion": 1,
                "clientCapabilities": [
                    "session": ["configOptions": ["boolean": [:]]],
                    "elicitation": ["form": [:]],
                ],
                "clientInfo": ["name": "mothxOS", "title": "mothxOS", "version": appVersion],
            ])
        } catch {
            stop()
            throw error
        }
    }

    func createSession(cwd: String) async throws -> String {
        let result = try await request(method: "session/new", params: ["cwd": cwd, "mcpServers": []])
        guard let sessionID = result["sessionId"] as? String, !sessionID.isEmpty else {
            throw MothxACPError.invalidResponse("session/new omitted sessionId")
        }
        loadedSessions.insert(sessionID)
        sessionConfigs[sessionID] = configValues(from: result)
        return sessionID
    }

    func resumeSession(id: String, cwd: String) async throws {
        guard !loadedSessions.contains(id) else { return }
        let result = try await request(method: "session/resume", params: ["sessionId": id, "cwd": cwd, "mcpServers": []])
        loadedSessions.insert(id)
        sessionConfigs[id] = configValues(from: result)
    }

    func setConfig(sessionID: String, id: String, value: Any) async throws {
        let stringValue: String
        if let value = value as? Bool {
            stringValue = String(value)
        } else {
            stringValue = String(describing: value)
        }
        if sessionConfigs[sessionID]?[id] == stringValue { return }
        _ = try await request(method: "session/set_config_option", params: [
            "sessionId": sessionID,
            "configId": id,
            "value": value,
        ])
        sessionConfigs[sessionID, default: [:]][id] = stringValue
    }

    func prompt(sessionID: String, text: String) async throws -> String {
        let result = try await request(method: "session/prompt", params: [
            "sessionId": sessionID,
            "prompt": [["type": "text", "text": text]],
            "_meta": ["mothx": ["surface": "mothxOS"]],
        ])
        return result["stopReason"] as? String ?? "end_turn"
    }

    func cancel(sessionID: String) async throws {
        _ = try await request(method: "session/cancel", params: ["sessionId": sessionID])
    }

    func respond(id: String, result: [String: Any]) throws {
        try write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func stop() {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        try? inputHandle?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        launchOptions = nil
        loadedSessions.removeAll()
        sessionConfigs.removeAll()
        outputBuffer.removeAll()
        failPending(with: MothxACPError.notRunning)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard process?.isRunning == true else { throw MothxACPError.notRunning }
        nextID += 1
        let id = "mothxos-\(nextID)"
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func write(_ object: [String: Any]) throws {
        guard let inputHandle else { throw MothxACPError.notRunning }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try inputHandle.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            handleFrame(Data(line))
        }
    }

    private func handleFrame(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            emitLog("Ignored malformed ACP stdout frame.\n")
            return
        }
        if object["method"] == nil, let id = rpcID(object["id"]), let continuation = pending.removeValue(forKey: id) {
            if let error = object["error"] as? [String: Any] {
                continuation.resume(throwing: MothxACPError.rpc(
                    code: (error["code"] as? NSNumber)?.intValue ?? -32000,
                    message: error["message"] as? String ?? "Unknown error"
                ))
            } else if let result = object["result"] as? [String: Any] {
                continuation.resume(returning: result)
            } else {
                continuation.resume(returning: [:])
            }
            return
        }
        messageHandler?(data)
    }

    private func rpcID(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private func emitLog(_ text: String) {
        logHandler?(text)
    }

    private func didExit(status: Int32, generation: UUID) {
        guard generation == processGeneration else { return }
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        launchOptions = nil
        loadedSessions.removeAll()
        sessionConfigs.removeAll()
        failPending(with: MothxACPError.processExited(status))
        emitLog("ACP process exited with status \(status).\n")
    }

    private func failPending(with error: Error) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
    }

    private func configValues(from result: [String: Any]) -> [String: String] {
        guard let options = result["configOptions"] as? [[String: Any]] else { return [:] }
        return options.reduce(into: [:]) { values, option in
            guard let id = option["id"] as? String,
                  let value = option["currentValue"] as? String else { return }
            values[id] = value
        }
    }
}
