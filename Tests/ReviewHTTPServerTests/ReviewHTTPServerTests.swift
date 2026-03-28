import Foundation
import MCP
import Testing
@testable import ReviewCore
@testable import ReviewHTTPServer

@Suite(.serialized) struct ReviewHTTPServerTests {
    @Test func reviewServerConfigurationNormalizesEndpointPath() {
        let configuration = ReviewServerConfiguration(endpoint: "mcp")

        #expect(configuration.endpoint == "/mcp")
    }

    @Test func normalizedDiscoveryHostMapsWildcardBindsToLocalhost() {
        #expect(normalizedDiscoveryHost(configuredHost: "0.0.0.0", boundHost: "0.0.0.0") == "localhost")
        #expect(normalizedDiscoveryHost(configuredHost: "::", boundHost: "::") == "localhost")
        #expect(normalizedDiscoveryHost(configuredHost: "localhost", boundHost: "127.0.0.1") == "localhost")
    }

    @Test func deleteSuccessStatusIncludesNoContent() {
        #expect(shouldCloseSessionAfterDelete(method: "DELETE", statusCode: 200))
        #expect(shouldCloseSessionAfterDelete(method: "DELETE", statusCode: 204))
        #expect(shouldCloseSessionAfterDelete(method: "DELETE", statusCode: 404))
        #expect(shouldCloseSessionAfterDelete(method: "DELETE", statusCode: 500) == false)
        #expect(shouldCloseSessionAfterDelete(method: "POST", statusCode: 204) == false)
    }

    @Test func reviewStartReturnsDetachedHandle() async throws {
        let transport = HTTPTestAppServerTransport { message, transport in
            let method = try #require(message.objectValue?["method"]?.stringValue)
            let requestID = message.objectValue?["id"]?.intValue
            switch method {
            case "initialize":
                await transport.respond(id: try #require(requestID), result: ["serverInfo": ["name": "codex"]])
            case "initialized":
                break
            case "thread/start":
                await transport.respond(id: try #require(requestID), result: ["thread": ["id": "parent-1", "turns": []]])
            case "review/start":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "turn": [
                            "id": "turn-1",
                            "items": [],
                            "status": "inProgress",
                            "error": nil,
                        ],
                        "reviewThreadId": .string("review-1"),
                    ]
                )
            default:
                throw TestFailure("unexpected method \(method)")
            }
        }
        let server = ReviewMCPHTTPServer(
            configuration: .init(port: 0),
            appServerTransportFactory: { transport }
        )

        let sessionID = try await initialize(server: server)
        let response = try await callTool(
            server: server,
            sessionID: sessionID,
            requestID: 10,
            name: "review_start",
            arguments: [
                "cwd": FileManager.default.temporaryDirectory.path,
                "target": ["type": "uncommittedChanges"],
            ]
        )

        let result = try #require(response["result"] as? [String: Any])
        let structuredContent = try #require(result["structuredContent"] as? [String: Any])
        #expect(structuredContent["parentThreadId"] as? String == "parent-1")
        #expect(structuredContent["reviewThreadId"] as? String == "review-1")
        #expect(structuredContent["turnId"] as? String == "turn-1")
        await server.stop()
    }

    @Test func reviewReadIsIsolatedBySessionID() async throws {
        let transport = HTTPTestAppServerTransport { message, transport in
            let method = try #require(message.objectValue?["method"]?.stringValue)
            let requestID = message.objectValue?["id"]?.intValue
            switch method {
            case "initialize":
                await transport.respond(id: try #require(requestID), result: ["serverInfo": ["name": "codex"]])
            case "initialized":
                break
            case "thread/start":
                await transport.respond(id: try #require(requestID), result: ["thread": ["id": "parent-1", "turns": []]])
            case "review/start":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "turn": [
                            "id": "turn-1",
                            "items": [],
                            "status": "inProgress",
                            "error": nil,
                        ],
                        "reviewThreadId": .string("review-1"),
                    ]
                )
            default:
                throw TestFailure("unexpected method \(method)")
            }
        }
        let server = ReviewMCPHTTPServer(
            configuration: .init(port: 0),
            appServerTransportFactory: { transport }
        )

        let session1 = try await initialize(server: server)
        let session2 = try await initialize(server: server)
        _ = try await callTool(
            server: server,
            sessionID: session1,
            requestID: 20,
            name: "review_start",
            arguments: [
                "cwd": FileManager.default.temporaryDirectory.path,
                "target": ["type": "uncommittedChanges"],
            ]
        )

        let readResponse = try await callTool(
            server: server,
            sessionID: session2,
            requestID: 21,
            name: "review_read",
            arguments: ["reviewThreadId": "review-1"]
        )
        let result = try #require(readResponse["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        await server.stop()
    }

