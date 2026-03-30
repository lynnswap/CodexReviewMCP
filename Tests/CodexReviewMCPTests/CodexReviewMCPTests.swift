import Foundation
import MCP
import Testing
@testable import CodexReviewMCP
@testable import ReviewCore
@testable import ReviewHTTPServer
import Darwin

@Suite(.serialized)
@MainActor
struct CodexReviewMCPTests {
    @Test func storeTransitionsThroughStartStopAndRestart() async throws {
        let firstPort = try nextAvailableTestPort(in: 39411 ... 39420)
        let secondPort = try nextAvailableTestPort(in: 39421 ... 39430)
        let scriptURL = try makeFakeExecReviewScript(mode: .success)
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        let firstStore = CodexReviewStore(
            configuration: .init(host: "127.0.0.1", port: firstPort, codexCommand: scriptURL.path)
        )

        await firstStore.start()
        #expect(firstStore.serverState == .running)
        #expect(firstStore.endpointURL != nil)

        await firstStore.stop()
        #expect(firstStore.serverState == .stopped)
        #expect(firstStore.endpointURL == nil)
        #expect(firstStore.jobStore.jobs.isEmpty)

        let secondStore = CodexReviewStore(
            configuration: .init(host: "127.0.0.1", port: secondPort, codexCommand: scriptURL.path)
        )
        await secondStore.start()
        #expect(secondStore.serverState == .running)
        #expect(secondStore.endpointURL != nil)
        await secondStore.stop()
    }

    @Test func embeddedServerReviewStartProgressesViaHTTP() async throws {
        let port = try nextAvailableTestPort(in: 39421 ... 39430)
        let scriptURL = try makeFakeExecReviewScript(mode: .success)
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        let repository = try TemporaryReviewRepository.make()
        defer { repository.cleanup() }
        let store = CodexReviewStore(
            configuration: .init(host: "127.0.0.1", port: port, codexCommand: scriptURL.path)
        )

        do {
            await store.start()
            #expect(store.serverState == .running)
            let endpointURL = try #require(store.endpointURL)
            let client = ReviewMCPHTTPTestClient(endpointURL: endpointURL, timeoutInterval: 5)

            let response = try await client.callTool(
                name: "review_start",
                arguments: [
                    "cwd": repository.url.path,
                    "target": [
                        "type": "uncommittedChanges",
                        "title": "Uncommitted changes",
                    ],
                ]
            )

            let result = try #require(response["result"] as? [String: Any])
            let structuredContent = try #require(result["structuredContent"] as? [String: Any])
            let jobID = try #require(structuredContent["jobId"] as? String)
            #expect(structuredContent["reviewThreadId"] as? String == jobID)
            #expect(structuredContent["status"] as? String == "succeeded")
            #expect(((structuredContent["review"] as? String) ?? "").isEmpty == false)

            try await waitUntil(timeout: .seconds(2)) {
                await MainActor.run {
                    guard let job = store.jobStore.jobs.first else {
                        return false
                    }
                    return job.status == .succeeded &&
                        job.reviewLogText.isEmpty == false &&
                        job.reasoningLogText.isEmpty == false
                }
            }

            let job = try #require(store.jobStore.jobs.first)
            #expect(job.status == .succeeded)
            #expect(job.reviewLogText.contains("$ git diff --stat"))
            #expect(job.reasoningLogText.contains("Inspecting current changes"))
        } catch {
            await store.stop()
            throw error
        }

        await store.stop()
    }

