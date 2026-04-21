import Foundation
import Observation

@MainActor
@Observable
public final class CodexReviewAuthModel {
    private enum PendingAccountAction {
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
    public package(set) var account: CodexAccount? {
        didSet {
            guard account?.accountKey != oldValue?.accountKey else {
                return
            }
            onAccountDidChange?()
        }
    }
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

    @ObservationIgnored private let controller: any CodexReviewAuthControlling
    @ObservationIgnored private var pendingAccountAction: PendingAccountAction?
    @ObservationIgnored package var onAccountDidChange: (@MainActor () -> Void)?

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

    package func addAccount(
        presentationFallbackAccount: CodexAccount? = nil
    ) async {
        await controller.addAccount(
            auth: self,
            presentationFallbackAccount: presentationFallbackAccount
        )
    }

    public func cancelAuthentication() async {
        await controller.cancelAuthentication(auth: self)
    }

    package func switchAccount(_ account: CodexAccount) async throws {
        guard self.account?.accountKey != account.accountKey else {
            return
        }
        let targetAccount = savedAccounts.first(where: { $0.accountKey == account.accountKey })
        if savedAccounts.contains(where: { $0.isSwitching }) {
            return
        }
        if let currentAccount = self.account,
           currentAccount.isSwitching,
           savedAccounts.contains(where: { $0 === currentAccount }) == false
        {
            return
        }
        targetAccount?.updateIsSwitching(true)
        defer {
            targetAccount?.updateIsSwitching(false)
        }
        try await controller.switchAccount(auth: self, accountKey: account.accountKey)
    }

    package func requestSwitchAccount(
        _ account: CodexAccount,
        requiresConfirmation: Bool
    ) {
        guard self.account?.accountKey != account.accountKey else {
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

    package func confirmPendingAccountAction() {
        guard let pendingAccountAction else {
            return
        }
        clearPendingAccountActionConfirmation()
        performAccountAction(pendingAccountAction)
    }

    package func cancelPendingAccountAction() {
        clearPendingAccountActionConfirmation()
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
        performAccountAction(action)
    }

    private func clearPendingAccountActionConfirmation() {
        pendingAccountAction = nil
        isPresentingPendingAccountActionConfirmation = false
        pendingAccountActionConfirmationTitle = ""
        pendingAccountActionConfirmationMessage = ""
        pendingAccountActionConfirmationButtonTitle = ""
    }

    private func performAccountAction(_ action: PendingAccountAction) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                try await executeAccountAction(action)
                if let warningMessage {
                    presentAccountActionAlert(
                        title: "Account Updated With Warning",
                        message: warningMessage
                    )
                }
            } catch {
                presentAccountActionAlert(
                    title: action.failureTitle,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func executeAccountAction(_ action: PendingAccountAction) async throws {
        switch action {
        case .switchAccount(let accountKey):
            guard let account = savedAccounts.first(where: { $0.accountKey == accountKey }) else {
                return
            }
            try await switchAccount(account)
        case .signOutActiveAccount:
            try await signOutActiveAccount()
        case .removeAccount(let accountKey):
            try await removeAccount(accountKey: accountKey)
        }
    }
}