    @Test func reviewCancelInterruptsActiveReview() async throws {
        let transport = HTTPTestAppServerTransport { message, transport in
            let method = try #require(message.objectValue?["method"]?.stringValue)
            let requestID = message.objectValue?["id"]?.intValue
            switch method {
            case "initialize":
                await transport.respond(id: try #require(requestID), result: ["serverInfo": ["name": "codex"]])
            case "initialized":
                break
            case "thread/start":
                await transport.respond(id: try #require(requestID), result: ["thread": ["id": "parent-1", "turns": []]])
            case "review/start":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "turn": [
                            "id": "turn-1",
                            "items": [],
                            "status": "inProgress",
                            "error": nil,
                        ],
                        "reviewThreadId": .string("review-1"),
                    ]
                )
            case "turn/interrupt":
                await transport.respond(id: try #require(requestID), result: [:])
            default:
                throw TestFailure("unexpected method \(method)")
            }
        }
        let server = ReviewMCPHTTPServer(
            configuration: .init(port: 0),
            appServerTransportFactory: { transport }
        )

        let sessionID = try await initialize(server: server)
        _ = try await callTool(
            server: server,
            sessionID: sessionID,
            requestID: 30,
            name: "review_start",
            arguments: [
                "cwd": FileManager.default.temporaryDirectory.path,
                "target": ["type": "uncommittedChanges"],
            ]
        )

        let cancelResponse = try await callTool(
            server: server,
            sessionID: sessionID,
            requestID: 31,
            name: "review_cancel",
            arguments: ["reviewThreadId": "review-1"]
        )
        let result = try #require(cancelResponse["result"] as? [String: Any])
        let structuredContent = try #require(result["structuredContent"] as? [String: Any])
        #expect(structuredContent["cancelled"] as? Bool == true)
        #expect(await transport.sentMethods().suffix(1) == ["turn/interrupt"])

        let readResponse = try await callTool(
            server: server,
            sessionID: sessionID,
            requestID: 32,
            name: "review_read",
            arguments: ["reviewThreadId": "review-1"]
        )
        let readResult = try #require(readResponse["result"] as? [String: Any])
        let readStructuredContent = try #require(readResult["structuredContent"] as? [String: Any])
        #expect(readStructuredContent["status"] as? String == "cancelled")
        await server.stop()
    }

    @Test func deletingSessionCancelsOnlyOwnedReviews() async throws {
        let transport = HTTPTestAppServerTransport { message, transport in
            let method = try #require(message.objectValue?["method"]?.stringValue)
            let requestID = message.objectValue?["id"]?.intValue
            switch method {
            case "initialize":
                await transport.respond(id: try #require(requestID), result: ["serverInfo": ["name": "codex"]])
            case "initialized":
                break
            case "thread/start":
                let parentID = await transport.sentMethods().filter { $0 == "thread/start" }.count == 1 ? "parent-1" : "parent-2"
                await transport.respond(id: try #require(requestID), result: ["thread": ["id": .string(parentID), "turns": []]])
            case "review/start":
                let reviewIndex = await transport.sentMethods().filter { $0 == "review/start" }.count
                let reviewThreadID = reviewIndex == 1 ? "review-1" : "review-2"
                let turnID = reviewIndex == 1 ? "turn-1" : "turn-2"
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "turn": .object([
                            "id": .string(turnID),
                            "items": .array([]),
                            "status": .string("inProgress"),
                            "error": .null,
                        ]),
                        "reviewThreadId": .string(reviewThreadID),
                    ]
                )
            case "turn/interrupt":
                await transport.respond(id: try #require(requestID), result: [:])
            default:
                throw TestFailure("unexpected method \(method)")
            }
        }
        let server = ReviewMCPHTTPServer(
            configuration: .init(port: 0),
            appServerTransportFactory: { transport }
        )

        let session1 = try await initialize(server: server)
        let session2 = try await initialize(server: server)
        _ = try await callTool(
            server: server,
            sessionID: session1,
            requestID: 40,
            name: "review_start",
            arguments: [
                "cwd": FileManager.default.temporaryDirectory.path,
                "target": ["type": "uncommittedChanges"],
            ]
        )
        _ = try await callTool(
            server: server,
            sessionID: session2,
            requestID: 41,
            name: "review_start",
            arguments: [
                "cwd": FileManager.default.temporaryDirectory.path + "/other",
                "target": ["type": "uncommittedChanges"],
            ]
        )

        let deleteResponse = await server.handleHTTPRequest(
            HTTPRequest(
                method: "DELETE",
                headers: [
                    HTTPHeaderName.sessionID: session1,
                    HTTPHeaderName.protocolVersion: Version.latest,
                    HTTPHeaderName.host: "localhost:9417",
                ],
                path: "/mcp"
            )
        )
        #expect(deleteResponse.statusCode == 200)

        try await waitUntil {
            await transport.sentMethods().contains("turn/interrupt")
        }
        let interruptRequest = try #require(await transport.sentMessages().first(where: {
            $0.objectValue?["method"]?.stringValue == "turn/interrupt"
        })?.objectValue)
        let params = try #require(interruptRequest["params"]?.objectValue)
        #expect(params["threadId"]?.stringValue == "review-1")
        #expect(params["turnId"]?.stringValue == "turn-1")
        await server.stop()
    }
}

