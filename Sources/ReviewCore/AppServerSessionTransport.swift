import Foundation
import ReviewJobs

package protocol AppServerSessionTransport: Sendable {
    func initializeResponse() async -> AppServerInitializeResponse
    func request<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params: Params,
        responseType: Response.Type
    ) async throws -> Response
    func notify<Params: Encodable & Sendable>(method: String, params: Params) async throws
    func drainNotifications() async -> [AppServerServerNotification]
    func disconnectError() async -> Error?
    func diagnosticsTail() async -> String
    func isClosed() async -> Bool
    func close() async
}

package actor AppServerWebSocketSessionTransport: AppServerSessionTransport {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private var initializePayload: AppServerInitializeResponse
    private let diagnosticsProvider: @Sendable () async -> String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let requestTimeout: Duration = .seconds(30)
    private var nextRequestID = 1
    private var pendingResponses: [AppServerRequestID: CheckedContinuation<Data, Error>] = [:]
    private var notifications: [AppServerServerNotification] = []
    private var receiveTask: Task<Void, Never>?
    private var closed = false
    private var disconnected: Error?

    package static func connect(
        websocketURL: URL,
        authToken: String,
        clientName: String,
        clientTitle: String,
        clientVersion: String,
        diagnosticsProvider: @escaping @Sendable () async -> String
    ) async throws -> AppServerWebSocketSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: websocketURL)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.resume()

        let initializePayload = AppServerInitializeResponse(
            userAgent: nil,
            codexHome: nil,
            platformFamily: nil,
            platformOs: nil
        )
        let transport = AppServerWebSocketSessionTransport(
            session: session,
            task: task,
            initializePayload: initializePayload,
            diagnosticsProvider: diagnosticsProvider
        )
        do {
            await transport.startReceiving()
            let initializeResponse: AppServerInitializeResponse = try await transport.request(
                method: "initialize",
                params: AppServerInitializeParams(
                    clientInfo: .init(
                        name: clientName,
                        title: clientTitle,
                        version: clientVersion
                    ),
                    capabilities: .init(experimentalApi: true)
                ),
                responseType: AppServerInitializeResponse.self
            )
            await transport.storeInitializeResponse(initializeResponse)
            try await transport.notify(method: "initialized", params: AppServerInitializedParams())
            return transport
        } catch {
            await transport.close()
            throw error
        }
    }

    private init(
        session: URLSession,
        task: URLSessionWebSocketTask,
        initializePayload: AppServerInitializeResponse,
        diagnosticsProvider: @escaping @Sendable () async -> String
    ) {
        self.session = session
        self.task = task
        self.initializePayload = initializePayload
        self.diagnosticsProvider = diagnosticsProvider
    }

    package func initializeResponse() async -> AppServerInitializeResponse {
        initializePayload
    }

    package func request<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params: Params,
        responseType: Response.Type
    ) async throws -> Response {
        if let disconnected {
            throw disconnected
        }
        if closed {
            throw ReviewError.io("app-server websocket session is closed.")
        }

        let id = AppServerRequestID.integer(nextRequestID)
        nextRequestID += 1
        appServerTransportDebug("sending websocket request \(id): \(method)")
        let payload = try encoder.encode(
            AppServerRequestEnvelope(
                id: id,
                method: method,
                params: params
            )
        )

        let timeoutError = ReviewError.io("app-server websocket request `\(method)` timed out.")
        let requestTimeout = self.requestTimeout
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: requestTimeout)
            await self?.failPendingResponseIfPresent(id: id, error: timeoutError)
        }
        defer { timeoutTask.cancel() }

        let responseData = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                pendingResponses[id] = continuation
                Task {
                    do {
                        try await self.send(payload)
                    } catch {
                        self.failPendingResponseIfPresent(id: id, error: error)
                    }
                }
            }
        } onCancel: {
            Task {
                await self.failPendingResponseIfPresent(id: id, error: CancellationError())
            }
        }
        return try decoder.decode(AppServerResponseEnvelope<Response>.self, from: responseData).result
    }

    package func notify<Params: Encodable & Sendable>(method: String, params: Params) async throws {
        if let disconnected {
            throw disconnected
        }
        if closed {
            throw ReviewError.io("app-server websocket session is closed.")
        }
        appServerTransportDebug("sending websocket notification: \(method)")
        let payload = try encoder.encode(
            AppServerOutgoingNotificationEnvelope(
                method: method,
                params: params
            )
        )
        try await send(payload)
    }

    package func drainNotifications() async -> [AppServerServerNotification] {
        defer { notifications.removeAll(keepingCapacity: true) }
        return notifications
    }

    package func disconnectError() async -> Error? {
        disconnected
    }

    package func diagnosticsTail() async -> String {
        await diagnosticsProvider()
    }

    package func isClosed() async -> Bool {
        closed
    }

    package func close() async {
        guard closed == false else {
            return
        }
        closed = true
        receiveTask?.cancel()
        receiveTask = nil
        failPendingResponses(with: ReviewError.io("app-server websocket session closed."))
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func storeInitializeResponse(_ response: AppServerInitializeResponse) {
        initializePayload = response
    }

    private func startReceiving() {
        guard receiveTask == nil else {
            return
        }
        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
    }

    private func receiveLoop() async {
        while Task.isCancelled == false {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    await processIncomingText(text)
                case .data(let data):
                    await processIncomingText(String(decoding: data, as: UTF8.self))
                @unknown default:
                    continue
                }
            } catch {
                if closed {
                    return
                }
                disconnected = ReviewError.io("app-server websocket disconnected: \(error.localizedDescription)")
                failPendingResponses(with: disconnected!)
                return
            }
        }
    }

    private func processIncomingText(_ text: String) async {
        let data = Data(text.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            appServerTransportDebug("non-JSON websocket payload: \(String(text.prefix(400)))")
            return
        }

        if let idObject = object["id"], let requestID = AppServerRequestID(jsonObject: idObject) {
            if let method = object["method"] as? String {
                appServerTransportDebug("server request over websocket: \(method)")
                await rejectServerRequest(id: requestID, method: method)
                return
            }
            guard let continuation = pendingResponses.removeValue(forKey: requestID) else {
                appServerTransportDebug("response for unknown request id: \(requestID)")
                return
            }
            if let error = parseResponseError(from: object) {
                appServerTransportDebug("response error for request id \(requestID): \(error.message)")
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: data)
            }
            return
        }

        guard let method = object["method"] as? String else {
            appServerTransportDebug("websocket notification missing method: \(String(text.prefix(400)))")
            return
        }
        let notification = decodeNotification(method: method, data: data)
        if case .ignored = notification {
            appServerTransportDebug("ignored websocket notification \(method): \(String(text.prefix(400)))")
        } else {
            appServerTransportDebug("websocket notification \(method)")
        }
        notifications.append(notification)
    }

    private func send(_ data: Data) async throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ReviewError.io("failed to encode websocket payload as UTF-8 text.")
        }
        try await task.send(.string(text))
    }

    private func rejectServerRequest(id: AppServerRequestID, method: String) async {
        let payload = [
            "id": id.foundationObject,
            "error": [
                "code": -32601,
                "message": "Unsupported app-server request `\(method)`."
            ]
        ] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        try? await send(data)
    }

    private func parseResponseError(from object: [String: Any]) -> AppServerResponseError? {
        guard let error = object["error"] as? [String: Any] else {
            return nil
        }
        let code = (error["code"] as? Int)
            ?? (error["code"] as? NSNumber)?.intValue
        let message = (error["message"] as? String)?.nilIfEmpty ?? "app-server request failed."
        return AppServerResponseError(code: code, message: message)
    }

    private func failPendingResponses(with error: Error) {
        for (_, continuation) in pendingResponses {
            continuation.resume(throwing: error)
        }
        pendingResponses.removeAll()
    }

    private func failPendingResponse(id: AppServerRequestID, error: Error) {
        guard let continuation = pendingResponses.removeValue(forKey: id) else {
            return
        }
        continuation.resume(throwing: error)
    }

    private func failPendingResponseIfPresent(id: AppServerRequestID, error: Error) {
        failPendingResponse(id: id, error: error)
    }
}

