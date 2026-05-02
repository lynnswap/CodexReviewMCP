import Darwin
import Dispatch
import Foundation
import ReviewInfrastructure

func forceRestart(_ discovery: LiveEndpointRecord) async throws {
    do {
        try await forceStopDiscoveredServerProcess(
            discovery,
            runtimeState: ReviewRuntimeStateStore.read()
        )
    } catch let error as ForcedRestartError {
        throw CLIError(
            message: error.message,
            exitCode: 1
        )
    }
}

final class ServerSignalHandler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "codex-review-mcp.signal")
    private let handler: @Sendable () -> Void
    private var sources: [DispatchSourceSignal] = []

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func start() {
        guard sources.isEmpty else {
            return
        }

        for signal in [SIGTERM, SIGINT] {
            Darwin.signal(signal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signal, queue: queue)
            source.setEventHandler(handler: handler)
            source.resume()
            sources.append(source)
        }
    }

    func cancel() {
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
    }
}
