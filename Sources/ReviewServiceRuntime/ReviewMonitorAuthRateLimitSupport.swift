import Foundation
import ReviewApplication
import ReviewAppServerAdapter
import ReviewDomain
import ReviewPlatform

@MainActor
final class ActiveAccountRateLimitObserver {
    typealias AccountResolver = @MainActor @Sendable (String) -> [CodexAccount]

    private struct AttachmentTarget: Equatable {
        var accountKey: String
        var runtimeGeneration: Int
    }

    private enum RateLimitsReadCapability {
        case unknown
        case supported
        case unsupported
        case authenticationRequired
    }

    private let appServerManager: any AppServerManaging
    private let accountRegistryStore: ReviewAccountRegistryStore
    private let clock: any ReviewClock
    private let staleRefreshInterval: Duration
    private var activeTarget: AttachmentTarget?
    private var observerTask: Task<Void, Never>?
    private var observerTransport: (any AppServerSessionTransport)?
    private var retryTask: Task<Void, Never>?
    private var staleRefreshTask: Task<Void, Never>?
    private var staleRefreshTaskID: UUID?
    private var rateLimitsReadCapability: RateLimitsReadCapability = .unknown
    private var accountResolver: AccountResolver?

    init(
        appServerManager: any AppServerManaging,
        accountRegistryStore: ReviewAccountRegistryStore,
        clock: any ReviewClock = ContinuousClock(),
        staleRefreshInterval: Duration = .seconds(60)
    ) {
        self.appServerManager = appServerManager
        self.accountRegistryStore = accountRegistryStore
        self.clock = clock
        self.staleRefreshInterval = staleRefreshInterval
    }

    func reconcile(
        serverIsRunning: Bool,
        accountKey: String?,
        runtimeGeneration: Int,
        accountResolver: @escaping AccountResolver
    ) async {
        let desiredTarget = accountKey.map {
            AttachmentTarget(
                accountKey: $0,
                runtimeGeneration: runtimeGeneration
            )
        }
        let targetChanged = desiredTarget != activeTarget

        let shouldAttach = serverIsRunning && desiredTarget != nil
        if shouldAttach == false || targetChanged {
            await detach()
            activeTarget = shouldAttach ? desiredTarget : nil
            if targetChanged {
                rateLimitsReadCapability = .unknown
            }
        }
        self.accountResolver = shouldAttach ? accountResolver : nil

        if desiredTarget == activeTarget,
           rateLimitsReadCapability == .authenticationRequired
        {
            return
        }

        guard shouldAttach,
              let target = activeTarget,
              observerTask == nil,
              observerTransport == nil,
              retryTask == nil
        else {
            return
        }

        await attach(target: target)
    }

    private func resolveCurrentAccounts(for target: AttachmentTarget) -> [CodexAccount] {
        accountResolver?(target.accountKey) ?? []
    }

