extension CodexReviewStore {
    package func reorderWorkspace(cwd: String, toIndex: Int) {
        var reorderedWorkspaces = workspaces
        guard let sourceIndex = reorderedWorkspaces.firstIndex(where: { $0.cwd == cwd }) else {
            return
        }

        let destinationIndex = max(0, min(toIndex, reorderedWorkspaces.count - 1))
        guard sourceIndex != destinationIndex else {
            return
        }

        let workspace = reorderedWorkspaces.remove(at: sourceIndex)
        reorderedWorkspaces.insert(workspace, at: destinationIndex)
        workspaces = reorderedWorkspaces
        writeDiagnosticsIfNeeded()
    }

    package func reorderJob(
        id: String,
        inWorkspace cwd: String,
        toIndex: Int
    ) {
        guard let workspace = workspaces.first(where: { $0.cwd == cwd })
        else {
            return
        }

        var reorderedJobs = workspace.jobs
        guard let sourceIndex = reorderedJobs.firstIndex(where: { $0.id == id }) else {
            return
        }

        let destinationIndex = max(0, min(toIndex, reorderedJobs.count - 1))
        guard sourceIndex != destinationIndex else {
            return
        }

        let job = reorderedJobs.remove(at: sourceIndex)
        reorderedJobs.insert(job, at: destinationIndex)
        workspace.jobs = reorderedJobs
        writeDiagnosticsIfNeeded()
    }
}
