import Foundation
import MCP
import Testing
@testable import CodexReviewMCP
@testable import ReviewCore
@testable import ReviewHTTPServer
@testable import ReviewJobs
@testable import ReviewRuntime
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
        #expect(firstStore.serverURL != nil)

        await firstStore.stop()
        #expect(firstStore.serverState == .stopped)
        #expect(firstStore.serverURL == nil)
        #expect(firstStore.jobs.isEmpty)

        let secondStore = CodexReviewStore(
            configuration: .init(host: "127.0.0.1", port: secondPort, codexCommand: scriptURL.path)
        )
        await secondStore.start()
        #expect(secondStore.serverState == .running)
        #expect(secondStore.serverURL != nil)
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
            let endpointURL = try #require(store.serverURL)
            let client = ReviewMCPHTTPTestClient(endpointURL: endpointURL, timeoutInterval: 5)

            let response = try await client.callTool(
                name: "review_start",
                arguments: [
                    "cwd": repository.url.path,
                    "target": [
                        "type": "uncommitted",
                    ],
                ]
            )

            let result = try #require(response["result"] as? [String: Any])
            let structuredContent = try #require(result["structuredContent"] as? [String: Any])
            let jobID = try #require(structuredContent["jobId"] as? String)
            let logs = try #require(structuredContent["logs"] as? [[String: Any]])
            let rawLogText = try #require(structuredContent["rawLogText"] as? String)
            #expect(structuredContent["reviewThreadId"] as? String == jobID)
            #expect(structuredContent["status"] as? String == "succeeded")
            #expect(((structuredContent["review"] as? String) ?? "").isEmpty == false)
            #expect(logs.contains { ($0["kind"] as? String) == "reasoning" && (($0["text"] as? String) ?? "").contains("Inspecting current changes") })
            #expect(rawLogText.contains("\"type\":\"thread.started\""))

            try await waitUntil(timeout: .seconds(2)) {
                await MainActor.run {
                    guard let job = store.jobs.first else {
                        return false
                    }
                    return job.status == .succeeded && job.logText.isEmpty == false
                }
            }

            let job = try #require(store.jobs.first)
            #expect(job.status == .succeeded)
            #expect(job.logText.contains("$ git diff --stat"))
            #expect(job.logText.contains("Inspecting current changes"))
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
                let endpointURL = try #require(store.serverURL)
                let client = ReviewMCPHTTPTestClient(endpointURL: endpointURL, timeoutInterval: 1200)

                let response = try await client.callTool(
                    name: "review_start",
                    arguments: [
                        "cwd": repository.url.path,
                        "target": [
                            "type": "uncommitted",
                        ],
                    ]
                )

                let result = try #require(response["result"] as? [String: Any])
                let structuredContent = try #require(result["structuredContent"] as? [String: Any])
                let reviewThreadID = try #require(structuredContent["reviewThreadId"] as? String)
                let logs = try #require(structuredContent["logs"] as? [[String: Any]])
                #expect(structuredContent["status"] as? String == "succeeded")
                #expect(((structuredContent["review"] as? String) ?? "").isEmpty == false)
                #expect(reviewThreadID.isEmpty == false)
                #expect(logs.isEmpty == false)

                try await waitUntil(timeout: .seconds(60), interval: .milliseconds(200)) {
                    await MainActor.run {
                        guard let job = store.jobs.first else {
                            return false
                        }
                        return job.status == .succeeded && job.logText.isEmpty == false
                    }
                }

                let job = try #require(store.jobs.first)
                #expect(job.status == .succeeded)
                #expect(job.logText.isEmpty == false)
                let readResponse = try await client.callTool(
                    name: "review_read",
                    arguments: [
                        "reviewThreadId": reviewThreadID,
                    ]
                )
                let readResult = try #require(readResponse["result"] as? [String: Any])
                let readStructuredContent = try #require(readResult["structuredContent"] as? [String: Any])
                let readLogs = try #require(readStructuredContent["logs"] as? [[String: Any]])
                let rawLogText = try #require(readStructuredContent["rawLogText"] as? String)
                #expect(readStructuredContent["status"] as? String == "succeeded")
                #expect(((readStructuredContent["review"] as? String) ?? "").isEmpty == false)
                #expect(readLogs.isEmpty == false)
                #expect(rawLogText.isEmpty == false)
            }
        } catch {
            await store.stop()
            throw error
        }

        await store.stop()
    }

    @Test func codexReviewStoreAppliesMutationsInPlace() throws {
        let store = CodexReviewStore(configuration: .init())
        let queuedRequest = ReviewRequestOptions(
            cwd: "/tmp/repo",
            uncommitted: true,
            model: "gpt-5"
        )

        let firstJobID = try store.enqueueReview(sessionID: "session-1", request: queuedRequest)
        let firstJob = try #require(store.jobs.first(where: { $0.id == firstJobID }))
        #expect(store.activeJobs.map(\.id) == [firstJobID])
        #expect(store.recentJobs.isEmpty)

        store.markStarted(
            jobID: firstJobID,
            artifacts: .init(eventsPath: nil, logPath: nil, lastMessagePath: nil),
            startedAt: Date(timeIntervalSince1970: 123)
        )
        store.handle(jobID: firstJobID, event: .threadStarted("thread-1"))
        store.handle(jobID: firstJobID, event: .logEntry(.init(kind: .agentMessage, text: "Running review")))

        let secondJobID = try store.enqueueReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/repo", base: "main")
        )
        store.failToStart(
            jobID: secondJobID,
            message: "boom",
            startedAt: Date(timeIntervalSince1970: 200),
            endedAt: Date(timeIntervalSince1970: 201)
        )

        let updatedJob = try #require(store.jobs.first(where: { $0.id == firstJobID }))
        #expect(updatedJob === firstJob)
        #expect(updatedJob.status == .running)
        #expect(updatedJob.threadID == "thread-1")
        #expect(updatedJob.logText == "Running review")
        #expect(store.activeJobs.map(\.id) == [firstJobID])
        #expect(store.recentJobs.map(\.id) == [secondJobID])
        #expect(updatedJob.startedAt == Date(timeIntervalSince1970: 123))
    }

    @Test func initializeAdvertisesResourcesCapability() async throws {
        let server = makeMonitorServer()
        let initialized = try await initializeMonitorSessionAndReadInitializeResponse(server: server)
        let result = try #require(initialized.response["result"] as? [String: Any])
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        #expect(capabilities["resources"] as? [String: Any] != nil)
    }

    @Test func monitorServerListsReviewHelpResources() async throws {
        let server = makeMonitorServer()
        let sessionID = try await initializeMonitorSession(server: server)
        let response = try await callMonitorMethod(
            server: server,
            sessionID: sessionID,
            requestID: 11,
            method: "resources/list",
            params: [:]
        )

        let result = try #require(response["result"] as? [String: Any])
        let resources = try #require(result["resources"] as? [[String: Any]])
        let uris = resources.compactMap { $0["uri"] as? String }
        #expect(uris == [
            "codex-review://help/overview",
            "codex-review://help/troubleshooting",
        ])
    }

    @Test func monitorServerListsReviewHelpTemplates() async throws {
        let server = makeMonitorServer()
        let sessionID = try await initializeMonitorSession(server: server)
        let response = try await callMonitorMethod(
            server: server,
            sessionID: sessionID,
            requestID: 12,
            method: "resources/templates/list",
            params: [:]
        )

        let result = try #require(response["result"] as? [String: Any])
        let templates = try #require(result["resourceTemplates"] as? [[String: Any]])
        let uris = templates.compactMap { $0["uriTemplate"] as? String }
        #expect(uris == [
            "codex-review://help/tools/{toolName}",
            "codex-review://help/targets/{targetType}",
        ])
    }

    @Test func monitorServerReadsConcreteHelpResources() async throws {
        let server = makeMonitorServer()
        let sessionID = try await initializeMonitorSession(server: server)

        let toolResponse = try await callMonitorMethod(
            server: server,
            sessionID: sessionID,
            requestID: 13,
            method: "resources/read",
            params: ["uri": "codex-review://help/tools/review_start"]
        )
        let targetResponse = try await callMonitorMethod(
            server: server,
            sessionID: sessionID,
            requestID: 14,
            method: "resources/read",
            params: ["uri": "codex-review://help/targets/uncommitted"]
        )

        let toolContents = try #require(((toolResponse["result"] as? [String: Any])?["contents"] as? [[String: Any]])?.first)
        let targetContents = try #require(((targetResponse["result"] as? [String: Any])?["contents"] as? [[String: Any]])?.first)
        #expect(((toolContents["text"] as? String) ?? "").contains("`review_start`"))
        #expect(((targetContents["text"] as? String) ?? "").contains("`target.type = \"uncommitted\"`"))
    }

    @Test func monitorServerRejectsUnknownTargetHelpResource() async throws {
        let server = makeMonitorServer()
        let sessionID = try await initializeMonitorSession(server: server)
        let response = try await callMonitorMethod(
            server: server,
            sessionID: sessionID,
            requestID: 15,
            method: "resources/read",
            params: ["uri": "codex-review://help/targets/bogus"]
        )

        let error = try #require(response["error"] as? [String: Any])
        let message = try #require(error["message"] as? String)
        #expect(message.contains("Allowed values: uncommitted, branch, commit, custom"))
    }

    @Test func monitorServerReviewStartInvalidTargetReturnsGuidance() async throws {
        let server = makeMonitorServer()
        let sessionID = try await initializeMonitorSession(server: server)
        let response = try await callMonitorTool(
            server: server,
            sessionID: sessionID,
            requestID: 16,
            name: "review_start",
            arguments: [
                "cwd": "/tmp/repo",
                "target": [
                    "type": "uncommittedChanges",
                ],
            ]
        )

        let result = try #require(response["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        let structuredContent = try #require(result["structuredContent"] as? [String: Any])
        let acceptedTargetTypes = try #require(structuredContent["acceptedTargetTypes"] as? [String])
        let helpResources = try #require(structuredContent["helpResources"] as? [String])
        let helpTemplates = try #require(structuredContent["helpTemplates"] as? [String])

        #expect((result["isError"] as? Bool) == true)
        #expect(text.contains("Accepted `target.type` values: uncommitted, branch, commit, custom"))
        #expect(text.contains("codex-review://help/overview"))
        #expect(text.contains("codex-review://help/tools/review_start"))
        #expect(text.contains("codex-review://help/targets/uncommitted"))
        #expect(text.contains("codex-review://help/targets/branch"))
        #expect(text.contains("codex-review://help/targets/commit"))
        #expect(text.contains("codex-review://help/targets/custom"))
        #expect(acceptedTargetTypes == ["uncommitted", "branch", "commit", "custom"])
        #expect(helpResources == ["codex-review://help/overview", "codex-review://help/troubleshooting"])
        #expect(helpTemplates == ["codex-review://help/tools/{toolName}", "codex-review://help/targets/{targetType}"])
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
    try await initializeMonitorSessionAndReadInitializeResponse(server: server).sessionID
}