    private func attach(
        target: AttachmentTarget
    ) async {
        guard resolveCurrentAccounts(for: target).isEmpty == false else {
            return
        }
        do {
            let transport = try await appServerManager.checkoutAuthTransport()
            guard isCurrent(target: target) else {
                await transport.close()
                return
            }
            observerTransport = transport
            observerTask = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                await self.runObservation(
                    target: target,
                    transport: transport
                )
            }
        } catch {
            scheduleRetry(target: target)
        }
    }

    private func runObservation(
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
                scheduleRetry(target: target)
            }
        }

        let session = SharedAppServerReviewAuthSession(transport: transport)
        let notificationStream = await session.notificationStream()

        do {
            let response = try await session.readRateLimits()
            guard isCurrent(target: target) else {
                return
            }
            let accounts = resolveCurrentAccounts(for: target)
            guard let persistedAccount = accounts.first
            else {
                return
            }
            rateLimitsReadCapability = .supported
            for account in accounts {
                applyRateLimits(from: response, to: account)
            }
            try? accountRegistryStore.updateSavedAccountMetadata(from: persistedAccount)
            try? accountRegistryStore.updateCachedRateLimits(from: persistedAccount)
            scheduleStaleRefresh(
                target: target,
                session: session
            )
        } catch let error as AppServerResponseError where error.isUnsupportedMethod {
            guard isCurrent(target: target) else {
                return
            }
            let accounts = resolveCurrentAccounts(for: target)
            guard let persistedAccount = accounts.first
            else {
                return
            }
            rateLimitsReadCapability = .unsupported
            for account in accounts {
                account.clearRateLimits()
                account.updateRateLimitFetchMetadata(
                    fetchedAt: Date(),
                    error: error.message
                )
            }
            try? accountRegistryStore.updateCachedRateLimits(from: persistedAccount)
        } catch let error as AppServerResponseError where error.isRateLimitAuthenticationRequired {
            guard isCurrent(target: target) else {
                return
            }
            let accounts = resolveCurrentAccounts(for: target)
            guard let persistedAccount = accounts.first
            else {
                return
            }
            rateLimitsReadCapability = .authenticationRequired
            for account in accounts {
                account.clearRateLimits()
                account.updateRateLimitFetchMetadata(
                    fetchedAt: Date(),
                    error: error.message
                )
            }
            try? accountRegistryStore.updateCachedRateLimits(from: persistedAccount)
            return
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(target: target) else {
                return
            }
            let accounts = resolveCurrentAccounts(for: target)
            guard let persistedAccount = accounts.first
            else {
                return
            }
            for account in accounts {
                account.updateRateLimitFetchMetadata(
                    fetchedAt: Date(),
                    error: error.localizedDescription
                )
            }
            try? accountRegistryStore.updateCachedRateLimits(from: persistedAccount)
            shouldRetry = true
            return
        }

        guard isCurrent(target: target) else {
            return
        }

        do {
            for try await notification in notificationStream {
                guard case .accountRateLimitsUpdated(let payload) = notification else {
                    continue
                }
                guard isCurrent(target: target) else {
                    return
                }
                let accounts = resolveCurrentAccounts(for: target)
                guard let persistedAccount = accounts.first
                else {
                    return
                }
                guard isCodexRateLimit(payload.rateLimits.limitID) else {
                    continue
                }
                for account in accounts {
                    applyRateLimits(from: payload.rateLimits, to: account)
                }
                try? accountRegistryStore.updateCachedRateLimits(from: persistedAccount)
                if rateLimitsReadCapability != .unsupported {
                    scheduleStaleRefresh(
                        target: target,
                        session: session
                    )
                }
            }
            guard isCurrent(target: target) else {
                return
            }
            shouldRetry = true
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(target: target),
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
        staleRefreshTask?.cancel()
        staleRefreshTask = nil
        staleRefreshTaskID = nil
        observerTask = nil
        observerTransport = nil
    }

    func resetAuthenticationRequiredCapabilityForAuthRecovery() {
        guard rateLimitsReadCapability == .authenticationRequired else {
            return
        }
        rateLimitsReadCapability = .unknown
    }

    func requiresAuthenticationRecoveryForCurrentSession() -> Bool {
        rateLimitsReadCapability == .authenticationRequired
    }

    private func scheduleStaleRefresh(
        target: AttachmentTarget,
        session: SharedAppServerReviewAuthSession
    ) {
        guard rateLimitsReadCapability != .unsupported else {
            return
        }
        staleRefreshTask?.cancel()
        let taskID = UUID()
        staleRefreshTaskID = taskID
        staleRefreshTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                try await self.clock.sleep(for: self.staleRefreshInterval)
            } catch {
                return
            }

            guard self.staleRefreshTaskID == taskID,
                  self.isCurrent(target: target)
            else {
                return
            }
            let accounts = self.resolveCurrentAccounts(for: target)
            guard let persistedAccount = accounts.first else {
                return
            }

            do {
                let response = try await session.readRateLimits()
                guard self.staleRefreshTaskID == taskID,
                      self.isCurrent(target: target)
                else {
                    return
                }
                let currentAccounts = self.resolveCurrentAccounts(for: target)
                guard let currentPersistedAccount = currentAccounts.first else {
                    return
                }
                self.rateLimitsReadCapability = .supported
                for account in currentAccounts {
                    applyRateLimits(from: response, to: account)
                }
                try? self.accountRegistryStore.updateCachedRateLimits(from: currentPersistedAccount)
                self.staleRefreshTask = nil
                self.staleRefreshTaskID = nil
                self.scheduleStaleRefresh(
                    target: target,
                    session: session
                )
            } catch let error as AppServerResponseError where error.isUnsupportedMethod {
                guard self.staleRefreshTaskID == taskID,
                      self.isCurrent(target: target)
                else {
                    return
                }
                self.rateLimitsReadCapability = .unsupported
                for account in accounts {
                    account.clearRateLimits()
                    account.updateRateLimitFetchMetadata(
                        fetchedAt: Date(),
                        error: error.message
                    )
                }
                try? self.accountRegistryStore.updateCachedRateLimits(from: persistedAccount)
                self.staleRefreshTask = nil
                self.staleRefreshTaskID = nil
            } catch let error as AppServerResponseError where error.isRateLimitAuthenticationRequired {
                guard self.staleRefreshTaskID == taskID,
                      self.isCurrent(target: target)
                else {
                    return
                }
                self.rateLimitsReadCapability = .authenticationRequired
                for account in accounts {
                    account.clearRateLimits()
                    account.updateRateLimitFetchMetadata(
                        fetchedAt: Date(),
                        error: error.message
                    )
                }
                try? self.accountRegistryStore.updateCachedRateLimits(from: persistedAccount)
                self.staleRefreshTask = nil
                self.staleRefreshTaskID = nil
            } catch is CancellationError {
                return
            } catch {
                guard self.staleRefreshTaskID == taskID,
                      self.isCurrent(target: target)
                else {
                    return
                }
                for account in accounts {
                    account.updateRateLimitFetchMetadata(
                        fetchedAt: Date(),
                        error: error.localizedDescription
                    )
                }
                try? self.accountRegistryStore.updateCachedRateLimits(from: persistedAccount)
                self.staleRefreshTask = nil
                self.staleRefreshTaskID = nil
                self.scheduleStaleRefresh(
                    target: target,
                    session: session
                )
            }
        }
    }

    private func scheduleRetry(
        target: AttachmentTarget
    ) {
        guard activeTarget == target,
              retryTask == nil
        else {
            return
        }

        retryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self else {
                return
            }
            self.retryTask = nil
            guard self.isCurrent(target: target) else {
                return
            }
            await self.attach(target: target)
        }
    }

    private func isCurrent(
        target: AttachmentTarget
    ) -> Bool {
        activeTarget == target
    }

    private func detach() async {
        retryTask?.cancel()
        retryTask = nil
        staleRefreshTask?.cancel()
        staleRefreshTask = nil
        staleRefreshTaskID = nil
        rateLimitsReadCapability = .unknown
        accountResolver = nil
        let task = observerTask
        observerTask = nil
        let transport = observerTransport
        observerTransport = nil
        task?.cancel()
        if let transport {
            await transport.close()
        }
    }

    func checkoutActiveRateLimitTransport() async throws -> any AppServerSessionTransport {
        try await appServerManager.checkoutAuthTransport()
    }
}

