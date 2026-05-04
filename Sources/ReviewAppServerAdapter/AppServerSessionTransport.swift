import Foundation
import ReviewDomain
import ReviewPlatform

package protocol AppServerSessionTransport: Sendable {
    func initializeResponse() async -> AppServerInitializeResponse
    func request<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params: Params,
        responseType: Response.Type
    ) async throws -> Response
    func notify<Params: Encodable & Sendable>(method: String, params: Params) async throws
    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error>
    func isClosed() async -> Bool
    /// Closes this transport lease and aborts any in-flight work started through it.
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
    private var pendingResponses: [AppServerRequestID: PendingResponse] = [:]
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
            ownerID: UUID(),
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
        AppServerStdioTransportLease(
            connection: self,
            ownerID: UUID()
        )
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
        ownerID: UUID,
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
                pendingResponses[id] = .init(
                    ownerID: ownerID,
                    method: method,
                    continuation: continuation
                )
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

    package func closeLease(ownerID: UUID) {
        failPendingResponses(ownerID: ownerID, error: CancellationError())
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

    package func notificationStream() -> AsyncThrowingStream<AppServerServerNotification, Error> {
        let disconnected = self.disconnected
        let closed = self.closed
        var continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation!
        let stream = AsyncThrowingStream<AppServerServerNotification, Error>(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        if let disconnected {
            continuation.finish(throwing: disconnected)
            return stream
        }
        if closed {
            continuation.finish()
            return stream
        }

        let subscriberID = UUID()
        notificationSubscribers[subscriberID] = continuation
        continuation.onTermination = { _ in
            Task {
                await self.removeNotificationSubscriber(id: subscriberID)
            }
        }
        return stream
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
            guard let pendingResponse = pendingResponses.removeValue(forKey: requestID) else {
                return
            }
            if let error = parseResponseError(from: object) {
                pendingResponse.continuation.resume(throwing: error)
            } else {
                pendingResponse.continuation.resume(returning: data)
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
        for (_, pendingResponse) in pendingResponses {
            pendingResponse.continuation.resume(throwing: error)
        }
        pendingResponses.removeAll()
    }

    private func failPendingResponse(id: AppServerRequestID, error: Error) {
        guard let pendingResponse = pendingResponses.removeValue(forKey: id) else {
            return
        }
        pendingResponse.continuation.resume(throwing: error)
    }

    private func failPendingResponseIfPresent(id: AppServerRequestID, error: Error) {
        failPendingResponse(id: id, error: error)
    }

    private func failPendingResponses(ownerID: UUID, error: Error) {
        let requestIDs = pendingResponses.compactMap { requestID, pendingResponse in
            pendingResponse.ownerID == ownerID ? requestID : nil
        }
        for requestID in requestIDs {
            failPendingResponse(id: requestID, error: error)
        }
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
    private let ownerID: UUID
    private var closed = false
    private var notificationRelayTasks: [UUID: Task<Void, Never>] = [:]
    private var notificationContinuations: [UUID: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation] = [:]

    package init(
        connection: AppServerSharedTransportConnection,
        ownerID: UUID
    ) {
        self.connection = connection
        self.ownerID = ownerID
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
            ownerID: ownerID,
            method: method,
            params: params,
            responseType: responseType
        )
    }

    package func notify<Params: Encodable & Sendable>(method: String, params: Params) async throws {
        try throwIfLeaseClosed()
        try await connection.notify(method: method, params: params)
    }

    package func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        if closed {
            return .init { continuation in
                continuation.finish()
            }
        }

        let token = UUID()
        let baseStream = await connection.notificationStream()
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.installNotificationRelay(
                    id: token,
                    continuation: continuation,
                    baseStream: baseStream
                )
            }
        }
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
        await connection.closeLease(ownerID: ownerID)
        let relayTasks = Array(notificationRelayTasks.values)
        notificationRelayTasks.removeAll()
        let continuations = Array(notificationContinuations.values)
        notificationContinuations.removeAll()
        for relayTask in relayTasks {
            relayTask.cancel()
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func throwIfLeaseClosed() throws {
        if closed {
            throw ReviewError.io("app-server transport lease is closed.")
        }
    }

    private func installNotificationRelay(
        id: UUID,
        continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation,
        baseStream: AsyncThrowingStream<AppServerServerNotification, Error>
    ) {
        guard closed == false else {
            continuation.finish()
            return
        }
        notificationContinuations[id] = continuation
        let relayTask = Task { [weak self] in
            do {
                for try await notification in baseStream {
                    await self?.yieldNotification(notification, for: id)
                }
                await self?.finishNotificationRelay(id: id, error: nil)
            } catch {
                guard error is CancellationError == false else {
                    await self?.finishNotificationRelay(id: id, error: nil)
                    return
                }
                await self?.finishNotificationRelay(id: id, error: error)
            }
        }
        notificationRelayTasks[id] = relayTask
        continuation.onTermination = { _ in
            Task {
                await self.cancelNotificationRelay(id: id)
            }
        }
    }

    private func yieldNotification(
        _ notification: AppServerServerNotification,
        for id: UUID
    ) {
        notificationContinuations[id]?.yield(notification)
    }

    private func finishNotificationRelay(id: UUID, error: Error?) {
        notificationRelayTasks[id] = nil
        guard let continuation = notificationContinuations.removeValue(forKey: id) else {
            return
        }
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    private func cancelNotificationRelay(id: UUID) {
        notificationRelayTasks.removeValue(forKey: id)?.cancel()
        notificationContinuations.removeValue(forKey: id)?.finish()
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
    private struct PendingResponse {
        var ownerID: UUID
        var method: String
        var continuation: CheckedContinuation<Data, Error>
    }
