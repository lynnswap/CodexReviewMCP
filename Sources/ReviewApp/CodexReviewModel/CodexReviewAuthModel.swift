import Foundation
import Observation
import ReviewDomain

@MainActor
@Observable
public final class CodexReviewAuthModel {
    package enum PendingAccountAction {
        case switchAccount(accountKey: String)
        case signOutActiveAccount
        case removeAccount(accountKey: String)

        var confirmationTitle: String {
            switch self {
            case .switchAccount:
                "Switch Account?"
            case .signOutActiveAccount:
                "Sign Out?"
            case .removeAccount:
                "Remove Account?"
            }
        }

        var confirmationMessage: String {
            "Running review jobs may stop after the account change is applied."
        }

        var confirmationButtonTitle: String {
            switch self {
            case .switchAccount:
                "Switch"
            case .signOutActiveAccount:
                "Sign Out"
            case .removeAccount:
                "Remove"
            }
        }

        var failureTitle: String {
            switch self {
            case .switchAccount:
                "Failed to Switch Account"
            case .signOutActiveAccount:
                "Failed to Sign Out"
            case .removeAccount:
                "Failed to Remove Account"
            }
        }
    }

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
    public package(set) var isPresentingPendingAccountActionConfirmation = false
    public package(set) var pendingAccountActionConfirmationTitle = ""
    public package(set) var pendingAccountActionConfirmationMessage = ""
    public package(set) var pendingAccountActionConfirmationButtonTitle = ""
    public package(set) var isPresentingAccountActionAlert = false
    public package(set) var accountActionAlertTitle = ""
    public package(set) var accountActionAlertMessage = ""

    @ObservationIgnored private var pendingAccountAction: PendingAccountAction?

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

    package static func makePreview() -> CodexReviewAuthModel {
        .init()
    }

    package init() {}

    package func requestSwitchAccount(
        _ account: CodexAccount,
        requiresConfirmation: Bool
    ) {
        guard savedAccounts.contains(where: { $0.accountKey == account.accountKey }) else {
            return
        }
        requestAccountAction(
            .switchAccount(accountKey: account.accountKey),
            requiresConfirmation: requiresConfirmation
        )
    }

    package func requestSignOutActiveAccount(requiresConfirmation: Bool) {
        guard account != nil else {
            return
        }
        requestAccountAction(
            .signOutActiveAccount,
            requiresConfirmation: requiresConfirmation
        )
    }

    package func requestRemoveAccount(
        _ account: CodexAccount,
        requiresConfirmation: Bool
    ) {
        requestAccountAction(
            .removeAccount(accountKey: account.accountKey),
            requiresConfirmation: requiresConfirmation
        )
    }

    package func cancelPendingAccountAction() {
        clearPendingAccountActionConfirmation()
    }

    package func consumePendingAccountAction() -> PendingAccountAction? {
        let action = pendingAccountAction
        clearPendingAccountActionConfirmation()
        return action
    }

    package func presentAccountActionAlert(
        title: String,
        message: String
    ) {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        accountActionAlertTitle = title
        accountActionAlertMessage = trimmedMessage.isEmpty ? "Request failed." : trimmedMessage
        isPresentingAccountActionAlert = true
    }

    package func dismissAccountActionAlert() {
        isPresentingAccountActionAlert = false
        accountActionAlertTitle = ""
        accountActionAlertMessage = ""
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
        self.account = account
    }

    package func updateSavedAccounts(_ incomingSavedAccounts: [CodexAccount]) {
        self.savedAccounts = incomingSavedAccounts.map { incomingAccount in
            let reconciledAccount = reusableAccount(for: incomingAccount.accountKey) ?? incomingAccount
            guard reconciledAccount !== incomingAccount else {
                reconciledAccount.updateIsActive(incomingAccount.isActive)
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
            reconciledAccount.updateIsActive(incomingAccount.isActive)
            return reconciledAccount
        }
    }

    private func reusableAccount(for accountKey: String) -> CodexAccount? {
        savedAccounts.first(where: { $0.accountKey == accountKey })
    }

    private func requestAccountAction(
        _ action: PendingAccountAction,
        requiresConfirmation: Bool
    ) {
        if requiresConfirmation {
            pendingAccountAction = action
            pendingAccountActionConfirmationTitle = action.confirmationTitle
            pendingAccountActionConfirmationMessage = action.confirmationMessage
            pendingAccountActionConfirmationButtonTitle = action.confirmationButtonTitle
            isPresentingPendingAccountActionConfirmation = true
            return
        }
        clearPendingAccountActionConfirmation()
        pendingAccountAction = action
    }

    private func clearPendingAccountActionConfirmation() {
        pendingAccountAction = nil
        isPresentingPendingAccountActionConfirmation = false
        pendingAccountActionConfirmationTitle = ""
        pendingAccountActionConfirmationMessage = ""
        pendingAccountActionConfirmationButtonTitle = ""
    }

}