    @Test func embeddedServerLiveReviewStartProgressesViaHTTP() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_REVIEW_MCP_LIVE_TESTS"] == "1" else {
            return
        }
        let repository = try TemporaryReviewRepository.make()
        defer { repository.cleanup() }
        let port = try nextAvailableTestPort(in: 39431 ... 39440)

        let store = CodexReviewStore(
            configuration: .init(
                host: "127.0.0.1",
                port: port,
                codexCommand: "codex",
                environment: liveReviewEnvironment()
            )
        )

        do {
            try await withTestTimeout(seconds: 1500) { @MainActor in
                await store.start()
                #expect(store.serverState == .running)
                let endpointURL = try #require(store.endpointURL)
                let client = ReviewMCPHTTPTestClient(endpointURL: endpointURL, timeoutInterval: 1200)

                let response = try await client.callTool(
                    name: "review_start",
                    arguments: [
                        "cwd": repository.url.path,
                        "target": [
                            "type": "uncommittedChanges",
                            "title": "Uncommitted changes",
                        ],
                    ]
                )

                let result = try #require(response["result"] as? [String: Any])
                let structuredContent = try #require(result["structuredContent"] as? [String: Any])
                let reviewThreadID = try #require(structuredContent["reviewThreadId"] as? String)
                #expect(structuredContent["status"] as? String == "succeeded")
                #expect(((structuredContent["review"] as? String) ?? "").isEmpty == false)
                #expect(reviewThreadID.isEmpty == false)

                try await waitUntil(timeout: .seconds(60), interval: .milliseconds(200)) {
                    await MainActor.run {
                        guard let job = store.jobStore.jobs.first else {
                            return false
                        }
                        return job.status == .succeeded &&
                            (job.activityLogText.isEmpty == false || job.reasoningSummaryText.isEmpty == false)
                    }
                }

                let job = try #require(store.jobStore.jobs.first)
                #expect(job.status == .succeeded)
                #expect(job.activityLogText.isEmpty == false || job.reasoningSummaryText.isEmpty == false)
                let readResponse = try await client.callTool(
                    name: "review_read",
                    arguments: [
                        "reviewThreadId": reviewThreadID,
                    ]
                )
                let readResult = try #require(readResponse["result"] as? [String: Any])
                let readStructuredContent = try #require(readResult["structuredContent"] as? [String: Any])
                #expect(readStructuredContent["status"] as? String == "succeeded")
                #expect(((readStructuredContent["review"] as? String) ?? "").isEmpty == false)
            }
        } catch {
            await store.stop()
            throw error
        }

        await store.stop()
    }

    @Test func jobStoreAppliesSnapshotsInPlace() throws {
        let store = CodexReviewJobStore()
        let queuedSnapshot = ReviewJobSnapshot(
            jobID: "job-1",
            sessionID: "session-1",
            cwd: "/tmp/repo",
            targetSummary: "Uncommitted changes",
            model: "gpt-5",
            state: .queued,
            summary: "Queued."
        )
        let runningSnapshot = ReviewJobSnapshot(
            jobID: "job-1",
            sessionID: "session-1",
            cwd: "/tmp/repo",
            targetSummary: "Uncommitted changes",
            model: "gpt-5",
            state: .running,
            threadID: "thread-1",
            reviewLogText: "Running review\n",
            reasoningLogText: "Inspecting diff\n",
            startedAt: Date(timeIntervalSince1970: 123),
            summary: "Running."
        )
        let requeuedSnapshot = ReviewJobSnapshot(
            jobID: "job-1",
            sessionID: "session-1",
            cwd: "/tmp/repo",
            targetSummary: "Uncommitted changes",
            model: "gpt-5",
            state: .queued,
            summary: "Queued again."
        )
        let recentSnapshot = ReviewJobSnapshot(
            jobID: "job-2",
            sessionID: "session-1",
            cwd: "/tmp/repo",
            targetSummary: "Base branch: main",
            model: nil,
            state: .failed,
            summary: "Failed."
        )

        store.apply(snapshots: [queuedSnapshot])
        let firstJob = try #require(store.jobs.first(where: { $0.id == "job-1" }))
        #expect(store.activeJobs.map(\.id) == ["job-1"])
        #expect(store.recentJobs.isEmpty)

        store.apply(snapshots: [runningSnapshot, recentSnapshot])
        let updatedJob = try #require(store.jobs.first(where: { $0.id == "job-1" }))
        #expect(updatedJob === firstJob)
        #expect(updatedJob.status == .running)
        #expect(updatedJob.threadID == "thread-1")
        #expect(updatedJob.reviewLogText == "Running review\n")
        #expect(store.activeJobs.map(\.id) == ["job-1"])
        #expect(store.recentJobs.map(\.id) == ["job-2"])
        #expect(updatedJob.startedAt == Date(timeIntervalSince1970: 123))

        store.apply(snapshots: [requeuedSnapshot])
        #expect(updatedJob.startedAt == .distantPast)

        store.apply(snapshots: [runningSnapshot])
        #expect(store.jobs.contains(where: { $0.id == "job-2" }) == false)
        #expect(store.jobs.map(\.id) == ["job-1"])
        #expect(store.activeJobs.map(\.id) == ["job-1"])
    }

}

private struct TemporaryReviewRepository {
    let url: URL

