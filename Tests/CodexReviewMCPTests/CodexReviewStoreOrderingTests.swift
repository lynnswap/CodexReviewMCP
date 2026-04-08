import Foundation
import Testing
@_spi(Testing) @testable import CodexReviewMCP
@_spi(Testing) @testable import CodexReviewModel
@testable import ReviewJobs
@testable import ReviewRuntime

@Suite
@MainActor
struct CodexReviewStoreOrderingTests {
    @Test func reorderingWorkspacesAndJobsUpdatesDisplayedArrayOrder() {
        let store = CodexReviewStore(configuration: .init())
        let alphaFirstJob = makeJob(
            id: "job-alpha-1",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Alpha 1"
        )
        let alphaSecondJob = makeJob(
            id: "job-alpha-2",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Alpha 2"
        )
        let betaJob = makeJob(
            id: "job-beta-1",
            cwd: "/tmp/workspace-beta",
            targetSummary: "Beta 1"
        )
        let alphaWorkspace = CodexReviewWorkspace(
            cwd: "/tmp/workspace-alpha",
            jobs: [alphaFirstJob, alphaSecondJob]
        )
        let betaWorkspace = CodexReviewWorkspace(
            cwd: "/tmp/workspace-beta",
            jobs: [betaJob]
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [alphaWorkspace, betaWorkspace]
        )

        store.reorderWorkspace(cwd: betaWorkspace.cwd, toIndex: 0)
        store.reorderJob(id: alphaSecondJob.id, inWorkspace: alphaWorkspace.cwd, toIndex: 0)

        #expect(store.workspaces.map(\.cwd) == [
            "/tmp/workspace-beta",
            "/tmp/workspace-alpha",
        ])
        #expect(alphaWorkspace.jobs.map(\.id) == ["job-alpha-2", "job-alpha-1"])
    }

    @Test func enqueueingIntoExistingWorkspaceInsertsNewJobAtHead() throws {
        let store = CodexReviewStore(configuration: .init())
        let alphaJob = makeJob(
            id: "job-alpha-1",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Alpha 1"
        )
        let betaJob = makeJob(
            id: "job-beta-1",
            cwd: "/tmp/workspace-beta",
            targetSummary: "Beta 1"
        )
        let alphaWorkspace = CodexReviewWorkspace(
            cwd: alphaJob.cwd,
            jobs: [alphaJob]
        )
        let betaWorkspace = CodexReviewWorkspace(
            cwd: betaJob.cwd,
            jobs: [betaJob]
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [alphaWorkspace, betaWorkspace]
        )

        let newJobID = try store.enqueueReview(
            sessionID: "session-1",
            request: .init(
                cwd: alphaWorkspace.cwd,
                target: .uncommittedChanges
            )
        )

        #expect(alphaWorkspace.jobs.map(\.id) == [newJobID, "job-alpha-1"])
        #expect(store.workspaces.map(\.cwd) == [
            "/tmp/workspace-alpha",
            "/tmp/workspace-beta",
        ])
    }

    @Test func removingLastJobDeletesEmptyWorkspace() throws {
        let store = CodexReviewStore(configuration: .init())
        let alphaJob = makeJob(
            id: "job-alpha-1",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Alpha 1"
        )
        let betaJob = makeJob(
            id: "job-beta-1",
            cwd: "/tmp/workspace-beta",
            targetSummary: "Beta 1"
        )
        let alphaWorkspace = CodexReviewWorkspace(
            cwd: alphaJob.cwd,
            jobs: [alphaJob]
        )
        let betaWorkspace = CodexReviewWorkspace(
            cwd: betaJob.cwd,
            jobs: [betaJob]
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [alphaWorkspace, betaWorkspace]
        )

        let queuedJobID = try store.enqueueReview(
            sessionID: "session-1",
            request: .init(
                cwd: "/tmp/workspace-gamma",
                target: .uncommittedChanges
            )
        )
        #expect(store.workspaces.map(\.cwd) == [
            "/tmp/workspace-gamma",
            "/tmp/workspace-alpha",
            "/tmp/workspace-beta",
        ])

        store.discardQueuedOrRunningJob(jobID: queuedJobID)

        #expect(store.workspaces.map(\.cwd) == [
            "/tmp/workspace-alpha",
            "/tmp/workspace-beta",
        ])
    }
}

@MainActor
private func makeJob(
    id: String,
    cwd: String,
    targetSummary: String
) -> CodexReviewJob {
    CodexReviewJob.makeForTesting(
        id: id,
        cwd: cwd,
        targetSummary: targetSummary,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 100),
        summary: "Running."
    )
}
