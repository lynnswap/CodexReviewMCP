import Foundation

@MainActor
package protocol CodexReviewAuthControlling: AnyObject {
    func startStartupRefresh(auth: CodexReviewAuthModel)
    func cancelStartupRefresh()
    func refresh(auth: CodexReviewAuthModel) async
    func beginAuthentication(auth: CodexReviewAuthModel) async
    func cancelAuthentication(auth: CodexReviewAuthModel) async
    func logout(auth: CodexReviewAuthModel) async
    func reconcileAuthenticatedSession(
        auth: CodexReviewAuthModel,
        serverIsRunning: Bool,
        runtimeGeneration: Int
    ) async
}

@MainActor
package final class CodexReviewPreviewAuthController: CodexReviewAuthControlling {
    package init() {}

    package func startStartupRefresh(auth _: CodexReviewAuthModel) {}

    package func cancelStartupRefresh() {}

    package func refresh(auth: CodexReviewAuthModel) async {
        if auth.account == nil {
            auth.updatePhase(.signedOut)
        }
    }

    package func beginAuthentication(auth: CodexReviewAuthModel) async {
        auth.updatePhase(.failed(message: "Authentication is unavailable in preview mode."))
    }

    package func cancelAuthentication(auth: CodexReviewAuthModel) async {
        if auth.account == nil {
            auth.updatePhase(.signedOut)
        }
    }

    package func logout(auth: CodexReviewAuthModel) async {
        auth.updatePhase(.signedOut)
        auth.updateAccount(nil)
    }

    package func reconcileAuthenticatedSession(
        auth _: CodexReviewAuthModel,
        serverIsRunning _: Bool,
        runtimeGeneration _: Int
    ) async {}
}
