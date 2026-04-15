import CodexReviewModel
import Foundation
import ReviewCore
import ReviewHTTPServer

@MainActor
struct CodexAuthRuntimeState {
    var serverIsRunning: Bool
    var runtimeGeneration: Int

    static let stopped = Self(
        serverIsRunning: false,
        runtimeGeneration: 0
    )
}

@MainActor
package final class CodexAuthController: CodexReviewAuthControlling {
    private let authManager: ReviewAuthManager
    private let accountSessionController: CodexAccountSessionController
    private let runtimeState: @MainActor @Sendable () -> CodexAuthRuntimeState
    private let recycleServerIfRunning: @MainActor @Sendable () async -> Void
    private var refreshTask: Task<Void, Never>?
    private var refreshTaskID: UUID?
    private var authenticationCancellationRestoreState: AuthPresentationSnapshot?

    init(
        configuration: ReviewServerConfiguration,
        appServerManager: any AppServerManaging,
        authSessionFactory: @escaping @Sendable () async throws -> any ReviewAuthSession,
        runtimeState: @escaping @MainActor @Sendable () -> CodexAuthRuntimeState,
        recycleServerIfRunning: @escaping @MainActor @Sendable () async -> Void
    ) {
        authManager = ReviewAuthManager(
            configuration: .init(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment
            ),
            sessionFactory: authSessionFactory
        )
        accountSessionController = CodexAccountSessionController(
            appServerManager: appServerManager
        )
        self.runtimeState = runtimeState
        self.recycleServerIfRunning = recycleServerIfRunning
    }

    package func startStartupRefresh(auth: CodexReviewAuthModel) {
        cancelStartupRefresh()
        let refreshID = UUID()
        refreshTaskID = refreshID
        refreshTask = Task { @MainActor [weak self, weak auth] in
            guard let self, let auth else {
                return
            }
            await self.refreshResolvedState(auth: auth)
            if self.refreshTaskID == refreshID {
                self.refreshTask = nil
                self.refreshTaskID = nil
            }
        }
    }

    package func cancelStartupRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskID = nil
    }

    package func refresh(auth: CodexReviewAuthModel) async {
        cancelStartupRefresh()
        await refreshResolvedState(auth: auth)
    }

    package func beginAuthentication(auth: CodexReviewAuthModel) async {
        cancelStartupRefresh()
        let priorSnapshot = snapshot(from: auth)
        authenticationCancellationRestoreState = priorSnapshot
        defer {
            authenticationCancellationRestoreState = nil
        }

        do {
            try await authManager.beginAuthentication { state in
                await MainActor.run {
                    _ = applyReviewAuthState(state, to: auth)
                }
            }
            let identityChanged = priorSnapshot.account?.email != auth.account?.email
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: identityChanged,
                forceRestartSession: auth.isAuthenticated,
                forceRecycleServer: auth.isAuthenticated
            )
        } catch ReviewAuthError.cancelled {
            restore(auth: auth, from: priorSnapshot)
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: false
            )
        } catch {
            updateAuthenticationFailureState(error, auth: auth)
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: false
            )
        }
    }

    package func cancelAuthentication(auth: CodexReviewAuthModel) async {
        let restoreState = authenticationCancellationRestoreState ?? snapshot(from: auth)
        await authManager.cancelAuthentication()
        restore(auth: auth, from: restoreState)
        await reconcileAfterResolvedAuthState(
            auth: auth,
            identityChanged: false
        )
    }

    package func logout(auth: CodexReviewAuthModel) async {
        cancelStartupRefresh()
        if auth.isAuthenticating {
            await cancelAuthentication(auth: auth)
        }
        do {
            let state = try await authManager.logout()
            let identityChanged = applyReviewAuthState(state, to: auth)
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: identityChanged,
                forceRestartSession: state.isAuthenticated
            )
        } catch let error as ReviewAuthError {
            await resolveLogoutFailureState(
                auth: auth,
                message: error.errorDescription ?? "Failed to sign out."
            )
        } catch {
            await resolveLogoutFailureState(
                auth: auth,
                message: error.localizedDescription
            )
        }
    }

    package func reconcileAuthenticatedSession(
        auth: CodexReviewAuthModel,
        serverIsRunning: Bool,
        runtimeGeneration: Int
    ) async {
        await accountSessionController.reconcile(
            serverIsRunning: serverIsRunning,
            account: auth.account,
            runtimeGeneration: runtimeGeneration
        )
    }

    private func refreshResolvedState(auth: CodexReviewAuthModel) async {
        do {
            let state = try await authManager.loadState()
            if auth.isAuthenticating {
                return
            }
            let identityChanged = applyReviewAuthState(state, to: auth)
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: identityChanged,
                forceRestartSession: state.isAuthenticated
            )
        } catch {
            guard auth.isAuthenticating == false else {
                return
            }
            if auth.isAuthenticated {
                auth.updatePhase(.failed(message: error.localizedDescription))
            } else {
                auth.updatePhase(.signedOut)
                auth.updateAccount(nil)
            }
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: false
            )
        }
    }

    private func reconcileAfterResolvedAuthState(
        auth: CodexReviewAuthModel,
        identityChanged: Bool,
        forceRestartSession: Bool = false,
        forceRecycleServer: Bool = false
    ) async {
        let currentRuntimeState = runtimeState()
        if currentRuntimeState.serverIsRunning,
           identityChanged || forceRestartSession
        {
            await accountSessionController.reconcile(
                serverIsRunning: false,
                account: auth.account,
                runtimeGeneration: currentRuntimeState.runtimeGeneration
            )
            if identityChanged || forceRecycleServer {
                await recycleServerIfRunning()
            }
        }

        let resolvedRuntimeState = runtimeState()
        await accountSessionController.reconcile(
            serverIsRunning: resolvedRuntimeState.serverIsRunning,
            account: auth.account,
            runtimeGeneration: resolvedRuntimeState.runtimeGeneration
        )
    }

    private func updateAuthenticationFailureState(
        _ error: Error,
        auth: CodexReviewAuthModel
    ) {
        let message: String
        if let error = error as? ReviewAuthError {
            message = error.errorDescription ?? "Authentication failed."
        } else {
            message = error.localizedDescription
        }
        auth.updatePhase(.failed(message: message))
    }

    private func resolveLogoutFailureState(
        auth: CodexReviewAuthModel,
        message: String
    ) async {
        if let resolvedState = try? await authManager.loadState() {
            let identityChanged = applyReviewAuthState(resolvedState, to: auth)
            if auth.isAuthenticated {
                auth.updatePhase(.failed(message: message))
            }
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: identityChanged,
                forceRestartSession: auth.isAuthenticated
            )
            return
        }

        auth.updatePhase(.failed(message: message))
        await reconcileAfterResolvedAuthState(
            auth: auth,
            identityChanged: false
        )
    }
}

