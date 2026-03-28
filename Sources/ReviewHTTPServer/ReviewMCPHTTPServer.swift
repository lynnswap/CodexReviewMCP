import Foundation
import Logging
import MCP
import ReviewCore

@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

package struct ReviewServerConfiguration: Sendable {
    package var host: String
    package var port: Int
    package var endpoint: String
    package var sessionTimeoutSeconds: TimeInterval
    package var codexCommand: String
    package var environment: [String: String]

    package init(
        host: String = "localhost",
        port: Int = codexReviewDefaultPort,
        endpoint: String = ReviewDefaults.shared.server.endpointPath,
        sessionTimeoutSeconds: TimeInterval = ReviewDefaults.shared.server.sessionTimeoutSeconds,
        codexCommand: String = "codex",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.host = host
        self.port = port
        self.endpoint = normalizeEndpointPath(endpoint)
        self.sessionTimeoutSeconds = sessionTimeoutSeconds
        self.codexCommand = codexCommand
        self.environment = environment
    }
}

package final class ReviewMCPHTTPServer: @unchecked Sendable {
    package let configuration: ReviewServerConfiguration
    package let reviewRegistry: ReviewRegistry
    private let logger = Logger(label: "codex-review-mcp.http")
    private let app: ReviewHTTPApplication
    private var startedURL: URL?

    package init(
        configuration: ReviewServerConfiguration = .init(),
        appServerTransportFactory: CodexAppServerTransportFactory? = nil
    ) {
        self.configuration = configuration
        self.reviewRegistry = ReviewRegistry(
            configuration: .init(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment
            ),
            transportFactory: appServerTransportFactory
        )
        self.app = ReviewHTTPApplication(
            configuration: .init(
                host: configuration.host,
                port: configuration.port,
                endpoint: configuration.endpoint,
                sessionTimeoutSeconds: configuration.sessionTimeoutSeconds
            ),
            serverFactory: { [reviewRegistry] sessionID, transport in
                await Self.makeServer(
                    sessionID: sessionID,
                    transport: transport,
                    reviewRegistry: reviewRegistry
                )
            },
            onSessionClosed: { [reviewRegistry] sessionID in
                await reviewRegistry.closeSession(sessionID, reason: "MCP session closed.")
            },
            isSessionBusy: { [reviewRegistry] sessionID in
                await reviewRegistry.hasActiveReviews(for: sessionID)
            }
        )
    }

    package func start() async throws -> URL {
        await reviewRegistry.start()
        let address = try await app.startListening()
        let discoveryHost = normalizedDiscoveryHost(
            configuredHost: configuration.host,
            boundHost: address.host
        )
        if let record = ReviewDiscovery.makeRecord(
            host: discoveryHost,
            port: address.port,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            endpointPath: configuration.endpoint
        ) {
            try? ReviewDiscovery.write(record)
        }
        guard let url = ReviewDiscovery.makeURL(
            host: discoveryHost,
            port: address.port,
            endpointPath: configuration.endpoint
        ) else {
            throw ReviewError.io("Failed to construct server URL for \(discoveryHost):\(address.port).")
        }
        startedURL = url
        logger.info("Review MCP server listening", metadata: ["url": "\(url.absoluteString)"])
        return url
    }

    package func waitUntilShutdown() async throws {
        try await app.waitUntilShutdown()
    }

    package func run() async throws {
        _ = try await start()
        try await waitUntilShutdown()
    }

    package func stop() async {
        await app.stop()
        await reviewRegistry.shutdown()
        ReviewDiscovery.removeIfOwned(
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            url: startedURL
        )
        startedURL = nil
    }

    package func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        await reviewRegistry.start()
        return await app.handleHTTPRequest(request)
    }

    package func url() -> URL? {
        startedURL
    }
}

package func normalizedDiscoveryHost(configuredHost: String, boundHost: String) -> String {
    if configuredHost == "localhost" || isWildcardListenHost(configuredHost) || isWildcardListenHost(boundHost) {
        return "localhost"
    }
    return boundHost
}

package func shouldCloseSessionAfterDelete(method: String, statusCode: Int) -> Bool {
    method.uppercased() == "DELETE" && ((200 ... 299).contains(statusCode) || statusCode == 404)
}

private func normalizeEndpointPath(_ endpoint: String) -> String {
    endpoint.hasPrefix("/") ? endpoint : "/\(endpoint)"
}

private extension ReviewMCPHTTPServer {
    static func makeServer(
        sessionID: String,
        transport: StatefulHTTPServerTransport,
        reviewRegistry: ReviewRegistry
    ) async -> Server {
        let server = Server(
            name: codexReviewMCPName,
            version: codexReviewMCPVersion,
            instructions: "Run repository reviews through Codex CLI without streaming agent reasoning.",
            capabilities: .init(
                tools: .init()
            )
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: ReviewToolCatalog.tools)
        }

