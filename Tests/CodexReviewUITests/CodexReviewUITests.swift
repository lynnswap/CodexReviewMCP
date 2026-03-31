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
        viewController.sidebarViewControllerForTesting.applySectionForTesting(.active, jobs: [])
        viewController.sidebarViewControllerForTesting.applySectionForTesting(.recent, jobs: [])

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

    @Test func splitViewSeparatesActiveAndRecentJobs() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let activeJob = makeJob(status: .running, targetSummary: "Uncommitted changes")
        let recentJob = makeJob(status: .failed, targetSummary: "Base branch: main")
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(serverState: .running, jobs: [activeJob, recentJob])
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarViewControllerForTesting.displayedSectionTitlesForTesting == ["Active", "Recent"])
        #expect(viewController.splitViewItems.count == 2)
        #expect(viewController.splitViewItems[0].behavior == .sidebar)
        #expect(viewController.splitViewItems[1].behavior == .default)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)
        #expect(viewController.contentAccessoryCountForTesting == 0)
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
        store.loadForTesting(serverState: .running, jobs: [activeJob, recentJob])
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
        store.loadForTesting(serverState: .running, jobs: [activeJob, recentJob])
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

    @Test func removingSelectedJobAutoSelectsNextVisibleJob() async throws {
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
        store.loadForTesting(serverState: .running, jobs: [activeJob, recentJob])
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)

        let _: Bool = try await waitUntilValue(timeout: .seconds(5), interval: .milliseconds(50)) {
            guard viewController.transportViewControllerForTesting.displayedTitleForTesting == activeJob.displayTitle else {
                return nil
            }
            return true
        }

        viewController.sidebarViewControllerForTesting.applySectionForTesting(.active, jobs: [])

        let _: Bool = try await waitUntilValue(timeout: .seconds(5), interval: .milliseconds(50)) {
            let sidebar = viewController.sidebarViewControllerForTesting
            let transport = viewController.transportViewControllerForTesting
            guard sidebar.selectedJobForTesting?.id == recentJob.id,
                  transport.displayedTitleForTesting == recentJob.displayTitle,
                  transport.displayedSummaryForTesting == recentJob.summary
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
        store.loadForTesting(serverState: .running, jobs: [job])
        let viewController = ReviewMonitorSplitViewController(store: store)
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
        store.loadForTesting(serverState: .running, jobs: [job])
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

        viewController.sidebarViewControllerForTesting.applySectionForTesting(.active, jobs: [])
        viewController.sidebarViewControllerForTesting.applySectionForTesting(.recent, jobs: [job])

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
    status: CodexReviewJobStatus,
    targetSummary: String,
    summary: String? = nil,
    logText: String = "",
    rawLogText: String = ""
) -> CodexReviewJob {
    CodexReviewJob.makeForTesting(
        id: id,
        targetSummary: targetSummary,
        threadID: status == .queued ? nil : UUID().uuidString,
        turnID: UUID().uuidString,
        status: status,
        startedAt: Date(),
        endedAt: status.isTerminal ? Date() : nil,
        summary: summary ?? status.displayText,
        lastAgentMessage: "",
        logEntries: logText.isEmpty ? [] : [.init(kind: .agentMessage, text: logText.trimmingCharacters(in: .newlines))],
        rawLogLines: rawLogText.isEmpty ? [] : rawLogText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    )
}

private struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
