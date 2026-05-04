import Foundation
import Testing
import ReviewDomain
@testable import ReviewServiceRuntime
@_spi(Testing) @testable import ReviewApplication

@Suite(.serialized)
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

    @Test func listReviewsPreservesWorkspaceAndJobArrayOrder() {
        let store = CodexReviewStore(configuration: .init())
        let alphaFirstJob = makeJob(
            id: "job-a",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Alpha 1",
            startedAt: nil
        )
        let alphaSecondJob = makeJob(
            id: "job-c",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Alpha 2",
            startedAt: nil
        )
        let betaJob = makeJob(
            id: "job-b",
            cwd: "/tmp/workspace-beta",
            targetSummary: "Beta 1",
            startedAt: nil
        )
        let alphaWorkspace = CodexReviewWorkspace(
            cwd: alphaFirstJob.cwd,
            jobs: [alphaFirstJob, alphaSecondJob]
        )
        let betaWorkspace = CodexReviewWorkspace(
            cwd: betaJob.cwd,
            jobs: [betaJob]
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [alphaWorkspace, betaWorkspace]
        )

        let listed = store.listReviews(sessionID: "session-1")

        #expect(listed.items.map(\.jobID) == ["job-a", "job-c", "job-b"])
    }

    @Test func selectorRequiresSingleMatchingJob() {
        let store = CodexReviewStore(configuration: .init())
        let firstJob = makeJob(
            id: "job-1",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Alpha",
            startedAt: nil
        )
        let secondJob = makeJob(
            id: "job-2",
            cwd: "/tmp/workspace-beta",
            targetSummary: "Beta",
            startedAt: nil
        )
        let alphaWorkspace = CodexReviewWorkspace(
            cwd: firstJob.cwd,
            jobs: [firstJob]
        )
        let betaWorkspace = CodexReviewWorkspace(
            cwd: secondJob.cwd,
            jobs: [secondJob]
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [alphaWorkspace, betaWorkspace]
        )

        do {
            _ = try store.resolveJob(
                sessionID: "session-1",
                selector: .init(statuses: [.running])
            )
            Issue.record("Expected selector resolution to fail for multiple matches.")
        } catch let error as ReviewJobSelectionError {
            switch error {
            case .ambiguous(let candidates):
                #expect(candidates.map(\.jobID) == ["job-1", "job-2"])
            case .notFound(let message):
                Issue.record("Unexpected notFound error: \(message)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@MainActor
private func makeJob(
    id: String,
    cwd: String,
    targetSummary: String,
    sessionID: String = "session-1",
    startedAt: Date? = Date(timeIntervalSince1970: 100)
) -> CodexReviewJob {
    CodexReviewJob.makeForTesting(
        id: id,
        sessionID: sessionID,
        cwd: cwd,
        targetSummary: targetSummary,
        status: .running,
        startedAt: startedAt,
        summary: "Running."
    )
}