private struct AppServerRequestEnvelope<Params: Encodable>: Encodable {
    var id: AppServerRequestID
    var method: String
    var params: Params

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch id {
        case .string(let value):
            try container.encode(value, forKey: .id)
        case .integer(let value):
            try container.encode(value, forKey: .id)
        case .double(let value):
            try container.encode(value, forKey: .id)
        }
        try container.encode(method, forKey: .method)
        try container.encode(params, forKey: .params)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case method
        case params
    }
}

private struct AppServerOutgoingNotificationEnvelope<Params: Encodable>: Encodable {
    var method: String
    var params: Params
}

private struct AppServerResponseEnvelope<Result: Decodable>: Decodable {
    var result: Result
}

private func decodeNotification(method: String, data: Data) -> AppServerServerNotification {
    let decoder = JSONDecoder()
    switch method {
    case "thread/status/changed":
        if let notification = try? decoder.decode(
            AppServerIncomingNotificationEnvelope<AppServerThreadStatusChangedNotification>.self,
            from: data
        ) {
            return .threadStatusChanged(notification.params)
        }
    case "thread/closed":
        if let notification = try? decoder.decode(
            AppServerIncomingNotificationEnvelope<AppServerThreadClosedNotification>.self,
            from: data
        ) {
            return .threadClosed(notification.params)
        }
    case "turn/started":
        if let notification = try? decoder.decode(
            AppServerIncomingNotificationEnvelope<AppServerTurnStartedNotification>.self,
            from: data
        ) {
            return .turnStarted(notification.params)
        }
    case "turn/completed":
        if let notification = try? decoder.decode(
            AppServerIncomingNotificationEnvelope<AppServerTurnCompletedNotification>.self,
            from: data
        ) {
            return .turnCompleted(notification.params)
        }
    case "item/started":
        if let notification = try? decoder.decode(
            AppServerIncomingNotificationEnvelope<AppServerItemStartedNotification>.self,
            from: data
        ) {
            return .itemStarted(notification.params)
        }
    case "item/completed":
        if let notification = try? decoder.decode(
            AppServerIncomingNotificationEnvelope<AppServerItemCompletedNotification>.self,
            from: data
        ) {
            return .itemCompleted(notification.params)
        }
    case "item/agentMessage/delta":
        if let notification = try? decoder.decode(
            AppServerIncomingNotificationEnvelope<AppServerAgentMessageDeltaNotification>.self,
            from: data
        ) {
            return .agentMessageDelta(notification.params)
        }
    case "item/plan/delta":
        if let notification = try? decoder.decode(
            AppServerIncomingNotificationEnvelope<AppServerPlanDeltaNotification>.self,
            from: data
        ) {
            return .planDelta(notification.params)
        }
    case "item/commandExecution/outputDelta":
        if let notification = try? decoder.decode(
            AppServerIncomingNotificationEnvelope<AppServerCommandExecutionOutputDeltaNotification>.self,
            from: data
        ) {
            return .commandExecutionOutputDelta(notification.params)
        }
    case "item/reasoning/summaryTextDelta":
        if let notification = try? decoder.decode(
            AppServerIncomingNotificationEnvelope<AppServerReasoningSummaryTextDeltaNotification>.self,
            from: data
        ) {
            return .reasoningSummaryTextDelta(notification.params)
        }
    case "item/reasoning/summaryPartAdded":
        if let notification = try? decoder.decode(
            AppServerIncomingNotificationEnvelope<AppServerReasoningSummaryPartAddedNotification>.self,
            from: data
        ) {
            return .reasoningSummaryPartAdded(notification.params)
        }
    case "item/reasoning/textDelta":
        if let notification = try? decoder.decode(
            AppServerIncomingNotificationEnvelope<AppServerReasoningTextDeltaNotification>.self,
            from: data
        ) {
            return .reasoningTextDelta(notification.params)
        }
    case "item/mcpToolCall/progress":
        if let notification = try? decoder.decode(
            AppServerIncomingNotificationEnvelope<AppServerMcpToolCallProgressNotification>.self,
            from: data
        ) {
            return .mcpToolCallProgress(notification.params)
        }
    case "error":
        if let notification = try? decoder.decode(
            AppServerIncomingNotificationEnvelope<AppServerErrorNotification>.self,
            from: data
        ) {
            return .error(notification.params)
        }
    default:
        break
    }
    return .ignored
}

private func appServerTransportDebug(_ message: String) {
    guard codexReviewMCPWebSocketDebugEnabled else {
        return
    }
    fputs("[codex-review-mcp.ws] \(message)\n", stderr)
}

private let codexReviewMCPWebSocketDebugEnabled: Bool = {
    let value = ProcessInfo.processInfo.environment["CODEX_REVIEW_MCP_DEBUG_WS"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    switch value {
    case "1", "true", "yes", "on":
        return true
    default:
        return false
    }
}()

private struct AppServerIncomingNotificationEnvelope<Params: Decodable>: Decodable {
    var method: String
    var params: Params
}