@MainActor
private final class CodexAccountSessionController {
    private struct AttachmentTarget: Equatable {
        var accountID: ObjectIdentifier
        var runtimeGeneration: Int
    }

    private let appServerManager: any AppServerManaging
    private var activeTarget: AttachmentTarget?
    private var observerTask: Task<Void, Never>?
    private var observerTransport: (any AppServerSessionTransport)?
    private var retryTask: Task<Void, Never>?

    init(appServerManager: any AppServerManaging) {
        self.appServerManager = appServerManager
    }

    func reconcile(
        serverIsRunning: Bool,
        account: CodexAccount?,
        runtimeGeneration: Int
    ) async {
        let desiredTarget = account.map {
            AttachmentTarget(
                accountID: ObjectIdentifier($0),
                runtimeGeneration: runtimeGeneration
            )
        }

        let shouldAttach = serverIsRunning && desiredTarget != nil
        if shouldAttach == false || desiredTarget != activeTarget {
            await detach()
            activeTarget = shouldAttach ? desiredTarget : nil
        }

        guard shouldAttach,
              let account,
              let target = activeTarget,
              observerTask == nil,
              observerTransport == nil,
              retryTask == nil
        else {
            return
        }

        await attach(account: account, target: target)
    }

    private func detach() async {
        retryTask?.cancel()
        retryTask = nil
        let task = observerTask
        observerTask = nil
        let transport = observerTransport
        observerTransport = nil
        task?.cancel()
        if let transport {
            await transport.close()
        }
    }

