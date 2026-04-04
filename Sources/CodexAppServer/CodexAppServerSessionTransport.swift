import Foundation
import CodexAppServerProtocol
import ReviewJobs

package protocol CodexAppServerSessionTransport: Sendable {
    func initializeResponse() async -> CodexAppServerInitializeResponse
    func request<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params: Params,
        responseType: Response.Type
    ) async throws -> Response
    func notify<Params: Encodable & Sendable>(method: String, params: Params) async throws
    func drainNotifications() async -> [CodexAppServerNotification]
    func disconnectError() async -> Error?
    func diagnosticsTail() async -> String
    func isClosed() async -> Bool
    func close() async
}

package actor CodexAppServerWebSocketSessionTransport: CodexAppServerSessionTransport {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private var initializePayload: CodexAppServerInitializeResponse
    private let diagnosticsProvider: @Sendable () async -> String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let requestTimeout: Duration = .seconds(30)
    private var nextRequestID = 1
    private var pendingResponses: [CodexAppServerRequestID: CheckedContinuation<Data, Error>] = [:]
    private var notifications: [CodexAppServerNotification] = []
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
    ) async throws -> CodexAppServerWebSocketSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: websocketURL)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.resume()

        let initializePayload = CodexAppServerInitializeResponse(
            userAgent: nil,
            codexHome: nil,
            platformFamily: nil,
            platformOs: nil
        )
        let transport = CodexAppServerWebSocketSessionTransport(
            session: session,
            task: task,
            initializePayload: initializePayload,
            diagnosticsProvider: diagnosticsProvider
        )
        do {
            await transport.startReceiving()
            let initializeResponse: CodexAppServerInitializeResponse = try await transport.request(
                method: "initialize",
                params: CodexAppServerInitializeParams(
                    clientInfo: .init(
                        name: clientName,
                        title: clientTitle,
                        version: clientVersion
                    ),
                    capabilities: .init(experimentalApi: true)
                ),
                responseType: CodexAppServerInitializeResponse.self
            )
            await transport.storeInitializeResponse(initializeResponse)
            try await transport.notify(method: "initialized", params: CodexAppServerInitializedParams())
            return transport
        } catch {
            await transport.close()
            throw error
        }
    }

    private init(
        session: URLSession,
        task: URLSessionWebSocketTask,
        initializePayload: CodexAppServerInitializeResponse,
        diagnosticsProvider: @escaping @Sendable () async -> String
    ) {
        self.session = session
        self.task = task
        self.initializePayload = initializePayload
        self.diagnosticsProvider = diagnosticsProvider
    }

    package func initializeResponse() async -> CodexAppServerInitializeResponse {
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

        let id = CodexAppServerRequestID.integer(nextRequestID)
        nextRequestID += 1
        appServerTransportDebug("sending websocket request \(id): \(method)")
        let payload = try encoder.encode(
            CodexAppServerRequestEnvelope(
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
        return try decoder.decode(CodexAppServerResponseEnvelope<Response>.self, from: responseData).result
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
            CodexAppServerOutgoingNotificationEnvelope(
                method: method,
                params: params
            )
        )
        try await send(payload)
    }

    package func drainNotifications() async -> [CodexAppServerNotification] {
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

    private func storeInitializeResponse(_ response: CodexAppServerInitializeResponse) {
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

        if let idObject = object["id"], let requestID = CodexAppServerRequestID(jsonObject: idObject) {
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

    private func rejectServerRequest(id: CodexAppServerRequestID, method: String) async {
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

    private func parseResponseError(from object: [String: Any]) -> CodexAppServerResponseError? {
        guard let error = object["error"] as? [String: Any] else {
            return nil
        }
        let code = (error["code"] as? Int)
            ?? (error["code"] as? NSNumber)?.intValue
        let message = (error["message"] as? String)?.nilIfEmpty ?? "app-server request failed."
        return CodexAppServerResponseError(code: code, message: message)
    }

    private func failPendingResponses(with error: Error) {
        for (_, continuation) in pendingResponses {
            continuation.resume(throwing: error)
        }
        pendingResponses.removeAll()
    }

    private func failPendingResponse(id: CodexAppServerRequestID, error: Error) {
        guard let continuation = pendingResponses.removeValue(forKey: id) else {
            return
        }
        continuation.resume(throwing: error)
    }

    private func failPendingResponseIfPresent(id: CodexAppServerRequestID, error: Error) {
        failPendingResponse(id: id, error: error)
    }
}

private struct CodexAppServerRequestEnvelope<Params: Encodable>: Encodable {
    var id: CodexAppServerRequestID
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

private struct CodexAppServerOutgoingNotificationEnvelope<Params: Encodable>: Encodable {
    var method: String
    var params: Params
}

private struct CodexAppServerResponseEnvelope<Result: Decodable>: Decodable {
    var result: Result
}

private func decodeNotification(method: String, data: Data) -> CodexAppServerNotification {
    let decoder = JSONDecoder()
    switch method {
    case "thread/status/changed":
        if let notification = try? decoder.decode(
            CodexAppServerIncomingNotificationEnvelope<CodexAppServerThreadStatusChangedNotification>.self,
            from: data
        ) {
            return .threadStatusChanged(notification.params)
        }
    case "thread/closed":
        if let notification = try? decoder.decode(
            CodexAppServerIncomingNotificationEnvelope<CodexAppServerThreadClosedNotification>.self,
            from: data
        ) {
            return .threadClosed(notification.params)
        }
    case "turn/started":
        if let notification = try? decoder.decode(
            CodexAppServerIncomingNotificationEnvelope<CodexAppServerTurnStartedNotification>.self,
            from: data
        ) {
            return .turnStarted(notification.params)
        }
    case "turn/completed":
        if let notification = try? decoder.decode(
            CodexAppServerIncomingNotificationEnvelope<CodexAppServerTurnCompletedNotification>.self,
            from: data
        ) {
            return .turnCompleted(notification.params)
        }
    case "item/started":
        if let notification = try? decoder.decode(
            CodexAppServerIncomingNotificationEnvelope<CodexAppServerItemStartedNotification>.self,
            from: data
        ) {
            return .itemStarted(notification.params)
        }
    case "item/completed":
        if let notification = try? decoder.decode(
            CodexAppServerIncomingNotificationEnvelope<CodexAppServerItemCompletedNotification>.self,
            from: data
        ) {
            return .itemCompleted(notification.params)
        }
    case "item/agentMessage/delta":
        if let notification = try? decoder.decode(
            CodexAppServerIncomingNotificationEnvelope<CodexAppServerAgentMessageDeltaNotification>.self,
            from: data
        ) {
            return .agentMessageDelta(notification.params)
        }
    case "item/plan/delta":
        if let notification = try? decoder.decode(
            CodexAppServerIncomingNotificationEnvelope<CodexAppServerPlanDeltaNotification>.self,
            from: data
        ) {
            return .planDelta(notification.params)
        }
    case "item/commandExecution/outputDelta":
        if let notification = try? decoder.decode(
            CodexAppServerIncomingNotificationEnvelope<CodexAppServerCommandExecutionOutputDeltaNotification>.self,
            from: data
        ) {
            return .commandExecutionOutputDelta(notification.params)
        }
    case "item/reasoning/summaryTextDelta":
        if let notification = try? decoder.decode(
            CodexAppServerIncomingNotificationEnvelope<CodexAppServerReasoningSummaryTextDeltaNotification>.self,
            from: data
        ) {
            return .reasoningSummaryTextDelta(notification.params)
        }
    case "item/reasoning/summaryPartAdded":
        if let notification = try? decoder.decode(
            CodexAppServerIncomingNotificationEnvelope<CodexAppServerReasoningSummaryPartAddedNotification>.self,
            from: data
        ) {
            return .reasoningSummaryPartAdded(notification.params)
        }
    case "item/reasoning/textDelta":
        if let notification = try? decoder.decode(
            CodexAppServerIncomingNotificationEnvelope<CodexAppServerReasoningTextDeltaNotification>.self,
            from: data
        ) {
            return .reasoningTextDelta(notification.params)
        }
    case "item/mcpToolCall/progress":
        if let notification = try? decoder.decode(
            CodexAppServerIncomingNotificationEnvelope<CodexAppServerMcpToolCallProgressNotification>.self,
            from: data
        ) {
            return .mcpToolCallProgress(notification.params)
        }
    case "error":
        if let notification = try? decoder.decode(
            CodexAppServerIncomingNotificationEnvelope<CodexAppServerErrorNotification>.self,
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

private struct CodexAppServerIncomingNotificationEnvelope<Params: Decodable>: Decodable {
    var method: String
    var params: Params
}
