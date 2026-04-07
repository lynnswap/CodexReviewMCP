import AppKit
import Foundation
import Testing
@_spi(Testing) @testable import CodexReviewModel
@testable import CodexReviewUI
import ReviewTestSupport
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

    @Test func splitViewStartsStoreOnceOnFirstAppearance() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let backend = CountingStartBackend()
        let store = CodexReviewStore(backend: backend)
        let viewController = ReviewMonitorSplitViewController(store: store)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }

        viewController.viewDidAppear()
        viewController.viewDidAppear()

        let backendBox = UncheckedSendableBox(backend)
        try await withTestTimeout {
            await backendBox.value.waitForStartCallCount(1)
        }

        #expect(viewController.didTriggerStoreStartForTesting)
        #expect(backend.startCallCount() == 1)
    }

    @Test func splitViewSkipsStoreStartWhenAutoStartIsDisabled() async {
        guard #available(macOS 26.0, *) else {
            return
        }
        let backend = CountingStartBackend(shouldAutoStartEmbeddedServer: false)
        let store = CodexReviewStore(backend: backend)
        let viewController = ReviewMonitorSplitViewController(store: store)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }

        viewController.viewDidAppear()

        #expect(viewController.didTriggerStoreStartForTesting == false)
        #expect(backend.startCallCount() == 0)
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
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)

        let selectedSnapshot = try await awaitTransportRender(transport, after: initialRenderCount)
        #expect(
            selectedSnapshot == .init(
                title: recentJob.displayTitle,
                summary: recentJob.summary,
                log: recentJob.logText,
                isShowingEmptyState: false
            )
        )

        let stableRenderCount = transport.renderCountForTesting
        activeJob.summary = "Old selection should not render."
        activeJob.replaceLogEntries([.init(kind: .agentMessage, text: "Old selection log")])
        await transport.flushMainQueueForTesting()

        #expect(transport.renderCountForTesting == stableRenderCount)
        #expect(transport.renderSnapshotForTesting == selectedSnapshot)
    }

    @Test func detailPaneHidesCommandOutputButKeepsCommandEntries() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = CodexReviewJob.makeForTesting(
            id: "job-command-output",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .succeeded,
            startedAt: Date(timeIntervalSince1970: 200),
            endedAt: Date(timeIntervalSince1970: 201),
            summary: "Review completed.",
            hasFinalReview: true,
            lastAgentMessage: "No correctness issues found.",
            logEntries: [
                .init(kind: .command, text: "$ git diff --stat"),
                .init(kind: .commandOutput, groupID: "cmd_1", text: "README.md | 1 +"),
                .init(kind: .agentMessage, text: "No correctness issues found.")
            ]
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [job])
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let selectedSnapshot = try await awaitTransportRender(transport, after: initialRenderCount)
        #expect(selectedSnapshot.title == job.displayTitle)
        #expect(selectedSnapshot.summary == job.summary)

        let displayedLog = transport.displayedLogForTesting
        #expect(displayedLog.contains("$ git diff --stat"))
        #expect(displayedLog.contains("No correctness issues found."))
        #expect(displayedLog.contains("README.md | 1 +") == false)
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
        let transport = viewController.transportViewControllerForTesting

        let firstRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)

        let activeSnapshot = try await awaitTransportRender(transport, after: firstRenderCount)
        #expect(activeSnapshot.title == activeJob.displayTitle)

        let secondRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)

        let recentSnapshot = try await awaitTransportRender(transport, after: secondRenderCount)
        #expect(
            recentSnapshot == .init(
                title: recentJob.displayTitle,
                summary: recentJob.summary,
                log: recentJob.logText,
                isShowingEmptyState: false
            )
        )
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
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let selectedSnapshot = try await awaitTransportRender(transport, after: initialRenderCount)

        let stableRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.clickBlankAreaForTesting()
        await transport.flushMainQueueForTesting()

        #expect(viewController.sidebarViewControllerForTesting.selectedJobForTesting?.id == job.id)
        #expect(transport.renderCountForTesting == stableRenderCount)
        #expect(transport.renderSnapshotForTesting == selectedSnapshot)
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
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let selectedSnapshot = try await awaitTransportRender(transport, after: initialRenderCount)

        let stableRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.clickWorkspaceHeaderForTesting(workspace)
        await transport.flushMainQueueForTesting()

        #expect(viewController.sidebarViewControllerForTesting.selectedJobForTesting?.id == job.id)
        #expect(transport.renderCountForTesting == stableRenderCount)
        #expect(transport.renderSnapshotForTesting == selectedSnapshot)
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
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)

        let activeSnapshot = try await awaitTransportRender(transport, after: initialRenderCount)
        #expect(activeSnapshot.title == activeJob.displayTitle)

        let removalRenderCount = transport.renderCountForTesting
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [recentJob])
        )

        let emptySnapshot = try await awaitTransportRender(transport, after: removalRenderCount)
        #expect(viewController.sidebarViewControllerForTesting.selectedJobForTesting == nil)
        #expect(emptySnapshot.isShowingEmptyState)
        #expect(emptySnapshot.title == nil)
        #expect(emptySnapshot.summary == nil)
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
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let selectedSnapshot = try await awaitTransportRender(transport, after: initialRenderCount)
        #expect(selectedSnapshot.title == job.displayTitle)

        let clearRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.clearSelectionForTesting()

        let emptySnapshot = try await awaitTransportRender(transport, after: clearRenderCount)
        #expect(emptySnapshot.isShowingEmptyState)
        #expect(emptySnapshot.title == nil)
        #expect(emptySnapshot.summary == nil)
        #expect(emptySnapshot.log.isEmpty)

        let stableRenderCount = transport.renderCountForTesting
        job.summary = "Deselected summary"
        job.replaceLogEntries([.init(kind: .agentMessage, text: "Deselected log")])
        await transport.flushMainQueueForTesting()

        #expect(transport.renderCountForTesting == stableRenderCount)
        #expect(transport.renderSnapshotForTesting == emptySnapshot)
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
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let selectedSnapshot = try await awaitTransportRender(transport, after: initialRenderCount)
        #expect(selectedSnapshot.title == job.displayTitle)

        let updateRenderCount = transport.renderCountForTesting
        job.status = .succeeded
        job.summary = "Review completed successfully."
        job.replaceLogEntries([.init(kind: .agentMessage, text: "Updated log")])

        let updatedSnapshot = try await awaitTransportRender(transport, after: updateRenderCount)
        #expect(viewController.sidebarViewControllerForTesting.selectedJobForTesting?.id == "job-1")
        #expect(updatedSnapshot.summary == "Review completed successfully.")
        #expect(updatedSnapshot.log == "Updated log")
    }

    @Test func selectedJobLogAppendUsesAppendPath() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = CodexReviewJob.makeForTesting(
            id: "job-append",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            logEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: "Initial")
            ]
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(serverState: .running, workspaces: makeWorkspaces(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        let appendRenderCount = transport.renderCountForTesting
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        job.appendLogEntry(.init(kind: .agentMessage, groupID: "msg_1", text: " log"))

        let snapshot = try await awaitTransportRender(transport, after: appendRenderCount)
        #expect(snapshot.log == "Initial log")
        #expect(transport.logAppendCountForTesting == appendCount + 1)
        #expect(transport.logReloadCountForTesting == reloadCount)
    }

    @Test func selectedJobGroupedReplacementUsesReloadPath() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = CodexReviewJob.makeForTesting(
            id: "job-reload",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            logEntries: [
                .init(kind: .plan, groupID: "plan_1", text: "- original")
            ]
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(serverState: .running, workspaces: makeWorkspaces(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        let reloadRenderCount = transport.renderCountForTesting
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        job.appendLogEntry(.init(kind: .plan, groupID: "plan_1", replacesGroup: true, text: "- updated"))

        let snapshot = try await awaitTransportRender(transport, after: reloadRenderCount)
        #expect(snapshot.log == "- updated")
        #expect(transport.logAppendCountForTesting == appendCount)
        #expect(transport.logReloadCountForTesting == reloadCount + 1)
    }

    @Test func metadataOnlyUpdatesDoNotTouchLogView() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = makeJob(
            id: "job-metadata",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: "Initial log\n"
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(serverState: .running, workspaces: makeWorkspaces(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        let metadataRenderCount = transport.renderCountForTesting
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        job.summary = "Updated summary."

        let snapshot = try await awaitTransportRender(transport, after: metadataRenderCount)
        #expect(snapshot.summary == "Updated summary.")
        #expect(snapshot.log == "Initial log")
        #expect(transport.logAppendCountForTesting == appendCount)
        #expect(transport.logReloadCountForTesting == reloadCount)
    }

    @Test func logAutoFollowRunsOnlyWhenPinnedToBottom() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let job = makeJob(
            id: "job-autofollow",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(serverState: .running, workspaces: makeWorkspaces(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)
        #expect(transport.isLogPinnedToBottomForTesting)

        let pinnedRenderCount = transport.renderCountForTesting
        let pinnedAutoFollow = transport.logAutoFollowCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Pinned update"))
        _ = try await awaitTransportRender(transport, after: pinnedRenderCount)
        #expect(transport.logAutoFollowCountForTesting == pinnedAutoFollow + 1)
        #expect(transport.isLogPinnedToBottomForTesting)

        transport.scrollLogToTopForTesting()
        #expect(transport.isLogPinnedToBottomForTesting == false)

        let unpinnedRenderCount = transport.renderCountForTesting
        let unpinnedAutoFollow = transport.logAutoFollowCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Unpinned update"))
        _ = try await awaitTransportRender(transport, after: unpinnedRenderCount)
        #expect(transport.logAutoFollowCountForTesting == unpinnedAutoFollow)
        #expect(transport.isLogPinnedToBottomForTesting == false)
    }

    @Test func logViewUsesTextKit1AndDisablesEditingFeatures() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = makeJob(
            id: "job-log-config",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: "Initial log\n"
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(serverState: .running, workspaces: makeWorkspaces(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        #expect(transport.logUsesTextKit1ForTesting)
        #expect(transport.logIsEditableForTesting == false)
        #expect(transport.logIsSelectableForTesting)
        #expect(transport.logWritingToolsDisabledForTesting)
    }

    @Test func authFailedJobShowsNormalFailureDetails() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = makeJob(
            id: "job-auth",
            status: .failed,
            targetSummary: "Uncommitted changes",
            summary: "Failed to start review.",
            logText: "Authentication required. Sign in to ReviewMCP and retry."
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            authState: .signedOut,
            workspaces: makeWorkspaces(from: [job])
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let snapshot = try await awaitTransportRender(transport, after: initialRenderCount)
        #expect(snapshot.summary == "Failed to start review.")
        #expect(snapshot.log == "Authentication required. Sign in to ReviewMCP and retry.")
    }

    @Test func authenticatedAuthFailedJobStillShowsNormalFailureDetails() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = makeJob(
            id: "job-auth-restored",
            status: .failed,
            targetSummary: "Uncommitted changes",
            summary: "Failed to start review.",
            logText: "Authentication required. Sign in to ReviewMCP and retry."
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            authState: .signedIn(accountID: "review@example.com"),
            workspaces: makeWorkspaces(from: [job])
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let snapshot = try await awaitTransportRender(transport, after: initialRenderCount)
        #expect(snapshot.summary == "Failed to start review.")
        #expect(snapshot.log == "Authentication required. Sign in to ReviewMCP and retry.")
    }

}

@MainActor
private func withTestTimeout<T: Sendable>(
    _ timeout: Duration = .seconds(2),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TestFailure("timed out")
        }
        defer { group.cancelAll() }
        return try await #require(group.next())
    }
}

@MainActor
private func awaitTransportRender(
    _ transport: ReviewMonitorTransportViewController,
    after renderCount: Int,
    timeout: Duration = .seconds(2)
) async throws -> ReviewMonitorTransportViewController.RenderSnapshotForTesting {
    let transportBox = UncheckedSendableBox(transport)
    return try await withTestTimeout(timeout) {
        await transportBox.value.waitForRenderCountForTesting(renderCount + 1)
        return await MainActor.run {
            transportBox.value.renderSnapshotForTesting
        }
    }
}

private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
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
            }),
        errorMessage: status == .failed ? summary ?? status.displayText : nil
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
    let shouldAutoStartEmbeddedServer = false

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

    func refreshAuthState(auth: CodexReviewAuthModel) async {
        _ = auth
    }

    func beginAuthentication(auth: CodexReviewAuthModel) async {
        _ = auth
    }

    func cancelAuthentication(auth: CodexReviewAuthModel) async {
        _ = auth
    }

    func logout(auth: CodexReviewAuthModel) async {
        _ = auth
    }
}

@MainActor
private final class CountingStartBackend: CodexReviewStoreBackend {
    let shouldAutoStartEmbeddedServer: Bool
    private let startSignal = AsyncSignal()
    private var startCalls = 0

    init(shouldAutoStartEmbeddedServer: Bool = true) {
        self.shouldAutoStartEmbeddedServer = shouldAutoStartEmbeddedServer
    }

    var isActive: Bool {
        startCalls > 0
    }

    func start(
        store: CodexReviewStore,
        forceRestartIfNeeded: Bool
    ) async {
        _ = store
        _ = forceRestartIfNeeded
        startCalls += 1
        await startSignal.signal()
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
    }

    func refreshAuthState(auth: CodexReviewAuthModel) async {
        _ = auth
    }

    func beginAuthentication(auth: CodexReviewAuthModel) async {
        _ = auth
    }

    func cancelAuthentication(auth: CodexReviewAuthModel) async {
        _ = auth
    }

    func logout(auth: CodexReviewAuthModel) async {
        _ = auth
    }

    func startCallCount() -> Int {
        startCalls
    }

    func waitForStartCallCount(_ count: Int) async {
        if startCalls >= count {
            return
        }
        await startSignal.wait(untilCount: count)
    }
}