private actor HTTPTestAppServerTransport: CodexAppServerTransport {
    typealias Handler = @Sendable (Value, HTTPTestAppServerTransport) async throws -> Void

    private let handler: Handler
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var sent: [Value] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() async throws -> AsyncThrowingStream<String, Error> {
        var continuation: AsyncThrowingStream<String, Error>.Continuation!
        let stream = AsyncThrowingStream<String, Error> { continuation = $0 }
        self.continuation = continuation
        return stream
    }

    func send(_ line: String) async throws {
        let value = try JSONDecoder().decode(Value.self, from: Data(line.utf8))
        sent.append(value)
        try await handler(value, self)
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }

    func respond(id: Int, result: Value) {
        continuation?.yield(jsonLine([
            "id": .int(id),
            "result": result,
        ]))
    }

    func sentMethods() -> [String] {
        sent.compactMap { $0.objectValue?["method"]?.stringValue }
    }

    func sentMessages() -> [Value] {
        sent
    }
}

private func initialize(server: ReviewMCPHTTPServer) async throws -> String {
    let initializeData = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-11-25",
            "capabilities": [:],
            "clientInfo": ["name": "test", "version": "0.0.1"],
        ],
    ])
    let response = await server.handleHTTPRequest(
        HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeaderName.accept: "application/json, text/event-stream",
                HTTPHeaderName.contentType: "application/json",
                HTTPHeaderName.protocolVersion: Version.latest,
                HTTPHeaderName.host: "localhost:9417",
            ],
            body: initializeData,
            path: "/mcp"
        )
    )
    let sessionID = try #require(response.headers[HTTPHeaderName.sessionID])
    let payload = try await firstStreamPayload(response)
    let object = try #require((try JSONSerialization.jsonObject(with: payload)) as? [String: Any])
    #expect((object["id"] as? Int) == 1)

    let initializedData = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0",
        "method": "notifications/initialized",
        "params": [:],
    ])
    let initializedResponse = await server.handleHTTPRequest(
        HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeaderName.sessionID: sessionID,
                HTTPHeaderName.accept: "application/json, text/event-stream",
                HTTPHeaderName.contentType: "application/json",
                HTTPHeaderName.protocolVersion: Version.latest,
                HTTPHeaderName.host: "localhost:9417",
            ],
            body: initializedData,
            path: "/mcp"
        )
    )
    #expect(initializedResponse.statusCode == 202)
    return sessionID
}

private func callTool(
    server: ReviewMCPHTTPServer,
    sessionID: String,
    requestID: Int,
    name: String,
    arguments: [String: Any]
) async throws -> [String: Any] {
    let body = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0",
        "id": requestID,
        "method": "tools/call",
        "params": [
            "name": name,
            "arguments": arguments,
        ],
    ])
    let response = await server.handleHTTPRequest(
        HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeaderName.sessionID: sessionID,
                HTTPHeaderName.accept: "application/json, text/event-stream",
                HTTPHeaderName.contentType: "application/json",
                HTTPHeaderName.protocolVersion: Version.latest,
                HTTPHeaderName.host: "localhost:9417",
            ],
            body: body,
            path: "/mcp"
        )
    )
    let payload = try await firstStreamPayload(response)
    return try #require((try JSONSerialization.jsonObject(with: payload)) as? [String: Any])
}

private func firstStreamPayload(_ response: HTTPResponse) async throws -> Data {
    guard case .stream(let stream, _) = response else {
        throw TestFailure("expected stream response")
    }
    var decoder = LocalSSEDecoder()
    for try await chunk in stream {
        let text = String(decoding: chunk, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let payload = decoder.feed(line: String(line)), payload.isEmpty == false {
                return payload
            }
        }
    }
    if let payload = decoder.flushIfNeeded(), payload.isEmpty == false {
        return payload
    }
    throw TestFailure("missing stream payload")
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    interval: Duration = .milliseconds(20),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: interval)
    }
    throw TestFailure("timed out")
}

private func jsonLine(_ value: Value) -> String {
    let data = try! JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
}

private struct LocalSSEDecoder {
    private var dataLines: [String] = []

    mutating func feed(line: String) -> Data? {
        if line.isEmpty {
            return flushIfNeeded()
        }
        guard line.hasPrefix("data:") else {
            return nil
        }
        dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        return nil
    }

    mutating func flushIfNeeded() -> Data? {
        guard dataLines.isEmpty == false else {
            return nil
        }
        let payload = Data(dataLines.joined(separator: "\n").utf8)
        dataLines.removeAll(keepingCapacity: true)
        return payload
    }
}

private struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
