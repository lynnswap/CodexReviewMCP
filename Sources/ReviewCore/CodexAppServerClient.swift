import Foundation
import Logging
import MCP

package struct CodexAppServerClientConfiguration: Sendable {
    package var codexCommand: String
    package var environment: [String: String]
    package var clientName: String
    package var clientVersion: String

    package init(
        codexCommand: String = "codex",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        clientName: String = codexReviewMCPName,
        clientVersion: String = codexReviewMCPVersion
    ) {
        self.codexCommand = codexCommand
        self.environment = environment
        self.clientName = clientName
        self.clientVersion = clientVersion
    }
}

package protocol CodexAppServerTransport: Sendable {
    func start() async throws -> AsyncThrowingStream<String, Error>
    func send(_ line: String) async throws
    func stop() async
}

package typealias CodexAppServerTransportFactory = @Sendable () -> any CodexAppServerTransport

package struct CodexAppServerNotification: Sendable {
    package var method: String
    package var params: Value?
}

package enum CodexAppServerEvent: Sendable {
    case notification(CodexAppServerNotification)
    case disconnected
}

package struct CodexAppServerRPCError: Error, Codable, Sendable {
    package var code: Int
    package var message: String

    package var localizedDescription: String {
        message
    }
}

private struct CodexAppServerRequestEnvelope: Encodable {
    var id: Int
    var method: String
    var params: Value?
}

private struct CodexAppServerNotificationEnvelope: Encodable {
    var method: String
    var params: Value?
}

private struct CodexAppServerInboundEnvelope: Decodable {
    var id: Int?
    var method: String?
    var params: Value?
    var result: Value?
    var error: CodexAppServerRPCError?
}

private struct CodexAppServerInitializeParams: Codable {
    struct ClientInfo: Codable {
        var name: String
        var version: String
    }

    var clientInfo: ClientInfo
}

package struct AppServerProcessInvocation: Sendable {
    package var executable: String
    package var arguments: [String]
}

package actor CodexAppServerClient {
    nonisolated let events: AsyncStream<CodexAppServerEvent>

    private let eventsContinuation: AsyncStream<CodexAppServerEvent>.Continuation
    private let configuration: CodexAppServerClientConfiguration
    private let transportFactory: CodexAppServerTransportFactory
    private let logger = Logger(label: "codex-review-mcp.app-server")

    private var transport: (any CodexAppServerTransport)?
    private var readTask: Task<Void, Never>?
    private var initializationTask: Task<Void, Error>?
    private var pendingResponses: [Int: CheckedContinuation<Value, Error>] = [:]
    private var nextRequestID = 1
    private var initialized = false

    package init(
        configuration: CodexAppServerClientConfiguration = .init(),
        transportFactory: CodexAppServerTransportFactory? = nil
    ) {
        self.configuration = configuration
        self.transportFactory = transportFactory ?? {
            ProcessCodexAppServerTransport(configuration: configuration)
        }
        var continuation: AsyncStream<CodexAppServerEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventsContinuation = continuation
    }

    package func call<Request: Codable, Response: Decodable>(
        method: String,
        params: Request,
        as responseType: Response.Type
    ) async throws -> Response {
        try await ensureInitialized()
        let result = try await sendRequest(method: method, params: try Value(params))
        return try decode(result, as: responseType)
    }

    package func call(
        method: String,
        params: Value? = nil
    ) async throws -> Value {
        try await ensureInitialized()
        return try await sendRequest(method: method, params: params)
    }

    package func notify(
        method: String,
        params: Value? = nil
    ) async throws {
        try await ensureInitialized()
        try await sendNotification(method: method, params: params)
    }

    package func shutdown() async {
        initializationTask?.cancel()
        initializationTask = nil
        await disconnect()
    }

    private func ensureInitialized() async throws {
        if initialized {
            return
        }
        if let initializationTask {
            return try await initializationTask.value
        }

        let task = Task<Void, Error> {
            try await self.initializeConnection()
        }
        initializationTask = task
        do {
            try await task.value
        } catch {
            initializationTask = nil
            throw error
        }
    }

    private func initializeConnection() async throws {
        let transport = transportFactory()
        let stream = try await transport.start()
        self.transport = transport
        self.readTask = Task {
            await self.readLoop(stream)
        }

        do {
            _ = try await sendRequest(
                method: "initialize",
                params: try Value(
                    CodexAppServerInitializeParams(
                        clientInfo: .init(
                            name: configuration.clientName,
                            version: configuration.clientVersion
                        )
                    )
                )
            )
            try await sendNotification(method: "initialized", params: [:])
            initialized = true
            initializationTask = nil
        } catch {
            initializationTask = nil
            await disconnect()
            throw error
        }
    }

    private func readLoop(_ stream: AsyncThrowingStream<String, Error>) async {
        do {
            for try await line in stream {
                if Task.isCancelled {
                    break
                }
                await handleInboundLine(line)
            }
        } catch {
            logger.warning("codex app-server stream failed", metadata: ["error": "\(error)"])
        }

        await disconnect()
    }

    private func handleInboundLine(_ line: String) async {
        guard let data = line.data(using: .utf8) else {
            return
        }
        let envelope: CodexAppServerInboundEnvelope
        do {
            envelope = try JSONDecoder().decode(CodexAppServerInboundEnvelope.self, from: data)
        } catch {
            logger.warning("Ignoring malformed codex app-server JSON line", metadata: ["line": "\(line)"])
            return
        }

        if let id = envelope.id {
            if let continuation = pendingResponses.removeValue(forKey: id) {
                if let error = envelope.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: envelope.result ?? .null)
                }
            }
            return
        }

        guard let method = envelope.method else {
            return
        }
        eventsContinuation.yield(
            .notification(
                CodexAppServerNotification(
                    method: method,
                    params: envelope.params
                )
            )
        )
    }

    private func sendRequest(method: String, params: Value?) async throws -> Value {
        guard transport != nil else {
            throw ReviewError.io("codex app-server is not connected.")
        }
        let requestID = nextRequestID
        nextRequestID += 1
        let line = try encodeLine(
            CodexAppServerRequestEnvelope(
                id: requestID,
                method: method,
                params: params
            )
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[requestID] = continuation
            Task {
                await self.sendPendingRequestLine(line, requestID: requestID)
            }
        }
    }

    private func sendPendingRequestLine(_ line: String, requestID: Int) async {
        guard let transport else {
            failPendingResponse(
                requestID,
                error: ReviewError.io("codex app-server is not connected.")
            )
            return
        }
        do {
            try await transport.send(line)
        } catch {
            failPendingResponse(requestID, error: error)
        }
    }

    private func sendNotification(method: String, params: Value?) async throws {
        guard let transport else {
            throw ReviewError.io("codex app-server is not connected.")
        }
        try await transport.send(
            encodeLine(
                CodexAppServerNotificationEnvelope(
                    method: method,
                    params: params
                )
            )
        )
    }

    private func failPendingResponse(_ requestID: Int, error: Error) {
        guard let continuation = pendingResponses.removeValue(forKey: requestID) else {
            return
        }
        continuation.resume(throwing: error)
    }

    private func disconnect() async {
        let currentReadTask = readTask
        let currentTransport = transport
        readTask = nil
        transport = nil
        initialized = false
        initializationTask = nil

        let pending = pendingResponses
        pendingResponses.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: ReviewError.io("codex app-server disconnected."))
        }

        currentReadTask?.cancel()
        await currentTransport?.stop()
        eventsContinuation.yield(.disconnected)
    }
}

