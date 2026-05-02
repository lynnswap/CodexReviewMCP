import Foundation
import Testing
import ReviewApplicationDependencies
import ReviewTestSupport
@testable import ReviewDomain
@testable import ReviewAppServerIntegration
@testable import ReviewInfrastructure
@testable import ReviewMCPAdapter

@Suite(.serialized)
struct AppServerReviewEngineTests {
    @Test func reviewStartedCallbackRunsBeforeBootstrapTransportIsCleared() async throws {
        let sessionID = "session-callback-order"
        let jobID = "job-callback-order"
        let environment = try isolatedReviewEngineEnvironment()
        let clock = ManualTestClock()
        let coreDependencies = ReviewCoreDependencies(
            environment: environment,
            fileSystem: .live,
            process: .live,
            clock: clock
        )
        let manager = MockAppServerManager { _ in .longRunning() }
        let engine = AppServerReviewEngine(
            configuration: .init(
                environment: environment,
                coreDependencies: coreDependencies
            ),
            appServerManager: manager
        )
        let recorder = BootstrapTransportRecorder()

        let reviewTask = Task {
            try await engine.runReview(
                jobID: jobID,
                sessionID: sessionID,
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommittedChanges
                ),
                resolvedModelHint: nil,
                stateChangeStream: AsyncStream { _ in },
                onStart: { _ in },
                onReviewStarted: {
                    let interrupted = await engine.interruptReview(jobID: jobID)
                    await recorder.record(interrupted)
                },
                onEvent: { _ in },
                requestedTerminationReason: { nil as ReviewTerminationReason? }
            )
        }

        let interruptedDuringCallback = await recorder.waitForInterruptResult()
        if interruptedDuringCallback == false {
            let transport = try #require(await manager.transport(for: sessionID))
            await transport.close()
        }
        await clock.sleepUntilSuspendedBy()
        clock.advance(by: .seconds(2))
        _ = try? await reviewTask.value

        #expect(interruptedDuringCallback)
    }
}

private actor BootstrapTransportRecorder {
    private let signal = AsyncSignal()
    private var interrupted: Bool?

    func record(_ interrupted: Bool) async {
        self.interrupted = interrupted
        await signal.signal()
    }

    func waitForInterruptResult() async -> Bool {
        await signal.wait()
        return interrupted ?? false
    }
}

private func isolatedReviewEngineEnvironment() throws -> [String: String] {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return ["HOME": url.path]
}
