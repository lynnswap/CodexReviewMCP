import AppKit
import Darwin
import Foundation
import Testing
import CodexReviewMCP
@testable import CodexReviewMonitor

@MainActor
struct CodexReviewMonitorTests {
    @Test func bindingStoreAppliesInitialState() {
        let store = CodexReviewMonitorStore()
        let viewController = ReviewMonitorSplitViewController()
        viewController.loadViewIfNeeded()
        viewController.bind(store: store, onRestart: {})

        #expect(viewController.sidebarViewControllerForTesting.statusTextForTesting == "Server: Stopped")
        #expect(viewController.listViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.transportViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.reasoningViewControllerForTesting.isShowingEmptyStateForTesting)
    }

    @Test func splitViewShowsEmptyStateWithoutJobs() {
        let viewController = ReviewMonitorSplitViewController()
        viewController.loadViewIfNeeded()
        viewController.apply(
            state: ReviewMonitorViewState(
                serverState: .stopped,
                endpointURL: nil,
                jobs: []
            ),
            onRestart: {}
        )

        #expect(viewController.splitViewItems.count == 3)
        #expect(viewController.sidebarViewControllerForTesting.statusTextForTesting == "Server: Stopped")
        #expect(viewController.listViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.transportViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.reasoningViewControllerForTesting.isShowingEmptyStateForTesting)
    }

    @Test func splitViewSeparatesActiveAndRecentJobs() {
        let activeJob = makeJob(status: .running, targetSummary: "Uncommitted changes")
        let recentJob = makeJob(status: .failed, targetSummary: "Base branch: main")
        let viewController = ReviewMonitorSplitViewController()
        viewController.loadViewIfNeeded()
        viewController.apply(
            state: ReviewMonitorViewState(
                serverState: .running,
                endpointURL: URL(string: "http://localhost:9417/mcp"),
                jobs: [activeJob, recentJob]
            ),
            onRestart: {}
        )

        #expect(viewController.listViewControllerForTesting.displayedSectionTitlesForTesting == ["Active", "Recent"])
        #expect(viewController.splitViewItems.count == 3)
        #expect(viewController.splitViewItems[0].behavior == .sidebar)
        #expect(viewController.splitViewItems[1].behavior == .default)
        #expect(viewController.splitViewItems[2].behavior == .inspector)
        #expect(viewController.sidebarViewControllerForTesting.statusTextForTesting == "Server: Running")
        #expect(viewController.sidebarViewControllerForTesting.endpointTextForTesting == "http://localhost:9417/mcp")
    }

    @Test func selectingJobUpdatesDetailPane() {
        let activeJob = makeJob(status: .running, targetSummary: "Uncommitted changes", activityLogText: "Running review\n")
        let recentJob = makeJob(
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "MCP server codex_review ready.",
            reasoningSummaryText: "差分が大きいので、まず ReviewCore と monitor UI を切り分けます。",
            activityLogText: "Findings ready\n"
        )
        let viewController = ReviewMonitorSplitViewController()
        viewController.loadViewIfNeeded()
        viewController.apply(
            state: ReviewMonitorViewState(
                serverState: .running,
                endpointURL: URL(string: "http://localhost:9417/mcp"),
                jobs: [activeJob, recentJob]
            ),
            onRestart: {}
        )

        viewController.listViewControllerForTesting.selectJobForTesting(id: recentJob.id)

        #expect(viewController.transportViewControllerForTesting.displayedTitleForTesting == recentJob.displayTitle)
        #expect(viewController.transportViewControllerForTesting.displayedSummaryForTesting == recentJob.summary)
        #expect(viewController.transportViewControllerForTesting.displayedActivityLogForTesting == recentJob.activityLogText)
        #expect(viewController.reasoningViewControllerForTesting.displayedTitleForTesting == "Reasoning")
        #expect(viewController.reasoningViewControllerForTesting.displayedSummaryForTesting == recentJob.summary)
        #expect(viewController.reasoningViewControllerForTesting.displayedReasoningForTesting == recentJob.reasoningSummaryText)
    }

