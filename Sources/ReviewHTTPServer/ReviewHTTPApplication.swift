import Foundation
import Logging
import MCP

@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

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
    private var deferredSessionClosures: Set<String> = []

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
        restartCleanupLoop()
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
            await closeSession(sessionID, force: true)
        }
        deferredSessionClosures.removeAll()
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
                if updatedSession.activeRequestCount == 0 {
                    await flushDeferredSessionClosures()
                }
            }
            if shouldCloseSessionAfterDelete(method: request.method, statusCode: response.statusCode) {
                await closeSession(sessionID)
                await flushDeferredSessionClosures()
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
                deferredSessionClosures.remove(sessionID)
                await transport.disconnect()
                await onSessionClosed(sessionID)
            }
            return response
        } catch {
            await transport.disconnect()
            logger.error("Failed to start MCP session", metadata: ["error": "\(error)"])
            return .error(statusCode: 500, .internalError("Failed to start MCP server: \(error.localizedDescription)"))
        }
    }

    func closeSession(_ sessionID: String, force: Bool = false) async {
        if force == false, await isSessionBusy(sessionID) {
            deferredSessionClosures.insert(sessionID)
            if var session = sessions[sessionID] {
                session.lastAccessedAt = Date()
                sessions[sessionID] = session
            }
            logger.info("Deferring MCP session closure while review is running", metadata: ["sessionID": "\(sessionID)"])
            restartCleanupLoop()
            return
        }
        if force == false, let currentSession = sessions[sessionID], currentSession.activeRequestCount > 0 {
            deferredSessionClosures.insert(sessionID)
            var session = currentSession
            session.lastAccessedAt = Date()
            sessions[sessionID] = session
            logger.info("Deferring MCP session closure while requests are still in flight", metadata: ["sessionID": "\(sessionID)"])
            restartCleanupLoop()
            return
        }
        deferredSessionClosures.remove(sessionID)
        guard let session = sessions.removeValue(forKey: sessionID) else {
            return
        }
        await session.transport.disconnect()
        await onSessionClosed(sessionID)
    }

    func hasSession(_ sessionID: String) -> Bool {
        sessions[sessionID] != nil
    }

    func flushDeferredSessionClosures() async {
        for sessionID in Array(deferredSessionClosures) {
            guard let session = sessions[sessionID] else {
                deferredSessionClosures.remove(sessionID)
                continue
            }
            if session.activeRequestCount > 0 {
                continue
            }
            if await isSessionBusy(sessionID) {
                continue
            }
            guard let refreshedSession = sessions[sessionID], refreshedSession.activeRequestCount == 0 else {
                continue
            }
            logger.info("Finishing deferred MCP session closure", metadata: ["sessionID": "\(sessionID)"])
            await closeSession(sessionID, force: true)
        }
    }

    private func sessionCleanupLoop() async {
        while channel != nil {
            let sleepSeconds = deferredSessionClosures.isEmpty
                ? min(60.0, max(1.0, configuration.sessionTimeoutSeconds / 2))
                : 1.0
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
                await closeSession(sessionID, force: true)
            }
            await flushDeferredSessionClosures()
        }
    }

    private func restartCleanupLoop() {
        cleanupTask?.cancel()
        cleanupTask = Task { await self.sessionCleanupLoop() }
    }
}
