import Foundation
import Testing
import MCP
@testable import ReviewInfra


@Suite
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

    @Test func reviewHTTPRequestQueueSerializesAsyncHandlers() async throws {
        let queue = ReviewHTTPRequestQueue()
        let recorder = EventRecorder()
        let gate = AsyncGate()
        let firstStarted = AsyncGate()
        let firstFinished = AsyncGate()
        let secondFinished = AsyncGate()

        queue.enqueue {
            await recorder.append("start-1")
            await firstStarted.open()
            await gate.wait()
            await recorder.append("finish-1")
            await firstFinished.open()
        }
        queue.enqueue {
            await recorder.append("start-2")
            await recorder.append("finish-2")
            await secondFinished.open()
        }

        await firstStarted.wait()
        #expect(await recorder.snapshot() == ["start-1"])

        await gate.open()
        await firstFinished.wait()
        await secondFinished.wait()
        #expect(await recorder.snapshot() == ["start-1", "finish-1", "start-2", "finish-2"])
    }

    @Test func busySessionClosureIsDeferredUntilWorkCompletes() async throws {
        let busyFlag = BusyFlag()
        let recorder = ClosedSessionRecorder()
        let app = ReviewHTTPApplication(
            configuration: .init(
                host: "localhost",
                port: 0,
                endpoint: "/mcp",
                sessionTimeoutSeconds: 3600
            ),
            serverFactory: { _, _ in
                Server(
                    name: "test",
                    version: "0",
                    capabilities: .init(resources: .init(), tools: .init())
                )
            },
            onSessionClosed: { sessionID in
                await recorder.record(sessionID)
            },
            isSessionBusy: { _ in
                await busyFlag.isBusy
            }
        )

        let response = await app.handleHTTPRequest(
            HTTPRequest(
                method: "POST",
                headers: [
                    HTTPHeaderName.accept: "application/json, text/event-stream",
                    HTTPHeaderName.contentType: "application/json",
                    HTTPHeaderName.protocolVersion: "2025-11-25",
                ],
                body: try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": [
                        "protocolVersion": "2025-11-25",
                        "capabilities": [:],
                        "clientInfo": [
                            "name": "test-client",
                            "version": "0.0.1",
                        ],
                    ],
                ]),
                path: "/mcp"
            )
        )

        let sessionID = try #require(response.headers[HTTPHeaderName.sessionID])
        await busyFlag.setBusy(true)
        await app.closeSession(sessionID)
        #expect(await recorder.snapshot().isEmpty)
        #expect(await app.hasSession(sessionID))

        await busyFlag.setBusy(false)
        await app.flushDeferredSessionClosures()
        #expect(await recorder.snapshot() == [sessionID])
        #expect(await app.hasSession(sessionID) == false)
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        guard isOpen == false else {
            return
        }
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor EventRecorder {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

private actor BusyFlag {
    private(set) var isBusy = false

    func setBusy(_ value: Bool) {
        isBusy = value
    }
}

private actor ClosedSessionRecorder {
    private var sessionIDs: [String] = []

    func record(_ sessionID: String) {
        sessionIDs.append(sessionID)
    }

    func snapshot() -> [String] {
        sessionIDs
    }
}