    @Test func launchedAppEmbeddedReviewStartProgressesViaMCP() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_REVIEW_MCP_LIVE_TESTS"] == "1" else {
            return
        }
        let repository = try TemporaryReviewRepository.make()
        defer { repository.cleanup() }
        let scriptURL = try makeFakeExecReviewScript(mode: .success)
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        let port = try nextAvailableTestPort(in: 39501 ... 39510)

        let launchedApp = try LaunchedMonitorApp.start(codexCommand: scriptURL.path, port: port)
        defer { launchedApp.terminate() }

        let endpointURL: URL = try await waitUntilValue(timeout: .seconds(20), interval: .milliseconds(200)) {
            try launchedApp.readDiagnostics()?.endpointURL.flatMap(URL.init(string:))
        }
        let client = MonitorHTTPTestClient(endpointURL: endpointURL, timeoutInterval: 1200)

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
        let jobID = try #require(structuredContent["jobId"] as? String)
        #expect(reviewThreadID == jobID)
        #expect(reviewThreadID.isEmpty == false)
        #expect(structuredContent["status"] as? String == "succeeded")
        #expect(((structuredContent["review"] as? String) ?? "").isEmpty == false)

        let diagnostics: MonitorAppDiagnostics = try await waitUntilValue(timeout: .seconds(30), interval: .milliseconds(200)) {
            guard let diagnostics = try launchedApp.readDiagnostics(),
                  let job = diagnostics.jobs.first,
                  job.status == "succeeded",
                  job.reviewLogText.isEmpty == false || job.reasoningLogText.isEmpty == false
            else {
                return nil
            }
            return diagnostics
        }

        let job = try #require(diagnostics.jobs.first)
        #expect(job.status == "succeeded")
        #expect(job.reviewLogText.isEmpty == false || job.reasoningLogText.isEmpty == false)
        #expect(diagnostics.childRuntimePath == nil)

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
}

private enum MonitorAppTestEnvironment {
    static let portArgument = "--codex-review-monitor-test-port"
    static let codexCommandArgument = "--codex-review-monitor-test-codex-command"
    static let diagnosticsPathArgument = "--codex-review-monitor-test-diagnostics-path"
}

private struct MonitorAppDiagnostics: Decodable {
    struct Job: Decodable {
        var status: String
        var summary: String
        var reviewLogText: String
        var reasoningLogText: String
        var rawLogText: String
    }

    var serverState: String
    var failureMessage: String?
    var endpointURL: String?
    var childRuntimePath: String?
    var jobs: [Job]
}

private struct TemporaryReviewRepository {
    let url: URL

