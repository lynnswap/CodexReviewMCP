import Foundation
import ReviewDomain

extension CodexReviewStore {
    nonisolated(unsafe) private static var requestCancellationDelayForTestingStorage: TimeInterval = 0
    nonisolated(unsafe) package static var requestCancellationDelay: TimeInterval {
        get { requestCancellationDelayForTestingStorage }
        set { requestCancellationDelayForTestingStorage = max(0, newValue) }
    }

    @_spi(Testing)
    public static var requestCancellationDelayForTesting: TimeInterval {
        get { requestCancellationDelay }
        set { requestCancellationDelay = newValue }
    }

    package func loadForTesting(
        serverState: CodexReviewServerState,
        authPhase: CodexReviewAuthModel.Phase = .signedOut,
        account: CodexAccount? = nil,
        persistedAccounts: [CodexAccount]? = nil,
        serverURL: URL? = nil,
        workspaces: [CodexReviewWorkspace],
        settingsSnapshot: CodexReviewSettingsSnapshot? = nil
    ) {
        precondition(
            coordinator.isActive == false,
            "loadForTesting must be called before the embedded server starts."
        )
        self.serverState = serverState
        self.auth.updatePhase(authPhase)
        let resolvedPersistedAccounts = persistedAccounts ?? account.map { [$0] } ?? []
        self.auth.applyPersistedAccountStates(
            resolvedPersistedAccounts.map(savedAccountPayload(from:))
        )
        if let account,
           resolvedPersistedAccounts.contains(where: { $0.accountKey == account.accountKey })
        {
            self.auth.selectPersistedAccount(account.id)
        } else {
            self.auth.updateCurrentAccount(account)
        }
        self.serverURL = serverURL
        var existingByCWD: [String: CodexReviewWorkspace] = [:]
        for workspace in self.workspaces {
            existingByCWD[workspace.cwd] = workspace
        }

        var resolvedWorkspaces: [CodexReviewWorkspace] = []
        resolvedWorkspaces.reserveCapacity(workspaces.count)

        for workspace in workspaces {
            if let existingWorkspace = existingByCWD.removeValue(forKey: workspace.cwd) {
                existingWorkspace.jobs = workspace.jobs
                resolvedWorkspaces.append(existingWorkspace)
            } else {
                resolvedWorkspaces.append(workspace)
            }
        }

        self.workspaces = resolvedWorkspaces
        if let settingsSnapshot {
            settings.loadForTesting(snapshot: settingsSnapshot)
        }
        writeDiagnosticsIfNeeded()
    }
}
