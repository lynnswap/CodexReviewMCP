import Foundation
import Testing
@testable import ReviewHTTPServer

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
