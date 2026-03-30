import Darwin
import Foundation
import MCP
import Testing
@testable import ReviewCore
@testable import ReviewHTTPServer

@Suite(.serialized)
struct ReviewHTTPServerTests {
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

    @Test func reviewStartReturnsFinalReviewResult() async throws {
        let scriptURL = try makeFakeExecReviewScript(mode: .success)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let port = try nextAvailableTestPort(in: 39441 ... 39450)
        let server = ReviewMCPHTTPServer(
            configuration: .init(
                host: "127.0.0.1",
                port: port,
                codexCommand: scriptURL.path,
                environment: ["HOME": FileManager.default.homeDirectoryForCurrentUser.path]
            )
        )

        let endpointURL = try await server.start()
        let client = HTTPToolClient(endpointURL: endpointURL, timeoutInterval: 5)
        let response = try await client.callTool(
            name: "review_start",
            arguments: [
                "cwd": FileManager.default.temporaryDirectory.path,
                "target": ["type": "uncommittedChanges"],
            ]
        )

        let result = try #require(response["result"] as? [String: Any])
        let structuredContent = try #require(result["structuredContent"] as? [String: Any])
        let jobID = try #require(structuredContent["jobId"] as? String)
        #expect(structuredContent["reviewThreadId"] as? String == jobID)
        #expect(structuredContent["status"] as? String == "succeeded")
        #expect(((structuredContent["review"] as? String) ?? "").isEmpty == false)
        await server.stop()
    }

    @Test func reviewReadIsIsolatedBySessionID() async throws {
        let scriptURL = try makeFakeExecReviewScript(mode: .success)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let port = try nextAvailableTestPort(in: 39451 ... 39460)
        let server = ReviewMCPHTTPServer(
            configuration: .init(
                host: "127.0.0.1",
                port: port,
                codexCommand: scriptURL.path,
                environment: ["HOME": FileManager.default.homeDirectoryForCurrentUser.path]
            )
        )

        let endpointURL = try await server.start()
        let client1 = HTTPToolClient(endpointURL: endpointURL, timeoutInterval: 5)
        let client2 = HTTPToolClient(endpointURL: endpointURL, timeoutInterval: 5)
        let startResponse = try await client1.callTool(
            name: "review_start",
            arguments: [
                "cwd": FileManager.default.temporaryDirectory.path,
                "target": ["type": "uncommittedChanges"],
            ]
        )
        let startResult = try #require(startResponse["result"] as? [String: Any])
        let startStructuredContent = try #require(startResult["structuredContent"] as? [String: Any])
        let jobID = try #require(startStructuredContent["reviewThreadId"] as? String)

        let readResponse = try await client2.callTool(
            name: "review_read",
            arguments: ["reviewThreadId": jobID]
        )
        let result = try #require(readResponse["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        await server.stop()
    }

    @Test func reviewCancelInterruptsActiveReview() async throws {
        let scriptURL = try makeFakeExecReviewScript(mode: .long)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let port = try nextAvailableTestPort(in: 39461 ... 39470)
        let server = ReviewMCPHTTPServer(
            configuration: .init(
                host: "127.0.0.1",
                port: port,
                codexCommand: scriptURL.path,
                environment: ["HOME": FileManager.default.homeDirectoryForCurrentUser.path]
            )
        )

        let endpointURL = try await server.start()
        let client = HTTPToolClient(endpointURL: endpointURL, timeoutInterval: 5)
        let sessionID = try await client.ensureSession()
        let jobID = try await server.reviewJobStore.enqueueReview(
            sessionID: sessionID,
            request: .init(cwd: FileManager.default.temporaryDirectory.path, uncommitted: true)
        )
        let reviewTask = Task {
            await server.reviewJobStore.runReview(jobID: jobID) { _, _ in }
        }

        try await waitUntil(timeout: .seconds(5), interval: .milliseconds(100)) {
            let snapshots = await server.reviewJobStore.allSnapshots()
            return snapshots.contains(where: { $0.jobID == jobID && $0.state == .running })
        }

        let cancelResponse = try await client.callTool(
            name: "review_cancel",
            arguments: ["reviewThreadId": jobID]
        )
        let cancelResult = try #require(cancelResponse["result"] as? [String: Any])
        let cancelStructuredContent = try #require(cancelResult["structuredContent"] as? [String: Any])
        #expect(cancelStructuredContent["jobId"] as? String == jobID)
        #expect(cancelStructuredContent["cancelled"] as? Bool == true)

        let execution = await reviewTask.value
        #expect(execution.snapshot.state == .cancelled)
        await server.stop()
    }

