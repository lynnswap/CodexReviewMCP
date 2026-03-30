import Darwin
import Dispatch
import Foundation
import ReviewCore

func forceRestart(_ discovery: ReviewDiscoveryRecord) async throws {
    let pid = pid_t(discovery.pid)
    let signalResult = kill(pid, SIGTERM)
    if signalResult == -1, errno != ESRCH {
        let message = String(cString: strerror(errno))
        throw CLIError(
            message: "failed to stop existing server process \(discovery.pid): \(message)",
            exitCode: 1
        )
    }

    let timeout: Duration = .seconds(10)
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while isProcessAlive(pid), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(100))
    }

    if isProcessAlive(pid) {
        killChildProcessGroups(of: pid, signal: SIGKILL)
        _ = kill(pid, SIGKILL)
        let killDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while isProcessAlive(pid), ContinuousClock.now < killDeadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    guard isProcessAlive(pid) == false else {
        throw CLIError(
            message: "existing server process \(discovery.pid) did not stop within 12 seconds",
            exitCode: 1
        )
    }
}

private func killChildProcessGroups(of pid: pid_t, signal: Int32) {
    for childPID in childProcessIDs(of: pid) {
        _ = killpg(childPID, signal)
        _ = kill(childPID, signal)
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