@MainActor
final class InactiveSavedAccountRateLimitScheduler {
    typealias SavedAccountsProvider = @MainActor @Sendable () -> [CodexAccount]
    typealias RefreshRateLimitsAction = @MainActor @Sendable (String) async -> Void

    private struct RefreshTarget: Equatable {
        var runtimeGeneration: Int
        var activeAccountKey: String?
        var savedAccountKeys: [String]
    }

    private let clock: any ReviewClock
    private let refreshInterval: Duration
    private let clockReferenceInstant: ContinuousClock.Instant
    private let clockReferenceDate: Date
    private var activeTarget: RefreshTarget?
    private var savedAccountsProvider: SavedAccountsProvider?
    private var refreshRateLimitsAction: RefreshRateLimitsAction?
    private var refreshTask: Task<Void, Never>?

    init(
        clock: any ReviewClock = ContinuousClock(),
        refreshInterval: Duration = .seconds(15 * 60)
    ) {
        self.clock = clock
        self.refreshInterval = refreshInterval
        clockReferenceInstant = clock.now
        clockReferenceDate = Date()
    }

    func reconcile(
        serverIsRunning: Bool,
        activeAccountKey: String?,
        runtimeGeneration: Int,
        savedAccountsProvider: @escaping SavedAccountsProvider,
        refreshRateLimits: @escaping RefreshRateLimitsAction
    ) async {
        let desiredTarget = serverIsRunning
            ? makeTarget(
                savedAccountsProvider: savedAccountsProvider,
                activeAccountKey: activeAccountKey,
                runtimeGeneration: runtimeGeneration
            )
            : nil

        if desiredTarget != activeTarget {
            await detach()
            activeTarget = desiredTarget
        }

        self.savedAccountsProvider = desiredTarget == nil ? nil : savedAccountsProvider
        refreshRateLimitsAction = desiredTarget == nil ? nil : refreshRateLimits

        guard let target = activeTarget,
              refreshTask == nil,
              currentInactiveAccounts(for: target).isEmpty == false
        else {
            return
        }

        refreshTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.runRefreshLoop(target: target)
        }
    }

    private func makeTarget(
        savedAccountsProvider: SavedAccountsProvider,
        activeAccountKey: String?,
        runtimeGeneration: Int
    ) -> RefreshTarget {
        RefreshTarget(
            runtimeGeneration: runtimeGeneration,
            activeAccountKey: activeAccountKey,
            savedAccountKeys: savedAccountsProvider().map(\.accountKey)
        )
    }

    private func runRefreshLoop(
        target: RefreshTarget
    ) async {
        defer {
            finishRefreshLoop(target: target)
        }

        await refreshInactiveAccounts(
            for: target,
            shouldRefresh: { [weak self] account in
                guard let self else {
                    return false
                }
                return self.shouldImmediatelyCatchUp(account)
            }
        )

        while isCurrent(target: target) {
            do {
                try await clock.sleep(for: refreshInterval)
            } catch {
                return
            }

            await refreshInactiveAccounts(
                for: target,
                shouldRefresh: { _ in true }
            )
        }
    }

    private func refreshInactiveAccounts(
        for target: RefreshTarget,
        shouldRefresh: (CodexAccount) -> Bool
    ) async {
        let inactiveAccounts = currentInactiveAccounts(for: target)

        for account in inactiveAccounts where shouldRefresh(account) {
            guard isCurrent(target: target),
                  let refreshRateLimitsAction
            else {
                return
            }
            await refreshRateLimitsAction(account.accountKey)
        }
    }

    private func currentInactiveAccounts(
        for target: RefreshTarget
    ) -> [CodexAccount] {
        guard isCurrent(target: target),
              let savedAccountsProvider
        else {
            return []
        }

        return savedAccountsProvider().filter {
            $0.accountKey != target.activeAccountKey
        }
    }

    private func shouldImmediatelyCatchUp(
        _ account: CodexAccount
    ) -> Bool {
        guard let lastFetchAt = account.lastRateLimitFetchAt else {
            return true
        }
        return currentDate().timeIntervalSince(lastFetchAt) > timeInterval(for: refreshInterval)
    }

    private func currentDate() -> Date {
        let elapsed = clockReferenceInstant.duration(to: clock.now)
        return clockReferenceDate.addingTimeInterval(timeInterval(for: elapsed))
    }

    private func timeInterval(
        for duration: Duration
    ) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func finishRefreshLoop(
        target: RefreshTarget
    ) {
        guard activeTarget == target else {
            return
        }

        refreshTask = nil
    }

    private func isCurrent(
        target: RefreshTarget
    ) -> Bool {
        activeTarget == target
    }

    private func detach() async {
        let task = refreshTask
        refreshTask = nil
        activeTarget = nil
        savedAccountsProvider = nil
        refreshRateLimitsAction = nil
        task?.cancel()
        if let task {
            await task.value
        }
    }
}