    @Test func deletingSessionCancelsOnlyOwnedReviews() async throws {
        let scriptURL = try makeFakeExecReviewScript(mode: .long)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let port = try nextAvailableTestPort(in: 39471 ... 39480)
        let server = ReviewMCPHTTPServer(
            configuration: .init(
                host: "127.0.0.1",
                port: port,
                codexCommand: scriptURL.path,
                environment: ["HOME": FileManager.default.homeDirectoryForCurrentUser.path]
            )
        )

        let endpointURL = try await server.start()
        let client1 = HTTPToolClient(endpointURL: endpointURL, timeoutInterval: 5)
        let client2 = HTTPToolClient(endpointURL: endpointURL, timeoutInterval: 5)
        let sessionID1 = try await client1.ensureSession()
        let sessionID2 = try await client2.ensureSession()
        let jobID1 = try await server.reviewJobStore.enqueueReview(
            sessionID: sessionID1,
            request: .init(cwd: FileManager.default.temporaryDirectory.path, uncommitted: true)
        )
        let jobID2 = try await server.reviewJobStore.enqueueReview(
            sessionID: sessionID2,
            request: .init(cwd: FileManager.default.temporaryDirectory.path, uncommitted: true)
        )
        let reviewTask1 = Task {
            await server.reviewJobStore.runReview(jobID: jobID1) { _, _ in }
        }
        let reviewTask2 = Task {
            await server.reviewJobStore.runReview(jobID: jobID2) { _, _ in }
        }

        try await waitUntil(timeout: .seconds(5), interval: .milliseconds(100)) {
            let snapshots = await server.reviewJobStore.allSnapshots()
            return snapshots.contains(where: { $0.jobID == jobID1 && $0.state == .running }) &&
                snapshots.contains(where: { $0.jobID == jobID2 && $0.state == .running })
        }

        let deleteStatus = try await client1.deleteSession()
        #expect(deleteStatus == 200)

        let execution1 = await reviewTask1.value
        #expect(execution1.snapshot.state == .cancelled)

        let session2Read = try await client2.callTool(
            name: "review_read",
            arguments: ["reviewThreadId": jobID2]
        )
        let session2Result = try #require(session2Read["result"] as? [String: Any])
        let session2StructuredContent = try #require(session2Result["structuredContent"] as? [String: Any])
        #expect(session2StructuredContent["status"] as? String == "running")

        _ = try await client2.callTool(
            name: "review_cancel",
            arguments: ["reviewThreadId": jobID2]
        )
        let execution2 = await reviewTask2.value
        #expect(execution2.snapshot.state == .cancelled)
        await server.stop()
    }
}

private enum FakeExecReviewMode {
    case success
    case long
}

