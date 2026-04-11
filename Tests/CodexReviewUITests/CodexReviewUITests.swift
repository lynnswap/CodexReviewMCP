import AppKit
import Foundation
import Testing
@_spi(Testing) @testable import CodexReviewModel
@_spi(PreviewSupport) @testable import CodexReviewUI
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
        #expect(viewController.contentPaneViewControllerForTesting.isShowingEmptyStateForTesting)
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
        #expect(viewController.contentPaneViewControllerForTesting.isShowingEmptyStateForTesting)
    }

    @Test func splitViewShowsUnavailableSidebarWhenServerFailedOnLoad() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .failed("Embedded server is unavailable in preview mode."),
            workspaces: []
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        #expect(viewController.splitViewItems.count == 2)
        #expect(viewController.sidebarPresentationForTesting == .unavailable)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)
    }

    @Test func splitViewShowsJobSidebarWhenServerRunningOnLoad() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            serverURL: URL(string: "http://localhost:9417/mcp"),
            workspaces: []
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarPresentationForTesting == .jobList)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)
    }

    @Test func contentPanePinsDisplayedContentToSafeArea() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 900, height: 600)
        )
        let window = harness.window
        defer { window.close() }

        let contentPane = harness.viewController.contentPaneViewControllerForTesting
        window.layoutIfNeeded()
        contentPane.view.layoutSubtreeIfNeeded()

        let safeAreaFrame = contentPane.safeAreaFrameForTesting
        let displayedViewFrame = contentPane.displayedViewFrameForTesting

        #expect(abs(displayedViewFrame.minX - safeAreaFrame.minX) < 0.5)
        #expect(abs(displayedViewFrame.maxX - safeAreaFrame.maxX) < 0.5)
        #expect(abs(displayedViewFrame.minY - safeAreaFrame.minY) < 0.5)
        #expect(abs(displayedViewFrame.maxY - safeAreaFrame.maxY) < 0.5)
        #expect(contentPane.activeDisplayedViewConstraintCountForTesting == 4)
    }

    @Test func splitViewSwitchesSidebarWhenServerAvailabilityChanges() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            serverURL: URL(string: "http://localhost:9417/mcp"),
            workspaces: []
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarPresentationForTesting == .jobList)

        store.loadForTesting(
            serverState: .failed("Embedded server is unavailable in preview mode."),
            workspaces: []
        )
        try await waitForSidebarPresentation(viewController, .unavailable)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)

        store.loadForTesting(
            serverState: .running,
            serverURL: URL(string: "http://localhost:9417/mcp"),
            workspaces: []
        )
        try await waitForSidebarPresentation(viewController, .jobList)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)
    }

    @Test func splitViewInstallsToolbarWithSidebarTrackingSeparator() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let harness = makeWindowHarness(store: store)
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }

        #expect(window.toolbar != nil)
        #expect(harness.windowController.displayedContentKindForTesting == .splitView)
        #expect(viewController.toolbarIdentifiersForTesting.contains(.toggleSidebar))
        #expect(viewController.toolbarIdentifiersForTesting.contains(.sidebarTrackingSeparator))
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .visible)
        #expect(window.title == "Untitled")
        #expect(window.subtitle == "")
        #expect(window.isMovableByWindowBackground == false)
        #expect(viewController.sidebarAllowsFullHeightLayoutForTesting)
        #expect(viewController.contentAutomaticallyAdjustsSafeAreaInsetsForTesting)
    }

    @Test func previewContentViewControllerConfiguresAttachedWindowLikeSplitPresentation() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let viewController = makeReviewMonitorPreviewContentViewControllerForPreview()
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        window.layoutIfNeeded()

        #expect(window.toolbar != nil)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .visible)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titlebarSeparatorStyle == .automatic)
        #expect(window.isMovableByWindowBackground == false)
        #expect(window.backgroundColor == .clear)
        #expect(window.isOpaque == false)
    }

    @Test func windowControllerUsesSeededAuthenticatedStateOnFirstPresentation() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let backend = AuthActionBackend(
            initialAuthState: .signedIn(accountID: "review@example.com")
        )
        let store = CodexReviewStore(backend: backend)
        let windowController = ReviewMonitorWindowController(
            store: store,
            performInitialAuthRefresh: false
        )
        guard let window = windowController.window else {
            Issue.record("ReviewMonitorWindowController did not create a window.")
            return
        }
        defer { window.close() }

        #expect(windowController.displayedContentKindForTesting == .splitView)
        #expect(window.toolbar != nil)
    }

    @Test func windowControllerShowsSignInViewWhenSignedOut() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let harness = makeWindowHarness(
            store: store,
            authState: .signedOut
        )
        let window = harness.window
        defer { window.close() }

        #expect(harness.windowController.displayedContentKindForTesting == .signInView)
        #expect(window.toolbar == nil)
        #expect(window.titleVisibility == .hidden)
        #expect(window.title == "")
        #expect(window.subtitle == "")
        #expect(window.isMovableByWindowBackground)
    }

    @Test func windowControllerDoesNotRefreshAuthStateBeforeStoreStart() async {
        guard #available(macOS 26.0, *) else {
            return
        }
        let backend = AuthActionBackend()
        let store = CodexReviewStore(backend: backend)
        let windowController = ReviewMonitorWindowController(store: store)
        defer { windowController.window?.close() }
        await Task.yield()

        #expect(backend.refreshAuthStateCallCount() == 0)
    }

    @Test func windowControllerSwitchesToSignInViewAfterLogout() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let harness = makeWindowHarness(
            store: store,
            authState: .signedIn(accountID: "review@example.com")
        )
        let window = harness.window
        defer { window.close() }

        store.auth.updateState(.signedOut)
        try await waitForDisplayedContentKind(harness.windowController, .signInView)
        try await waitForEmbeddedContentSubviewCount(harness.windowController, 1)

        #expect(harness.windowController.embeddedContentSubviewCountForTesting == 1)
        #expect(window.toolbar == nil)
        #expect(window.title == "")
        #expect(window.subtitle == "")
        #expect(window.isMovableByWindowBackground)
    }

    @Test func windowControllerCrossfadesBackToSplitViewAfterAuthentication() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let harness = makeWindowHarness(
            store: store,
            authState: .signedOut
        )
        let window = harness.window
        defer { window.close() }

        store.auth.updateState(.signedIn(accountID: "review@example.com"))
        try await waitForDisplayedContentKind(harness.windowController, .splitView)
        try await waitForEmbeddedContentSubviewCount(harness.windowController, 1)

        #expect(harness.windowController.embeddedContentSubviewCountForTesting == 1)
        #expect(window.toolbar != nil)
        #expect(window.titleVisibility == .visible)
        #expect(window.titlebarSeparatorStyle == .automatic)
        #expect(window.isMovableByWindowBackground == false)
    }

    @Test func windowControllerRapidAuthFlipsKeepLatestContentEmbedded() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let harness = makeWindowHarness(
            store: store,
            authState: .signedIn(accountID: "review@example.com")
        )
        let window = harness.window
        defer { window.close() }

        store.auth.updateState(.signedOut)
        store.auth.updateState(.signedIn(accountID: "review@example.com"))
        try await waitForDisplayedContentKind(harness.windowController, .splitView)
        try await waitForEmbeddedContentSubviewCount(harness.windowController, 1)
        try await Task.sleep(for: .milliseconds(300))
        try await waitForEmbeddedContentSubviewCount(harness.windowController, 1)

        #expect(harness.windowController.embeddedContentSubviewCountForTesting == 1)
        #expect(harness.windowController.isSplitViewEmbeddedForTesting)
        #expect(harness.windowController.isSignInViewEmbeddedForTesting == false)
        #expect(window.toolbar != nil)
    }

    @Test func windowControllerPreservesWindowSizeWhenSwitchingToSignInView() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let harness = makeWindowHarness(
            store: store,
            authState: .signedIn(accountID: "review@example.com")
        )
        let window = harness.window
        defer { window.close() }

        window.setContentSize(NSSize(width: 1080, height: 720))
        window.layoutIfNeeded()
        let beforeSize = window.frame.size

        store.auth.updateState(.signedOut)
        try await waitForDisplayedContentKind(harness.windowController, .signInView)
        window.layoutIfNeeded()
        let afterSize = window.frame.size

        #expect(abs(beforeSize.width - afterSize.width) < 0.5)
        #expect(abs(beforeSize.height - afterSize.height) < 0.5)
    }

    @Test func windowControllerKeepsSplitViewAfterAuthFailure() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let harness = makeWindowHarness(
            store: store,
            authState: .signedIn(accountID: "review@example.com")
        )
        let window = harness.window
        defer { window.close() }

        store.auth.updateState(.failed("Authentication failed."))
        await Task.yield()

        #expect(harness.windowController.displayedContentKindForTesting == .splitView)
        #expect(window.toolbar != nil)
    }

    @Test func windowControllerKeepsSignInViewPresentedWhileAuthenticating() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let harness = makeWindowHarness(
            store: store,
            authState: .signedOut
        )
        defer { harness.window.close() }

        store.auth.updateState(
            .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue.",
                    browserURL: "https://auth.openai.com/oauth/authorize?foo=bar"
                )
            )
        )
        try await waitForDisplayedContentKind(harness.windowController, .signInView)

        #expect(harness.windowController.displayedContentKindForTesting == .signInView)
    }

    @Test func windowControllerKeepsSplitViewPresentedWhileAuthenticatedRetryAuthenticates() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let harness = makeWindowHarness(
            store: store,
            authState: .signedIn(accountID: "review@example.com")
        )
        defer { harness.window.close() }

        store.auth.updateState(
            .failed(
                "Authentication failed.",
                isAuthenticated: true,
                accountID: "review@example.com"
            )
        )
        await Task.yield()

        store.auth.updateState(
            .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue.",
                    browserURL: "https://auth.openai.com/oauth/authorize?foo=bar"
                )
            )
        )
        await Task.yield()

        #expect(harness.windowController.displayedContentKindForTesting == .splitView)
        #expect(harness.windowController.isSplitViewEmbeddedForTesting)
        #expect(harness.windowController.isSignInViewEmbeddedForTesting == false)
    }

    @Test func detailLogViewFillsSafeAreaWithoutTopInsetFromRemovedHeader() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = makeJob(
            id: "job-safe-area",
            status: .running,
            targetSummary: "Uncommitted changes",
            logText: "Safe area log\n"
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(serverState: .running, workspaces: makeWorkspaces(from: [job]))
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 900, height: 600)
        )
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)
        transport.view.layoutSubtreeIfNeeded()

        let logFrame = transport.logFrameForTesting
        let safeAreaFrame = transport.safeAreaFrameForTesting

        #expect(abs(logFrame.minX - safeAreaFrame.minX) < 0.5)
        #expect(abs(logFrame.maxX - safeAreaFrame.maxX) < 0.5)
        #expect(abs(logFrame.minY - safeAreaFrame.minY) < 0.5)
        #expect(abs(logFrame.maxY - safeAreaFrame.maxY) < 0.5)
    }

    @Test func shortDetailLogKeepsTextViewWithinDocumentBounds() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = makeJob(
            id: "job-short-log-layout",
            status: .running,
            targetSummary: "Uncommitted changes",
            logText: "Short log\n"
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(serverState: .running, workspaces: makeWorkspaces(from: [job]))
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 900, height: 600)
        )
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)
        transport.view.layoutSubtreeIfNeeded()

        let textViewFrame = transport.logTextViewFrameForTesting
        let documentViewFrame = transport.logDocumentViewFrameForTesting

        #expect(abs(textViewFrame.minY) < 0.5)
        #expect(textViewFrame.maxY <= documentViewFrame.maxY + 0.5)
        #expect(textViewFrame.height <= documentViewFrame.height + 0.5)
        expectLogTextContainerWidthTracksTextView(transport)
    }

    @Test func detailLogExpandsAfterSidebarReopensFromCompactWidth() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = makeJob(
            id: "job-sidebar-width-regression",
            status: .running,
            targetSummary: "Uncommitted changes",
            logText: Array(repeating: "Long line that should reflow across the widened detail pane.\n", count: 40).joined()
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(serverState: .running, workspaces: makeWorkspaces(from: [job]))
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 520, height: 420)
        )
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        try await waitForDisplayedContentKind(harness.windowController, .splitView)
        let transport = viewController.transportViewControllerForTesting
        let sidebarItem = try #require(viewController.splitViewItems.first)

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        window.setContentSize(NSSize(width: 360, height: 420))
        sidebarItem.isCollapsed = true
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        let compactDocumentWidth = transport.logDocumentViewFrameForTesting.width
        expectLogTextContainerWidthTracksTextView(transport)

        sidebarItem.isCollapsed = false
        window.setContentSize(NSSize(width: 960, height: 600))
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        await transport.flushMainQueueForTesting()

        let expandedDocumentWidth = transport.logDocumentViewFrameForTesting.width
        let expandedLogWidth = transport.logFrameForTesting.width
        let expandedTextWidth = transport.logTextViewFrameForTesting.width

        #expect(expandedDocumentWidth > compactDocumentWidth + 200)
        #expect(abs(expandedDocumentWidth - expandedLogWidth) < 32)
        #expect(abs(expandedTextWidth - expandedLogWidth) < 32)
        expectLogTextContainerWidthTracksTextView(transport)
    }

    @Test func detailLogShrinksAfterSidebarReopensIntoNarrowWidth() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = makeJob(
            id: "job-sidebar-width-shrink-regression",
            status: .running,
            targetSummary: "Uncommitted changes",
            logText: Array(repeating: "Long line that should reflow when the detail pane narrows.\n", count: 40).joined()
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(serverState: .running, workspaces: makeWorkspaces(from: [job]))
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 960, height: 600)
        )
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        try await waitForDisplayedContentKind(harness.windowController, .splitView)
        let transport = viewController.transportViewControllerForTesting
        let sidebarItem = try #require(viewController.splitViewItems.first)

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)
        window.layoutIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        let expandedDocumentWidth = transport.logDocumentViewFrameForTesting.width
        expectLogTextContainerWidthTracksTextView(transport)

        sidebarItem.isCollapsed = true
        window.setContentSize(NSSize(width: 360, height: 420))
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        await transport.flushMainQueueForTesting()

        let compactDocumentWidth = transport.logDocumentViewFrameForTesting.width
        let compactLogWidth = transport.logFrameForTesting.width
        let compactTextWidth = transport.logTextViewFrameForTesting.width

        #expect(compactDocumentWidth < expandedDocumentWidth - 200)
        #expect(abs(compactDocumentWidth - compactLogWidth) < 32)
        #expect(abs(compactTextWidth - compactLogWidth) < 32)
        expectLogTextContainerWidthTracksTextView(transport)
    }

    @Test func detailLogTracksSimpleWindowResizeInBothDirections() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = makeJob(
            id: "job-window-resize-width-regression",
            status: .running,
            targetSummary: "Uncommitted changes",
            logText: Array(repeating: "Long line that should reflow as the window resizes.\n", count: 40).joined()
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(serverState: .running, workspaces: makeWorkspaces(from: [job]))
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 960, height: 600)
        )
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)
        window.layoutIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        let wideWidth = transport.logDocumentViewFrameForTesting.width
        expectLogTextContainerWidthTracksTextView(transport)

        window.setContentSize(NSSize(width: 520, height: 420))
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        await transport.flushMainQueueForTesting()
        let narrowWidth = transport.logDocumentViewFrameForTesting.width
        let narrowTextWidth = transport.logTextViewFrameForTesting.width
        let narrowLogWidth = transport.logFrameForTesting.width
        expectLogTextContainerWidthTracksTextView(transport)

        window.setContentSize(NSSize(width: 900, height: 600))
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        await transport.flushMainQueueForTesting()
        let widenedAgainWidth = transport.logDocumentViewFrameForTesting.width
        let widenedAgainTextWidth = transport.logTextViewFrameForTesting.width
        let widenedAgainLogWidth = transport.logFrameForTesting.width

        #expect(narrowWidth < wideWidth - 150)
        #expect(widenedAgainWidth > narrowWidth + 150)
        #expect(abs(narrowWidth - narrowLogWidth) < 32)
        #expect(abs(narrowTextWidth - narrowLogWidth) < 32)
        #expect(abs(widenedAgainWidth - widenedAgainLogWidth) < 32)
        #expect(abs(widenedAgainTextWidth - widenedAgainLogWidth) < 32)
        expectLogTextContainerWidthTracksTextView(transport)
    }

    @Test func detailLogTextContainerExpandsAfterToolbarSidebarToggleAtCompactWidth() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = makeJob(
            id: "job-toolbar-sidebar-toggle-textkit-width-regression",
            status: .running,
            targetSummary: "Uncommitted changes",
            logText: Array(repeating: "Long line that should reflow after the toolbar sidebar toggle path.\n", count: 40).joined()
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(serverState: .running, workspaces: makeWorkspaces(from: [job]))
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 520, height: 420)
        )
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        try await waitForDisplayedContentKind(harness.windowController, .splitView)
        let transport = viewController.transportViewControllerForTesting
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        await transport.flushMainQueueForTesting()

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        viewController.toggleSidebar(nil)
        window.setContentSize(NSSize(width: 360, height: 420))
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        await transport.flushMainQueueForTesting()
        #expect(sidebarItem.isCollapsed)

        viewController.toggleSidebar(nil)
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        await transport.flushMainQueueForTesting()
        let compactDocumentWidth = transport.logDocumentViewFrameForTesting.width
        expectLogTextContainerWidthTracksTextView(transport)

        window.setContentSize(NSSize(width: 960, height: 600))
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        await transport.flushMainQueueForTesting()

        let expandedDocumentWidth = transport.logDocumentViewFrameForTesting.width
        let expandedLogWidth = transport.logFrameForTesting.width
        let expandedTextWidth = transport.logTextViewFrameForTesting.width

        #expect(sidebarItem.isCollapsed == false)
        #expect(expandedDocumentWidth > compactDocumentWidth + 200)
        #expect(abs(expandedDocumentWidth - expandedLogWidth) < 32)
        #expect(abs(expandedTextWidth - expandedLogWidth) < 32)
        expectLogTextContainerWidthTracksTextView(transport)
    }

    @Test func windowControllerDoesNotStartStoreWhenConstructed() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let backend = CountingStartBackend()
        let store = CodexReviewStore(backend: backend)
        let harness = makeWindowHarness(store: store)
        let window = harness.window
        defer { window.close() }

        #expect(backend.startCallCount() == 0)
    }

    @Test func splitViewAttachIsIdempotentForSameWindow() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let backend = CountingStartBackend()
        let store = CodexReviewStore(backend: backend)
        let viewController = ReviewMonitorSplitViewController(store: store)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }

        viewController.attach(to: window)
        let initialToolbar = window.toolbar
        let initialIdentifiers = viewController.toolbarIdentifiersForTesting
        viewController.attach(to: window)

        #expect(window.toolbar === initialToolbar)
        #expect(viewController.toolbarIdentifiersForTesting == initialIdentifiers)
        #expect(backend.startCallCount() == 0)
    }

    @Test func previewRunningJobsAppendPseudoStreamOverTime() async throws {
        let store = ReviewMonitorPreviewContent.makeStore(
            streamInterval: Duration.milliseconds(10)
        )
        let runningJob = try #require(
            store.workspaces
                .flatMap { $0.jobs }
                .first(where: { $0.status == .running })
        )
        let initialRevision = runningJob.reviewMonitorRevision
        let initialLog = runningJob.reviewMonitorLogText

        try await withTestTimeout(.seconds(1)) {
            while await MainActor.run(body: { runningJob.reviewMonitorRevision }) == initialRevision {
                await Task.yield()
            }
        }

        #expect(runningJob.reviewMonitorLogText != initialLog)
        #expect(runningJob.reviewMonitorLogText.contains("stream.tick"))
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

    @Test func workspaceDropReordersDisplayedSectionsImmediately() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let workspaceAlphaJob = makeJob(
            id: "job-workspace-alpha",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let workspaceBetaJob = makeJob(
            id: "job-workspace-beta",
            cwd: "/tmp/workspace-beta",
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

        let sidebar = viewController.sidebarViewControllerForTesting
        guard let workspaceAlpha = store.workspaces.first(where: { $0.cwd == "/tmp/workspace-alpha" }) else {
            Issue.record("workspace-alpha was not loaded.")
            return
        }
        #expect(sidebar.performWorkspaceDropForTesting(workspaceAlpha, toIndex: store.workspaces.count))

        #expect(sidebar.displayedSectionTitlesForTesting == [
            "workspace-beta",
            "workspace-alpha",
        ])
    }

    @Test func workspaceDropOnWorkspaceRowReordersDisplayedSections() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let workspaceAlphaJob = makeJob(
            id: "job-workspace-alpha-on-row",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let workspaceBetaJob = makeJob(
            id: "job-workspace-beta-on-row",
            cwd: "/tmp/workspace-beta",
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

        let sidebar = viewController.sidebarViewControllerForTesting
        guard let workspaceAlpha = store.workspaces.first(where: { $0.cwd == "/tmp/workspace-alpha" }),
              let workspaceBeta = store.workspaces.first(where: { $0.cwd == "/tmp/workspace-beta" })
        else {
            Issue.record("workspaces were not loaded.")
            return
        }

        #expect(sidebar.performWorkspaceDropForTesting(workspaceBeta, proposedWorkspace: workspaceAlpha))
        #expect(sidebar.displayedSectionTitlesForTesting == [
            "workspace-beta",
            "workspace-alpha",
        ])
    }

    @Test func workspaceInsertionIndexFollowsCurrentHoverPosition() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let workspaceAlphaJob = makeJob(
            id: "job-workspace-alpha-blank",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let workspaceBetaJob = makeJob(
            id: "job-workspace-beta-blank",
            cwd: "/tmp/workspace-beta",
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

        let sidebar = viewController.sidebarViewControllerForTesting
        guard let workspaceAlpha = store.workspaces.first(where: { $0.cwd == "/tmp/workspace-alpha" }) else {
            Issue.record("workspace-alpha was not loaded.")
            return
        }
        #expect(sidebar.workspaceInsertionIndexForTesting(workspaceAlpha, hoveringBelowMidpoint: false) == 0)
        #expect(sidebar.workspaceInsertionIndexForTesting(workspaceAlpha, hoveringBelowMidpoint: true) == 1)
    }

    @Test func workspaceBlankAreaInsertionUsesPointerPosition() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let workspaceAlphaJob = makeJob(
            id: "job-workspace-alpha-blank-area",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let workspaceBetaJob = makeJob(
            id: "job-workspace-beta-blank-area",
            cwd: "/tmp/workspace-beta",
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

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.blankAreaWorkspaceInsertionIndexForTesting(atEnd: false) == 0)
        #expect(sidebar.blankAreaWorkspaceInsertionIndexForTesting(atEnd: true) == store.workspaces.count)
    }

    @Test func workspaceDropOnJobRowIsRejected() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let workspaceAlphaJob = makeJob(
            id: "job-workspace-alpha-reject",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let workspaceBetaJob = makeJob(
            id: "job-workspace-beta-reject",
            cwd: "/tmp/workspace-beta",
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

        let sidebar = viewController.sidebarViewControllerForTesting
        guard let workspaceBeta = store.workspaces.first(where: { $0.cwd == "/tmp/workspace-beta" }),
              let workspaceAlpha = store.workspaces.first(where: { $0.cwd == "/tmp/workspace-alpha" }),
              let alphaJob = workspaceAlpha.jobs.first
        else {
            Issue.record("workspace/job state was not loaded.")
            return
        }

        #expect(sidebar.workspaceDropIsRejectedForTesting(workspaceBeta, proposedJob: alphaJob))
    }

    @Test func jobDropOnBlankAreaIsRejected() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let firstJob = makeJob(
            id: "job-blank-area-reject",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let secondJob = makeJob(
            id: "job-blank-area-peer",
            cwd: "/tmp/workspace-alpha",
            status: .queued,
            targetSummary: "Queued review"
        )
        let workspace = CodexReviewWorkspace(
            cwd: "/tmp/workspace-alpha",
            jobs: [firstJob, secondJob]
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace]
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.jobDropIsRejectedForTesting(firstJob))
    }

    @Test func jobDropReordersWithinWorkspaceAndPreservesSelection() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let firstJob = makeJob(
            id: "job-1",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let secondJob = makeJob(
            id: "job-2",
            cwd: "/tmp/workspace-alpha",
            status: .succeeded,
            targetSummary: "Commit: abc123"
        )
        let workspace = CodexReviewWorkspace(
            cwd: "/tmp/workspace-alpha",
            jobs: [firstJob, secondJob]
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace]
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.selectJobForTesting(firstJob)
        #expect(sidebar.performJobDropForTesting(firstJob, proposedWorkspace: workspace, childIndex: workspace.jobs.count))
        #expect(sidebar.displayedJobIDsForTesting(in: workspace) == ["job-2", "job-1"])
        #expect(sidebar.selectedJobForTesting?.id == "job-1")
    }

    @Test func workspaceDropPreservesExpansionState() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let alphaJob = makeJob(
            id: "job-alpha",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let betaJob = makeJob(
            id: "job-beta",
            cwd: "/tmp/workspace-beta",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let alphaWorkspace = CodexReviewWorkspace(
            cwd: alphaJob.cwd,
            jobs: [alphaJob]
        )
        let betaWorkspace = CodexReviewWorkspace(
            cwd: betaJob.cwd,
            jobs: [betaJob]
        )
        betaWorkspace.isExpanded = false

        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: [alphaWorkspace, betaWorkspace]
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.performWorkspaceDropForTesting(betaWorkspace, toIndex: 0))
        #expect(sidebar.workspaceIsExpandedForTesting(betaWorkspace) == false)
    }

    @Test func crossWorkspaceJobDropIsRejected() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let alphaJob = makeJob(
            id: "job-alpha",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let betaJob = makeJob(
            id: "job-beta",
            cwd: "/tmp/workspace-beta",
            status: .running,
            targetSummary: "Base branch: main"
        )
        let alphaWorkspace = CodexReviewWorkspace(
            cwd: alphaJob.cwd,
            jobs: [alphaJob]
        )
        let betaWorkspace = CodexReviewWorkspace(
            cwd: betaJob.cwd,
            jobs: [betaJob]
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: [alphaWorkspace, betaWorkspace]
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.performJobDropForTesting(alphaJob, proposedWorkspace: betaWorkspace, childIndex: 0) == false)
        #expect(alphaWorkspace.jobs.map(\.id) == ["job-alpha"])
        #expect(betaWorkspace.jobs.map(\.id) == ["job-beta"])
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
        #expect(sidebar.floatsGroupRowsEnabledForTesting)
        #expect(sidebar.jobRowUsesReviewMonitorJobRowViewForTesting(job))
    }

    @Test func scrollingSidebarMakesWorkspaceHeaderFloat() throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let primaryJobs = (0..<8).map { index in
            makeJob(
                id: "job-\(index)",
                cwd: "/tmp/workspace-alpha",
                status: .running,
                targetSummary: "Review \(index)"
            )
        }
        let secondaryJob = makeJob(
            id: "job-secondary",
            cwd: "/tmp/workspace-beta",
            status: .queued,
            targetSummary: "Queued review"
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [secondaryJob] + primaryJobs)
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 360, height: 220))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let workspace = try #require(store.workspaces.first(where: { $0.cwd == "/tmp/workspace-alpha" }))
        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.scrollSidebarToOffsetForTesting(80)

        #expect(sidebar.workspaceRowIsFloatingForTesting(workspace))
    }

    @Test func togglingWorkspaceDisclosureKeepsDetailAndRestoresSelectionAfterReexpand() async throws {
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
        let sidebar = viewController.sidebarViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        sidebar.selectJobForTesting(job)
        let selectedSnapshot = try await awaitTransportRender(transport, after: initialRenderCount)

        let stableRenderCount = transport.renderCountForTesting
        sidebar.toggleWorkspaceDisclosureForTesting(workspace)
        await transport.flushMainQueueForTesting()

        #expect(sidebar.workspaceIsExpandedForTesting(workspace) == false)
        #expect(sidebar.selectedJobForTesting?.id == job.id)
        #expect(transport.renderCountForTesting == stableRenderCount)
        #expect(transport.renderSnapshotForTesting == selectedSnapshot)

        sidebar.toggleWorkspaceDisclosureForTesting(workspace)
        await transport.flushMainQueueForTesting()

        #expect(sidebar.workspaceIsExpandedForTesting(workspace))
        #expect(sidebar.selectedJobForTesting?.id == job.id)
    }

    @Test func collapsedWorkspaceStaysCollapsedAcrossStoreReload() throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = makeJob(
            id: "job-1",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [job])
        )
        let workspace = try #require(store.workspaces.first(where: { $0.cwd == job.cwd }))
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.toggleWorkspaceDisclosureForTesting(workspace)
        #expect(sidebar.workspaceIsExpandedForTesting(workspace) == false)

        let replacement = makeJob(
            id: "job-2",
            cwd: job.cwd,
            status: .succeeded,
            targetSummary: "Commit: abc123"
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [replacement])
        )

        let reloadedWorkspace = try #require(store.workspaces.first(where: { $0.cwd == job.cwd }))
        #expect(sidebar.workspaceIsExpandedForTesting(reloadedWorkspace) == false)
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

    @Test func sidebarContextMenuPresentationRestoresResponderStateAfterClosing() {
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

        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.focusSidebarForTesting()

        #expect(sidebar.sidebarHasFirstResponderForTesting)
        #expect(sidebar.acceptsFirstResponderForTesting)
        #expect(sidebar.hasTemporaryContextMenuForTesting == false)

        var presentedTitles: [String] = []
        sidebar.presentContextMenuForTesting(for: job) { menu in
            presentedTitles = menu.items.map(\.title)
            #expect(sidebar.isPresentingContextMenuForTesting)
            #expect(sidebar.acceptsFirstResponderForTesting == false)
            #expect(sidebar.sidebarHasFirstResponderForTesting == false)
            #expect(sidebar.hasTemporaryContextMenuForTesting)
        }

        #expect(presentedTitles == ["Cancel"])
        #expect(sidebar.isPresentingContextMenuForTesting == false)
        #expect(sidebar.acceptsFirstResponderForTesting)
        #expect(sidebar.sidebarHasFirstResponderForTesting)
        #expect(sidebar.hasTemporaryContextMenuForTesting == false)
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
        #expect(viewController.contentPaneViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.contentPaneViewControllerForTesting.displayedTitleForTesting == nil)
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
        let harness = makeWindowHarness(store: store)
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)

        let selectedSnapshot = try await awaitTransportRender(transport, after: initialRenderCount)
        #expect(
            selectedSnapshot == .init(
                title: nil,
                summary: nil,
                log: recentJob.logText,
                isShowingEmptyState: false
            )
        )
        #expect(window.title == recentJob.targetSummary)
        #expect(window.subtitle == recentJob.cwd)

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
        let harness = makeWindowHarness(store: store)
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let selectedSnapshot = try await awaitTransportRender(transport, after: initialRenderCount)
        #expect(selectedSnapshot.title == nil)
        #expect(selectedSnapshot.summary == nil)
        #expect(window.title == job.targetSummary)
        #expect(window.subtitle == job.cwd)

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
        let harness = makeWindowHarness(store: store)
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting

        let firstRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)

        let activeSnapshot = try await awaitTransportRender(transport, after: firstRenderCount)
        #expect(activeSnapshot.title == nil)
        #expect(activeSnapshot.summary == nil)
        #expect(window.title == activeJob.targetSummary)
        #expect(window.subtitle == activeJob.cwd)

        let secondRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)

        let recentSnapshot = try await awaitTransportRender(transport, after: secondRenderCount)
        #expect(
            recentSnapshot == .init(
                title: nil,
                summary: nil,
                log: recentJob.logText,
                isShowingEmptyState: false
            )
        )
        #expect(window.title == recentJob.targetSummary)
        #expect(window.subtitle == recentJob.cwd)
    }

    @Test func firstSelectionFromEmptyStatePinsUnvisitedJobToBottom() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let job = makeJob(
            id: "job-first-bottom",
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
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)
        transport.view.layoutSubtreeIfNeeded()

        #expect(transport.isLogPinnedToBottomForTesting)
    }

    @Test func switchingSelectedJobStartsUnvisitedJobAtBottomAndRestoresPreviousOffset() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let longActiveLog = (0..<400).map { "active line \($0)" }.joined(separator: "\n")
        let longRecentLog = (0..<400).map { "recent line \($0)" }.joined(separator: "\n")
        let activeJob = makeJob(
            id: "job-active-scroll",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Active review in progress.",
            logText: longActiveLog
        )
        let recentJob = makeJob(
            id: "job-recent-scroll",
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "Recent review completed.",
            logText: longRecentLog
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [activeJob, recentJob])
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting

        let firstRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)
        _ = try await awaitTransportRender(transport, after: firstRenderCount)

        transport.scrollLogToOffsetForTesting(120)
        let activeOffset = transport.logVerticalScrollOffsetForTesting
        #expect(activeOffset > 0)
        #expect(transport.isLogPinnedToBottomForTesting == false)

        let secondRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)
        _ = try await awaitTransportRender(transport, after: secondRenderCount)

        #expect(transport.isLogPinnedToBottomForTesting)

        let thirdRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)
        _ = try await awaitTransportRender(transport, after: thirdRenderCount)

        #expect(transport.logVerticalScrollOffsetForTesting == activeOffset)
        #expect(transport.isLogPinnedToBottomForTesting == false)
    }

    @Test func switchingSelectedJobRestoresPinnedBottomPosition() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let longActiveLog = (0..<400).map { "active line \($0)" }.joined(separator: "\n")
        let longRecentLog = (0..<400).map { "recent line \($0)" }.joined(separator: "\n")
        let activeJob = makeJob(
            id: "job-active-bottom",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Active review in progress.",
            logText: longActiveLog
        )
        let recentJob = makeJob(
            id: "job-recent-bottom",
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "Recent review completed.",
            logText: longRecentLog
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [activeJob, recentJob])
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting

        let firstRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)
        _ = try await awaitTransportRender(transport, after: firstRenderCount)

        transport.scrollLogToBottomForTesting()
        #expect(transport.isLogPinnedToBottomForTesting)

        let secondRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)
        _ = try await awaitTransportRender(transport, after: secondRenderCount)

        #expect(transport.isLogPinnedToBottomForTesting)

        activeJob.appendLogEntry(.init(kind: .progress, text: "Newest active line"))

        let thirdRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)
        let snapshot = try await awaitTransportRender(transport, after: thirdRenderCount)

        #expect(snapshot.log.contains("Newest active line"))
        #expect(transport.isLogPinnedToBottomForTesting)
    }

    @Test func rehydratingSameSelectedJobPreservesLogScrollPosition() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let job = makeJob(
            id: "job-rehydrated",
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

        transport.scrollLogToOffsetForTesting(120)
        let preservedOffset = transport.logVerticalScrollOffsetForTesting
        #expect(preservedOffset > 0)

        let replacement = makeJob(
            id: "job-rehydrated",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )

        let refreshRenderCount = transport.renderCountForTesting
        store.loadForTesting(serverState: .running, workspaces: makeWorkspaces(from: [replacement]))
        await transport.flushMainQueueForTesting()

        #expect(transport.renderCountForTesting == refreshRenderCount)
        #expect(transport.logVerticalScrollOffsetForTesting == preservedOffset)
    }

    @Test func switchingJobWithIdenticalLogTextStartsUnvisitedJobAtBottom() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let sharedLog = (0..<400).map { "shared line \($0)" }.joined(separator: "\n")
        let firstJob = makeJob(
            id: "job-identical-1",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: sharedLog
        )
        let secondJob = makeJob(
            id: "job-identical-2",
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "Review completed.",
            logText: sharedLog
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(serverState: .running, workspaces: makeWorkspaces(from: [firstJob, secondJob]))
        let viewController = ReviewMonitorSplitViewController(store: store)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting

        let firstRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(firstJob)
        _ = try await awaitTransportRender(transport, after: firstRenderCount)

        transport.scrollLogToOffsetForTesting(120)
        #expect(transport.logVerticalScrollOffsetForTesting > 0)

        let secondRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(secondJob)
        _ = try await awaitTransportRender(transport, after: secondRenderCount)

        #expect(transport.isLogPinnedToBottomForTesting)
    }

    @Test func shortLogSelectionCacheRestoresTopAfterLaterGrowth() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let shortLog = (0..<3).map { "short line \($0)" }.joined(separator: "\n")
        let longLog = (0..<400).map { "long line \($0)" }.joined(separator: "\n")
        let shortJob = makeJob(
            id: "job-short-cache",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Short preview.",
            logText: shortLog
        )
        let recentJob = makeJob(
            id: "job-short-cache-recent",
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "Recent review completed.",
            logText: longLog
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(serverState: .running, workspaces: makeWorkspaces(from: [shortJob, recentJob]))
        let viewController = ReviewMonitorSplitViewController(store: store)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting

        let firstRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(shortJob)
        _ = try await awaitTransportRender(transport, after: firstRenderCount)

        let secondRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)
        _ = try await awaitTransportRender(transport, after: secondRenderCount)

        shortJob.replaceLogEntries([.init(kind: .agentMessage, text: longLog)])

        let thirdRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(shortJob)
        _ = try await awaitTransportRender(transport, after: thirdRenderCount)

        #expect(transport.logVerticalScrollOffsetForTesting == 0)
        #expect(transport.isLogPinnedToBottomForTesting == false)
    }

    @Test func previouslySelectedJobUpdatesDoNotRepaintCurrentDetailPane() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let activeJob = makeJob(
            id: "job-old-selection",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Active review.",
            logText: "Active log\n"
        )
        let recentJob = makeJob(
            id: "job-current-selection",
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "Recent review.",
            logText: "Recent log\n"
        )
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(serverState: .running, workspaces: makeWorkspaces(from: [activeJob, recentJob]))
        let viewController = ReviewMonitorSplitViewController(store: store)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting

        let firstRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)
        _ = try await awaitTransportRender(transport, after: firstRenderCount)

        let secondRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)
        let snapshot = try await awaitTransportRender(transport, after: secondRenderCount)

        let stableRenderCount = transport.renderCountForTesting
        activeJob.appendLogEntry(.init(kind: .progress, text: "stale update"))
        await transport.flushMainQueueForTesting()

        #expect(transport.renderCountForTesting == stableRenderCount)
        #expect(transport.renderSnapshotForTesting == snapshot)
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
        #expect(viewController.contentPaneViewControllerForTesting.isShowingEmptyStateForTesting)

        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [activeJob])
        )

        #expect(viewController.sidebarViewControllerForTesting.selectedJobForTesting == nil)
        #expect(viewController.contentPaneViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.contentPaneViewControllerForTesting.displayedTitleForTesting == nil)
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
        let contentPane = viewController.contentPaneViewControllerForTesting
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)

        let activeSnapshot = try await awaitTransportRender(transport, after: initialRenderCount)
        #expect(activeSnapshot.title == nil)
        #expect(activeSnapshot.summary == nil)

        let removalRenderCount = contentPane.renderCountForTesting
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: [recentJob])
        )

        let emptySnapshot = try await awaitContentPaneRender(contentPane, after: removalRenderCount)
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
        let harness = makeWindowHarness(store: store)
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let contentPane = viewController.contentPaneViewControllerForTesting
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let selectedSnapshot = try await awaitTransportRender(transport, after: initialRenderCount)
        #expect(selectedSnapshot.title == nil)
        #expect(window.title == job.targetSummary)
        #expect(window.subtitle == job.cwd)

        let clearRenderCount = contentPane.renderCountForTesting
        viewController.sidebarViewControllerForTesting.clearSelectionForTesting()

        let emptySnapshot = try await awaitContentPaneRender(contentPane, after: clearRenderCount)
        #expect(emptySnapshot.isShowingEmptyState)
        #expect(emptySnapshot.title == nil)
        #expect(emptySnapshot.summary == nil)
        #expect(emptySnapshot.log.isEmpty)
        #expect(window.title == "")
        #expect(window.subtitle == "")

        let stableRenderCount = transport.renderCountForTesting
        job.summary = "Deselected summary"
        job.replaceLogEntries([.init(kind: .agentMessage, text: "Deselected log")])
        await transport.flushMainQueueForTesting()

        #expect(transport.renderCountForTesting == stableRenderCount)
        #expect(contentPane.renderSnapshotForTesting == emptySnapshot)
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
        #expect(selectedSnapshot.title == nil)
        #expect(selectedSnapshot.summary == nil)

        let updateRenderCount = transport.renderCountForTesting
        job.status = .succeeded
        job.summary = "Review completed successfully."
        job.replaceLogEntries([.init(kind: .agentMessage, text: "Updated log")])

        let updatedSnapshot = try await awaitTransportRender(transport, after: updateRenderCount)
        #expect(viewController.sidebarViewControllerForTesting.selectedJobForTesting?.id == "job-1")
        #expect(updatedSnapshot.summary == nil)
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

    @Test func coalescedLogTextUpdateUsesAppendPathWhenSuffixCanBeDerived() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let job = CodexReviewJob.makeForTesting(
            id: "job-coalesced",
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

        let updateRenderCount = transport.renderCountForTesting
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        job.appendLogEntry(.init(kind: .agentMessage, groupID: "msg_1", text: " one"))
        job.appendLogEntry(.init(kind: .agentMessage, groupID: "msg_1", text: " two"))

        let snapshot = try await awaitTransportRender(transport, after: updateRenderCount)
        #expect(snapshot.log == "Initial one two")
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

        await transport.flushMainQueueForTesting()

        #expect(transport.renderCountForTesting == metadataRenderCount)
        #expect(transport.displayedLogForTesting == "Initial log")
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

        transport.scrollLogToBottomForTesting()
        #expect(transport.isLogPinnedToBottomForTesting)

        transport.scrollLogToTopForTesting()
        #expect(transport.isLogPinnedToBottomForTesting == false)

        let unpinnedRenderCount = transport.renderCountForTesting
        let unpinnedAutoFollow = transport.logAutoFollowCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Unpinned update"))
        _ = try await awaitTransportRender(transport, after: unpinnedRenderCount)
        #expect(transport.logAutoFollowCountForTesting == unpinnedAutoFollow)
        #expect(transport.isLogPinnedToBottomForTesting == false)

        transport.scrollLogToBottomForTesting()
        #expect(transport.isLogPinnedToBottomForTesting)

        let pinnedRenderCount = transport.renderCountForTesting
        let pinnedAutoFollow = transport.logAutoFollowCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Pinned update"))
        _ = try await awaitTransportRender(transport, after: pinnedRenderCount)
        #expect(transport.logAutoFollowCountForTesting == pinnedAutoFollow + 1)
        #expect(transport.isLogPinnedToBottomForTesting)
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
        #expect(snapshot.summary == nil)
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
        #expect(snapshot.summary == nil)
        #expect(snapshot.log == "Authentication required. Sign in to ReviewMCP and retry.")
    }

    @Test func signInViewStartsAuthenticationFromButtonAction() async {
        guard #available(macOS 26.0, *) else {
            return
        }
        let backend = AuthActionBackend()
        let store = CodexReviewStore(backend: backend)
        let view = SignInView(store: store)

        view.performAuthenticationAction()
        await backend.waitForBeginAuthenticationCallCount(1)

        #expect(backend.beginAuthenticationCallCount() == 1)
    }

    @Test func signInViewCancelsAuthenticationFromButtonAction() async {
        guard #available(macOS 26.0, *) else {
            return
        }
        let backend = AuthActionBackend()
        let store = CodexReviewStore(backend: backend)
        store.auth.updateState(
            .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue."
                )
            )
        )
        let view = SignInView(store: store)

        view.performAuthenticationAction()
        await backend.waitForCancelAuthenticationCallCount(1)

        #expect(backend.cancelAuthenticationCallCount() == 1)
        #expect(backend.beginAuthenticationCallCount() == 0)
    }

    @Test func statusViewDoesNotRetryAuthenticationWhileAuthenticated() async {
        guard #available(macOS 26.0, *) else {
            return
        }
        let backend = AuthActionBackend()
        let store = CodexReviewStore(backend: backend)
        store.auth.updateState(
            .failed(
                "Authentication failed.",
                isAuthenticated: true,
                accountID: "review@example.com"
            )
        )
        let view = StatusView(store: store)

        #expect(view.canRetryAuthentication == false)
        #expect(view.showsAuthenticationAction == false)
        #expect(view.canSignOut)

        view.performAuthenticationAction()

        #expect(backend.beginAuthenticationCallCount() == 0)
    }

    @Test func statusViewCancelsAuthenticationWhileRetryAuthenticating() async {
        guard #available(macOS 26.0, *) else {
            return
        }
        let backend = AuthActionBackend()
        let store = CodexReviewStore(backend: backend)
        store.auth.updateState(
            .init(
                isAuthenticated: true,
                accountID: "review@example.com",
                progress: .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue."
                )
            )
        )
        let view = StatusView(store: store)

        #expect(view.showsAuthenticationAction)
        #expect(view.authenticationActionTitle == "Cancel")
        #expect(view.canSignOut == false)

        view.performAuthenticationAction()
        await backend.waitForCancelAuthenticationCallCount(1)

        #expect(backend.cancelAuthenticationCallCount() == 1)
    }

    @Test func statusViewRestartsStoppedServer() async {
        guard #available(macOS 26.0, *) else {
            return
        }
        let backend = CountingStartBackend(
            shouldAutoStartEmbeddedServer: false,
            initialAuthState: .signedIn(accountID: "review@example.com")
        )
        let store = CodexReviewStore(backend: backend)
        store.loadForTesting(
            serverState: .stopped,
            authState: .signedIn(accountID: "review@example.com"),
            workspaces: []
        )
        let view = StatusView(store: store)

        #expect(view.showsServerRestartAction)

        view.restartServer()
        await backend.waitForStartCallCount(1)

        #expect(backend.startCallCount() == 1)
    }

    @Test func signInViewDescriptionTextReflectsAuthState() {
        guard #available(macOS 26.0, *) else {
            return
        }
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())

        store.auth.updateState(
            .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue."
                )
            )
        )
        #expect(SignInView(store: store).descriptionText == nil)

        store.auth.updateState(.failed("Authentication failed."))
        #expect(SignInView(store: store).descriptionText == "Authentication failed.")

        store.auth.updateState(.signedIn(accountID: "review@example.com"))
        #expect(SignInView(store: store).descriptionText == nil)

        store.loadForTesting(
            serverState: .failed("The embedded server stopped responding."),
            authState: .signedOut,
            workspaces: []
        )
        #expect(SignInView(store: store).descriptionText == "The embedded server stopped responding.")
        #expect(SignInView(store: store).showsServerRestartAction)

        store.loadForTesting(
            serverState: .stopped,
            authState: .signedOut,
            workspaces: []
        )
        #expect(SignInView(store: store).showsServerRestartAction == false)
    }

    @Test func signInViewRestartServerUsesStoreRestartFlow() async {
        guard #available(macOS 26.0, *) else {
            return
        }
        let backend = CountingStartBackend(
            shouldAutoStartEmbeddedServer: false,
            initialAuthState: .signedOut
        )
        let store = CodexReviewStore(backend: backend)
        store.loadForTesting(
            serverState: .failed("The embedded server stopped responding."),
            authState: .signedOut,
            workspaces: []
        )
        let view = SignInView(store: store)

        #expect(view.showsServerRestartAction)

        view.restartServer()
        await backend.waitForStartCallCount(1)

        #expect(backend.startCallCount() == 1)
        #expect(store.serverState == .starting)
    }

    @Test func signInViewRestartServerCancelsAuthenticationBeforeRestart() async {
        guard #available(macOS 26.0, *) else {
            return
        }
        let backend = CountingStartBackend(
            shouldAutoStartEmbeddedServer: false,
            initialAuthState: .signedOut
        )
        let store = CodexReviewStore(backend: backend)
        store.loadForTesting(
            serverState: .failed("The embedded server stopped responding."),
            authState: .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue."
                )
            ),
            workspaces: []
        )
        let view = SignInView(store: store)

        view.restartServer()
        await backend.waitForCancelAuthenticationCallCount(1)
        await backend.waitForStartCallCount(1)

        #expect(backend.cancelAuthenticationCallCount() == 1)
        #expect(backend.startCallCount() == 1)
    }

    @Test func mcpServerUnavailableViewRestartServerUsesStoreRestartFlow() async {
        guard #available(macOS 26.0, *) else {
            return
        }
        let backend = CountingStartBackend(
            shouldAutoStartEmbeddedServer: false,
            initialAuthState: .signedIn(accountID: "review@example.com")
        )
        let store = CodexReviewStore(backend: backend)
        store.loadForTesting(
            serverState: .failed("The embedded server stopped responding."),
            authState: .signedIn(accountID: "review@example.com"),
            workspaces: []
        )
        let view = MCPServerUnavailableView(store: store)

        #expect(view.failureMessage == "The embedded server stopped responding.")

        view.restartServer()
        await backend.waitForStartCallCount(1)

        #expect(backend.startCallCount() == 1)
        #expect(store.serverState == .starting)
    }

    @Test func mcpServerUnavailableViewRestartCancelsAuthenticationBeforeRestart() async {
        guard #available(macOS 26.0, *) else {
            return
        }
        let backend = CountingStartBackend(
            shouldAutoStartEmbeddedServer: false,
            initialAuthState: .signedOut
        )
        let store = CodexReviewStore(backend: backend)
        store.loadForTesting(
            serverState: .failed("The embedded server stopped responding."),
            authState: .init(
                isAuthenticated: true,
                accountID: "review@example.com",
                progress: .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue."
                )
            ),
            workspaces: []
        )
        let view = MCPServerUnavailableView(store: store)

        view.restartServer()
        await backend.waitForCancelAuthenticationCallCount(1)
        await backend.waitForStartCallCount(1)

        #expect(backend.cancelAuthenticationCallCount() == 1)
        #expect(backend.startCallCount() == 1)
    }

}