struct AuthPresentationSnapshot {
    var phase: CodexReviewAuthModel.Phase
    var persistedAccounts: [SavedAccountPresentationSnapshot]
    var selectedAccountKey: CodexAccount.ID?
    var selectedAccount: SavedAccountPresentationSnapshot?
    var persistedActiveAccountKey: String?
    var warningMessage: String?
    var isResolvedAuthenticated: Bool
}

struct SavedAccountPresentationSnapshot {
    var accountKey: String
    var email: String
    var planType: String?
    var rateLimits: [ReviewSavedRateLimitWindowRecord]
    var lastRateLimitFetchAt: Date?
    var lastRateLimitError: String?
}

@MainActor
func snapshot(
    from auth: CodexReviewAuthModel,
    isResolvedAuthenticated: Bool
) -> AuthPresentationSnapshot {
    .init(
        phase: auth.phase,
        persistedAccounts: auth.persistedAccounts.map(makeSavedAccountPresentationSnapshot),
        selectedAccountKey: auth.selectedAccount?.id,
        selectedAccount: auth.selectedAccount.map(makeSavedAccountPresentationSnapshot),
        persistedActiveAccountKey: auth.persistedActiveAccountKey,
        warningMessage: auth.warningMessage,
        isResolvedAuthenticated: isResolvedAuthenticated
    )
}

