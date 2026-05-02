import Foundation

@MainActor
package struct CodexAuthRuntimeState {
    package var serverIsRunning: Bool
    package var runtimeGeneration: Int

    package init(
        serverIsRunning: Bool,
        runtimeGeneration: Int
    ) {
        self.serverIsRunning = serverIsRunning
        self.runtimeGeneration = runtimeGeneration
    }

    package static let stopped = Self(
        serverIsRunning: false,
        runtimeGeneration: 0
    )
}

@MainActor
package enum CodexAuthRuntimeEffect {
    case none
    case recycleNow(accountKey: String, runtimeGeneration: Int)
    case deferRecycleUntilJobsDrain(accountKey: String, runtimeGeneration: Int)
}

@MainActor
package protocol ReviewMonitorAuthRuntimeManaging: AnyObject {
    var authRuntimeState: CodexAuthRuntimeState { get }

    func recycleSharedAppServerAfterAuthChange() async

    func resolveAddAccountRuntimeEffect(
        accountKey: String,
        runtimeGeneration: Int
    ) -> CodexAuthRuntimeEffect

    func applyAddAccountRuntimeEffect(
        _ effect: CodexAuthRuntimeEffect,
        auth: CodexReviewAuthModel
    ) async

    func cancelRunningJobs(reason: String) async throws
}
