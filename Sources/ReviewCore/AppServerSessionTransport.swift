import Foundation
import ReviewJobs

package struct AsyncStreamSubscription<Element: Sendable>: Sendable {
    package var stream: AsyncStream<Element>
    package var cancel: @Sendable () async -> Void

    package init(
        stream: AsyncStream<Element>,
        cancel: @escaping @Sendable () async -> Void
    ) {
        self.stream = stream
        self.cancel = cancel
    }
}

package struct AsyncThrowingStreamSubscription<Element: Sendable>: Sendable {
    package var stream: AsyncThrowingStream<Element, Error>
    package var cancel: @Sendable () async -> Void

    package init(
        stream: AsyncThrowingStream<Element, Error>,
        cancel: @escaping @Sendable () async -> Void
    ) {
        self.stream = stream
        self.cancel = cancel
    }
}

package protocol AppServerSessionTransport: Sendable {
    func initializeResponse() async -> AppServerInitializeResponse
    func request<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params: Params,
        responseType: Response.Type
    ) async throws -> Response
    func notify<Params: Encodable & Sendable>(method: String, params: Params) async throws
    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification>
    func isClosed() async -> Bool
    func close() async
}

package actor AppServerSharedTransportConnection {
    package typealias SendMessage = @Sendable (String) async throws -> Void
    package typealias CloseInput = @Sendable () async -> Void

    private let sendMessage: SendMessage
    private let closeInput: CloseInput
    private var initializePayload: AppServerInitializeResponse
    private var framer = AppServerJSONLFramer()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let requestTimeout: Duration = .seconds(30)
    private var nextRequestID = 1
    private var pendingResponses: [AppServerRequestID: CheckedContinuation<Data, Error>] = [:]
    private var pendingRequestMethods: [AppServerRequestID: String] = [:]
    private var notificationSubscribers: [UUID: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation] = [:]
    private var closed = false
    private var disconnected: Error?

    package static func connect(
        sendMessage: @escaping SendMessage,
        closeInput: @escaping CloseInput = {},
        clientName: String,
        clientTitle: String,
        clientVersion: String
    ) async throws -> AppServerSharedTransportConnection {
        let connection = AppServerSharedTransportConnection(
            sendMessage: sendMessage,
            closeInput: closeInput,
            initializePayload: .init(
                userAgent: nil,
                codexHome: nil,
                platformFamily: nil,
                platformOs: nil
            )
        )
        do {
            _ = try await connection.initialize(
                clientName: clientName,
                clientTitle: clientTitle,
                clientVersion: clientVersion
            )
            return connection
        } catch {
            await connection.shutdown()
            throw error
        }
    }

    package init(
        sendMessage: @escaping SendMessage,
        closeInput: @escaping CloseInput,
        initializePayload: AppServerInitializeResponse = .init(
            userAgent: nil,
            codexHome: nil,
            platformFamily: nil,
            platformOs: nil
        )
    ) {
        self.sendMessage = sendMessage
        self.closeInput = closeInput
        self.initializePayload = initializePayload
    }

    package func initializeResponse() -> AppServerInitializeResponse {
        initializePayload
    }

    package func initialize(
        clientName: String,
        clientTitle: String,
        clientVersion: String
    ) async throws -> AppServerInitializeResponse {
        let initializeResponse: AppServerInitializeResponse = try await request(
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
        storeInitializeResponse(initializeResponse)
        try await notify(method: "initialized", params: AppServerInitializedParams())
        return initializeResponse
    }

    package func checkoutTransport() -> any AppServerSessionTransport {
        AppServerStdioTransportLease(connection: self)
    }

    package func isClosed() -> Bool {
        closed
    }

    package func shutdown() async {
        guard closed == false else {
            return
        }
        closed = true
        failPendingResponses(with: ReviewError.io("app-server stdio connection closed."))
        finishNotificationSubscribers(failing: nil)
        await closeInput()
    }

    package func receive(_ data: Data) async {
        guard closed == false else {
            return
        }
        let messages = framer.append(data)
        for message in messages {
            await processIncomingMessageData(message)
        }
    }

    package func finishReceiving(error: Error?) async {
        let messages = framer.finish()
        for message in messages {
            await processIncomingMessageData(message)
        }

        guard closed == false else {
            return
        }

        let disconnectError: Error = if let error {
            ReviewError.io("app-server stdio disconnected: \(error.localizedDescription)")
        } else {
            ReviewError.io("app-server stdio connection closed.")
        }
        handleTransportFailure(disconnectError)
    }

    package func request<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params: Params,
        responseType: Response.Type
    ) async throws -> Response {
        _ = responseType
        try throwIfClosed()

        let id = AppServerRequestID.integer(nextRequestID)
        nextRequestID += 1
        let payload = try encoder.encode(
            AppServerRequestEnvelope(
                id: id,
                method: method,
                params: params
            )
        )

        let timeoutError = ReviewError.io("app-server stdio request `\(method)` timed out.")
        let timeoutTask = Task { [requestTimeout] in
            do {
                try await Task.sleep(for: requestTimeout)
            } catch {
                return
            }
            self.failPendingResponseIfPresent(id: id, error: timeoutError)
        }
        defer { timeoutTask.cancel() }

        let responseData = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                pendingResponses[id] = continuation
                pendingRequestMethods[id] = method
                Task {
                    do {
                        try await self.sendPayload(payload)
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
        try throwIfClosed()
        let payload = try encoder.encode(
            AppServerOutgoingNotificationEnvelope(
                method: method,
                params: params
            )
        )
        try await sendPayload(payload)
    }

    package func notificationStream() -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        let disconnected = self.disconnected
        let closed = self.closed
        var continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation!
        let stream = AsyncThrowingStream<AppServerServerNotification, Error>(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        if let disconnected {
            continuation.finish(throwing: disconnected)
            return .init(stream: stream, cancel: {})
        }
        if closed {
            continuation.finish()
            return .init(stream: stream, cancel: {})
        }

        let subscriberID = UUID()
        notificationSubscribers[subscriberID] = continuation
        continuation.onTermination = { _ in
            Task {
                await self.removeNotificationSubscriber(id: subscriberID)
            }
        }
        return .init(
            stream: stream,
            cancel: { [self] in
                await self.cancelNotificationSubscriber(id: subscriberID)
            }
        )
    }

    private func storeInitializeResponse(_ response: AppServerInitializeResponse) {
        initializePayload = response
    }

    private func throwIfClosed() throws {
        if let disconnected {
            throw disconnected
        }
        if closed {
            throw ReviewError.io("app-server stdio connection is closed.")
        }
    }

    private func sendPayload(_ data: Data) async throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ReviewError.io("failed to encode stdio payload as UTF-8 text.")
        }
        do {
            try await sendMessage(text + "\n")
        } catch {
            let disconnectError = ReviewError.io("app-server stdio disconnected: \(error.localizedDescription)")
            handleTransportFailure(disconnectError)
            throw disconnectError
        }
    }

    private func processIncomingMessageData(_ data: Data) async {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let idObject = object["id"], let requestID = AppServerRequestID(jsonObject: idObject) {
            if let method = object["method"] as? String {
                await rejectServerRequest(id: requestID, method: method)
                return
            }
            guard let continuation = pendingResponses.removeValue(forKey: requestID) else {
                return
            }
            let requestMethod = pendingRequestMethods.removeValue(forKey: requestID)
            if let error = parseResponseError(from: object) {
                _ = requestMethod
                continuation.resume(throwing: error)
            } else {
                _ = requestMethod
                continuation.resume(returning: data)
            }
            return
        }

        guard let method = object["method"] as? String else {
            return
        }
        let notification = decodeNotification(method: method, data: data)
        if case .ignored = notification {
        } else {
            broadcastNotification(notification)
        }
    }

    private func rejectServerRequest(id: AppServerRequestID, method: String) async {
        let payload = [
            "jsonrpc": "2.0",
            "id": id.foundationObject,
            "error": [
                "code": -32601,
                "message": "Unsupported app-server request `\(method)`."
            ]
        ] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        do {
            try await sendPayload(data)
        } catch {
        }
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

    private func handleTransportFailure(_ error: Error) {
        guard closed == false else {
            return
        }
        closed = true
        disconnected = error
        failPendingResponses(with: error)
        finishNotificationSubscribers(failing: error)
    }

    private func failPendingResponses(with error: Error) {
        for (_, continuation) in pendingResponses {
            continuation.resume(throwing: error)
        }
        pendingResponses.removeAll()
        pendingRequestMethods.removeAll()
    }

    private func failPendingResponse(id: AppServerRequestID, error: Error) {
        let requestMethod = pendingRequestMethods.removeValue(forKey: id)
        _ = requestMethod
        guard let continuation = pendingResponses.removeValue(forKey: id) else {
            return
        }
        continuation.resume(throwing: error)
    }

    private func failPendingResponseIfPresent(id: AppServerRequestID, error: Error) {
        failPendingResponse(id: id, error: error)
    }

    private func broadcastNotification(_ notification: AppServerServerNotification) {
        for continuation in notificationSubscribers.values {
            continuation.yield(notification)
        }
    }

    private func finishNotificationSubscribers(failing error: Error?) {
        let continuations = notificationSubscribers.values
        notificationSubscribers.removeAll()
        for continuation in continuations {
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }

    private func removeNotificationSubscriber(id: UUID) {
        notificationSubscribers[id] = nil
    }

    private func cancelNotificationSubscriber(id: UUID) {
        guard let continuation = notificationSubscribers.removeValue(forKey: id) else {
            return
        }
        continuation.finish()
    }
}

package actor AppServerStdioTransportLease: AppServerSessionTransport {
    private let connection: AppServerSharedTransportConnection
    private var closed = false
    private var notificationCancels: [UUID: @Sendable () async -> Void] = [:]

    package init(connection: AppServerSharedTransportConnection) {
        self.connection = connection
    }

    package func initializeResponse() async -> AppServerInitializeResponse {
        await connection.initializeResponse()
    }

    package func request<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params: Params,
        responseType: Response.Type
    ) async throws -> Response {
        try throwIfLeaseClosed()
        return try await connection.request(
            method: method,
            params: params,
            responseType: responseType
        )
    }

    package func notify<Params: Encodable & Sendable>(method: String, params: Params) async throws {
        try throwIfLeaseClosed()
        try await connection.notify(method: method, params: params)
    }

    package func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        if closed {
            return .init(
                stream: .init { continuation in
                    continuation.finish()
                },
                cancel: {}
            )
        }

        let token = UUID()
        let baseSubscription = await connection.notificationStream()
        notificationCancels[token] = baseSubscription.cancel
        return .init(
            stream: baseSubscription.stream,
            cancel: { [self] in
                await self.cancelNotificationSubscription(id: token)
            }
        )
    }

    package func isClosed() async -> Bool {
        if closed {
            return true
        }
        return await connection.isClosed()
    }

    package func close() async {
        guard closed == false else {
            return
        }
        closed = true
        let cancels = Array(notificationCancels.values)
        notificationCancels.removeAll()
        for cancel in cancels {
            await cancel()
        }
    }

    private func throwIfLeaseClosed() throws {
        if closed {
            throw ReviewError.io("app-server transport lease is closed.")
        }
    }

    private func cancelNotificationSubscription(id: UUID) async {
        guard let cancel = notificationCancels.removeValue(forKey: id) else {
            return
        }
        await cancel()
    }
}