    private func attach(
        account: CodexAccount,
        target: AttachmentTarget
    ) async {
        do {
            let transport = try await appServerManager.checkoutAuthTransport()
            guard isCurrent(target: target, account: account) else {
                await transport.close()
                return
            }
            observerTransport = transport
            observerTask = Task { @MainActor [weak self, weak account] in
                guard let self, let account else {
                    return
                }
                await self.runObservation(
                    account: account,
                    target: target,
                    transport: transport
                )
            }
        } catch {
            scheduleRetry(account: account, target: target)
        }
    }

    private func runObservation(
        account: CodexAccount,
        target: AttachmentTarget,
        transport: any AppServerSessionTransport
    ) async {
        var shouldRetry = false
        defer {
            Task {
                await transport.close()
            }
            finishObservation(target: target)
            if shouldRetry {
                scheduleRetry(account: account, target: target)
            }
        }

        let session = SharedAppServerReviewAuthSession(transport: transport)
        let subscription = await session.notificationStream()
        defer {
            Task {
                await subscription.cancel()
            }
        }

        do {
            let response = try await session.readRateLimits()
            guard isCurrent(target: target, account: account) else {
                return
            }
            applyRateLimits(from: response, to: account)
        } catch let error as AppServerResponseError where error.isUnsupportedMethod {
            guard isCurrent(target: target, account: account) else {
                return
            }
            account.clearRateLimits()
        } catch let error as AppServerResponseError where error.isRateLimitAuthenticationRequired {
            guard isCurrent(target: target, account: account) else {
                return
            }
            account.clearRateLimits()
            return
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(target: target, account: account) else {
                return
            }
            shouldRetry = true
            return
        }

        guard isCurrent(target: target, account: account) else {
            return
        }

        do {
            for try await notification in subscription.stream {
                guard case .accountRateLimitsUpdated(let payload) = notification else {
                    continue
                }
                guard isCurrent(target: target, account: account) else {
                    return
                }
                guard isCodexRateLimit(payload.rateLimits.limitID) else {
                    continue
                }
                applyRateLimits(from: payload.rateLimits, to: account)
            }
            guard isCurrent(target: target, account: account) else {
                return
            }
            shouldRetry = true
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(target: target, account: account),
                  shouldRetryRateLimitObservation(after: error)
            else {
                return
            }
            shouldRetry = true
        }
    }

    private func finishObservation(target: AttachmentTarget) {
        guard activeTarget == target else {
            return
        }
        observerTask = nil
        observerTransport = nil
    }

    private func scheduleRetry(
        account: CodexAccount,
        target: AttachmentTarget
    ) {
        guard activeTarget == target,
              retryTask == nil
        else {
            return
        }

        retryTask = Task { @MainActor [weak self, weak account] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, let account else {
                return
            }
            self.retryTask = nil
            guard self.isCurrent(target: target, account: account) else {
                return
            }
            await self.attach(account: account, target: target)
        }
    }

    private func isCurrent(
        target: AttachmentTarget,
        account: CodexAccount
    ) -> Bool {
        activeTarget == target && ObjectIdentifier(account) == target.accountID
    }
}

private struct AuthPresentationSnapshot {
    var phase: CodexReviewAuthModel.Phase
    var account: ReviewAuthAccount?
}

@MainActor
private func snapshot(from auth: CodexReviewAuthModel) -> AuthPresentationSnapshot {
    .init(
        phase: auth.phase,
        account: auth.account.map(makeReviewAuthAccount)
    )
}

@MainActor
private func restore(
    auth: CodexReviewAuthModel,
    from snapshot: AuthPresentationSnapshot
) {
    auth.updatePhase(snapshot.phase)
    if let account = snapshot.account {
        _ = applyReviewAuthAccount(account, to: auth)
    } else {
        auth.updateAccount(nil)
    }
}

