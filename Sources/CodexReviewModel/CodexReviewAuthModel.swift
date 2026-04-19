import Foundation
import Observation

@MainActor
@Observable
public final class CodexReviewAuthModel {
    public struct Progress: Sendable, Equatable {
        public var title: String
        public var detail: String
        public var browserURL: String?

        public init(
            title: String,
            detail: String,
            browserURL: String? = nil
        ) {
            self.title = title
            self.detail = detail
            self.browserURL = browserURL
        }
    }

    public enum Phase: Sendable, Equatable {
        case signedOut
        case signingIn(Progress)
        case failed(message: String)
    }

    public package(set) var phase: Phase = .signedOut
    public package(set) var account: CodexAccount?
    public package(set) var savedAccounts: [CodexAccount] = []
    public package(set) var authenticationFailureCount = 0
    public package(set) var warningMessage: String?

    @ObservationIgnored private let controller: any CodexReviewAuthControlling

    public var progress: Progress? {
        guard case .signingIn(let progress) = phase else {
            return nil
        }
        return progress
    }

    public var isAuthenticating: Bool {
        progress != nil
    }

    public var isAuthenticated: Bool {
        account != nil
    }

    public var hasSavedAccounts: Bool {
        savedAccounts.isEmpty == false
    }

    public var errorMessage: String? {
        guard case .failed(let message) = phase else {
            return nil
        }
        return message
    }

    package init(controller: any CodexReviewAuthControlling) {
        self.controller = controller
    }

    public func refresh() async {
        await controller.refresh(auth: self)
    }

    public func beginAuthentication() async {
        await controller.beginAuthentication(auth: self)
    }

    public func cancelAuthentication() async {
        await controller.cancelAuthentication(auth: self)
    }

    public func switchAccount(accountKey: String) async throws {
        guard account?.accountKey != accountKey else {
            return
        }
        let targetAccount = savedAccounts.first(where: { $0.accountKey == accountKey })
        if savedAccounts.contains(where: { $0.isSwitching }) {
            return
        }
        if let account,
           account.isSwitching,
           savedAccounts.contains(where: { $0 === account }) == false
        {
            return
        }
        targetAccount?.updateIsSwitching(true)
        defer {
            targetAccount?.updateIsSwitching(false)
        }
        try await controller.switchAccount(auth: self, accountKey: accountKey)
    }

    public func removeAccount(accountKey: String) async throws {
        try await controller.removeAccount(auth: self, accountKey: accountKey)
    }

    package func reorderSavedAccount(accountKey: String, toIndex: Int) async throws {
        try await controller.reorderSavedAccount(
            auth: self,
            accountKey: accountKey,
            toIndex: toIndex
        )
    }

    public func signOutActiveAccount() async throws {
        try await controller.signOutActiveAccount(auth: self)
    }

    public func logout() async {
        if isAuthenticating, account == nil {
            await cancelAuthentication()
            return
        }
        do {
            try await signOutActiveAccount()
        } catch {
            if errorMessage == nil, isAuthenticated {
                updatePhase(.failed(message: error.localizedDescription))
            }
        }
    }

    public func refreshSavedAccountRateLimits(accountKey: String) async {
        await controller.refreshSavedAccountRateLimits(auth: self, accountKey: accountKey)
    }

    package func startStartupRefresh() {
        controller.startStartupRefresh(auth: self)
    }

    package func cancelStartupRefresh() {
        controller.cancelStartupRefresh()
    }

    package func reconcileAuthenticatedSession(
        serverIsRunning: Bool,
        runtimeGeneration: Int
    ) async {
        await controller.reconcileAuthenticatedSession(
            auth: self,
            serverIsRunning: serverIsRunning,
            runtimeGeneration: runtimeGeneration
        )
    }

    package func updatePhase(_ phase: Phase) {
        self.phase = phase
    }

    package func recordAuthenticationFailure(message: String) {
        authenticationFailureCount += 1
        warningMessage = nil
        phase = .failed(message: message)
    }

    package func updateWarning(message: String?) {
        warningMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    package func updateAccount(_ account: CodexAccount?) {
        if let account,
           let savedAccount = savedAccounts.first(where: { $0.accountKey == account.accountKey })
        {
            self.account = savedAccount
        } else {
            self.account = account
        }
        let activeAccountKey = self.account?.accountKey
        for savedAccount in savedAccounts {
            savedAccount.updateIsActive(savedAccount.accountKey == activeAccountKey)
        }
    }

    package func updateSavedAccounts(_ incomingSavedAccounts: [CodexAccount]) {
        let activeAccountKey = account?.accountKey
        self.savedAccounts = incomingSavedAccounts.map { incomingAccount in
            let reconciledAccount = reusableAccount(for: incomingAccount.accountKey) ?? incomingAccount
            guard reconciledAccount !== incomingAccount else {
                reconciledAccount.updateIsActive(reconciledAccount.accountKey == activeAccountKey)
                return reconciledAccount
            }
            reconciledAccount.updateEmail(incomingAccount.email)
            reconciledAccount.updatePlanType(incomingAccount.planType)
            reconciledAccount.updateRateLimits(
                incomingAccount.rateLimits.map {
                    (
                        windowDurationMinutes: $0.windowDurationMinutes,
                        usedPercent: $0.usedPercent,
                        resetsAt: $0.resetsAt
                    )
                }
            )
            reconciledAccount.updateRateLimitFetchMetadata(
                fetchedAt: incomingAccount.lastRateLimitFetchAt,
                error: incomingAccount.lastRateLimitError
            )
            reconciledAccount.updateIsActive(reconciledAccount.accountKey == activeAccountKey)
            return reconciledAccount
        }
        if let account,
           let savedAccount = self.savedAccounts.first(where: { $0.accountKey == account.accountKey })
        {
            self.account = savedAccount
        }
    }

    private func reusableAccount(for accountKey: String) -> CodexAccount? {
        savedAccounts.first(where: { $0.accountKey == accountKey })
    }
}