        await server.withMethodHandler(CallTool.self) { (params: CallTool.Parameters) in
            await ReviewToolHandler(
                sessionID: sessionID,
                reviewRegistry: reviewRegistry
            ).handle(params: params)
        }

        return server
    }
}

private func isWildcardListenHost(_ host: String) -> Bool {
    switch host {
    case "0.0.0.0", "::", "[::]":
        true
    default:
        false
    }
}

private enum ReviewToolCatalog {
    static let tools: [Tool] = [
        Tool(
            name: "review_start",
            description: "Start a detached review through codex app-server and return the review thread handle.",
            inputSchema: reviewStartInputSchema,
            annotations: .init(readOnlyHint: false)
        ),
        Tool(
            name: "review_read",
            description: "Read the current or final state of a detached review thread owned by the current MCP session.",
            inputSchema: reviewReadInputSchema,
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "review_cancel",
            description: "Cancel a detached review thread owned by the current MCP session.",
            inputSchema: cancelInputSchema,
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
    ]

    private static let reviewStartInputSchema: Value = [
        "type": "object",
        "properties": [
            "cwd": ["type": "string", "description": "Repository path to review."],
            "target": [
                "type": "object",
                "properties": [
                    "type": [
                        "type": "string",
                        "enum": ["uncommittedChanges", "baseBranch", "commit", "custom"],
                    ],
                    "branch": ["type": "string"],
                    "sha": ["type": "string"],
                    "title": ["type": "string"],
                    "instructions": ["type": "string"],
                ],
                "required": ["type"],
                "additionalProperties": false,
            ],
            "model": ["type": "string"],
        ],
        "required": ["cwd", "target"],
        "additionalProperties": false,
    ]

    private static let reviewReadInputSchema: Value = [
        "type": "object",
        "properties": [
            "reviewThreadId": ["type": "string"],
        ],
        "required": ["reviewThreadId"],
        "additionalProperties": false,
    ]

    private static let cancelInputSchema: Value = [
        "type": "object",
        "properties": [
            "reviewThreadId": ["type": "string"],
        ],
        "required": ["reviewThreadId"],
        "additionalProperties": false,
    ]
}

private struct ReviewToolHandler {
    let sessionID: String
    let reviewRegistry: ReviewRegistry

    func handle(params: CallTool.Parameters) async -> CallTool.Result {
        switch params.name {
        case "review_start":
            return await handleReviewStart(params: params)
        case "review_read":
            return await handleReviewRead(params: params)
        case "review_cancel":
            return await handleCancel(params: params)
        default:
            return toolError("Unknown tool: \(params.name)")
        }
    }

    private func handleReviewStart(params: CallTool.Parameters) async -> CallTool.Result {
        do {
            let arguments = try decodeArguments(params.arguments, as: ReviewStartArguments.self)
            let handle = try await reviewRegistry.startReview(
                sessionID: sessionID,
                request: arguments.makeRequest()
            )
            return try CallTool.Result(
                content: [.text(text: "Review started.", annotations: nil, _meta: nil)],
                structuredContent: handle.structuredContent(),
                isError: false
            )
        } catch {
            return toolError(error.localizedDescription)
        }
    }

    private func handleReviewRead(params: CallTool.Parameters) async -> CallTool.Result {
        do {
            let arguments = try decodeArguments(params.arguments, as: ReviewReadArguments.self)
            let result = try await reviewRegistry.readReview(
                reviewThreadID: arguments.reviewThreadID,
                sessionID: sessionID
            )
            return try CallTool.Result(
                content: [.text(text: result.review.isEmpty ? result.status.rawValue : result.review, annotations: nil, _meta: nil)],
                structuredContent: result.structuredContent(),
                isError: result.status == .failed
            )
        } catch {
            return toolError(error.localizedDescription)
        }
    }

    private func handleCancel(params: CallTool.Parameters) async -> CallTool.Result {
        do {
            let arguments = try decodeArguments(params.arguments, as: ReviewCancelArguments.self)
            let result = try await reviewRegistry.cancelReview(
                reviewThreadID: arguments.reviewThreadID,
                sessionID: sessionID
            )
            return try CallTool.Result(
                content: [.text(text: result.cancelled ? "Cancellation requested." : "Review was already finished.", annotations: nil, _meta: nil)],
                structuredContent: result.structuredContent(),
                isError: false
            )
        } catch {
            return toolError(error.localizedDescription)
        }
    }

    private func toolError(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }
}

private struct ReviewStartArguments: Codable {
    var cwd: String
    var target: ReviewTarget
    var model: String?

