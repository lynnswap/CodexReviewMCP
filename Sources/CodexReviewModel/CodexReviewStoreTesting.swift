import Foundation

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

    @_spi(Testing)
    public func loadForTesting(
        serverState: CodexReviewServerState,
        authState: CodexReviewAuthModel.State = .signedOut,
        serverURL: URL? = nil,
        workspaces: [CodexReviewWorkspace]
    ) {
        precondition(
            backend.isActive == false,
            "loadForTesting must be called before the embedded server starts."
        )
        self.serverState = serverState
        self.auth.updateState(authState)
        self.serverURL = serverURL
        var existingByCWD: [String: CodexReviewWorkspace] = [:]
        for workspace in self.workspaces {
            existingByCWD[workspace.cwd] = workspace
        }

        var resolvedWorkspaces: [CodexReviewWorkspace] = []
        resolvedWorkspaces.reserveCapacity(workspaces.count)

        for workspace in workspaces {
            if let existingWorkspace = existingByCWD.removeValue(forKey: workspace.cwd) {
                existingWorkspace.sortOrder = workspace.sortOrder
                existingWorkspace.jobs = workspace.jobs
                resolvedWorkspaces.append(existingWorkspace)
            } else {
                resolvedWorkspaces.append(workspace)
            }
        }

        self.workspaces = resolvedWorkspaces
        writeDiagnosticsIfNeeded()
    }
}