@MainActor
@discardableResult
private func applyReviewAuthState(
    _ state: ReviewAuthState,
    to auth: CodexReviewAuthModel
) -> Bool {
    switch state {
    case .signedOut:
        let hadAccount = auth.account != nil
        auth.updatePhase(.signedOut)
        auth.updateAccount(nil)
        return hadAccount
    case .signingIn(let progress):
        auth.updatePhase(.signingIn(makeAuthProgress(progress)))
        return false
    case .failed(let message):
        auth.updatePhase(.failed(message: message))
        return false
    case .signedIn(let account):
        let identityChanged = applyReviewAuthAccount(account, to: auth)
        auth.updatePhase(.signedOut)
        return identityChanged
    }
}

@MainActor
@discardableResult
private func applyReviewAuthAccount(
    _ account: ReviewAuthAccount,
    to auth: CodexReviewAuthModel
) -> Bool {
    let priorEmail = auth.account?.email
    if let existingAccount = auth.account,
       existingAccount.email == account.email
    {
        existingAccount.updatePlanType(account.planType)
    } else {
        auth.updateAccount(makeCodexAccount(account))
    }
    return priorEmail != auth.account?.email
}

@MainActor
private func makeCodexAccount(_ account: ReviewAuthAccount) -> CodexAccount {
    CodexAccount(
        email: account.email,
        planType: account.planType
    )
}

@MainActor
private func makeReviewAuthAccount(_ account: CodexAccount) -> ReviewAuthAccount {
    .init(
        email: account.email,
        planType: account.planType
    )
}

private func makeAuthProgress(_ progress: ReviewAuthProgress) -> CodexReviewAuthModel.Progress {
    .init(
        title: progress.title,
        detail: progress.detail,
        browserURL: progress.browserURL
    )
}

private func normalizedRateLimitID(_ limitID: String?) -> String {
    guard let limitID, limitID.isEmpty == false else {
        return "codex"
    }
    return limitID
}

private func isCodexRateLimit(_ limitID: String?) -> Bool {
    normalizedRateLimitID(limitID) == "codex"
}

@MainActor
private func applyRateLimits(
    from response: AppServerAccountRateLimitsResponse,
    to account: CodexAccount
) {
    applyRateLimits(
        from: resolvedCodexSnapshot(from: response),
        to: account
    )
}

@MainActor
private func applyRateLimits(
    from snapshot: AppServerRateLimitSnapshotPayload?,
    to account: CodexAccount
) {
    account.updateRateLimits(rateLimits(from: snapshot))
}

private func resolvedCodexSnapshot(
    from response: AppServerAccountRateLimitsResponse
) -> AppServerRateLimitSnapshotPayload? {
    if isCodexRateLimit(response.rateLimits.limitID) {
        return response.rateLimits
    }

    guard let rateLimitsByLimitID = response.rateLimitsByLimitID else {
        return nil
    }

    if let codexSnapshot = rateLimitsByLimitID["codex"] {
        return codexSnapshot
    }

    for (limitID, snapshot) in rateLimitsByLimitID {
        if isCodexRateLimit(limitID) || isCodexRateLimit(snapshot.limitID) {
            return snapshot
        }
    }

    return nil
}

private func rateLimits(
    from snapshot: AppServerRateLimitSnapshotPayload?
) -> [(windowDurationMinutes: Int, usedPercent: Int, resetsAt: Date?)] {
    var resolved: [(windowDurationMinutes: Int, usedPercent: Int, resetsAt: Date?)] = []

    if let primary = snapshot?.primary,
       let duration = primary.windowDurationMins
    {
        resolved.append((
            windowDurationMinutes: duration,
            usedPercent: primary.usedPercent,
            resetsAt: primary.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        ))
    }

    if let secondary = snapshot?.secondary,
       let duration = secondary.windowDurationMins
    {
        resolved.append((
            windowDurationMinutes: duration,
            usedPercent: secondary.usedPercent,
            resetsAt: secondary.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        ))
    }

    return resolved
}

private func shouldRetryRateLimitObservation(after error: Error) -> Bool {
    let message = error.localizedDescription.lowercased()
    return message.contains("disconnected") || message.contains("closed")
}

private extension AppServerResponseError {
    var isRateLimitAuthenticationRequired: Bool {
        message.range(
            of: "authentication required to read rate limits",
            options: [.caseInsensitive]
        ) != nil
    }
}