    func makeRequest() -> ReviewStartRequest {
        ReviewStartRequest(
            cwd: cwd,
            target: target,
            model: model
        )
    }
}

private struct ReviewReadArguments: Codable {
    var reviewThreadID: String

    private enum CodingKeys: String, CodingKey {
        case reviewThreadID = "reviewThreadId"
    }
}

private struct ReviewCancelArguments: Codable {
    var reviewThreadID: String

    private enum CodingKeys: String, CodingKey {
        case reviewThreadID = "reviewThreadId"
    }
}

private func decodeArguments<T: Decodable>(_ arguments: [String: Value]?, as type: T.Type) throws -> T {
    let data = try JSONEncoder().encode(arguments ?? [:])
    return try JSONDecoder().decode(type, from: data)
}

actor ReviewHTTPApplication {
    struct Configuration: Sendable {
        var host: String
        var port: Int
        var endpoint: String
        var sessionTimeoutSeconds: TimeInterval
    }

    typealias ServerFactory = @Sendable (String, StatefulHTTPServerTransport) async -> Server
    typealias SessionClosedHandler = @Sendable (String) async -> Void

    private struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        var lastAccessedAt: Date
        var activeRequestCount: Int
    }

    private let configuration: Configuration
    private let serverFactory: ServerFactory
    private let onSessionClosed: SessionClosedHandler
    private let isSessionBusy: @Sendable (String) async -> Bool
    private let logger = Logger(label: "codex-review-mcp.http.app")
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    private var channel: Channel?
    private var cleanupTask: Task<Void, Never>?
    private var sessions: [String: SessionContext] = [:]

    init(
        configuration: Configuration,
        serverFactory: @escaping ServerFactory,
        onSessionClosed: @escaping SessionClosedHandler,
        isSessionBusy: @escaping @Sendable (String) async -> Bool
    ) {
        self.configuration = configuration
        self.serverFactory = serverFactory
        self.onSessionClosed = onSessionClosed
        self.isSessionBusy = isSessionBusy
    }

    func startListening() async throws -> (host: String, port: Int) {
        if let channel, let localAddress = channel.localAddress {
            return (localAddress.ipAddress ?? configuration.host, localAddress.port ?? configuration.port)
        }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeSucceededFuture(())
                }
                return channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        ReviewHTTPHandler(
                            app: self,
                            endpoint: self.configuration.endpoint
                        )
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
        self.channel = channel
        cleanupTask?.cancel()
        cleanupTask = Task { await self.sessionCleanupLoop() }
        let localAddress = channel.localAddress
        return (
            localAddress?.ipAddress ?? configuration.host,
            localAddress?.port ?? configuration.port
        )
    }

    func waitUntilShutdown() async throws {
        guard let channel else {
            return
        }
        try await channel.closeFuture.get()
    }

    func stop() async {
        cleanupTask?.cancel()
        _ = await cleanupTask?.value
        cleanupTask = nil
        for sessionID in Array(sessions.keys) {
            await closeSession(sessionID)
        }
        try? await channel?.close()
        channel = nil
        try? await group.shutdownGracefully()
    }

    func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)
        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            session.activeRequestCount += 1
            sessions[sessionID] = session
            let response = await session.transport.handleRequest(request)
            if var updatedSession = sessions[sessionID] {
                updatedSession.activeRequestCount = max(0, updatedSession.activeRequestCount - 1)
                updatedSession.lastAccessedAt = Date()
                sessions[sessionID] = updatedSession
            }
            if shouldCloseSessionAfterDelete(method: request.method, statusCode: response.statusCode) {
                await closeSession(sessionID)
            }
            return response
        }

        if request.method.uppercased() == "POST",
           let body = request.body,
           isInitializeRequestBody(body)
        {
            return await createSessionAndHandle(request)
        }

        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired."))
        }
        return .error(statusCode: 400, .invalidRequest("Missing \(HTTPHeaderName.sessionID) header."))
    }

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String
        func generateSessionID() -> String { sessionID }
    }

    private func isInitializeRequestBody(_ body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return false
        }
        return object["method"] as? String == "initialize"
    }

    private func createSessionAndHandle(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            retryInterval: 1000
        )
        let server = await serverFactory(sessionID, transport)
        do {
            try await server.start(transport: transport)
            sessions[sessionID] = SessionContext(
                server: server,
                transport: transport,
                lastAccessedAt: Date(),
                activeRequestCount: 1
            )
            let response = await transport.handleRequest(request)
            if var session = sessions[sessionID] {
                session.activeRequestCount = max(0, session.activeRequestCount - 1)
                session.lastAccessedAt = Date()
                sessions[sessionID] = session
            }
            if case .error = response {
                sessions.removeValue(forKey: sessionID)
                await transport.disconnect()
                await onSessionClosed(sessionID)
            }
            return response
        } catch {
            await transport.disconnect()
            return .error(statusCode: 500, .internalError("Failed to start MCP server: \(error.localizedDescription)"))
        }
    }

    private func closeSession(_ sessionID: String) async {
        guard let session = sessions.removeValue(forKey: sessionID) else {
            return
        }
        await session.transport.disconnect()
        await onSessionClosed(sessionID)
    }

    private func sessionCleanupLoop() async {
        while channel != nil {
            let sleepSeconds = min(60.0, max(1.0, configuration.sessionTimeoutSeconds / 2))
            try? await Task.sleep(for: .seconds(sleepSeconds))
            if Task.isCancelled {
                break
            }
            let cutoff = Date().addingTimeInterval(-configuration.sessionTimeoutSeconds)
            var expiredIDs: [String] = []
            let sessionRecords = Array(sessions)
            for (sessionID, context) in sessionRecords {
                if context.lastAccessedAt >= cutoff {
                    continue
                }
                if context.activeRequestCount > 0 {
                    continue
                }
                if await isSessionBusy(sessionID) {
                    if var record = sessions[sessionID] {
                        record.lastAccessedAt = Date()
                        sessions[sessionID] = record
                    }
                    continue
                }
                if let record = sessions[sessionID], record.lastAccessedAt >= cutoff || record.activeRequestCount > 0 {
                    continue
                }
                expiredIDs.append(sessionID)
            }
            for sessionID in expiredIDs {
                await closeSession(sessionID)
            }
        }
    }
}