private func initializeMonitorSessionAndReadInitializeResponse(
    server: ReviewMCPHTTPServer
) async throws -> (sessionID: String, response: [String: Any]) {
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
    return (sessionID, object)
}

private func callMonitorTool(
    server: ReviewMCPHTTPServer,
    sessionID: String,
    requestID: Int,
    name: String,
    arguments: [String: Any]
) async throws -> [String: Any] {
    try await callMonitorMethod(
        server: server,
        sessionID: sessionID,
        requestID: requestID,
        method: "tools/call",
        params: [
            "name": name,
            "arguments": arguments,
        ]
    )
}

private func callMonitorMethod(
    server: ReviewMCPHTTPServer,
    sessionID: String,
    requestID: Int,
    method: String,
    params: [String: Any]?
) async throws -> [String: Any] {
    var requestObject: [String: Any] = [
        "jsonrpc": "2.0",
        "id": requestID,
        "method": method,
    ]
    if let params {
        requestObject["params"] = params
    }
    let body = try JSONSerialization.data(withJSONObject: requestObject)
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

private func makeMonitorServer() -> ReviewMCPHTTPServer {
    ReviewMCPHTTPServer(
        configuration: .init(),
        startReview: { _, _ in
            ReviewReadResult(
                jobID: "job-1",
                reviewThreadID: "job-1",
                status: .succeeded,
                review: "ok",
                lastAgentMessage: "ok",
                logs: [],
                rawLogText: ""
            )
        },
        readReview: { _, _ in
            ReviewReadResult(
                jobID: "job-1",
                reviewThreadID: "job-1",
                status: .succeeded,
                review: "ok",
                lastAgentMessage: "ok",
                logs: [],
                rawLogText: ""
            )
        },
        listReviews: { _, _, _, _ in
            ReviewListResult(items: [])
        },
        cancelReviewByID: { _, _ in
            ReviewCancelOutcome(
                jobID: "job-1",
                reviewThreadID: "job-1",
                cancelled: true,
                status: .cancelled
            )
        },
        cancelReviewBySelector: { _, _, _, _ in
            ReviewCancelOutcome(
                jobID: "job-1",
                reviewThreadID: "job-1",
                cancelled: true,
                status: .cancelled
            )
        },
        closeSession: { _ in },
        hasActiveJobs: { _ in false }
    )
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
