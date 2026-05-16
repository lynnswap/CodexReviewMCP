extension CodexReviewStore {
    package func reorderWorkspace(cwd: String, toIndex: Int) {
        let ordered = orderedWorkspaces
        guard let workspace = ordered.first(where: { $0.cwd == cwd }),
              let sourceIndex = ordered.firstIndex(where: { $0 === workspace })
        else {
            return
        }

        let destinationIndex = max(0, min(toIndex, ordered.count - 1))
        guard sourceIndex != destinationIndex else {
            return
        }

        guard let sortOrder = reorderedSortOrder(
            moving: workspace,
            toIndex: destinationIndex,
            in: ordered,
            sortOrder: \.sortOrder
        ) else {
            return
        }
        workspace.sortOrder = sortOrder
        writeDiagnosticsIfNeeded()
    }

    package func reorderJob(
        id: String,
        inWorkspace cwd: String,
        toIndex: Int
    ) {
        guard workspace(cwd: cwd) != nil else {
            return
        }

        let ordered = orderedJobs(inWorkspace: cwd)
        guard let job = ordered.first(where: { $0.id == id }),
              let sourceIndex = ordered.firstIndex(where: { $0 === job })
        else {
            return
        }

        let destinationIndex = max(0, min(toIndex, ordered.count - 1))
        guard sourceIndex != destinationIndex else {
            return
        }

        guard let sortOrder = reorderedSortOrder(
            moving: job,
            toIndex: destinationIndex,
            in: ordered,
            sortOrder: \.sortOrder
        ) else {
            return
        }
        job.sortOrder = sortOrder
        writeDiagnosticsIfNeeded()
    }
}