@available(macOS 26.0, *)
@MainActor
private struct ReviewMonitorWindowHarness {
    let windowController: ReviewMonitorWindowController
    let viewController: ReviewMonitorSplitViewController
    let window: NSWindow
}

@available(macOS 26.0, *)
@MainActor
private func makeWindowHarness(
    store: CodexReviewStore,
    authState: CodexReviewAuthModel.State = .signedIn(accountID: "review@example.com"),
    contentSize: NSSize? = nil,
    performInitialAuthRefresh: Bool = false
) -> ReviewMonitorWindowHarness {
    store.auth.updateState(authState)
    let windowController = ReviewMonitorWindowController(
        store: store,
        performInitialAuthRefresh: performInitialAuthRefresh
    )
    guard let window = windowController.window else {
        fatalError("ReviewMonitorWindowController did not create a window.")
    }
    if let contentSize {
        window.setContentSize(contentSize)
    }
    return ReviewMonitorWindowHarness(
        windowController: windowController,
        viewController: windowController.splitViewControllerForTesting,
        window: window
    )
}

@available(macOS 26.0, *)
@MainActor
private func waitForDisplayedContentKind(
    _ windowController: ReviewMonitorWindowController,
    _ expected: ReviewMonitorWindowController.DisplayedContentKind,
    timeout: Duration = .seconds(2)
) async throws {
    let windowControllerBox = UncheckedSendableBox(windowController)
    try await withTestTimeout(timeout) {
        while await MainActor.run(body: {
            windowControllerBox.value.displayedContentKindForTesting != expected
        }) {
            await Task.yield()
        }
    }
}