private func makeFakeExecReviewScript(mode: FakeExecReviewMode) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let body: String
    switch mode {
    case .success:
        body = """
        #!/bin/zsh
        out=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --output-last-message)
              out="$2"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        print '{"type":"thread.started","thread_id":"thread-success"}'
        print '{"type":"turn.started"}'
        print '{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"git diff --stat","aggregated_output":"","status":"in_progress"}}'
        print '{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"git diff --stat","aggregated_output":"README.md | 1 +","exit_code":0,"status":"completed"}}'
        print '{"type":"item.completed","item":{"id":"item_2","type":"reasoning","text":"Inspecting current changes"}}'
        print '{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"No functional issues found."}}'
        print '{"type":"turn.completed","usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1}}'
        [[ -n "$out" ]] && print -n 'No functional issues found.' > "$out"
        """
    case .long:
        body = """
        #!/bin/zsh
        trap 'exit 143' TERM INT
        print '{"type":"thread.started","thread_id":"thread-long"}'
        print '{"type":"turn.started"}'
        while true; do
          sleep 1
        done
        """
    }
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private final class HTTPToolClient: @unchecked Sendable {
    private let endpointURL: URL
    private let session: URLSession
    private let timeoutInterval: TimeInterval
    private var sessionID: String?

    init(endpointURL: URL, timeoutInterval: TimeInterval) {
        self.endpointURL = endpointURL
        self.timeoutInterval = timeoutInterval
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutInterval
        configuration.timeoutIntervalForResource = timeoutInterval
        self.session = URLSession(configuration: configuration)
    }

    func callTool(
        name: String,
        arguments: [String: Any]
    ) async throws -> [String: Any] {
        let payload = try await callToolPayload(name: name, arguments: arguments)
        return try #require((try JSONSerialization.jsonObject(with: payload)) as? [String: Any])
    }

    func callToolPayload(
        name: String,
        arguments: [String: Any]
    ) async throws -> Data {
        let sessionID = try await ensureSession()
        return try await postSSEPayload(
            body: [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": [
                    "name": name,
                    "arguments": arguments,
                ],
            ],
            sessionID: sessionID
        )
    }

    func deleteSession() async throws -> Int {
        let sessionID = try await ensureSession()
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "DELETE"
        request.timeoutInterval = timeoutInterval
        request.setValue("2025-11-25", forHTTPHeaderField: "Mcp-Protocol-Version")
        request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
        let (_, response) = try await session.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        self.sessionID = nil
        return httpResponse.statusCode
    }

    func ensureSession() async throws -> String {
        try await initializeIfNeeded()
    }

    func siblingSharingSession() async throws -> HTTPToolClient {
        let sharedSessionID = try await ensureSession()
        let client = HTTPToolClient(endpointURL: endpointURL, timeoutInterval: timeoutInterval)
        client.sessionID = sharedSessionID
        return client
    }

    private func initializeIfNeeded() async throws -> String {
        if let sessionID {
            return sessionID
        }

        let (payload, response) = try await postSSE(
            body: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": "2025-11-25",
                    "capabilities": [:],
                    "clientInfo": [
                        "name": "test",
                        "version": "0.0.1",
                    ],
                ],
            ],
            sessionID: nil
        )
        let httpResponse = try #require(response as? HTTPURLResponse)
        let newSessionID = try #require(httpResponse.value(forHTTPHeaderField: "MCP-Session-Id"))
        let object = try #require((try JSONSerialization.jsonObject(with: payload)) as? [String: Any])
        #expect((object["id"] as? Int) == 1)

        try await postNotificationInitialized(sessionID: newSessionID)
        self.sessionID = newSessionID
        return newSessionID
    }

    private func postNotificationInitialized(sessionID: String) async throws {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2025-11-25", forHTTPHeaderField: "Mcp-Protocol-Version")
        request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": [:],
        ])
        let (_, response) = try await session.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 202)
    }

    private func postSSEPayload(
        body: [String: Any],
        sessionID: String?
    ) async throws -> Data {
        let (payload, _) = try await postSSE(body: body, sessionID: sessionID)
        return payload
    }

    private func postSSE(
        body: [String: Any],
        sessionID: String?
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2025-11-25", forHTTPHeaderField: "Mcp-Protocol-Version")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        return (try decodeFirstSSEPayload(from: data), response)
    }
}

private func decodeFirstSSEPayload(from data: Data) throws -> Data {
    var decoder = LocalSSEDecoder()
    let text = String(decoding: data, as: UTF8.self)
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if let payload = decoder.feed(line: String(line)), payload.isEmpty == false {
            return payload
        }
    }
    if let payload = decoder.flushIfNeeded(), payload.isEmpty == false {
        return payload
    }
    throw TestFailure("missing SSE payload")
}

private struct LocalSSEDecoder {
    private var dataLines: [String] = []

    mutating func feed(line: String) -> Data? {
        if line.isEmpty {
            return flushIfNeeded()
        }
        if line.hasPrefix("data:") {
            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    mutating func flushIfNeeded() -> Data? {
        guard dataLines.isEmpty == false else {
            return nil
        }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        return Data(payload.utf8)
    }
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    interval: Duration = .milliseconds(20),
    condition: @escaping () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if try await condition() {
            return
        }
        try await Task.sleep(for: interval)
    }
    throw TestFailure("timed out")
}

private func waitUntilValue<T>(
    timeout: Duration = .seconds(2),
    interval: Duration = .milliseconds(20),
    action: @escaping () async throws -> T?
) async throws -> T {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if let value = try await action() {
            return value
        }
        try await Task.sleep(for: interval)
    }
    throw TestFailure("timed out")
}

private func nextAvailableTestPort(in range: ClosedRange<Int>) throws -> Int {
    for port in range {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            continue
        }
        defer { close(descriptor) }

        var value: Int32 = 1
        _ = withUnsafePointer(to: &value) {
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 {
            return port
        }
    }
    throw TestFailure("no free TCP port in range \(range)")
}

private struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