private final class ReviewHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }

    private weak var app: ReviewHTTPApplication?
    private let endpoint: String
    private var requestState: RequestState?

    init(app: ReviewHTTPApplication?, endpoint: String) {
        self.app = app
        self.endpoint = endpoint
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestState = RequestState(head: head, bodyBuffer: context.channel.allocator.buffer(capacity: 0))
        case .body(var buffer):
            requestState?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let state = requestState else {
                return
            }
            requestState = nil
            nonisolated(unsafe) let ctx = context
            Task { [weak self] in
                await self?.handleRequest(state: state, context: ctx)
            }
        }
    }

    private func handleRequest(state: RequestState, context: ChannelHandlerContext) async {
        guard let app else {
            await writeResponse(
                .error(statusCode: 500, .internalError("HTTP application deallocated.")),
                version: state.head.version,
                context: context
            )
            return
        }
        let path = state.head.uri.split(separator: "?").first.map(String.init) ?? state.head.uri
        let request = makeHTTPRequest(from: state)
        if path != endpoint {
            await writeResponse(
                .error(statusCode: 404, .invalidRequest("Not Found")),
                version: state.head.version,
                context: context
            )
            return
        }
        let response = await app.handleHTTPRequest(request)
        await writeResponse(response, version: state.head.version, context: context)
    }

    private func makeHTTPRequest(from state: RequestState) -> HTTPRequest {
        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        let body: Data?
        if state.bodyBuffer.readableBytes > 0,
           let bytes = state.bodyBuffer.getBytes(at: 0, length: state.bodyBuffer.readableBytes)
        {
            body = Data(bytes)
        } else {
            body = nil
        }
        let path = String(state.head.uri.split(separator: "?").first ?? Substring(state.head.uri))
        return HTTPRequest(
            method: state.head.method.rawValue,
            headers: headers,
            body: body,
            path: path
        )
    }

    private func writeResponse(
        _ response: HTTPResponse,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let ctx = context
        let eventLoop = ctx.eventLoop
        switch response {
        case .stream(let stream, let headers):
            eventLoop.execute {
                var head = HTTPResponseHead(version: version, status: .init(statusCode: response.statusCode))
                for (name, value) in headers {
                    head.headers.add(name: name, value: value)
                }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                ctx.flush()
            }
            do {
                for try await chunk in stream {
                    eventLoop.execute {
                        var buffer = ctx.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }
                }
            } catch {
                eventLoop.execute {
                    ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                }
                return
            }
            eventLoop.execute {
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }

        default:
            let headers = response.headers
            let bodyData = response.bodyData
            eventLoop.execute {
                var head = HTTPResponseHead(version: version, status: .init(statusCode: response.statusCode))
                for (name, value) in headers {
                    head.headers.add(name: name, value: value)
                }
                if let bodyData {
                    head.headers.replaceOrAdd(name: "Content-Length", value: "\(bodyData.count)")
                } else {
                    head.headers.replaceOrAdd(name: "Content-Length", value: "0")
                }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                if let bodyData {
                    var buffer = ctx.channel.allocator.buffer(capacity: bodyData.count)
                    buffer.writeBytes(bodyData)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}
