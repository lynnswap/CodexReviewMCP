import Foundation
import Logging
import MCP
import ReviewDomain
import ReviewPlatform
import ReviewPorts

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
        store: any ReviewStoreProtocol
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
            serverFactory: { [weak store] sessionID, _ in
                await Self.makeServer(
                    tool: ReviewSessionToolAdapter(
                        sessionID: sessionID,
                        store: store
                    )
                )
            },
            onSessionClosed: { [weak store] sessionID in
                guard let store else {
                    return
                }
                await store.closeSession(sessionID, reason: "MCP session closed.")
            },
            isSessionBusy: { [weak store] sessionID in
                guard let store else {
                    return false
                }
                return await store.hasActiveJobs(for: sessionID)
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

@MainActor
private final class ReviewSessionToolAdapter: ReviewToolProtocol, @unchecked Sendable {
    private let sessionID: String
    private weak var store: (any ReviewStoreProtocol)?

    init(
        sessionID: String,
        store: (any ReviewStoreProtocol)?
    ) {
        self.sessionID = sessionID
        self.store = store
    }

    func startReview(_ request: ReviewStartRequest) async throws -> ReviewReadResult {
        try await requireStore().startReview(
            sessionID: sessionID,
            request: request
        )
    }

    func readReview(jobID: String) async throws -> ReviewReadResult {
        try await requireStore().readReview(
            jobID: jobID
        )
    }

    func listReviews(
        cwd: String?,
        statuses: [ReviewJobState]?,
        limit: Int?
    ) async -> ReviewListResult {
        guard let store else {
            return .init(items: [])
        }
        return await store.listReviews(
            cwd: cwd,
            statuses: statuses,
            limit: limit
        )
    }

    func cancelReview(
        jobID: String,
        cancellation: ReviewCancellation
    ) async throws -> ReviewCancelOutcome {
        try await requireStore().cancelReview(
            selectedJobID: jobID,
            cancellation: cancellation
        )
    }

    func cancelReview(
        selector: ReviewJobSelector,
        cancellation: ReviewCancellation
    ) async throws -> ReviewCancelOutcome {
        try await requireStore().cancelReview(
            selector: selector,
            cancellation: cancellation
        )
    }

    private func requireStore() throws -> any ReviewStoreProtocol {
        guard let store else {
            throw ReviewError.io("Review store is unavailable.")
        }
        return store
    }
}

private extension ReviewMCPHTTPServer {
    static func makeServer(
        tool: any ReviewToolProtocol
    ) async -> Server {
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
                tool: tool
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