@available(macOS 26.0, *)
@MainActor
private func waitForSidebarPresentation(
    _ viewController: ReviewMonitorSplitViewController,
    _ expected: ReviewMonitorSplitViewController.SidebarPresentationForTesting,
    timeout: Duration = .seconds(2)
) async throws {
    let viewControllerBox = UncheckedSendableBox(viewController)
    try await withTestTimeout(timeout) {
        while await MainActor.run(body: {
            viewControllerBox.value.sidebarPresentationForTesting != expected
        }) {
            await Task.yield()
        }
    }
}

@available(macOS 26.0, *)
@MainActor
private func waitForEmbeddedContentSubviewCount(
    _ windowController: ReviewMonitorWindowController,
    _ expected: Int,
    timeout: Duration = .seconds(2)
) async throws {
    let windowControllerBox = UncheckedSendableBox(windowController)
    try await withTestTimeout(timeout) {
        while await MainActor.run(body: {
            windowControllerBox.value.embeddedContentSubviewCountForTesting != expected
        }) {
            await Task.yield()
        }
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

@available(macOS 26.0, *)
@MainActor
private func expectLogTextContainerWidthTracksTextView(
    _ transport: ReviewMonitorTransportViewController
) {
    let textViewFrame = transport.logTextViewFrameForTesting
    let textContainerInset = transport.logTextContainerInsetForTesting
    let textContainerSize = transport.logTextContainerSizeForTesting
    let expectedWidth = max(0, textViewFrame.width - textContainerInset.width * 2)

    #expect(abs(textContainerSize.width - expectedWidth) < 1)
}

@available(macOS 26.0, *)
@MainActor
private func awaitContentPaneRender(
    _ contentPane: ReviewMonitorContentPaneViewController,
    after renderCount: Int,
    timeout: Duration = .seconds(2)
) async throws -> ReviewMonitorContentPaneViewController.RenderSnapshotForTesting {
    let contentPaneBox = UncheckedSendableBox(contentPane)
    return try await withTestTimeout(timeout) {
        await contentPaneBox.value.waitForRenderCountForTesting(renderCount + 1)
        return await MainActor.run {
            contentPaneBox.value.renderSnapshotForTesting
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
    return order.map { cwd in
        CodexReviewWorkspace(
            cwd: cwd,
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
    let initialAuthState: CodexReviewAuthModel.State = .signedOut

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
    let initialAuthState: CodexReviewAuthModel.State
    private let startSignal = AsyncSignal()
    private let cancelSignal = AsyncSignal()
    private var startCalls = 0
    private var cancelCalls = 0

    init(
        shouldAutoStartEmbeddedServer: Bool = true,
        initialAuthState: CodexReviewAuthModel.State = .signedOut
    ) {
        self.shouldAutoStartEmbeddedServer = shouldAutoStartEmbeddedServer
        self.initialAuthState = initialAuthState
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
        cancelCalls += 1
        await cancelSignal.signal()
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

    func cancelAuthenticationCallCount() -> Int {
        cancelCalls
    }

    func waitForCancelAuthenticationCallCount(_ count: Int) async {
        if cancelCalls >= count {
            return
        }
        await cancelSignal.wait(untilCount: count)
    }
}

@MainActor
private final class AuthActionBackend: CodexReviewStoreBackend {
    var isActive: Bool = false
    let shouldAutoStartEmbeddedServer = false
    let initialAuthState: CodexReviewAuthModel.State

    private let refreshSignal = AsyncSignal()
    private let beginSignal = AsyncSignal()
    private let cancelSignal = AsyncSignal()
    private var refreshCalls = 0
    private var beginCalls = 0
    private var cancelCalls = 0

    init(initialAuthState: CodexReviewAuthModel.State = .signedOut) {
        self.initialAuthState = initialAuthState
    }

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
    }

    func refreshAuthState(auth: CodexReviewAuthModel) async {
        _ = auth
        refreshCalls += 1
        await refreshSignal.signal()
    }

    func beginAuthentication(auth: CodexReviewAuthModel) async {
        _ = auth
        beginCalls += 1
        await beginSignal.signal()
    }

    func cancelAuthentication(auth: CodexReviewAuthModel) async {
        _ = auth
        cancelCalls += 1
        await cancelSignal.signal()
    }

    func logout(auth: CodexReviewAuthModel) async {
        _ = auth
    }

    func beginAuthenticationCallCount() -> Int {
        beginCalls
    }

    func refreshAuthStateCallCount() -> Int {
        refreshCalls
    }

    func waitForRefreshAuthStateCallCount(_ count: Int) async {
        if refreshCalls >= count {
            return
        }
        await refreshSignal.wait(untilCount: count)
    }

    func waitForBeginAuthenticationCallCount(_ count: Int) async {
        if beginCalls >= count {
            return
        }
        await beginSignal.wait(untilCount: count)
    }

    func cancelAuthenticationCallCount() -> Int {
        cancelCalls
    }

    func waitForCancelAuthenticationCallCount(_ count: Int) async {
        if cancelCalls >= count {
            return
        }
        await cancelSignal.wait(untilCount: count)
    }
}
