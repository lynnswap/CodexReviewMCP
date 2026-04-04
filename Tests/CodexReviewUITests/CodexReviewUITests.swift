import AppKit
import Foundation
import Testing
@_spi(Testing) @testable import CodexReviewModel
@testable import CodexReviewUI
import ReviewJobs
import ReviewRuntime

@Suite(.serialized)
@MainActor
struct CodexReviewUITests {
    @Test func bindingStoreAppliesInitialState() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarAccessoryCountForTesting == 1)
        #expect(viewController.contentAccessoryCountForTesting == 0)
        #expect(viewController.sidebarViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.transportViewControllerForTesting.isShowingEmptyStateForTesting)
    }

    @Test func splitViewShowsEmptyStateWithoutJobs() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        #expect(viewController.splitViewItems.count == 2)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)
        #expect(viewController.contentAccessoryCountForTesting == 0)
        #expect(viewController.sidebarViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.transportViewControllerForTesting.isShowingEmptyStateForTesting)
    }

    @Test func splitViewInstallsToolbarWithSidebarTrackingSeparator() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let viewController = ReviewMonitorSplitViewController(store: store)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }

        viewController.viewDidAppear()

        #expect(window.toolbar != nil)
        #expect(viewController.toolbarIdentifiersForTesting.contains(.toggleSidebar))
        #expect(viewController.toolbarIdentifiersForTesting.contains(.sidebarTrackingSeparator))
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .hidden)
        #expect(window.title == "Review Details")
        #expect(viewController.sidebarAllowsFullHeightLayoutForTesting)
    }

    @Test func splitViewSectionsByWorkspace() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let workspaceAlphaJob = makeJob(
            cwd: "/tmp/workspace-alpha",
            startedAt: Date(timeIntervalSince1970: 200),
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let workspaceBetaJob = makeJob(
            cwd: "/tmp/workspace-beta",
            startedAt: Date(timeIntervalSince1970: 100),
            status: .failed,
            targetSummary: "Base branch: main"
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [workspaceBetaJob, workspaceAlphaJob])
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarViewControllerForTesting.displayedSectionTitlesForTesting == [
            "workspace-alpha",
            "workspace-beta",
        ])
        #expect(viewController.splitViewItems.count == 2)
        #expect(viewController.splitViewItems[0].behavior == .sidebar)
        #expect(viewController.splitViewItems[1].behavior == .default)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)
        #expect(viewController.contentAccessoryCountForTesting == 0)
    }

    @Test func sidebarWorkspaceRowsStayExpandedAndUseExpectedCellViews() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = makeJob(
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let workspace = CodexReviewWorkspace(
            cwd: job.cwd,
            sortOrder: 1,
            jobs: [job]
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace]
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.allWorkspaceRowsExpandedForTesting)
        #expect(sidebar.workspaceIsSelectableForTesting(workspace) == false)
        #expect(sidebar.jobRowUsesReviewMonitorJobRowViewForTesting(job))
    }

    @Test func cancellingRunningJobFromSidebarMarksJobCancelled() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let startedAt = Date(timeIntervalSince1970: 200)
        let job = makeJob(
            id: "job-running",
            cwd: "/tmp/workspace-alpha",
            startedAt: startedAt,
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review."
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [job])
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        await viewController.sidebarViewControllerForTesting.cancelJobForTesting(job)

        #expect(job.status == .cancelled)
        #expect(job.summary == "Review cancelled.")
        #expect(job.errorMessage == "Cancellation requested.")
        #expect(job.startedAt == startedAt)
        #expect(job.endedAt != nil)
    }

    @Test func cancellationFailureUpdatesJobErrorState() async {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = makeJob(
            id: "job-running",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review."
        )
        let store = CodexReviewStore(backend: FailingCancellationBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [job])
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        await viewController.sidebarViewControllerForTesting.cancelJobForTesting(job)

        #expect(job.status == .running)
        #expect(job.summary == "Failed to cancel review: Cancellation failed.")
        #expect(job.errorMessage == "Cancellation failed.")
        #expect(job.endedAt == nil)
    }

    @Test func jobsPresentOnInitialLoadStayUnselected() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let activeJob = makeJob(status: .running, targetSummary: "Uncommitted changes")
        let recentJob = makeJob(status: .succeeded, targetSummary: "Commit: abc123")
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [activeJob, recentJob])
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarViewControllerForTesting.selectedJobForTesting == nil)
        #expect(viewController.transportViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.transportViewControllerForTesting.displayedTitleForTesting == nil)
    }

    @Test func selectingJobUpdatesDetailPane() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let activeJob = makeJob(status: .running, targetSummary: "Uncommitted changes", logText: "Running review\n")
        let recentJob = makeJob(
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "MCP server codex_review ready.",
            logText: "Findings ready\n"
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [activeJob, recentJob])
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)

        let _: Bool = try await waitUntilValue(timeout: .seconds(5), interval: .milliseconds(50)) {
            let transport = viewController.transportViewControllerForTesting
            guard transport.displayedTitleForTesting == recentJob.displayTitle,
                  transport.displayedSummaryForTesting == recentJob.summary,
                  transport.displayedLogForTesting == recentJob.logText
            else {
                return nil
            }
            return true
        }

        activeJob.summary = "Old selection should not render."
        activeJob.logEntries = [.init(kind: .agentMessage, text: "Old selection log")]
        try await Task.sleep(for: .milliseconds(200))

        #expect(viewController.transportViewControllerForTesting.displayedTitleForTesting == recentJob.displayTitle)
        #expect(viewController.transportViewControllerForTesting.displayedSummaryForTesting == recentJob.summary)
        #expect(viewController.transportViewControllerForTesting.displayedLogForTesting == recentJob.logText)
    }

    @Test func switchingSelectedJobRebindsDetailPane() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let activeJob = makeJob(
            id: "job-active",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Active review in progress.",
            logText: "Active log\n"
        )
        let recentJob = makeJob(
            id: "job-recent",
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "Recent review completed.",
            logText: "Recent log\n"
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [activeJob, recentJob])
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)

        let _: Bool = try await waitUntilValue(timeout: .seconds(5), interval: .milliseconds(50)) {
            guard viewController.transportViewControllerForTesting.displayedTitleForTesting == activeJob.displayTitle else {
                return nil
            }
            return true
        }

        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)

        let _: Bool = try await waitUntilValue(timeout: .seconds(5), interval: .milliseconds(50)) {
            let transport = viewController.transportViewControllerForTesting
            guard transport.displayedTitleForTesting == recentJob.displayTitle,
                  transport.displayedSummaryForTesting == recentJob.summary,
                  transport.displayedLogForTesting == recentJob.logText
            else {
                return nil
            }
            return true
        }
    }

    @Test func clickingSidebarBlankAreaKeepsSelectionAndDetailPane() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = makeJob(
            id: "job-selected",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Review is still running.",
            logText: "Selected log\n"
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [job])
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let _: Bool = try await waitUntilValue(timeout: .seconds(5), interval: .milliseconds(50)) {
            let transport = viewController.transportViewControllerForTesting
            guard transport.displayedTitleForTesting == job.displayTitle,
                  transport.displayedSummaryForTesting == job.summary,
                  transport.displayedLogForTesting == job.logText
            else {
                return nil
            }
            return true
        }

        viewController.sidebarViewControllerForTesting.clickBlankAreaForTesting()

        #expect(viewController.sidebarViewControllerForTesting.selectedJobForTesting?.id == job.id)
        #expect(viewController.transportViewControllerForTesting.displayedTitleForTesting == job.displayTitle)
        #expect(viewController.transportViewControllerForTesting.displayedSummaryForTesting == job.summary)
        #expect(viewController.transportViewControllerForTesting.displayedLogForTesting == job.logText)
    }

    @Test func clickingWorkspaceHeaderKeepsSelectionAndDetailPane() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = makeJob(
            id: "job-selected",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Review is still running.",
            logText: "Selected log\n"
        )
        let workspace = CodexReviewWorkspace(
            cwd: job.cwd,
            sortOrder: 1,
            jobs: [job]
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace]
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let _: Bool = try await waitUntilValue(timeout: .seconds(5), interval: .milliseconds(50)) {
            let transport = viewController.transportViewControllerForTesting
            guard transport.displayedTitleForTesting == job.displayTitle,
                  transport.displayedSummaryForTesting == job.summary,
                  transport.displayedLogForTesting == job.logText
            else {
                return nil
            }
            return true
        }

        viewController.sidebarViewControllerForTesting.clickWorkspaceHeaderForTesting(workspace)

        #expect(viewController.sidebarViewControllerForTesting.selectedJobForTesting?.id == job.id)
        #expect(viewController.transportViewControllerForTesting.displayedTitleForTesting == job.displayTitle)
        #expect(viewController.transportViewControllerForTesting.displayedSummaryForTesting == job.summary)
        #expect(viewController.transportViewControllerForTesting.displayedLogForTesting == job.logText)
    }

    @Test func newJobsArrivingWhileUnselectedDoNotAutoSelect() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let activeJob = makeJob(status: .running, targetSummary: "Uncommitted changes")
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(serverState: .running, workspaces: [])
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarViewControllerForTesting.selectedJobForTesting == nil)
        #expect(viewController.transportViewControllerForTesting.isShowingEmptyStateForTesting)

        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [activeJob])
        )

        #expect(viewController.sidebarViewControllerForTesting.selectedJobForTesting == nil)
        #expect(viewController.transportViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.transportViewControllerForTesting.displayedTitleForTesting == nil)
    }

    @Test func removingSelectedJobClearsSelectionWithoutAutoSelectingReplacement() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let activeJob = makeJob(
            id: "job-active",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Active review in progress.",
            logText: "Active log\n"
        )
        let recentJob = makeJob(
            id: "job-recent",
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "Recent review completed.",
            logText: "Recent log\n"
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [activeJob, recentJob])
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)

        let _: Bool = try await waitUntilValue(timeout: .seconds(5), interval: .milliseconds(50)) {
            guard viewController.transportViewControllerForTesting.displayedTitleForTesting == activeJob.displayTitle else {
                return nil
            }
            return true
        }

        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [recentJob])
        )

        let _: Bool = try await waitUntilValue(timeout: .seconds(5), interval: .milliseconds(50)) {
            let sidebar = viewController.sidebarViewControllerForTesting
            let transport = viewController.transportViewControllerForTesting
            guard sidebar.selectedJobForTesting == nil,
                  transport.isShowingEmptyStateForTesting,
                  transport.displayedTitleForTesting == nil,
                  transport.displayedSummaryForTesting == nil
            else {
                return nil
            }
            return true
        }
    }

    @Test func clearingSelectionShowsEmptyStateAndClearsDetailPane() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = makeJob(
            id: "job-1",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: "Initial log\n"
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [job])
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        viewController.loadViewIfNeeded()
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let _: Bool = try await waitUntilValue(timeout: .seconds(5), interval: .milliseconds(50)) {
            guard viewController.transportViewControllerForTesting.displayedTitleForTesting == job.displayTitle else {
                return nil
            }
            return true
        }

        viewController.sidebarViewControllerForTesting.clearSelectionForTesting()

        let _: Bool = try await waitUntilValue(timeout: .seconds(5), interval: .milliseconds(50)) {
            let transport = viewController.transportViewControllerForTesting
            guard transport.isShowingEmptyStateForTesting,
                  transport.displayedTitleForTesting == nil,
                  transport.displayedSummaryForTesting == nil,
                  transport.displayedLogForTesting.isEmpty
            else {
                return nil
            }
            return true
        }

        job.summary = "Deselected summary"
        job.logEntries = [.init(kind: .agentMessage, text: "Deselected log")]
        try await Task.sleep(for: .milliseconds(200))

        #expect(viewController.transportViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.transportViewControllerForTesting.displayedLogForTesting.isEmpty)
    }

    @Test func inPlaceJobUpdateKeepsSelectionAndRefreshesDetailPane() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = makeJob(
            id: "job-1",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: "Initial log\n"
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [job])
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let _: Bool = try await waitUntilValue(timeout: .seconds(5), interval: .milliseconds(50)) {
            guard viewController.transportViewControllerForTesting.displayedTitleForTesting == job.displayTitle else {
                return nil
            }
            return true
        }

        job.status = .succeeded
        job.summary = "Review completed successfully."
        job.logEntries = [.init(kind: .agentMessage, text: "Updated log")]

        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [job])
        )

        let _: Bool = try await waitUntilValue(timeout: .seconds(5), interval: .milliseconds(50)) {
            let sidebar = viewController.sidebarViewControllerForTesting
            let transport = viewController.transportViewControllerForTesting
            guard sidebar.selectedJobForTesting?.id == "job-1",
                  transport.displayedSummaryForTesting == "Review completed successfully.",
                  transport.displayedLogForTesting == "Updated log"
            else {
                return nil
            }
            return true
        }
    }

}