package actor ProcessCodexAppServerTransport: CodexAppServerTransport {
    private let configuration: CodexAppServerClientConfiguration
    private let logger = Logger(label: "codex-review-mcp.app-server.transport")

    private var process: Process?
    private var inputHandle: FileHandle?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    package init(configuration: CodexAppServerClientConfiguration) {
        self.configuration = configuration
    }

    package func start() async throws -> AsyncThrowingStream<String, Error> {
        guard process == nil else {
            throw ReviewError.io("codex app-server transport already started.")
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = Process()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = configuration.environment
        let invocation = appServerProcessInvocation(codexCommand: configuration.codexCommand)
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments

        try process.run()

        self.process = process
        self.inputHandle = stdinPipe.fileHandleForWriting

        var continuation: AsyncThrowingStream<String, Error>.Continuation!
        let stream = AsyncThrowingStream<String, Error> { continuation = $0 }

        stdoutTask = Task {
            do {
                for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                    continuation.yield(line)
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        stderrTask = Task {
            do {
                for try await line in stderrPipe.fileHandleForReading.bytes.lines {
                    logger.debug("codex app-server stderr", metadata: ["line": "\(line)"])
                }
            } catch {
                logger.debug("codex app-server stderr stream closed", metadata: ["error": "\(error)"])
            }
        }

        return stream
    }

    package func send(_ line: String) async throws {
        guard let inputHandle else {
            throw ReviewError.io("codex app-server stdin is unavailable.")
        }
        try inputHandle.write(contentsOf: Data((line + "\n").utf8))
    }

    package func stop() async {
        stdoutTask?.cancel()
        stderrTask?.cancel()
        stdoutTask = nil
        stderrTask = nil

        try? inputHandle?.close()
        inputHandle = nil

        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        self.process = nil
    }
}

private func encodeLine<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
}

private func decode<T: Decodable>(_ value: Value, as type: T.Type) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(type, from: data)
}

package func appServerProcessInvocation(codexCommand: String) -> AppServerProcessInvocation {
    let command = "trap - TERM INT; exec \(shellEscape(codexCommand)) app-server --listen stdio://"
    return AppServerProcessInvocation(
        executable: "/bin/sh",
        arguments: ["-lc", command]
    )
}

private func shellEscape(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
}
