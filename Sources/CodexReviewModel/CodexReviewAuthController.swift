import Foundation

@MainActor
package protocol CodexReviewAuthControlling: AnyObject {
    func startStartupRefresh(auth: CodexReviewAuthModel)
    func cancelStartupRefresh()
    func refresh(auth: CodexReviewAuthModel) async
    func beginAuthentication(auth: CodexReviewAuthModel) async
    func cancelAuthentication(auth: CodexReviewAuthModel) async
    func switchAccount(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async throws
    func removeAccount(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async throws
    func reorderSavedAccount(
        auth: CodexReviewAuthModel,
        accountKey: String,
        toIndex: Int
    ) async throws
    func signOutActiveAccount(auth: CodexReviewAuthModel) async throws
    func refreshSavedAccountRateLimits(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async
    func reconcileAuthenticatedSession(
        auth: CodexReviewAuthModel,
        serverIsRunning: Bool,
        runtimeGeneration: Int
    ) async
}

extension CodexReviewAuthControlling {
    package func switchAccount(
        auth _: CodexReviewAuthModel,
        accountKey _: String
    ) async throws {}

    package func removeAccount(
        auth _: CodexReviewAuthModel,
        accountKey _: String
    ) async throws {}

    package func reorderSavedAccount(
        auth: CodexReviewAuthModel,
        accountKey: String,
        toIndex: Int
    ) async throws {
        var reorderedAccounts = auth.savedAccounts
        guard let sourceIndex = reorderedAccounts.firstIndex(where: { $0.accountKey == accountKey }) else {
            return
        }

        let destinationIndex = max(0, min(toIndex, reorderedAccounts.count - 1))
        guard sourceIndex != destinationIndex else {
            return
        }

        let account = reorderedAccounts.remove(at: sourceIndex)
        reorderedAccounts.insert(account, at: destinationIndex)
        auth.updateSavedAccounts(reorderedAccounts)
    }

    package func signOutActiveAccount(auth: CodexReviewAuthModel) async throws {
        auth.updatePhase(.signedOut)
        auth.updateAccount(nil)
        auth.updateSavedAccounts([])
    }

    package func refreshSavedAccountRateLimits(
        auth _: CodexReviewAuthModel,
        accountKey _: String
    ) async {}
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

    package func reconcileAuthenticatedSession(
        auth _: CodexReviewAuthModel,
        serverIsRunning _: Bool,
        runtimeGeneration _: Int
    ) async {}
}