@MainActor
private func waitUntilValue<T>(
    timeout: Duration = .seconds(2),
    interval: Duration = .milliseconds(20),
    action: @escaping () async throws -> T?
) async throws -> T {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if let value = try await action() {
            return value
        }
        try await Task.sleep(for: interval)
    }
    throw TestFailure("timed out")
}

@MainActor
private func makeJob(
    id: String = UUID().uuidString,
    cwd: String = "/tmp/repo",
    startedAt: Date = Date(),
    status: CodexReviewJobStatus,
    targetSummary: String,
    summary: String? = nil,
    logText: String = "",
    rawLogText: String = ""
) -> CodexReviewJob {
    CodexReviewJob.makeForTesting(
        id: id,
        cwd: cwd,
        targetSummary: targetSummary,
        threadID: status == .queued ? nil : UUID().uuidString,
        turnID: UUID().uuidString,
        status: status,
        startedAt: startedAt,
        endedAt: status.isTerminal ? startedAt.addingTimeInterval(1) : nil,
        summary: summary ?? status.displayText,
        lastAgentMessage: "",
        logEntries:
            (logText.isEmpty ? [] : [.init(kind: .agentMessage, text: logText.trimmingCharacters(in: .newlines))])
            + (rawLogText.isEmpty ? [] : rawLogText.split(separator: "\n", omittingEmptySubsequences: false).map {
                .init(kind: .diagnostic, text: String($0))
            })
    )
}