    static func make() throws -> TemporaryReviewRepository {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexReviewMonitor-AppProcess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try """
        # CodexReviewMonitor fixture
        """.write(
            to: url.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["init"], in: url)
        try runGit(["config", "user.name", "Codex Review Test"], in: url)
        try runGit(["config", "user.email", "codex-review@example.com"], in: url)
        try runGit(["add", "README.md"], in: url)
        try runGit(["commit", "-m", "Initial commit"], in: url)
        try """
        # CodexReviewMonitor fixture

        This change should produce a short review.
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

private final class LaunchedMonitorApp {
    let launcherProcess: Process
    let appBundleURL: URL
    let appExecutableURL: URL
    let diagnosticsURL: URL
    let stdoutURL: URL
    let stderrURL: URL
    let startedAt: Date
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle

    private init(
        launcherProcess: Process,
        appBundleURL: URL,
        appExecutableURL: URL,
        diagnosticsURL: URL,
        stdoutURL: URL,
        stderrURL: URL,
        startedAt: Date,
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle
    ) {
        self.launcherProcess = launcherProcess
        self.appBundleURL = appBundleURL
        self.appExecutableURL = appExecutableURL
        self.diagnosticsURL = diagnosticsURL
        self.stdoutURL = stdoutURL
        self.stderrURL = stderrURL
        self.startedAt = startedAt
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
    }

    static func start(codexCommand: String, port: Int) throws -> LaunchedMonitorApp {
        guard let sourceBundleURL = Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.bundleURL
            : nil
        else {
            throw TestFailure("Missing app bundle URL.")
        }
        guard Bundle.main.executableURL != nil else {
            throw TestFailure("Missing app executable URL.")
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexReviewMonitorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let diagnosticsURL = tempDirectory.appendingPathComponent("diagnostics.json")
        let stdoutURL = tempDirectory.appendingPathComponent("stdout.log")
        let stderrURL = tempDirectory.appendingPathComponent("stderr.log")
        let appBundleURL = tempDirectory.appendingPathComponent("CodexReviewMonitor.app", isDirectory: true)
        FileManager.default.createFile(atPath: stdoutURL.path, contents: Data())
        FileManager.default.createFile(atPath: stderrURL.path, contents: Data())
        try FileManager.default.copyItem(at: sourceBundleURL, to: appBundleURL)
        guard let executableURL = Bundle(url: appBundleURL)?.executableURL else {
            throw TestFailure("Missing copied app executable URL.")
        }
        try terminateExistingMonitorProcesses(executableURL: executableURL)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-na",
            appBundleURL.path,
            "--args",
            MonitorAppTestEnvironment.portArgument,
            "\(port)",
            MonitorAppTestEnvironment.codexCommandArgument,
            codexCommand,
            MonitorAppTestEnvironment.diagnosticsPathArgument,
            diagnosticsURL.path,
        ]
        process.environment = [
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        try process.run()
        let startedAt = Date()

        return LaunchedMonitorApp(
            launcherProcess: process,
            appBundleURL: appBundleURL,
            appExecutableURL: executableURL,
            diagnosticsURL: diagnosticsURL,
            stdoutURL: stdoutURL,
            stderrURL: stderrURL,
            startedAt: startedAt,
            stdoutHandle: stdoutHandle,
            stderrHandle: stderrHandle
        )
    }

    func terminate() {
        if launcherProcess.isRunning {
            launcherProcess.terminate()
            launcherProcess.waitUntilExit()
        }
        Self.terminateMonitorProcesses(executableURL: appExecutableURL)
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }

    func readDiagnostics() throws -> MonitorAppDiagnostics? {
        guard FileManager.default.fileExists(atPath: diagnosticsURL.path) else {
            let startupGraceInterval: TimeInterval = 5
            if Date().timeIntervalSince(startedAt) >= startupGraceInterval,
               isAppRunning() == false
            {
                throw TestFailure("App exited before diagnostics appeared.\n\(failureContext())")
            }
            return nil
        }
        let data = try Data(contentsOf: diagnosticsURL)
        return try JSONDecoder().decode(MonitorAppDiagnostics.self, from: data)
    }

    func failureContext() -> String {
        """
        diagnostics: \(diagnosticsURL.path)
        stdout: \(stdoutURL.path)
        stderr: \(stderrURL.path)
        app: \(appBundleURL.path)
        """
    }

    private static func terminateExistingMonitorProcesses(executableURL: URL) throws {
        terminateMonitorProcesses(executableURL: executableURL)
        Thread.sleep(forTimeInterval: 0.5)
    }

    private static func terminateMonitorProcesses(executableURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", executableURL.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
        }
    }

    private func isAppRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", appExecutableURL.path]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

private enum FakeExecReviewMode {
    case success
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
    }
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private final class MonitorHTTPTestClient: @unchecked Sendable {
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

@discardableResult
private func runGit(_ arguments: [String], in directory: URL) throws -> String {
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = directory
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    process.waitUntilExit()

    let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw TestFailure("git \(arguments.joined(separator: " ")) failed in \(directory.path)\nstdout:\n\(stdout)\nstderr:\n\(stderr)")
    }
    return stdout
}

private func makeJob(
    status: CodexReviewMonitorJobStatus,
    targetSummary: String,
    summary: String? = nil,
    reasoningSummaryText: String = "",
    activityLogText: String = "",
    rawLogText: String = ""
) -> CodexReviewMonitorJob {
    CodexReviewMonitorJob(
        id: UUID().uuidString,
        sessionID: "session-1",
        cwd: "/tmp/repo",
        targetSummary: targetSummary,
        model: "gpt-5",
        threadID: status == .queued ? nil : UUID().uuidString,
        turnID: UUID().uuidString,
        status: status,
        startedAt: Date(),
        endedAt: status.isTerminal ? Date() : nil,
        summary: summary ?? status.displayText,
        reviewLogText: activityLogText,
        reasoningLogText: reasoningSummaryText,
        rawLogText: rawLogText
    )
}
