import Foundation
import Logging
import MCP
import ReviewDomain

public actor ReviewStdioAdapter {
    private enum MessageKind: Sendable {
        case initialize
        case initialized
        case cancelNotification
        case requestOrNotification
    }

    private enum SessionState: Sendable {
        case idle
        case bootstrapping(String?)
        case ready(String)
        case recovering
        case stopping

        var readySessionID: String? {
            guard case .ready(let sessionID) = self else {
                return nil
            }
            return sessionID
        }

        var sessionIDForShutdown: String? {
            switch self {
            case .bootstrapping(let sessionID):
                sessionID
            case .ready(let sessionID):
                sessionID
            case .idle, .recovering, .stopping:
                nil
            }
        }
    }

    private struct RequestEnvelope: Sendable {
        let ids: [JSONRPCRequestID]
        let method: String?
        let kind: MessageKind
        let requestID: JSONRPCRequestID?
        let cancelledRequestID: JSONRPCRequestID?

        var expectsResponse: Bool {
            ids.isEmpty == false
        }
    }

    private struct PendingMessage: Sendable {
        let id: UUID
        let generation: Int
        let data: Data
        let envelope: RequestEnvelope
    }

    private struct InFlightRequestTask {
        let generation: Int
        let requestID: JSONRPCRequestID?
        let task: Task<Void, Never>
    }

    private struct HandshakeCache: Sendable {
        var initializeRequest: Data?
        var initializedNotification: Data?

        var isComplete: Bool {
            initializeRequest != nil && initializedNotification != nil
        }
    }

    public struct Configuration: Sendable {
        public var upstreamURL: URL
        public var requestTimeout: TimeInterval

        public init(upstreamURL: URL, requestTimeout: TimeInterval = 0) {
            self.upstreamURL = upstreamURL
            self.requestTimeout = requestTimeout
        }
    }

    private let configuration: Configuration
    private let inputHandle: FileHandle
    private let outputWriter: any ReviewStdioOutputSink
    private let logger = Logger(label: "codex-review-mcp.stdio")
    private let transport: any ReviewStdioUpstreamTransport

    private var framer = SimpleStdioFramer()
    private var readTask: Task<Void, Never>?
    private var requestPumpTask: Task<Void, Never>?
    private var controlPumpTask: Task<Void, Never>?
    private var sseTask: Task<Void, Never>?
    private var sseTaskToken: UUID?
    private var recoveryTask: Task<String, Error>?
    private var recoveryToken: UUID?
    private var recoveringSessionID: String?
    private var inFlightRequestTasks: [UUID: InFlightRequestTask] = [:]
    private var requestQueue: [PendingMessage] = []
    private var controlQueue: [PendingMessage] = []
    private var cancelledRequestIDsByGeneration: [Int: Set<JSONRPCRequestID>] = [:]
    private var handshakeCache = HandshakeCache()
    private var lastSSEEventID: String?
    private var sessionState: SessionState = .idle
    private var currentGeneration = 0
    private var started = false
    private var stopped = false

    public init(
        configuration: Configuration,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) {
        self.configuration = configuration
        self.inputHandle = input
        self.outputWriter = StdioWriter(handle: output)
        self.transport = URLSessionReviewStdioTransport()
    }

    package init(
        configuration: Configuration,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        transport: any ReviewStdioUpstreamTransport
    ) {
        self.configuration = configuration
        self.inputHandle = input
        self.outputWriter = StdioWriter(handle: output)
        self.transport = transport
    }

    package init(
        configuration: Configuration,
        input: FileHandle = .standardInput,
        outputSink: any ReviewStdioOutputSink,
        transport: any ReviewStdioUpstreamTransport
    ) {
        self.configuration = configuration
        self.inputHandle = input
        self.outputWriter = outputSink
        self.transport = transport
    }

    public func start() async {
        guard started == false else {
            return
        }
        started = true
        readTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    public func wait() async {
        _ = await readTask?.value
    }

    public func stop() async {
        await stop(cancelReadTask: true)
    }

    private func readLoop() async {
        do {
            for try await byte in inputHandle.bytes {
                if Task.isCancelled {
                    break
                }
                let messages = handleInput(Data([byte]))
                for message in messages {
                    enqueueFramedMessage(message)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            logger.error("STDIO read failed", metadata: ["error": "\(error)"])
        }

        await stop(cancelReadTask: false)
    }

    private func handleInput(_ data: Data) -> [Data] {
        guard stopped == false else {
            return []
        }
        return framer.append(data)
    }

    private func enqueueFramedMessage(_ data: Data) {
        guard stopped == false else {
            return
        }
        let envelope = inspectRequest(data)
        if envelope.kind == .initialize {
            currentGeneration += 1
            handshakeCache.initializedNotification = nil
        }
        let message = PendingMessage(id: UUID(), generation: currentGeneration, data: data, envelope: envelope)
        switch envelope.kind {
        case .initialize:
            handshakeCache.initializeRequest = data
            requestQueue.append(message)
            ensureRequestPump()
        case .initialized:
            handshakeCache.initializedNotification = data
            requestQueue.append(message)
            ensureRequestPump()
        case .cancelNotification:
            recordCancellation(message)
            controlQueue.append(message)
            ensureControlPumpIfNeeded()
        case .requestOrNotification:
            requestQueue.append(message)
            ensureRequestPump()
        }
    }

    package func receiveChunkForTesting(_ data: Data) {
        let messages = handleInput(data)
        for message in messages {
            enqueueFramedMessage(message)
        }
    }

    private func ensureRequestPump() {
        guard requestPumpTask == nil, requestQueue.isEmpty == false, stopped == false else {
            return
        }
        requestPumpTask = Task { [weak self] in
            await self?.runRequestPump()
        }
    }

    private func runRequestPump() async {
        while stopped == false {
            guard let index = nextDispatchableRequestIndex() else {
                break
            }
            let message = requestQueue.remove(at: index)
            if shouldSuppress(message) {
                respond(to: message.envelope, with: nil, fallbackError: "Request cancelled.")
                clearCancellation(for: message)
                continue
            }
            if message.envelope.kind == .requestOrNotification {
                spawnConcurrentRequest(message)
                continue
            }
            await handleQueuedRequest(message)
        }

        requestPumpTask = nil
        if shouldRearmRequestPump() {
            ensureRequestPump()
        }
    }

    private func spawnConcurrentRequest(_ message: PendingMessage) {
        guard inFlightRequestTasks[message.id] == nil else {
            return
        }
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            await self.runConcurrentRequest(message)
        }
        inFlightRequestTasks[message.id] = InFlightRequestTask(
            generation: message.generation,
            requestID: message.envelope.requestID,
            task: task
        )
    }

    private func runConcurrentRequest(_ message: PendingMessage) async {
        await handleRequestOrNotification(message)
        inFlightRequestTasks.removeValue(forKey: message.id)
    }

    private func ensureControlPumpIfNeeded() {
        guard controlPumpTask == nil, controlQueue.isEmpty == false, stopped == false else {
            return
        }
        guard case .ready = sessionState else {
            return
        }
        controlPumpTask = Task { [weak self] in
            await self?.runControlPump()
        }
    }

    private func runControlPump() async {
        while stopped == false {
            guard case .ready = sessionState, controlQueue.isEmpty == false else {
                break
            }
            let message = controlQueue.removeFirst()
            await handleControlMessage(message)
        }

        controlPumpTask = nil
        if shouldRearmControlPump() {
            ensureControlPumpIfNeeded()
        }
    }

    private func handleQueuedRequest(_ message: PendingMessage) async {
        switch message.envelope.kind {
        case .initialize:
            await handleInitialize(message)
        case .initialized:
            await handleInitialized(message)
        case .cancelNotification:
            await handleControlMessage(message)
        case .requestOrNotification:
            await handleRequestOrNotification(message)
        }
    }

    private func handleInitialize(_ message: PendingMessage) async {
        do {
            recoveryTask?.cancel()
            recoveryTask = nil
            recoveryToken = nil
            recoveringSessionID = nil
            for entry in inFlightRequestTasks.values where entry.generation < message.generation {
                entry.task.cancel()
            }
            inFlightRequestTasks = inFlightRequestTasks.filter { _, entry in
                entry.generation >= message.generation
            }
            requestQueue.removeAll { $0.generation < message.generation }
            controlQueue.removeAll { $0.generation < message.generation }
            await invalidateActiveSession(sendDelete: true)
            sessionState = .bootstrapping(nil)

            let response = try await transport.sendPOST(
                url: configuration.upstreamURL,
                data: message.data,
                sessionID: nil,
                timeout: configuration.requestTimeout
            )

            guard message.generation == currentGeneration else {
                if let sessionID = response.sessionID?.nilIfEmpty {
                    await transport.deleteSession(url: configuration.upstreamURL, sessionID: sessionID)
                }
                return
            }

            guard (200 ... 299).contains(response.statusCode) else {
                if let sessionID = response.sessionID?.nilIfEmpty {
                    await transport.deleteSession(url: configuration.upstreamURL, sessionID: sessionID)
                }
                await discardFailedHandshake(generation: message.generation)
                respond(to: message.envelope, with: response.body, fallbackError: "upstream initialize failed")
                return
            }

            guard let sessionID = response.sessionID?.nilIfEmpty else {
                await discardFailedHandshake(generation: message.generation)
                throw ReviewError.io("Upstream initialize did not return a session ID.")
            }
            guard let responseBody = response.body else {
                await transport.deleteSession(url: configuration.upstreamURL, sessionID: sessionID)
                await discardFailedHandshake(generation: message.generation)
                emitError(for: message.envelope, message: "upstream returned empty initialize response")
                return
            }

            guard applyBootstrappingSession(sessionID, for: message) else {
                await transport.deleteSession(url: configuration.upstreamURL, sessionID: sessionID)
                return
            }

            respondIfCurrent(message, body: responseBody, fallbackError: "upstream returned empty initialize response")
        } catch {
            await discardFailedHandshake(generation: message.generation)
            logger.error("STDIO initialize failed", metadata: ["error": "\(error)"])
            emitError(for: message.envelope, message: error.localizedDescription)
        }
    }

    private func handleInitialized(_ message: PendingMessage) async {
        do {
            let sessionID = try await sessionIDForInitializedMessage()
            let response = try await sendPOSTWithRecovery(
                message,
                sessionID: sessionID,
                allowRecovery: true
            )
            guard (200 ... 299).contains(response.statusCode) else {
                await transport.deleteSession(
                    url: configuration.upstreamURL,
                    sessionID: sessionIDForResponse(response, fallback: sessionID)
                )
                await discardFailedHandshake(generation: message.generation, sendDelete: false)
                respond(to: message.envelope, with: response.body, fallbackError: "upstream initialized notification failed")
                return
            }
            let readySessionID = sessionIDForResponse(response, fallback: sessionID)
            guard applyReadySession(readySessionID, for: message) else {
                await transport.deleteSession(url: configuration.upstreamURL, sessionID: readySessionID)
                return
            }
            ensureRequestPump()
        } catch {
            if message.generation == currentGeneration {
                await discardFailedHandshake(generation: message.generation)
            }
            logger.error("STDIO initialized notification failed", metadata: ["error": "\(error)"])
            emitError(for: message.envelope, message: error.localizedDescription)
        }
    }

    private func handleRequestOrNotification(_ message: PendingMessage) async {
        do {
            let sessionID = try await ensureReadySession()
            let response = try await sendPOSTWithRecovery(
                message,
                sessionID: sessionID,
                allowRecovery: true
            )
            guard message.generation == currentGeneration else {
                clearCancellation(for: message)
                return
            }
            if shouldSuppress(message) {
                clearCancellation(for: message)
                return
            }
            guard (200 ... 299).contains(response.statusCode) else {
                let errorMessage = response.body.flatMap { String(data: $0, encoding: .utf8)?.nilIfEmpty }
                    ?? "Upstream HTTP \(response.statusCode)"
                emitError(for: message.envelope, message: errorMessage)
                clearCancellation(for: message)
                return
            }
            respondIfCurrent(message, body: response.body, fallbackError: "upstream returned empty response")
            clearCancellation(for: message)
        } catch is CancellationError {
            clearCancellation(for: message)
            return
        } catch {
            guard message.generation == currentGeneration else {
                clearCancellation(for: message)
                return
            }
            if shouldSuppress(message) {
                clearCancellation(for: message)
                return
            }
            logger.error("STDIO upstream request failed", metadata: ["error": "\(error)"])
            emitError(for: message.envelope, message: error.localizedDescription)
            clearCancellation(for: message)
        }
    }

    private func handleControlMessage(_ message: PendingMessage) async {
        do {
            let sessionID = try await ensureReadySession()
            _ = try await sendPOSTWithRecovery(
                message,
                sessionID: sessionID,
                allowRecovery: true
            )
        } catch {
            logger.warning("STDIO cancel forwarding failed", metadata: ["error": "\(error)"])
        }
    }

    private func sendPOSTWithRecovery(
        _ message: PendingMessage,
        sessionID: String,
        allowRecovery: Bool
    ) async throws -> ReviewStdioHTTPResponse {
        let response = try await transport.sendPOST(
            url: configuration.upstreamURL,
            data: message.data,
            sessionID: sessionID,
            timeout: configuration.requestTimeout
        )
        if response.statusCode == 404, allowRecovery {
            if shouldSuppress(message) {
                throw CancellationError()
            }
            let recoveredSessionID = try await recoverSession()
            if message.envelope.kind == .initialized {
                return ReviewStdioHTTPResponse(statusCode: 202, sessionID: recoveredSessionID, body: nil)
            }
            if shouldSuppress(message) {
                throw CancellationError()
            }
            return try await sendPOSTWithRecovery(
                message,
                sessionID: recoveredSessionID,
                allowRecovery: false
            )
        }
        return response
    }

    private func ensureReadySession() async throws -> String {
        if let sessionID = sessionState.readySessionID {
            return sessionID
        }
        return try await recoverSession()
    }

    private func sessionIDForInitializedMessage() async throws -> String {
        switch sessionState {
        case .bootstrapping(let sessionID):
            if let sessionID {
                return sessionID
            }
            throw ReviewError.io("Upstream initialize has not completed yet.")
        case .ready(let sessionID):
            return sessionID
        case .idle, .recovering, .stopping:
            return try await recoverSession()
        }
    }

    private func recoverSession(cancelSSETask: Bool = true) async throws -> String {
        if let recoveryTask {
            return try await recoveryTask.value
        }
        guard let initializeRequest = handshakeCache.initializeRequest,
              let initializedNotification = handshakeCache.initializedNotification
        else {
            throw ReviewError.io("Cannot recover upstream MCP session before downstream initialize/initialized.")
        }

        await invalidateActiveSession(sendDelete: false, cancelSSETask: cancelSSETask)
        sessionState = .recovering
        recoveringSessionID = nil

        let transport = self.transport
        let url = configuration.upstreamURL
        let timeout = configuration.requestTimeout
        let token = UUID()
        recoveryToken = token
        let task = Task<String, Error> {
            let initializeResponse = try await transport.sendPOST(
                url: url,
                data: initializeRequest,
                sessionID: nil,
                timeout: timeout
            )
            guard (200 ... 299).contains(initializeResponse.statusCode),
                  let sessionID = initializeResponse.sessionID?.nilIfEmpty
            else {
                throw ReviewError.io("Failed to recreate upstream MCP session.")
            }
            let claimed = self.claimRecoveringSession(sessionID, token: token)
            guard claimed else {
                await transport.deleteSession(url: url, sessionID: sessionID)
                throw CancellationError()
            }
            do {
                try Task.checkCancellation()
            } catch {
                self.releaseRecoveringSession(token: token)
                await transport.deleteSession(url: url, sessionID: sessionID)
                throw error
            }

            let initializedResponse: ReviewStdioHTTPResponse
            do {
                initializedResponse = try await transport.sendPOST(
                    url: url,
                    data: initializedNotification,
                    sessionID: sessionID,
                    timeout: timeout
                )
            } catch {
                await transport.deleteSession(url: url, sessionID: sessionID)
                throw error
            }
            guard (200 ... 299).contains(initializedResponse.statusCode) else {
                await transport.deleteSession(url: url, sessionID: sessionID)
                throw ReviewError.io("Failed to replay downstream initialized notification.")
            }
            return sessionID
        }

        recoveryTask = task
        do {
            let sessionID = try await task.value
            guard recoveryToken == token else {
                await transport.deleteSession(url: configuration.upstreamURL, sessionID: sessionID)
                if let sessionID = sessionState.readySessionID {
                    return sessionID
                }
                throw CancellationError()
            }
            recoveryTask = nil
            recoveryToken = nil
            recoveringSessionID = nil
            enterReady(sessionID: sessionID)
            return sessionID
        } catch {
            if recoveryToken == token {
                recoveryTask = nil
                recoveryToken = nil
                recoveringSessionID = nil
                if case .recovering = sessionState {
                    sessionState = .idle
                }
            }
            throw error
        }
    }

    private func runSSELoop(sessionID: String) {
        guard sseTask == nil, stopped == false else {
            return
        }
        let token = UUID()
        sseTaskToken = token
        sseTask = Task { [weak self] in
            await self?.sseLoop(sessionID: sessionID, token: token)
        }
    }

    private func sseLoop(sessionID initialSessionID: String, token: UUID) async {
        defer {
            if sseTaskToken == token {
                sseTask = nil
                sseTaskToken = nil
            }
        }
        var currentSessionID = initialSessionID
        var attempt = 0

        while stopped == false {
            do {
                let stream = try await transport.openSSE(
                    url: configuration.upstreamURL,
                    sessionID: currentSessionID,
                    lastEventID: lastSSEEventID
                )
                for try await event in stream {
                    if let eventID = event.id {
                        lastSSEEventID = eventID
                    }
                    outputWriter.send(event.payload)
                }
                attempt = 0
            } catch is CancellationError {
                return
            } catch let error as ReviewStdioUpstreamTransportError {
                switch error {
                case .httpStatus(404):
                    do {
                        currentSessionID = try await recoverSession(cancelSSETask: false)
                        attempt = 0
                        continue
                    } catch {
                        logger.warning("SSE recovery failed", metadata: ["error": "\(error)"])
                        return
                    }
                case .httpStatus, .invalidResponse:
                    logger.warning("SSE disconnected", metadata: ["error": "\(error)"])
                }
            } catch {
                logger.warning("SSE disconnected", metadata: ["error": "\(error)"])
            }

            guard stopped == false, sessionState.readySessionID == currentSessionID else {
                return
            }
            let delay = min(5.0, 0.5 * Double(1 << min(attempt, 4)))
            attempt += 1
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func enterReady(sessionID: String) {
        lastSSEEventID = nil
        recoveringSessionID = nil
        sessionState = .ready(sessionID)
        runSSELoop(sessionID: sessionID)
        ensureRequestPump()
        ensureControlPumpIfNeeded()
    }

    private func invalidateActiveSession(sendDelete: Bool, cancelSSETask: Bool = true) async {
        if cancelSSETask {
            sseTask?.cancel()
            sseTask = nil
            sseTaskToken = nil
        }
        lastSSEEventID = nil
        let sessionIDs = shutdownSessionIDs()
        if sendDelete {
            for sessionID in sessionIDs {
                await transport.deleteSession(url: configuration.upstreamURL, sessionID: sessionID)
            }
        }
        recoveringSessionID = nil
        if stopped == false {
            sessionState = .idle
        }
    }

    private func discardFailedHandshake(generation: Int, sendDelete: Bool = true) async {
        requestQueue.removeAll { $0.generation == generation }
        controlQueue.removeAll { $0.generation == generation }
        let inFlightIDs = inFlightRequestTasks.compactMap { id, entry in
            entry.generation == generation ? id : nil
        }
        for id in inFlightIDs {
            inFlightRequestTasks[id]?.task.cancel()
            inFlightRequestTasks.removeValue(forKey: id)
        }
        cancelledRequestIDsByGeneration.removeValue(forKey: generation)
        guard currentGeneration == generation else {
            return
        }
        handshakeCache.initializeRequest = nil
        handshakeCache.initializedNotification = nil
        await invalidateActiveSession(sendDelete: sendDelete)
    }

    private func stop(cancelReadTask: Bool) async {
        guard stopped == false else {
            return
        }
        let sessionIDs = shutdownSessionIDs()
        stopped = true
        sessionState = .stopping
        if cancelReadTask {
            readTask?.cancel()
        }
        requestPumpTask?.cancel()
        controlPumpTask?.cancel()
        recoveryTask?.cancel()
        sseTask?.cancel()
        for entry in inFlightRequestTasks.values {
            entry.task.cancel()
        }
        for sessionID in sessionIDs {
            await transport.deleteSession(url: configuration.upstreamURL, sessionID: sessionID)
        }
        readTask = nil
        requestPumpTask = nil
        controlPumpTask = nil
        recoveryTask = nil
        recoveryToken = nil
        recoveringSessionID = nil
        sseTask = nil
        sseTaskToken = nil
        inFlightRequestTasks.removeAll(keepingCapacity: false)
        requestQueue.removeAll(keepingCapacity: false)
        controlQueue.removeAll(keepingCapacity: false)
        cancelledRequestIDsByGeneration.removeAll(keepingCapacity: false)
        await transport.invalidate()
    }

    private func respond(to envelope: RequestEnvelope, with body: Data?, fallbackError: String) {
        if let body, envelope.expectsResponse {
            outputWriter.send(body)
        } else if envelope.expectsResponse {
            emitError(for: envelope, message: fallbackError)
        }
    }

    private func respondIfCurrent(_ message: PendingMessage, body: Data?, fallbackError: String) {
        guard isCurrent(message) else {
            return
        }
        guard shouldSuppress(message) == false else {
            return
        }
        respond(to: message.envelope, with: body, fallbackError: fallbackError)
    }

    private func sessionIDForResponse(_ response: ReviewStdioHTTPResponse, fallback: String) -> String {
        response.sessionID?.nilIfEmpty ?? fallback
    }

    private func inspectRequest(_ data: Data) -> RequestEnvelope {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return RequestEnvelope(ids: [], method: nil, kind: .requestOrNotification, requestID: nil, cancelledRequestID: nil)
        }
        if let object = json as? [String: Any] {
            let method = object["method"] as? String
            let kind: MessageKind
            switch method {
            case "initialize":
                kind = .initialize
            case "notifications/initialized":
                kind = .initialized
            case "notifications/cancelled":
                kind = .cancelNotification
            default:
                kind = .requestOrNotification
            }
            if let id = object["id"], !(id is NSNull) {
                let requestID = JSONRPCRequestID(jsonObject: id)
                return RequestEnvelope(
                    ids: requestID.map { [$0] } ?? [],
                    method: method,
                    kind: kind,
                    requestID: requestID,
                    cancelledRequestID: cancelledRequestID(from: object)
                )
            }
            return RequestEnvelope(
                ids: [],
                method: method,
                kind: kind,
                requestID: nil,
                cancelledRequestID: cancelledRequestID(from: object)
            )
        }
        if let array = json as? [[String: Any]] {
            let ids = array.compactMap { item -> JSONRPCRequestID? in
                guard let id = item["id"], !(id is NSNull) else {
                    return nil
                }
                return JSONRPCRequestID(jsonObject: id)
            }
            return RequestEnvelope(ids: ids, method: nil, kind: .requestOrNotification, requestID: nil, cancelledRequestID: nil)
        }
        return RequestEnvelope(ids: [], method: nil, kind: .requestOrNotification, requestID: nil, cancelledRequestID: nil)
    }

    private func nextDispatchableRequestIndex() -> Int? {
        if let initializeIndex = requestQueue.lastIndex(where: { $0.envelope.kind == .initialize }) {
            return initializeIndex
        }

        switch sessionState {
        case .idle:
            return requestQueue.firstIndex(where: { $0.envelope.kind == .requestOrNotification })
        case .bootstrapping(let sessionID):
            guard sessionID != nil else {
                return nil
            }
            return requestQueue.firstIndex(where: { $0.envelope.kind == .initialized })
        case .ready:
            return requestQueue.firstIndex(where: { $0.envelope.kind == .requestOrNotification })
        case .recovering, .stopping:
            return nil
        }
    }

    private func recordCancellation(_ message: PendingMessage) {
        guard let cancelledRequestID = message.envelope.cancelledRequestID else {
            return
        }
        var removedMessages: [PendingMessage] = []
        requestQueue.removeAll { candidate in
            let shouldRemove = candidate.generation == message.generation
                && candidate.envelope.requestID == cancelledRequestID
            if shouldRemove {
                removedMessages.append(candidate)
            }
            return shouldRemove
        }
        let hasInFlightMatch = inFlightRequestTasks.values.contains { entry in
            entry.generation == message.generation && entry.requestID == cancelledRequestID
        }
        guard removedMessages.isEmpty == false || hasInFlightMatch else {
            return
        }
        cancelledRequestIDsByGeneration[message.generation, default: []].insert(cancelledRequestID)
        for removed in removedMessages where removed.envelope.expectsResponse {
            Task { [weak self] in
                await self?.emitError(for: removed.envelope, message: "Request cancelled.")
            }
        }
        if hasInFlightMatch == false {
            cancelledRequestIDsByGeneration[message.generation]?.remove(cancelledRequestID)
            if cancelledRequestIDsByGeneration[message.generation]?.isEmpty == true {
                cancelledRequestIDsByGeneration.removeValue(forKey: message.generation)
            }
        }
    }

    private func shouldSuppress(_ message: PendingMessage) -> Bool {
        guard let requestID = message.envelope.requestID else {
            return false
        }
        return cancelledRequestIDsByGeneration[message.generation]?.contains(requestID) == true
    }

    private func clearCancellation(for message: PendingMessage) {
        guard let requestID = message.envelope.requestID else {
            return
        }
        cancelledRequestIDsByGeneration[message.generation]?.remove(requestID)
        if cancelledRequestIDsByGeneration[message.generation]?.isEmpty == true {
            cancelledRequestIDsByGeneration.removeValue(forKey: message.generation)
        }
    }

    private func cancelledRequestID(from object: [String: Any]) -> JSONRPCRequestID? {
        guard object["method"] as? String == "notifications/cancelled",
              let params = object["params"] as? [String: Any],
              let requestID = params["requestId"]
        else {
            return nil
        }
        return JSONRPCRequestID(jsonObject: requestID)
    }

    private func emitError(for envelope: RequestEnvelope, message: String) {
        guard envelope.expectsResponse else {
            return
        }
        let error: [String: Any] = [
            "code": -32000,
            "message": message,
        ]
        let responses = envelope.ids.map { id in
            [
                "jsonrpc": "2.0",
                "id": id.foundationObject,
                "error": error,
            ]
        }
        if let payload = try? JSONSerialization.data(withJSONObject: responses.count == 1 ? responses[0] : responses) {
            outputWriter.send(payload)
        }
    }

    private func isCurrent(_ message: PendingMessage) -> Bool {
        stopped == false && message.generation == currentGeneration
    }

    private func applyBootstrappingSession(_ sessionID: String, for message: PendingMessage) -> Bool {
        guard isCurrent(message) else {
            return false
        }
        sessionState = .bootstrapping(sessionID)
        ensureRequestPump()
        return true
    }

    private func applyReadySession(_ sessionID: String, for message: PendingMessage) -> Bool {
        guard isCurrent(message) else {
            return false
        }
        enterReady(sessionID: sessionID)
        return true
    }

    private func claimRecoveringSession(_ sessionID: String, token: UUID) -> Bool {
        guard recoveryToken == token, stopped == false else {
            return false
        }
        recoveringSessionID = sessionID
        return true
    }

    private func releaseRecoveringSession(token: UUID) {
        guard recoveryToken == token else {
            return
        }
        recoveringSessionID = nil
    }

    private func shutdownSessionIDs() -> [String] {
        Array(Set([sessionState.sessionIDForShutdown, recoveringSessionID].compactMap { $0 }))
    }

    private func shouldRearmRequestPump() -> Bool {
        stopped == false && nextDispatchableRequestIndex() != nil
    }

    private func shouldRearmControlPump() -> Bool {
        guard stopped == false, controlQueue.isEmpty == false else {
            return false
        }
        guard case .ready = sessionState else {
            return false
        }
        return true
    }
}