@MainActor
private func makeWorkspaces(from jobs: [CodexReviewJob]) -> [CodexReviewWorkspace] {
    var buckets: [String: [CodexReviewJob]] = [:]
    var order: [String] = []
    for job in jobs {
        if buckets[job.cwd] == nil {
            order.insert(job.cwd, at: 0)
            buckets[job.cwd] = []
        }
        buckets[job.cwd, default: []].insert(job, at: 0)
    }
    return order.enumerated().map { index, cwd in
        CodexReviewWorkspace(
            cwd: cwd,
            sortOrder: index + 1,
            jobs: buckets[cwd] ?? []
        )
    }
}

private struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

@MainActor
private final class FailingCancellationBackend: CodexReviewStoreBackend {
    var isActive: Bool = false

    func start(
        store: CodexReviewStore,
        forceRestartIfNeeded: Bool
    ) async {
        _ = store
        _ = forceRestartIfNeeded
    }

    func stop(store: CodexReviewStore) async {
        _ = store
    }

    func waitUntilStopped() async {}

    func cancelReview(
        jobID: String,
        sessionID: String,
        reason: String,
        store: CodexReviewStore
    ) async throws {
        _ = jobID
        _ = sessionID
        _ = reason
        _ = store
        throw ReviewError.io("Cancellation failed.")
    }
}
