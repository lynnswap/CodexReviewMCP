import Foundation

extension CodexReviewStore {
    @_spi(Testing)
    public func loadForTesting(
        serverState: CodexReviewServerState,
        serverURL: URL? = nil,
        workspaces: [CodexReviewWorkspace]
    ) {
        precondition(
            backend.isActive == false,
            "loadForTesting must be called before the embedded server starts."
        )
        self.serverState = serverState
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