private struct AppServerRequestEnvelope<Params: Encodable>: Encodable {
    var jsonrpc = "2.0"
    var id: AppServerRequestID
    var method: String
    var params: Params

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
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
        case jsonrpc
        case id
        case method
        case params
    }
}

private struct AppServerOutgoingNotificationEnvelope<Params: Encodable>: Encodable {
    var jsonrpc = "2.0"
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
    case "account/login/completed":
        if let notification = try? decoder.decode(
            AppServerIncomingNotificationEnvelope<AppServerAccountLoginCompletedNotification>.self,
            from: data
        ) {
            return .accountLoginCompleted(notification.params)
        }
    case "account/updated":
        if let notification = try? decoder.decode(
            AppServerIncomingNotificationEnvelope<AppServerAccountUpdatedNotification>.self,
            from: data
        ) {
            return .accountUpdated(notification.params)
        }
    case "account/rateLimits/updated":
        if let notification = try? decoder.decode(
            AppServerIncomingNotificationEnvelope<AppServerAccountRateLimitsUpdatedPayload>.self,
            from: data
        ) {
            return .accountRateLimitsUpdated(notification.params)
        }
    default:
        break
    }
    return .ignored
}

private struct AppServerIncomingNotificationEnvelope<Params: Decodable>: Decodable {
    var method: String
    var params: Params
}