    static func make() throws -> TemporaryReviewRepository {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexReviewMCPTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try "# Live Fixture\n".write(
            to: url.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runProcess(["/usr/bin/git", "init", "-q"], in: url)
        try runProcess(["/usr/bin/git", "config", "user.name", "Codex Review Test"], in: url)
        try runProcess(["/usr/bin/git", "config", "user.email", "codex-review@example.com"], in: url)
        try runProcess(["/usr/bin/git", "add", "README.md"], in: url)
        try runProcess(["/usr/bin/git", "commit", "-qm", "Initial commit"], in: url)
        try """
        # Live Fixture

        This line is intentionally uncommitted.
        """.write(
            to: url.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        return TemporaryReviewRepository(url: url)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
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

private func liveReviewEnvironment() -> [String: String] {
    let source = ProcessInfo.processInfo.environment
    let allowedKeys: Set<String> = [
        "HOME",
        "CODEX_HOME",
        "TMPDIR",
        "PATH",
        "LANG",
        "TERM",
        "SHELL",
        "USER",
        "LOGNAME",
        "SSH_AUTH_SOCK",
        "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY",
        "GITHUB_MCP_API_TOKEN",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "NO_PROXY",
        "http_proxy",
        "https_proxy",
        "no_proxy",
    ]

    return source.reduce(into: [:]) { partialResult, entry in
        let (key, value) = entry
        if allowedKeys.contains(key) || key.hasPrefix("LC_") {
            partialResult[key] = value
        }
    }
}

private func runProcess(_ arguments: [String], in directoryURL: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: arguments[0])
    process.arguments = Array(arguments.dropFirst())
    process.currentDirectoryURL = directoryURL
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw TestFailure("command failed: \(arguments.joined(separator: " "))")
    }
}

private final class ReviewMCPHTTPTestClient: @unchecked Sendable {
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
        let sessionID = try await initializeIfNeeded()
        let payload = try await postSSEPayload(
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
        return try #require((try JSONSerialization.jsonObject(with: payload)) as? [String: Any])
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
        sessionID = newSessionID
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
        let finalRequest = request
        let (_, response) = try await withTestTimeout(seconds: timeoutInterval) {
            try await self.session.data(for: finalRequest)
        }
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
        let finalRequest = request

        let (data, response) = try await withTestTimeout(seconds: timeoutInterval) {
            try await self.session.data(for: finalRequest)
        }
        return (try decodeFirstSSEPayload(from: data), response)
    }
}

private func initializeMonitorSession(server: ReviewMCPHTTPServer) async throws -> String {
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
    let payload = try await firstMonitorStreamPayload(response)
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

private func callMonitorTool(
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
    let payload = try await firstMonitorStreamPayload(response)
    return try #require((try JSONSerialization.jsonObject(with: payload)) as? [String: Any])
}

private func firstMonitorStreamPayload(_ response: HTTPResponse) async throws -> Data {
    guard case .stream(let stream, _) = response else {
        throw TestFailure("expected stream response")
    }
    var decoder = LocalMonitorSSEDecoder()
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

private func waitUntilValue<T>(
    timeout: Duration = .seconds(2),
    interval: Duration = .milliseconds(20),
    action: @escaping @Sendable () async throws -> T?
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

private func decodeFirstSSEPayload(from data: Data) throws -> Data {
    var decoder = LocalMonitorSSEDecoder()
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

private func nextAvailableTestPort(in range: ClosedRange<Int>) throws -> Int {
    for port in range {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            continue
        }
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult == 0 {
            return port
        }
    }
    throw TestFailure("No available test port in range \(range.lowerBound)...\(range.upperBound)")
}

private func withTestTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TestFailure("timed out after \(seconds) seconds")
        }
        let result = try await group.next()
        group.cancelAll()
        return try #require(result)
    }
}

private func jsonLine(_ value: Value) -> String {
    guard let data = try? JSONEncoder().encode(value) else {
        assertionFailure("Failed to encode JSON line payload.")
        return ""
    }
    return String(decoding: data, as: UTF8.self)
}

private struct LocalMonitorSSEDecoder {
    private var dataLines: [String] = []

    mutating func feed(line: String) -> Data? {
        if line.isEmpty {
            return flushIfNeeded()
        }
        if line.hasPrefix("data:") {
            let payload = line.dropFirst(5)
            dataLines.append(String(payload).trimmingCharacters(in: .whitespaces))
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

private struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