@MainActor
func restore(
    auth: CodexReviewAuthModel,
    from snapshot: AuthPresentationSnapshot
) {
    auth.updatePhase(snapshot.phase)
    auth.updateWarning(message: snapshot.warningMessage)
    auth.applyPersistedAccountStates(
        snapshot.persistedAccounts.map(makeSavedAccountPayload),
        activeAccountKey: snapshot.persistedActiveAccountKey
    )
    if let selectedAccountKey = snapshot.selectedAccountKey,
       let savedAccount = auth.persistedAccounts.first(where: { $0.id == selectedAccountKey })
    {
        auth.selectPersistedAccount(savedAccount.id)
    } else {
        auth.updateCurrentAccount(
            snapshot.selectedAccount.map(makeCurrentAccount)
        )
    }
}

@MainActor
func makeCurrentAccount(from snapshot: SavedAccountPresentationSnapshot) -> CodexAccount {
    let payload = makeSavedAccountPayload(snapshot)
    let account = CodexAccount(
        accountKey: payload.accountKey,
        email: payload.email,
        planType: payload.planType
    )
    account.apply(payload)
    return account
}

@MainActor
func makeReviewAuthAccount(_ account: CodexAccount) -> ReviewAuthAccount {
    .init(
        email: account.email,
        planType: account.planType
    )
}

@MainActor
func makeSavedAccountPresentationSnapshot(_ account: CodexAccount) -> SavedAccountPresentationSnapshot {
    .init(
        accountKey: account.accountKey,
        email: account.email,
        planType: account.planType,
        rateLimits: account.rateLimits.map {
            .init(
                windowDurationMinutes: $0.windowDurationMinutes,
                usedPercent: $0.usedPercent,
                resetsAt: $0.resetsAt
            )
        },
        lastRateLimitFetchAt: account.lastRateLimitFetchAt,
        lastRateLimitError: account.lastRateLimitError
    )
}

@MainActor
func makeSavedAccountPayload(_ snapshot: SavedAccountPresentationSnapshot) -> CodexSavedAccountPayload {
    .init(
        accountKey: snapshot.accountKey,
        email: snapshot.email,
        planType: snapshot.planType,
        rateLimits: snapshot.rateLimits.map {
            (
                windowDurationMinutes: $0.windowDurationMinutes,
                usedPercent: $0.usedPercent,
                resetsAt: $0.resetsAt
            )
        },
        lastRateLimitFetchAt: snapshot.lastRateLimitFetchAt,
        lastRateLimitError: snapshot.lastRateLimitError
    )
}

@MainActor
@discardableResult
func applyResolvedReviewAuthState(
    _ state: ReviewAuthState,
    activeAccountKey: String?,
    priorResolvedAuthenticatedAccount: Bool,
    preferActiveAccountSelection: Bool,
    to auth: CodexReviewAuthModel
) -> Bool {
    switch state {
    case .signedOut:
        auth.updatePhase(.signedOut)
        auth.selectPersistedAccount(nil)
        return priorResolvedAuthenticatedAccount
    case .signingIn(let progress):
        auth.updatePhase(.signingIn(makeAuthProgress(progress)))
        return false
    case .failed(let message):
        auth.updatePhase(.failed(message: message))
        return false
    case .signedIn(let account):
        let identityChanged = applyReviewAuthAccount(
            account,
            activeAccountKey: activeAccountKey,
            preferActiveAccountSelection: preferActiveAccountSelection,
            to: auth
        )
        auth.updatePhase(.signedOut)
        return identityChanged
    }
}

