import Foundation
import Logging
import MCP
import ReviewDomain

package struct ReviewServerConfiguration: Sendable {
    package var host: String
    package var port: Int
    package var endpoint: String
    package var sessionTimeoutSeconds: TimeInterval
    package var codexCommand: String
    package var shouldAutoStartEmbeddedServer: Bool
    package var environment: [String: String]
    package var coreDependencies: ReviewCoreDependencies

    package init(
        host: String = "localhost",
        port: Int = codexReviewDefaultPort,
        endpoint: String = codexReviewDefaultEndpointPath,
        sessionTimeoutSeconds: TimeInterval = codexReviewDefaultSessionTimeoutSeconds,
        codexCommand: String = "codex",
        shouldAutoStartEmbeddedServer: Bool = true,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        coreDependencies: ReviewCoreDependencies? = nil
    ) {
        let resolvedCoreDependencies = coreDependencies ?? .live(environment: environment)
        self.host = host
        self.port = port
        self.endpoint = normalizeEndpointPath(endpoint)
        self.sessionTimeoutSeconds = sessionTimeoutSeconds
        self.codexCommand = codexCommand
        self.shouldAutoStartEmbeddedServer = shouldAutoStartEmbeddedServer
        self.environment = resolvedCoreDependencies.environment
        self.coreDependencies = resolvedCoreDependencies
    }
}

package final class ReviewMCPHTTPServer: @unchecked Sendable {
    package typealias StartReviewHandler = @MainActor @Sendable (_ sessionID: String, _ request: ReviewStartRequest) async throws -> ReviewReadResult
    package typealias ReadReviewHandler = @MainActor @Sendable (_ sessionID: String, _ jobID: String) async throws -> ReviewReadResult
    package typealias ListReviewsHandler = @MainActor @Sendable (_ sessionID: String, _ cwd: String?, _ statuses: [ReviewJobState]?, _ limit: Int?) async -> ReviewListResult
    package typealias CancelByIDHandler = @MainActor @Sendable (_ sessionID: String, _ jobID: String, _ cancellation: ReviewCancellation) async throws -> ReviewCancelOutcome
    package typealias CancelBySelectorHandler = @MainActor @Sendable (_ sessionID: String, _ cwd: String?, _ statuses: [ReviewJobState]?, _ cancellation: ReviewCancellation) async throws -> ReviewCancelOutcome
    package typealias CloseSessionHandler = @MainActor @Sendable (_ sessionID: String) async -> Void
    package typealias HasActiveJobsHandler = @MainActor @Sendable (_ sessionID: String) async -> Bool

    package let configuration: ReviewServerConfiguration
    private let logger = Logger(label: "codex-review-mcp.http")
    private let app: ReviewHTTPApplication
    private var endpointRecord: LiveEndpointRecord?
    private var startedURL: URL?
    private var discoveryClient: ReviewDiscoveryClient {
        ReviewDiscoveryClient(dependencies: configuration.coreDependencies)
    }

    package init(
        configuration: ReviewServerConfiguration = .init(),
        startReview: @escaping StartReviewHandler,
        readReview: @escaping ReadReviewHandler,
        listReviews: @escaping ListReviewsHandler,
        cancelReviewByID: @escaping CancelByIDHandler,
        cancelReviewBySelector: @escaping CancelBySelectorHandler,
        closeSession: @escaping CloseSessionHandler,
        hasActiveJobs: @escaping HasActiveJobsHandler
    ) {
        self.configuration = configuration
        self.app = ReviewHTTPApplication(
            configuration: .init(
                host: configuration.host,
                port: configuration.port,
                endpoint: configuration.endpoint,
                sessionTimeoutSeconds: configuration.sessionTimeoutSeconds,
                dateNow: configuration.coreDependencies.dateNow,
                uuid: configuration.coreDependencies.uuid
            ),
            serverFactory: { sessionID, transport in
                await Self.makeServer(
                    sessionID: sessionID,
                    transport: transport,
                    startReview: { request in
                        try await startReview(sessionID, request)
                    },
                    readReview: { jobID in
                        try await readReview(sessionID, jobID)
                    },
                    listReviews: { cwd, statuses, limit in
                        await listReviews(sessionID, cwd, statuses, limit)
                    },
                    cancelReviewByID: { jobID, cancellation in
                        try await cancelReviewByID(sessionID, jobID, cancellation)
                    },
                    cancelReviewBySelector: { cwd, statuses, cancellation in
                        try await cancelReviewBySelector(sessionID, cwd, statuses, cancellation)
                    }
                )
            },
            onSessionClosed: { sessionID in
                await closeSession(sessionID)
            },
            isSessionBusy: { sessionID in
                await hasActiveJobs(sessionID)
            }
        )
    }

    package func start() async throws -> URL {
        let address = try await app.startListening()
        let discoveryHost = normalizedDiscoveryHost(
            configuredHost: configuration.host,
            boundHost: address.host
        )
        if let record = discoveryClient.makeRecord(
            host: discoveryHost,
            port: address.port,
            endpointPath: configuration.endpoint
        ) {
            try? discoveryClient.write(record)
            endpointRecord = record
        } else {
            endpointRecord = nil
        }
        guard let url = discoveryClient.makeURL(
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
        let record = endpointRecord
        let url = startedURL
        await app.stop()
        if let record {
            discoveryClient.removeIfOwned(
                pid: record.pid,
                url: url,
                serverStartTime: record.serverStartTime
            )
        } else if let url,
                  let persistedRecord = discoveryClient.read(),
                  persistedRecord.url == url.absoluteString
                    || persistedRecord.pid == configuration.coreDependencies.process.currentProcessIdentifier()
        {
            discoveryClient.remove()
        }
        endpointRecord = nil
        startedURL = nil
    }

    package func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        await app.handleHTTPRequest(request)
    }

    package func url() -> URL? {
        startedURL
    }

    package func currentEndpointRecord() -> LiveEndpointRecord? {
        endpointRecord
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
        startReview: @escaping @MainActor @Sendable (ReviewStartRequest) async throws -> ReviewReadResult,
        readReview: @escaping @MainActor @Sendable (String) async throws -> ReviewReadResult,
        listReviews: @escaping @MainActor @Sendable (String?, [ReviewJobState]?, Int?) async -> ReviewListResult,
        cancelReviewByID: @escaping @MainActor @Sendable (String, ReviewCancellation) async throws -> ReviewCancelOutcome,
        cancelReviewBySelector: @escaping @MainActor @Sendable (String?, [ReviewJobState]?, ReviewCancellation) async throws -> ReviewCancelOutcome
    ) async -> Server {
        let _ = transport
        let server = Server(
            name: codexReviewMCPName,
            version: codexReviewMCPVersion,
            instructions: ReviewHelpCatalog.serverInstructions,
            capabilities: .init(
                resources: .init(),
                tools: .init()
            )
        )

        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: ReviewHelpCatalog.staticResources)
        }

        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            .init(templates: ReviewHelpCatalog.resourceTemplates)
        }

        await server.withMethodHandler(ReadResource.self) { params in
            try ReviewHelpCatalog.readResource(uri: params.uri)
        }

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: ReviewToolCatalog.tools)
        }

        await server.withMethodHandler(CallTool.self) { (params: CallTool.Parameters) in
            await ReviewToolHandler(
                sessionID: sessionID,
                startReview: startReview,
                readReview: readReview,
                listReviews: listReviews,
                cancelReviewByID: cancelReviewByID,
                cancelReviewBySelector: cancelReviewBySelector
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