@MainActor
@discardableResult
func applyReviewAuthAccount(
    _ account: ReviewAuthAccount,
    activeAccountKey: String?,
    preferActiveAccountSelection: Bool,
    to auth: CodexReviewAuthModel
) -> Bool {
    let priorAccount = auth.selectedAccount
    if preferActiveAccountSelection,
       activeAccountKey == nil
    {
        auth.selectPersistedAccount(nil)
        return didAccountIdentityChange(from: priorAccount, to: nil)
    }
    let normalizedEmail = normalizedReviewAccountEmail(email: account.email)

    if let activeAccountKey,
       activeAccountKey == normalizedEmail,
       let existingAccount = auth.persistedAccounts.first(where: { $0.accountKey == activeAccountKey })
    {
        existingAccount.updateEmail(account.email)
        existingAccount.updatePlanType(account.planType)
        auth.selectPersistedAccount(existingAccount.id)
        return didAccountIdentityChange(from: priorAccount, to: existingAccount)
    }

    if let existingAccount = auth.persistedAccounts.first(where: {
        $0.accountKey == normalizedEmail
    }) {
        existingAccount.updateEmail(account.email)
        existingAccount.updatePlanType(account.planType)
        auth.selectPersistedAccount(existingAccount.id)
        return didAccountIdentityChange(from: priorAccount, to: existingAccount)
    }

    let normalizedCurrentAccount = CodexAccount(
        accountKey: normalizedEmail,
        email: account.email,
        planType: account.planType
    )
    auth.updateCurrentAccount(normalizedCurrentAccount)
    return didAccountIdentityChange(from: priorAccount, to: normalizedCurrentAccount)
}

@MainActor
func didAccountIdentityChange(
    from previousAccount: CodexAccount?,
    to currentAccount: CodexAccount?
) -> Bool {
    switch (previousAccount, currentAccount) {
    case (.none, .none):
        return false
    case (.some, .none), (.none, .some):
        return true
    case let (previousAccount?, currentAccount?):
        return previousAccount.accountKey != currentAccount.accountKey
    }
}

@MainActor
func resolvedAccounts(
    for accountKey: String,
    in auth: CodexReviewAuthModel
) -> [CodexAccount] {
    var accounts = auth.persistedAccounts.filter { $0.accountKey == accountKey }
    if let selectedAccount = auth.selectedAccount,
       selectedAccount.accountKey == accountKey,
       accounts.contains(where: { $0 === selectedAccount }) == false
    {
        accounts.append(selectedAccount)
    }
    return accounts
}

@MainActor
func resolvedSavedAccount(
    for accountKey: String,
    in auth: CodexReviewAuthModel
) -> CodexAccount? {
    auth.persistedAccounts.first(where: { $0.accountKey == accountKey })
}

func rateLimitWindowRecords(
    from snapshot: AppServerRateLimitSnapshotPayload?
) -> [ReviewSavedRateLimitWindowRecord] {
    rateLimits(from: snapshot).map {
        .init(
            windowDurationMinutes: $0.windowDurationMinutes,
            usedPercent: $0.usedPercent,
            resetsAt: $0.resetsAt
        )
    }
}

func makeAuthProgress(_ progress: ReviewAuthProgress) -> CodexReviewAuthModel.Progress {
    .init(
        title: progress.title,
        detail: progress.detail,
        browserURL: progress.browserURL
    )
}

func normalizedRateLimitID(_ limitID: String?) -> String {
    guard let limitID, limitID.isEmpty == false else {
        return "codex"
    }
    return limitID
}

func isCodexRateLimit(_ limitID: String?) -> Bool {
    normalizedRateLimitID(limitID) == "codex"
}

@MainActor
func applyRateLimits(
    from response: AppServerAccountRateLimitsResponse,
    to account: CodexAccount
) {
    applyRateLimits(
        from: resolvedCodexSnapshot(from: response),
        to: account
    )
}

@MainActor
func applyRateLimits(
    from snapshot: AppServerRateLimitSnapshotPayload?,
    to account: CodexAccount
) {
    account.updateRateLimits(rateLimits(from: snapshot))
    account.updateRateLimitFetchMetadata(
        fetchedAt: Date(),
        error: nil
    )
}

func resolvedCodexSnapshot(
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

func rateLimits(
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

func shouldRetryRateLimitObservation(after error: Error) -> Bool {
    let message = error.localizedDescription.lowercased()
    return message.contains("disconnected") || message.contains("closed")
}

extension AppServerResponseError {
    var isRateLimitAuthenticationRequired: Bool {
        message.range(
            of: "authentication required to read rate limits",
            options: [.caseInsensitive]
        ) != nil
    }
}
