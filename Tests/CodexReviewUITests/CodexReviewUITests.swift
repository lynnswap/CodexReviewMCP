import AppKit
import Foundation
import SwiftUI
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
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarTopAccessoryCountForTesting == 1)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)
        #expect(
            viewController.sidebarTopAccessorySegmentAccessibilityDescriptionsForTesting ==
                ["Workspace", "Account"]
        )
        #expect(viewController.contentAccessoryCountForTesting == 0)
        #expect(viewController.sidebarViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.contentPaneViewControllerForTesting.isShowingEmptyStateForTesting)
    }

    @Test func splitViewShowsEmptyStateWithoutJobs() {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        #expect(viewController.splitViewItems.count == 2)
        #expect(viewController.sidebarTopAccessoryCountForTesting == 1)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)
        #expect(viewController.contentAccessoryCountForTesting == 0)
        #expect(viewController.sidebarViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.contentPaneViewControllerForTesting.isShowingEmptyStateForTesting)
    }

    @Test func splitViewShowsUnavailableSidebarWhenServerFailedOnLoad() {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .failed("Embedded server is unavailable in preview mode."),
            workspaces: []
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        #expect(viewController.splitViewItems.count == 2)
        #expect(viewController.sidebarPresentationForTesting == .unavailable)
        #expect(viewController.sidebarTopAccessoryCountForTesting == 1)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)
    }

    @Test func splitViewShowsJobSidebarWhenServerRunningOnLoad() {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            serverURL: URL(string: "http://localhost:9417/mcp"),
            workspaces: []
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarPresentationForTesting == .jobList)
        #expect(viewController.sidebarTopAccessoryCountForTesting == 1)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)
    }

    @Test func splitViewSwitchesSidebarPresentationWhenPickerSelectionChanges() async throws {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let uiState = ReviewMonitorUIState()
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarPresentationForTesting == .jobList)
        #expect(viewController.sidebarBottomAccessoryIsHiddenForTesting == false)

        uiState.sidebarSelection = .account
        try await waitForSidebarBottomAccessoryHidden(viewController, true)
        #expect(viewController.sidebarPresentationForTesting == .accountList)

        uiState.sidebarSelection = .workspace
        try await waitForSidebarBottomAccessoryHidden(viewController, false)
        #expect(viewController.sidebarPresentationForTesting == .jobList)
    }

    @Test func statusAccessoryViewControllerObservesOnlySidebarSelection() {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let uiState = ReviewMonitorUIState()
        let viewController = ReviewMonitorServerStatusAccessoryViewController(
            store: store,
            uiState: uiState
        )
        viewController.loadViewIfNeeded()

        #expect(viewController.observationHandleCountForTesting == 1)
    }

    @Test func contentPanePinsDisplayedContentToSafeArea() {
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
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let harness = makeWindowHarness(store: store)
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }

        #expect(window.toolbar != nil)
        #expect(harness.windowController.displayedContentKindForTesting == .splitView)
        #expect(
            viewController.toolbarIdentifiersForTesting ==
                [
                    .toggleSidebar,
                    .flexibleSpace,
                    viewController.addAccountToolbarItemIdentifierForTesting,
                    .sidebarTrackingSeparator,
                    .flexibleSpace,
                ]
        )
        #expect(viewController.addAccountToolbarItemIsHiddenForTesting)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .visible)
        #expect(window.title == "Untitled")
        #expect(window.subtitle == "")
        #expect(window.isMovableByWindowBackground == false)
        #expect(viewController.sidebarAllowsFullHeightLayoutForTesting)
        #expect(viewController.contentAutomaticallyAdjustsSafeAreaInsetsForTesting)
    }

    @Test func splitViewShowsAddAccountToolbarItemOnlyForAccountSidebar() async throws {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let uiState = ReviewMonitorUIState()
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))

        viewController.attach(to: window)
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false
        window.layoutIfNeeded()

        #expect(viewController.addAccountToolbarItemIsHiddenForTesting)

        uiState.sidebarSelection = .account
        try await waitForAddAccountToolbarItemHidden(viewController, false)
        #expect(viewController.addAccountToolbarItemIsHiddenForTesting == false)

        uiState.sidebarSelection = .workspace
        try await waitForAddAccountToolbarItemHidden(viewController, true)
        #expect(viewController.addAccountToolbarItemIsHiddenForTesting)
    }

    @Test func splitViewHidesAddAccountToolbarItemWhileSidebarIsCollapsed() async throws {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let uiState = ReviewMonitorUIState()
        uiState.sidebarSelection = .account
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))

        viewController.attach(to: window)
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false
        window.layoutIfNeeded()

        try await waitForAddAccountToolbarItemHidden(viewController, false)
        sidebarItem.isCollapsed = true
        try await waitForAddAccountToolbarItemHidden(viewController, true)
        #expect(viewController.addAccountToolbarItemIsHiddenForTesting)

        sidebarItem.isCollapsed = false
        try await waitForAddAccountToolbarItemHidden(viewController, false)
        #expect(viewController.addAccountToolbarItemIsHiddenForTesting == false)
    }

    @Test func previewContentViewControllerConfiguresAttachedWindowLikeSplitPresentation() {
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
        let backend = AuthActionBackend(
            initialAuthState: .signedIn(accountID: "review@example.com")
        )
        let store = makeStore(backend: backend)
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

    @Test func windowControllerKeepsSplitViewForUnsavedCurrentSession() {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let currentAccount = CodexAccount(email: "current@example.com", planType: "pro")
        store.loadForTesting(
            serverState: .running,
            authPhase: .signedOut,
            account: currentAccount,
            savedAccounts: [],
            workspaces: []
        )
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

    @Test func windowControllerForceSplitViewShowsSplitViewWhenSignedOut() {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let harness = makeWindowHarness(
            store: store,
            authState: .signedOut,
            forceSplitView: true
        )
        let window = harness.window
        defer { window.close() }

        #expect(harness.windowController.displayedContentKindForTesting == .splitView)
        #expect(harness.windowController.isSplitViewEmbeddedForTesting)
        #expect(harness.windowController.isSignInViewEmbeddedForTesting == false)
        #expect(window.toolbar != nil)
        #expect(window.titleVisibility == .visible)
        #expect(window.isMovableByWindowBackground == false)
    }

    @Test func windowControllerDoesNotRefreshAuthStateBeforeStoreStart() async {
        let backend = AuthActionBackend()
        let store = makeStore(backend: backend)
        let windowController = ReviewMonitorWindowController(store: store)
        defer { windowController.window?.close() }
        await Task.yield()

        #expect(backend.refreshAuthStateCallCount() == 0)
    }

    @Test func windowControllerSwitchesToSignInViewAfterLogout() async throws {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let harness = makeWindowHarness(
            store: store,
            authState: .signedIn(accountID: "review@example.com")
        )
        let window = harness.window
        defer { window.close() }

        applyTestAuthState(auth: store.auth, state: .signedOut)
        try await waitForDisplayedContentKind(harness.windowController, .signInView)
        try await waitForEmbeddedContentSubviewCount(harness.windowController, 1)

        #expect(harness.windowController.embeddedContentSubviewCountForTesting == 1)
        #expect(window.toolbar == nil)
        #expect(window.title == "")
        #expect(window.subtitle == "")
        #expect(window.isMovableByWindowBackground)
    }

    @Test func windowControllerCrossfadesBackToSplitViewAfterAuthentication() async throws {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let harness = makeWindowHarness(
            store: store,
            authState: .signedOut
        )
        let window = harness.window
        defer { window.close() }

        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        try await waitForDisplayedContentKind(harness.windowController, .splitView)
        try await waitForEmbeddedContentSubviewCount(harness.windowController, 1)

        #expect(harness.windowController.embeddedContentSubviewCountForTesting == 1)
        #expect(window.toolbar != nil)
        #expect(window.titleVisibility == .visible)
        #expect(window.titlebarSeparatorStyle == .automatic)
        #expect(window.isMovableByWindowBackground == false)
    }

    @Test func windowControllerRapidAuthFlipsKeepLatestContentEmbedded() async throws {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let harness = makeWindowHarness(
            store: store,
            authState: .signedIn(accountID: "review@example.com")
        )
        let window = harness.window
        defer { window.close() }

        applyTestAuthState(auth: store.auth, state: .signedOut)
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        try await waitForDisplayedContentKind(harness.windowController, .splitView)
        try await waitForEmbeddedContentSubviewCount(harness.windowController, 1)
        try await Task.sleep(for: .milliseconds(300))
        try await waitForEmbeddedContentSubviewCount(harness.windowController, 1)

        #expect(harness.windowController.embeddedContentSubviewCountForTesting == 1)
        #expect(harness.windowController.isSplitViewEmbeddedForTesting)
        #expect(harness.windowController.isSignInViewEmbeddedForTesting == false)
        #expect(window.toolbar != nil)
    }

    @Test func windowControllerRapidAuthFlipsDoNotAccumulateEmbeddedConstraints() async throws {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let harness = makeWindowHarness(
            store: store,
            authState: .signedIn(accountID: "review@example.com")
        )
        defer { harness.window.close() }

        applyTestAuthState(auth: store.auth, state: .signedOut)
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        applyTestAuthState(auth: store.auth, state: .signedOut)
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))

        try await waitForDisplayedContentKind(harness.windowController, .splitView)
        try await waitForEmbeddedContentSubviewCount(harness.windowController, 1)
        try await Task.sleep(for: .milliseconds(300))

        #expect(harness.windowController.embeddedContentSubviewCountForTesting == 1)
        #expect(harness.windowController.isSplitViewEmbeddedForTesting)
    }

    @Test func windowControllerPreservesWindowSizeWhenSwitchingToSignInView() async throws {
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

        applyTestAuthState(auth: store.auth, state: .signedOut)
        try await waitForDisplayedContentKind(harness.windowController, .signInView)
        window.layoutIfNeeded()
        let afterSize = window.frame.size

        #expect(abs(beforeSize.width - afterSize.width) < 0.5)
        #expect(abs(beforeSize.height - afterSize.height) < 0.5)
    }

    @Test func windowControllerKeepsSplitViewAfterAuthFailure() async throws {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let harness = makeWindowHarness(
            store: store,
            authState: .signedIn(accountID: "review@example.com")
        )
        let window = harness.window
        defer { window.close() }

        applyTestAuthState(auth: store.auth, state: .failed("Authentication failed."))
        await Task.yield()

        #expect(harness.windowController.displayedContentKindForTesting == .splitView)
        #expect(window.toolbar != nil)
    }

    @Test func windowControllerKeepsSignInViewPresentedWhileAuthenticating() async throws {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let harness = makeWindowHarness(
            store: store,
            authState: .signedOut
        )
        defer { harness.window.close() }

        applyTestAuthState(
            auth: store.auth,
            state: .init(
                isAuthenticated: true,
                accountID: "review@example.com",
                progress: .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue.",
                    browserURL: "https://auth.openai.com/oauth/authorize?foo=bar"
                )
            )
        )
        try await waitForDisplayedContentKind(harness.windowController, .signInView)

        #expect(harness.windowController.displayedContentKindForTesting == .signInView)
    }

    @Test func windowControllerKeepsSplitViewWhileAuthenticatedRetryAuthenticates() async throws {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let harness = makeWindowHarness(
            store: store,
            authState: .signedIn(accountID: "review@example.com")
        )
        defer { harness.window.close() }

        applyTestAuthState(auth: store.auth, state: 
            .failed(
                "Authentication failed.",
                isAuthenticated: true,
                accountID: "review@example.com"
            )
        )
        await Task.yield()

        applyTestAuthState(auth: store.auth, state: 
            .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue.",
                    browserURL: "https://auth.openai.com/oauth/authorize?foo=bar"
                )
            )
        )
        try await waitForDisplayedContentKind(harness.windowController, .splitView)
        try await waitForEmbeddedContentSubviewCount(harness.windowController, 1)

        #expect(harness.windowController.displayedContentKindForTesting == .splitView)
        #expect(harness.windowController.isSignInViewEmbeddedForTesting == false)
        #expect(harness.windowController.isSplitViewEmbeddedForTesting)
    }

    @Test func detailLogViewFillsSafeAreaWithoutTopInsetFromRemovedHeader() async throws {
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
        let backend = CountingStartBackend()
        let store = makeStore(backend: backend)
        let harness = makeWindowHarness(store: store)
        let window = harness.window
        defer { window.close() }

        #expect(backend.startCallCount() == 0)
    }

    @Test func splitViewAttachIsIdempotentForSameWindow() {
        let backend = CountingStartBackend()
        let store = makeStore(backend: backend)
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
                try Task.checkCancellation()
                await Task.yield()
            }
        }

        #expect(runningJob.reviewMonitorLogText != initialLog)
        #expect(runningJob.reviewMonitorLogText.contains("stream.tick"))
    }

    @Test func splitViewSectionsByWorkspace() {
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

    @Test func switchingAccountFailureClearsProgressStateAndPreservesActiveAccount() async {
        let backend = AuthActionBackend(
            initialAuthState: .signedIn(accountID: "first@example.com"),
            switchStartsBlocked: true,
            switchErrorMessage: "Switch failed."
        )
        let store = makeStore(backend: backend)
        let firstAccount = CodexAccount(email: "first@example.com", planType: "pro")
        let secondAccount = CodexAccount(email: "second@example.com", planType: "plus")
        store.auth.updateSavedAccounts([firstAccount, secondAccount])
        store.auth.updateAccount(firstAccount)

        let switchTask = Task {
            try await store.auth.switchAccount(secondAccount)
        }

        await backend.waitForSwitchAccountStartCallCount(1)
        #expect(store.auth.savedAccounts.contains(where: { $0.accountKey == secondAccount.accountKey && $0.isSwitching }))

        await backend.releaseSwitchAccount()
        await #expect(throws: Error.self) {
            try await switchTask.value
        }

        #expect(store.auth.savedAccounts.contains(where: { $0.isSwitching }) == false)
        #expect(store.auth.account?.accountKey == firstAccount.accountKey)
    }

    @Test func activeAccountContextMenuSignOutUsesLogoutConfirmation() async {
        let backend = AuthActionBackend()
        let store = makeStore(backend: backend)
        let activeAccount = CodexAccount(email: "first@example.com", planType: "pro")
        let otherAccount = CodexAccount(email: "second@example.com", planType: "plus")
        let runningJob = makeJob(status: .running, targetSummary: "Uncommitted changes")
        store.loadForTesting(
            serverState: .running,
            authPhase: .signedOut,
            account: activeAccount,
            savedAccounts: [activeAccount, otherAccount],
            workspaces: makeWorkspaces(from: [runningJob])
        )
        let view = AccountContextMenuView(store: store, account: activeAccount)

        #expect(view.destructiveActionTitle == "Sign Out")
        view.requestDestructiveAccountAction()

        #expect(store.auth.isPresentingPendingAccountActionConfirmation)
        #expect(store.auth.pendingAccountActionConfirmationTitle == "Sign Out?")
        #expect(backend.logoutCallCount() == 0)
        #expect(backend.lastRemovedAccountKey() == nil)

        store.auth.confirmPendingAccountAction()
        await backend.waitForLogoutCallCount(1)

        #expect(store.auth.isPresentingPendingAccountActionConfirmation == false)
        #expect(backend.logoutCallCount() == 1)
        #expect(backend.lastRemovedAccountKey() == nil)
    }

    @Test func inactiveAccountContextMenuUsesUnifiedSignOutLabel() async {
        let backend = AuthActionBackend()
        let store = makeStore(backend: backend)
        let activeAccount = CodexAccount(email: "first@example.com", planType: "pro")
        let otherAccount = CodexAccount(email: "second@example.com", planType: "plus")
        let runningJob = makeJob(status: .running, targetSummary: "Uncommitted changes")
        store.loadForTesting(
            serverState: .running,
            authPhase: .signedOut,
            account: activeAccount,
            savedAccounts: [activeAccount, otherAccount],
            workspaces: makeWorkspaces(from: [runningJob])
        )
        let view = AccountContextMenuView(store: store, account: otherAccount)

        #expect(view.destructiveActionTitle == "Sign Out")
        view.requestDestructiveAccountAction()
        await backend.waitForRemoveAccountCallCount(1)

        #expect(store.auth.isPresentingPendingAccountActionConfirmation == false)
        #expect(backend.logoutCallCount() == 0)
        #expect(backend.lastRemovedAccountKey() == otherAccount.accountKey)
    }

    @Test func accountMenusUseFullEmailForSectionTitles() {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let account = CodexAccount(email: "masked.user@example.com", planType: "pro")
        store.auth.updateSavedAccounts([account])
        store.auth.updateAccount(account)

        let contextMenu = AccountContextMenuView(store: store, account: account)
        let statusView = StatusView(store: store)

        #expect(contextMenu.sectionTitle == account.email)
        #expect(store.auth.account?.email == account.email)
        _ = statusView
    }

    @Test func addAccountToolbarItemBeginsAuthentication() async throws {
        let backend = AuthActionBackend(initialAuthState: .signedIn(accountID: "first@example.com"))
        let store = makeStore(backend: backend)
        let uiState = ReviewMonitorUIState()
        uiState.sidebarSelection = .account
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))

        viewController.attach(to: window)
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false
        window.layoutIfNeeded()
        try await waitForAddAccountToolbarItemHidden(viewController, false)

        viewController.performAddAccountToolbarItemForTesting()
        await backend.waitForBeginAuthenticationCallCount(1)

        #expect(backend.beginAuthenticationCallCount() == 1)
    }

    @Test func codexAccountStoresMaskedEmailUsingExpectedLocalPartRules() {
        #expect(CodexAccount(email: "ashurum.deck@gmail.com").maskedEmail == "as…ck@gmail.com")
        #expect(CodexAccount(email: "ab+z@example.com").maskedEmail == "a…z@example.com")
        #expect(CodexAccount(email: "ab@example.com").maskedEmail == "a…@example.com")
        #expect(CodexAccount(email: "a@example.com").maskedEmail == "a…@example.com")
        #expect(CodexAccount(email: "alpha.beta+tag@corp.internal.example").maskedEmail == "al…ag@corp.internal.example")
        #expect(CodexAccount(email: "not-an-email").maskedEmail == "no…il")
    }

    @Test func authModelReusesSavedAccountInstancesAcrossReload() {
        let auth = CodexReviewAuthModel(controller: CodexReviewPreviewAuthController())
        let firstAccount = CodexAccount(email: "first@example.com", planType: "pro")
        let secondAccount = CodexAccount(email: "second@example.com", planType: "plus")
        auth.updateSavedAccounts([firstAccount, secondAccount])

        secondAccount.updateIsSwitching(true)

        let reloadedFirstAccount = CodexAccount(email: "first@example.com", planType: "pro")
        let reloadedSecondAccount = CodexAccount(email: "second@example.com", planType: "plus")
        auth.updateSavedAccounts([reloadedFirstAccount, reloadedSecondAccount])

        #expect(auth.savedAccounts[0] === firstAccount)
        #expect(auth.savedAccounts[1] === secondAccount)
        #expect(secondAccount.isSwitching)
        #expect(reloadedSecondAccount.isSwitching == false)
    }

    @Test func updateAccountReusesSavedAccountInstanceForMatchingKey() {
        let auth = CodexReviewAuthModel(controller: CodexReviewPreviewAuthController())
        let savedAccount = CodexAccount(email: "review@example.com", planType: "pro")
        auth.updateSavedAccounts([savedAccount])

        let detachedAccount = CodexAccount(email: "review@example.com", planType: "plus")
        auth.updateAccount(detachedAccount)

        #expect(auth.account === savedAccount)
        #expect(savedAccount.isActive)
    }

    @Test func jobCellViewUpdatesHostedObservationReferenceWithoutReplacingHostingView() throws {
        let placeholderJob = makeJob(
            id: "job-placeholder",
            status: .queued,
            targetSummary: "Queued review"
        )
        let loadedJob = makeJob(
            id: "job-loaded",
            status: .running,
            targetSummary: "Uncommitted changes"
        )

        let cellView = makeReviewMonitorJobCellViewForTesting(job: placeholderJob)
        let initialHostingViewIdentity = try #require(
            reviewMonitorJobCellHostingViewIdentityForTesting(cellView)
        )
        let initialHostedJobID = reviewMonitorJobCellHostedJobIDForTesting(cellView)

        configureReviewMonitorJobCellViewForTesting(cellView, job: loadedJob)

        let updatedHostingViewIdentity = try #require(
            reviewMonitorJobCellHostingViewIdentityForTesting(cellView)
        )
        let updatedHostedJobID = reviewMonitorJobCellHostedJobIDForTesting(cellView)

        #expect(initialHostedJobID == placeholderJob.id)
        #expect(updatedHostedJobID == loadedJob.id)
        #expect(initialHostingViewIdentity == updatedHostingViewIdentity)
        #expect(cellView.objectValue as? CodexReviewJob === loadedJob)
        #expect(cellView.toolTip == loadedJob.cwd)
    }

    @Test func workspaceDropPreservesExpansionState() {
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

    @Test func sidebarDoesNotAddBlankScrollWhenRowsFitVisibleArea() {
        let jobs = (0..<2).map { index in
            makeJob(
                id: "job-\(index)",
                cwd: "/tmp/workspace-alpha",
                status: .running,
                targetSummary: "Review \(index)"
            )
        }
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: jobs)
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 360, height: 320))
        viewController.loadViewIfNeeded()
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting

        #expect(sidebar.sidebarOutlineContentHeightForTesting < sidebar.sidebarVisibleHeightForTesting)
        #expect(sidebar.sidebarMaximumVerticalScrollOffsetForTesting < 0.5)
    }

    @Test func sidebarTopRowIsFullyVisibleAtMinimumScrollOffset() {
        let jobs = (0..<12).map { index in
            makeJob(
                id: "job-\(index)",
                cwd: "/tmp/workspace-alpha",
                status: .running,
                targetSummary: "Review \(index)"
            )
        }
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: jobs)
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 360, height: 220))
        viewController.loadViewIfNeeded()
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.scrollSidebarToOffsetForTesting(0)

        #expect(sidebar.sidebarFirstRowRectForTesting.minY >= sidebar.sidebarVisibleRectForTesting.minY - 0.5)
        #expect(sidebar.sidebarFirstRowRectForTesting.maxY <= sidebar.sidebarVisibleRectForTesting.maxY + 0.5)
    }

    @Test func sidebarBottomRowRemainsVisibleAtMaximumScrollOffset() {
        let jobs = (0..<12).map { index in
            makeJob(
                id: "job-\(index)",
                cwd: "/tmp/workspace-alpha",
                status: .running,
                targetSummary: "Review \(index)"
            )
        }
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            workspaces: makeWorkspaces(from: jobs)
        )
        let viewController = ReviewMonitorSplitViewController(store: store)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 360, height: 220))
        viewController.loadViewIfNeeded()
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.scrollSidebarToOffsetForTesting(10_000)

        #expect(sidebar.sidebarLastRowRectForTesting.maxY <= sidebar.sidebarVisibleRectForTesting.maxY + 0.5)
    }

    @Test func togglingWorkspaceDisclosureKeepsDetailAndRestoresSelectionAfterReexpand() async throws {
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

    @Test func programmaticLogAutoFollowRequestsOverlayScrollerHideWhenShown() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let job = makeJob(
            id: "job-overlay-hide",
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

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.scrollLogToBottomForTesting()
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting

        let updateRenderCount = transport.renderCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Newest line"))
        _ = try await awaitTransportRender(transport, after: updateRenderCount)

        #expect(transport.isLogPinnedToBottomForTesting)
        #expect(transport.logOverlayScrollerHideRequestCountForTesting == hideCountBeforeAppend + 1)
    }

    @Test func legacyScrollerStyleDoesNotRequestOverlayScrollerHide() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let job = makeJob(
            id: "job-legacy-hide",
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

        transport.setLogScrollerStyleForTesting(.legacy)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.scrollLogToBottomForTesting()
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting

        let updateRenderCount = transport.renderCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Newest line"))
        _ = try await awaitTransportRender(transport, after: updateRenderCount)

        #expect(transport.logOverlayScrollerHideRequestCountForTesting == hideCountBeforeAppend)
    }

    @Test func shortLogDoesNotRequestOverlayScrollerHideWhenNoScrollRange() async throws {
        let job = makeJob(
            id: "job-overlay-short",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: "short log"
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

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting

        let updateRenderCount = transport.renderCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "short update"))
        _ = try await awaitTransportRender(transport, after: updateRenderCount)

        #expect(transport.logOverlayScrollerHideRequestCountForTesting == hideCountBeforeAppend)
    }

    @Test func selectingJobRequestsOverlayScrollerHideWhenRestoringScrollPosition() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let firstJob = makeJob(
            id: "job-restore-1",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let secondJob = makeJob(
            id: "job-restore-2",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(firstJob)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.scrollLogToOffsetForTesting(120)

        let secondRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(secondJob)
        _ = try await awaitTransportRender(transport, after: secondRenderCount)

        let hideCountBeforeRestore = transport.logOverlayScrollerHideRequestCountForTesting
        let thirdRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(firstJob)
        _ = try await awaitTransportRender(transport, after: thirdRenderCount)

        #expect(transport.logOverlayScrollerHideRequestCountForTesting > hideCountBeforeRestore)
    }

    @Test func privateOverlayBridgeNoOpsWhenScrollerImpPairIsUnavailable() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let job = makeJob(
            id: "job-missing-pair",
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

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.setLogOverlayScrollerBridgeModeForTesting(.missingScrollerImpPair)

        let updateRenderCount = transport.renderCountForTesting
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Newest line"))
        _ = try await awaitTransportRender(transport, after: updateRenderCount)

        #expect(transport.logOverlayScrollerHideRequestCountForTesting == hideCountBeforeAppend)
    }

    @Test func privateOverlayBridgeNoOpsWhenHideSelectorsAreUnavailable() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let job = makeJob(
            id: "job-missing-hide",
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

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.setLogOverlayScrollerBridgeModeForTesting(.missingHideMethods)

        let updateRenderCount = transport.renderCountForTesting
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Newest line"))
        _ = try await awaitTransportRender(transport, after: updateRenderCount)

        #expect(transport.logOverlayScrollerHideRequestCountForTesting == hideCountBeforeAppend)
    }

    @Test func logViewUsesTextKit1AndDisablesEditingFeatures() async throws {
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

    @Test func signInViewShowsPrimaryActionLabelWhenSignedOut() {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        let view = SignInView(store: store)

        #expect(view.authenticationActionTitle == "Sign in with ChatGPT")
        #expect(view.authenticationActionRole == .confirm)
    }

    @Test func signInViewShowsPrimaryActionLabelWhenAuthenticating() {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        applyTestAuthState(auth: store.auth, state: 
            .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue."
                )
            )
        )
        let view = SignInView(store: store)

        #expect(view.authenticationActionTitle == "Cancel")
        #expect(view.authenticationActionRole == .cancel)
    }

    @Test func signInViewControllerStartsAuthenticationWhenSignedOutAndServerRunning() async {
        let backend = CountingStartBackend(shouldAutoStartEmbeddedServer: false)
        let store = makeStore(backend: backend)
        store.loadForTesting(serverState: .running, authState: .signedOut, workspaces: [])
        let viewController = ReviewMonitorSignInViewController(store: store)
        viewController.loadViewIfNeeded()
        viewController.startObservingAuth()

        viewController.performPrimaryAction()
        await backend.waitForBeginAuthenticationCallCount(1)

        #expect(backend.recordedActions() == ["begin"])
    }

    @Test func signInViewControllerCancelsAuthenticationWhenAuthenticating() async {
        let backend = CountingStartBackend(shouldAutoStartEmbeddedServer: false)
        let store = makeStore(backend: backend)
        store.loadForTesting(
            serverState: .running,
            authState: .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue."
                )
            ),
            workspaces: []
        )
        let viewController = ReviewMonitorSignInViewController(store: store)
        viewController.loadViewIfNeeded()
        viewController.startObservingAuth()

        viewController.performPrimaryAction()
        await backend.waitForCancelAuthenticationCallCount(1)

        #expect(backend.recordedActions() == ["cancel"])
    }

    @Test func signInViewControllerRestartsFailedServerBeforeBeginningAuthentication() async {
        let backend = CountingStartBackend(
            shouldAutoStartEmbeddedServer: false,
            restartResultingServerState: .running
        )
        let store = makeStore(backend: backend)
        store.loadForTesting(
            serverState: .failed("The embedded server stopped responding."),
            authState: .signedOut,
            workspaces: []
        )
        let viewController = ReviewMonitorSignInViewController(store: store)
        viewController.loadViewIfNeeded()
        viewController.startObservingAuth()

        viewController.performPrimaryAction()
        await backend.waitForStartCallCount(1)
        await backend.waitForBeginAuthenticationCallCount(1)

        #expect(backend.recordedActions() == ["start", "begin"])
        #expect(store.serverState == .running)
    }

    @Test func signInViewControllerRestartsStoppedServerBeforeBeginningAuthentication() async {
        let backend = CountingStartBackend(
            shouldAutoStartEmbeddedServer: false,
            restartResultingServerState: .running
        )
        let store = makeStore(backend: backend)
        store.loadForTesting(serverState: .stopped, authState: .signedOut, workspaces: [])
        let viewController = ReviewMonitorSignInViewController(store: store)
        viewController.loadViewIfNeeded()
        viewController.startObservingAuth()

        viewController.performPrimaryAction()
        await backend.waitForStartCallCount(1)
        await backend.waitForBeginAuthenticationCallCount(1)

        #expect(backend.recordedActions() == ["start", "begin"])
        #expect(store.serverState == .running)
    }

    @Test func signInViewControllerBeginsAuthenticationEvenWhenRestartFails() async {
        let backend = CountingStartBackend(
            shouldAutoStartEmbeddedServer: false,
            restartResultingServerState: .failed("Still unavailable.")
        )
        let store = makeStore(backend: backend)
        store.loadForTesting(
            serverState: .failed("The embedded server stopped responding."),
            authState: .signedOut,
            workspaces: []
        )
        let viewController = ReviewMonitorSignInViewController(store: store)
        viewController.loadViewIfNeeded()
        viewController.startObservingAuth()

        viewController.performPrimaryAction()
        await backend.waitForStartCallCount(1)
        await backend.waitForBeginAuthenticationCallCount(1)

        #expect(backend.recordedActions() == ["start", "begin"])
        #expect(store.serverState == .failed("Still unavailable."))
    }

    @Test func signInViewControllerDoesNotActOnBrowserProgressUpdates() async {
        let backend = CountingStartBackend(shouldAutoStartEmbeddedServer: false)
        let store = makeStore(backend: backend)
        let viewController = ReviewMonitorSignInViewController(store: store)
        viewController.loadViewIfNeeded()
        viewController.startObservingAuth()

        applyTestAuthState(auth: store.auth, state: 
            .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue.",
                    browserURL: "https://auth.openai.com/oauth/authorize?foo=bar"
                )
            )
        )
        await Task.yield()
        await Task.yield()
        #expect(backend.recordedActions().isEmpty)
    }

    @Test func storeRestartStartsStoppedServer() async {
        let backend = CountingStartBackend(
            shouldAutoStartEmbeddedServer: false,
            initialAuthState: .signedIn(accountID: "review@example.com"),
            restartResultingServerState: .running
        )
        let store = makeStore(backend: backend)
        store.loadForTesting(
            serverState: .stopped,
            authState: .signedIn(accountID: "review@example.com"),
            workspaces: []
        )
        await store.restart()
        await backend.waitForStartCallCount(1)

        #expect(backend.startCallCount() == 1)
    }

    @Test func statusViewShowsRestartActionWhileServerStarting() {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .starting,
            authState: .signedIn(accountID: "review@example.com"),
            workspaces: []
        )
        let view = StatusView(store: store)

        #expect(view.showsServerRestartAction)
    }

    @Test func statusViewUsesSettingsStoreLabels() {
        let backend = CodexReviewPreviewStoreBackend()
        backend.initialSettingsSnapshot = makeSettingsSnapshot(
            model: "gpt-5.4-mini",
            reasoningEffort: .low,
            serviceTier: nil
        )
        let store = CodexReviewStore(backend: backend)
        store.loadForTesting(
            serverState: .running,
            authState: .signedIn(accountID: "review@example.com"),
            workspaces: [],
            settingsSnapshot: backend.initialSettingsSnapshot
        )

        let view = StatusView(store: store)

        #expect(store.settings.currentModelDisplayText == "GPT-5.4 Mini")
        #expect(store.settings.currentReasoningDisplayText == "Low")
        #expect(store.settings.currentServiceTierDisplayText == "Normal")
        _ = view
    }

    @Test func statusViewDisablesSettingsControlsWhenServerIsNotRunning() {
        let backend = CodexReviewPreviewStoreBackend()
        backend.initialSettingsSnapshot = makeSettingsSnapshot()
        let store = CodexReviewStore(backend: backend)
        store.loadForTesting(
            serverState: .stopped,
            authState: .signedIn(accountID: "review@example.com"),
            workspaces: [],
            settingsSnapshot: backend.initialSettingsSnapshot
        )

        #expect(store.serverState != .running || store.settings.isLoading || store.settings.displayedModels.isEmpty)
    }

    @Test func settingsStoreNormalizesReasoningAndTierWhenModelChanges() async {
        let backend = CodexReviewPreviewStoreBackend()
        backend.initialSettingsSnapshot = makeSettingsSnapshot(
            model: "gpt-5.4",
            reasoningEffort: .high,
            serviceTier: .fast
        )
        let store = CodexReviewStore(backend: backend)

        await store.settings.updateModel("gpt-5.4-mini")

        #expect(store.settings.selectedModel == "gpt-5.4-mini")
        #expect(store.settings.selectedReasoningEffort == .medium)
        #expect(store.settings.selectedServiceTier == nil)
    }

    @Test func settingsStoreKeepsCurrentHiddenModelVisible() {
        let hiddenModel = CodexReviewModelCatalogItem(
            id: "gpt-hidden",
            model: "gpt-hidden",
            displayName: "GPT Hidden",
            hidden: true,
            supportedReasoningEfforts: [
                .init(reasoningEffort: .medium, description: "Hidden default.")
            ],
            defaultReasoningEffort: .medium,
            supportedServiceTiers: []
        )
        let visibleModel = CodexReviewModelCatalogItem(
            id: "gpt-5.4",
            model: "gpt-5.4",
            displayName: "GPT-5.4",
            hidden: false,
            supportedReasoningEfforts: [
                .init(reasoningEffort: .medium, description: "Visible default.")
            ],
            defaultReasoningEffort: .medium,
            supportedServiceTiers: [.fast]
        )
        let backend = CodexReviewPreviewStoreBackend()
        backend.initialSettingsSnapshot = .init(
            model: "gpt-hidden",
            reasoningEffort: .medium,
            serviceTier: nil,
            models: [visibleModel, hiddenModel]
        )
        let store = CodexReviewStore(backend: backend)

        #expect(store.settings.displayedModels.map(\.model) == ["gpt-5.4", "gpt-hidden"])
    }

    @Test func settingsStoreAppliesPendingSelectionAfterInFlightSave() async throws {
        let backend = BlockingSettingsBackend(snapshot: makeSettingsSnapshot())
        backend.blockNextModelUpdate()
        let store = CodexReviewStore(backend: backend)

        store.settings.selectedModel = "gpt-5.4-mini"
        await backend.waitForBlockedModelUpdateToStart()

        store.settings.selectedReasoningEffort = .low
        await backend.resumeBlockedModelUpdate()

        try await waitForCondition {
            backend.reasoningUpdateCalls == [.low]
        }

        #expect(store.settings.selectedModel == "gpt-5.4-mini")
        #expect(store.settings.selectedReasoningEffort == .low)
        #expect(backend.modelUpdateCalls.count == 1)
    }

    @Test func settingsStoreRunsQueuedRefreshAfterCurrentLoad() async throws {
        let backend = BlockingSettingsBackend(snapshot: makeSettingsSnapshot())
        backend.blockNextRefresh()
        let store = CodexReviewStore(backend: backend)

        let refreshTask = Task { @MainActor in
            await store.settings.refresh()
        }
        await backend.waitForBlockedRefreshToStart()

        await store.settings.refresh()
        await backend.resumeBlockedRefresh()
        await refreshTask.value

        try await waitForCondition {
            backend.refreshCallCount == 2
        }
    }

    @Test func settingsStorePersistsQueuedReasoningAndTierWithoutWritingModelOverride() async throws {
        let backend = BlockingSettingsBackend(
            snapshot: makeSettingsSnapshot(
                model: "gpt-5.3-codex",
                reasoningEffort: .low,
                serviceTier: .fast
            )
        )
        backend.blockNextReasoningUpdate()
        let store = CodexReviewStore(backend: backend)

        store.settings.selectedReasoningEffort = .medium
        await backend.waitForBlockedReasoningUpdateToStart()

        store.settings.selectedReasoningEffort = .minimal
        store.settings.selectedServiceTier = .flex
        await backend.resumeBlockedReasoningUpdate()

        try await waitForCondition {
            backend.reasoningUpdateCalls == [.medium, .minimal]
                && backend.serviceTierUpdateCalls == [.flex]
        }

        #expect(backend.modelUpdateCalls.isEmpty)
        #expect(store.settings.selectedReasoningEffort == .minimal)
        #expect(store.settings.selectedServiceTier == .flex)
    }

    @Test func signInViewDescriptionTextReflectsAuthState() {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())

        applyTestAuthState(auth: store.auth, state: 
            .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue.",
                    browserURL: "https://auth.openai.com/oauth/authorize?foo=bar"
                )
            )
        )
        #expect(SignInView(store: store).descriptionText == nil)

        applyTestAuthState(auth: store.auth, state: .failed("Authentication failed."))
        #expect(SignInView(store: store).descriptionText == "Authentication failed.")

        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        #expect(SignInView(store: store).descriptionText == nil)

        store.loadForTesting(
            serverState: .failed("The embedded server stopped responding."),
            authState: .signedOut,
            workspaces: []
        )
        #expect(SignInView(store: store).descriptionText == "The embedded server stopped responding.")

        store.loadForTesting(
            serverState: .stopped,
            authState: .signedOut,
            workspaces: []
        )
        #expect(SignInView(store: store).descriptionText == nil)
    }

    @Test func mcpServerUnavailableViewRestartServerUsesStoreRestartFlow() async {
        let backend = CountingStartBackend(
            shouldAutoStartEmbeddedServer: false,
            initialAuthState: .signedIn(accountID: "review@example.com")
        )
        let store = makeStore(backend: backend)
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
        let backend = CountingStartBackend(
            shouldAutoStartEmbeddedServer: false,
            initialAuthState: .signedOut
        )
        let store = makeStore(backend: backend)
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

@MainActor
private struct ReviewMonitorWindowHarness {
    let windowController: ReviewMonitorWindowController
    let viewController: ReviewMonitorSplitViewController
    let window: NSWindow
}

@MainActor
private func makeWindowHarness(
    store: CodexReviewStore,
    authState: TestAuthState = .signedIn(accountID: "review@example.com"),
    contentSize: NSSize? = nil,
    performInitialAuthRefresh: Bool = false,
    forceSplitView: Bool = false
) -> ReviewMonitorWindowHarness {
    applyTestAuthState(auth: store.auth, state: authState)
    let windowController = ReviewMonitorWindowController(
        store: store,
        performInitialAuthRefresh: performInitialAuthRefresh,
        forceSplitView: forceSplitView
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
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

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
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

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
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

@MainActor
private func waitForSidebarBottomAccessoryHidden(
    _ viewController: ReviewMonitorSplitViewController,
    _ expected: Bool,
    timeout: Duration = .seconds(2)
) async throws {
    let viewControllerBox = UncheckedSendableBox(viewController)
    try await withTestTimeout(timeout) {
        while await MainActor.run(body: {
            viewControllerBox.value.sidebarBottomAccessoryIsHiddenForTesting != expected
        }) {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

@MainActor
private func waitForAddAccountToolbarItemHidden(
    _ viewController: ReviewMonitorSplitViewController,
    _ expected: Bool,
    timeout: Duration = .seconds(2)
) async throws {
    let viewControllerBox = UncheckedSendableBox(viewController)
    try await withTestTimeout(timeout) {
        while await MainActor.run(body: {
            if let window = viewControllerBox.value.view.window {
                window.layoutIfNeeded()
            }
            viewControllerBox.value.view.layoutSubtreeIfNeeded()
            return viewControllerBox.value.addAccountToolbarItemIsHiddenForTesting != expected
        }) {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

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
private func waitForCondition(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @MainActor @Sendable () -> Bool
) async throws {
    try await withTestTimeout(timeout) {
        while await MainActor.run(body: {
            condition() == false
        }) {
            try Task.checkCancellation()
            await Task.yield()
        }
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

@MainActor
private func awaitContentPaneRender(
    _ contentPane: ReviewMonitorTransportViewController,
    after renderCount: Int,
    timeout: Duration = .seconds(2)
) async throws -> ReviewMonitorTransportViewController.RenderSnapshotForTesting {
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

private struct TestAuthState: Equatable {
    var phase: CodexReviewAuthModel.Phase
    var accountEmail: String?
    var accountPlanType: String?

    init(
        isAuthenticated: Bool = false,
        accountID: String? = nil,
        progress: CodexReviewAuthModel.Progress? = nil,
        errorMessage: String? = nil
    ) {
        if let progress {
            phase = .signingIn(progress)
        } else if let errorMessage {
            phase = .failed(message: errorMessage)
        } else {
            phase = .signedOut
        }
        accountEmail = isAuthenticated ? accountID : nil
        accountPlanType = isAuthenticated ? "pro" : nil
    }

    static let signedOut = Self()

    static func signedIn(accountID: String?) -> Self {
        .init(
            isAuthenticated: true,
            accountID: accountID
        )
    }

    static func signingIn(_ progress: CodexReviewAuthModel.Progress) -> Self {
        .init(progress: progress)
    }

    static func failed(
        _ message: String,
        isAuthenticated: Bool = false,
        accountID: String? = nil
    ) -> Self {
        .init(
            isAuthenticated: isAuthenticated,
            accountID: accountID,
            errorMessage: message
        )
    }

    var progress: CodexReviewAuthModel.Progress? {
        guard case .signingIn(let progress) = phase else {
            return nil
        }
        return progress
    }

    var isAuthenticated: Bool {
        accountEmail != nil
    }

    var errorMessage: String? {
        guard case .failed(let message) = phase else {
            return nil
        }
        return message
    }
}

@MainActor
private func applyTestAuthState(
    auth: CodexReviewAuthModel,
    state: TestAuthState
) {
    auth.updatePhase(state.phase)
    if let accountEmail = state.accountEmail {
        let account = CodexAccount(
            email: accountEmail,
            planType: state.accountPlanType ?? "pro"
        )
        auth.updateSavedAccounts([account])
        auth.updateAccount(account)
    } else {
        auth.updateSavedAccounts([])
        auth.updateAccount(nil)
    }
}

@MainActor
private func testAuthState(from auth: CodexReviewAuthModel) -> TestAuthState {
    .init(
        isAuthenticated: auth.isAuthenticated,
        accountID: auth.account?.email,
        progress: auth.progress,
        errorMessage: auth.errorMessage
    )
}

@MainActor
private extension CodexReviewStore {
    func loadForTesting(
        serverState: CodexReviewServerState,
        authState: TestAuthState = .signedOut,
        serverURL: URL? = nil,
        workspaces: [CodexReviewWorkspace],
        settingsSnapshot: CodexReviewSettingsSnapshot? = nil
    ) {
        loadForTesting(
            serverState: serverState,
            authPhase: authState.phase,
            account: authState.accountEmail.map {
                CodexAccount(
                    email: $0,
                    planType: authState.accountPlanType ?? "pro"
                )
            },
            savedAccounts: authState.accountEmail.map {
                [
                    CodexAccount(
                        email: $0,
                        planType: authState.accountPlanType ?? "pro"
                    )
                ]
            } ?? [],
            serverURL: serverURL,
            workspaces: workspaces,
            settingsSnapshot: settingsSnapshot
        )
    }
}

@MainActor
private func makeSettingsSnapshot(
    model: String = "gpt-5.4",
    reasoningEffort: CodexReviewReasoningEffort = .medium,
    serviceTier: CodexReviewServiceTier? = .fast
) -> CodexReviewSettingsSnapshot {
    .init(
        model: model,
        reasoningEffort: reasoningEffort,
        serviceTier: serviceTier,
        models: ReviewMonitorPreviewContent.makePreviewModelCatalog()
    )
}

@MainActor
private func makeStore(backend: CountingStartBackend) -> CodexReviewStore {
    CodexReviewStore(
        backend: backend,
        authController: CountingStartAuthController(backend: backend)
    )
}

@MainActor
private func makeStore(backend: AuthActionBackend) -> CodexReviewStore {
    CodexReviewStore(
        backend: backend,
        authController: AuthActionController(backend: backend)
    )
}

@MainActor
private final class FailingCancellationBackend: CodexReviewStoreBackend {
    var isActive: Bool = false
    let shouldAutoStartEmbeddedServer = false
    let initialAuthState: TestAuthState = .signedOut
    var initialAccount: CodexAccount? {
        initialAuthState.accountEmail.map {
            CodexAccount(email: $0, planType: initialAuthState.accountPlanType ?? "pro")
        }
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
private final class BlockingSettingsBackend: CodexReviewStoreBackend {
    var isActive = false
    let shouldAutoStartEmbeddedServer = false
    let initialAccount: CodexAccount? = nil
    let initialAccounts: [CodexAccount] = []
    let initialActiveAccountKey: String? = nil
    var initialSettingsSnapshot: CodexReviewSettingsSnapshot

    private(set) var refreshCallCount = 0
    private(set) var modelUpdateCalls: [(model: String, reasoningEffort: CodexReviewReasoningEffort?, serviceTier: CodexReviewServiceTier?)] = []
    private(set) var reasoningUpdateCalls: [CodexReviewReasoningEffort?] = []
    private(set) var serviceTierUpdateCalls: [CodexReviewServiceTier?] = []

    private var shouldBlockNextRefresh = false
    private var shouldBlockNextModelUpdate = false
    private var shouldBlockNextReasoningUpdate = false
    private let blockedRefreshStartedGate = OneShotGate()
    private let blockedRefreshResumeGate = OneShotGate()
    private let blockedModelUpdateStartedGate = OneShotGate()
    private let blockedModelUpdateResumeGate = OneShotGate()
    private let blockedReasoningUpdateStartedGate = OneShotGate()
    private let blockedReasoningUpdateResumeGate = OneShotGate()

    init(snapshot: CodexReviewSettingsSnapshot) {
        initialSettingsSnapshot = snapshot
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

    func refreshSettings() async throws -> CodexReviewSettingsSnapshot {
        refreshCallCount += 1
        if shouldBlockNextRefresh {
            shouldBlockNextRefresh = false
            await blockedRefreshStartedGate.open()
            await blockedRefreshResumeGate.wait()
        }
        return initialSettingsSnapshot
    }

    func updateSettingsModel(
        _ model: String,
        reasoningEffort: CodexReviewReasoningEffort?,
        serviceTier: CodexReviewServiceTier?
    ) async throws {
        modelUpdateCalls.append(
            (
                model: model,
                reasoningEffort: reasoningEffort,
                serviceTier: serviceTier
            )
        )
        initialSettingsSnapshot.model = model
        initialSettingsSnapshot.reasoningEffort = reasoningEffort
        initialSettingsSnapshot.serviceTier = serviceTier

        if shouldBlockNextModelUpdate {
            shouldBlockNextModelUpdate = false
            await blockedModelUpdateStartedGate.open()
            await blockedModelUpdateResumeGate.wait()
        }
    }

    func updateSettingsReasoningEffort(
        _ reasoningEffort: CodexReviewReasoningEffort?
    ) async throws {
        reasoningUpdateCalls.append(reasoningEffort)
        initialSettingsSnapshot.reasoningEffort = reasoningEffort

        if shouldBlockNextReasoningUpdate {
            shouldBlockNextReasoningUpdate = false
            await blockedReasoningUpdateStartedGate.open()
            await blockedReasoningUpdateResumeGate.wait()
        }
    }

    func updateSettingsServiceTier(
        _ serviceTier: CodexReviewServiceTier?
    ) async throws {
        serviceTierUpdateCalls.append(serviceTier)
        initialSettingsSnapshot.serviceTier = serviceTier
    }

    func blockNextRefresh() {
        shouldBlockNextRefresh = true
    }

    func waitForBlockedRefreshToStart() async {
        await blockedRefreshStartedGate.wait()
    }

    func resumeBlockedRefresh() async {
        await blockedRefreshResumeGate.open()
    }

    func blockNextModelUpdate() {
        shouldBlockNextModelUpdate = true
    }

    func waitForBlockedModelUpdateToStart() async {
        await blockedModelUpdateStartedGate.wait()
    }

    func resumeBlockedModelUpdate() async {
        await blockedModelUpdateResumeGate.open()
    }

    func blockNextReasoningUpdate() {
        shouldBlockNextReasoningUpdate = true
    }

    func waitForBlockedReasoningUpdateToStart() async {
        await blockedReasoningUpdateStartedGate.wait()
    }

    func resumeBlockedReasoningUpdate() async {
        await blockedReasoningUpdateResumeGate.open()
    }
}

@MainActor
private final class CountingStartAuthController: CodexReviewAuthControlling {
    private unowned let backend: CountingStartBackend

    init(backend: CountingStartBackend) {
        self.backend = backend
    }

    func startStartupRefresh(auth _: CodexReviewAuthModel) {}

    func cancelStartupRefresh() {}

    func refresh(auth _: CodexReviewAuthModel) async {}

    func beginAuthentication(auth: CodexReviewAuthModel) async {
        await backend.beginAuthentication(auth: auth)
    }

    func cancelAuthentication(auth: CodexReviewAuthModel) async {
        await backend.cancelAuthentication(auth: auth)
    }

    func signOutActiveAccount(auth: CodexReviewAuthModel) async throws {
        await backend.logout(auth: auth)
    }

    func reconcileAuthenticatedSession(
        auth _: CodexReviewAuthModel,
        serverIsRunning _: Bool,
        runtimeGeneration _: Int
    ) async {}
}

@MainActor
private final class CountingStartBackend: CodexReviewStoreBackend {
    let shouldAutoStartEmbeddedServer: Bool
    let initialAuthState: TestAuthState
    var initialAccount: CodexAccount? {
        initialAuthState.accountEmail.map {
            CodexAccount(email: $0, planType: initialAuthState.accountPlanType ?? "pro")
        }
    }
    let restartResultingServerState: CodexReviewServerState
    private let startSignal = AsyncSignal()
    private let beginSignal = AsyncSignal()
    private let cancelSignal = AsyncSignal()
    private var startCalls = 0
    private var beginCalls = 0
    private var cancelCalls = 0
    private var actions: [String] = []

    init(
        shouldAutoStartEmbeddedServer: Bool = true,
        initialAuthState: TestAuthState = .signedOut,
        restartResultingServerState: CodexReviewServerState = .starting
    ) {
        self.shouldAutoStartEmbeddedServer = shouldAutoStartEmbeddedServer
        self.initialAuthState = initialAuthState
        self.restartResultingServerState = restartResultingServerState
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
        actions.append("start")
        store.serverState = restartResultingServerState
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
        beginCalls += 1
        actions.append("begin")
        await beginSignal.signal()
    }

    func cancelAuthentication(auth: CodexReviewAuthModel) async {
        _ = auth
        cancelCalls += 1
        actions.append("cancel")
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

    func beginAuthenticationCallCount() -> Int {
        beginCalls
    }

    func waitForBeginAuthenticationCallCount(_ count: Int) async {
        if beginCalls >= count {
            return
        }
        await beginSignal.wait(untilCount: count)
    }

    func recordedActions() -> [String] {
        actions
    }

    func waitForCancelAuthenticationCallCount(_ count: Int) async {
        if cancelCalls >= count {
            return
        }
        await cancelSignal.wait(untilCount: count)
    }
}

@MainActor
private final class AuthActionController: CodexReviewAuthControlling {
    private unowned let backend: AuthActionBackend

    init(backend: AuthActionBackend) {
        self.backend = backend
    }

    func startStartupRefresh(auth _: CodexReviewAuthModel) {}

    func cancelStartupRefresh() {}

    func refresh(auth: CodexReviewAuthModel) async {
        await backend.refreshAuthState(auth: auth)
    }

    func beginAuthentication(auth: CodexReviewAuthModel) async {
        await backend.beginAuthentication(auth: auth)
    }

    func cancelAuthentication(auth: CodexReviewAuthModel) async {
        await backend.cancelAuthentication(auth: auth)
    }

    func switchAccount(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async throws {
        try await backend.switchAccount(auth: auth, accountKey: accountKey)
    }

    func removeAccount(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async throws {
        await backend.removeAccount(auth: auth, accountKey: accountKey)
    }

    func signOutActiveAccount(auth: CodexReviewAuthModel) async throws {
        await backend.logout(auth: auth)
    }

    func reconcileAuthenticatedSession(
        auth _: CodexReviewAuthModel,
        serverIsRunning _: Bool,
        runtimeGeneration _: Int
    ) async {}
}

@MainActor
private final class AuthActionBackend: CodexReviewStoreBackend {
    var isActive: Bool = false
    let shouldAutoStartEmbeddedServer = false
    let initialAuthState: TestAuthState
    var initialAccount: CodexAccount? {
        initialAuthState.accountEmail.map {
            CodexAccount(email: $0, planType: initialAuthState.accountPlanType ?? "pro")
        }
    }

    private let refreshSignal = AsyncSignal()
    private let beginSignal = AsyncSignal()
    private let cancelSignal = AsyncSignal()
    private let logoutSignal = AsyncSignal()
    private let switchStartSignal = AsyncSignal()
    private let switchSignal = AsyncSignal()
    private let removeSignal = AsyncSignal()
    private let switchCompletionGate: OneShotGate
    private let switchErrorMessage: String?
    private var refreshCalls = 0
    private var beginCalls = 0
    private var cancelCalls = 0
    private var logoutCalls = 0
    private var switchCalls = 0
    private var removeCalls = 0
    private var switchedAccountKeys: [String] = []
    private var removedAccountKeys: [String] = []

    init(
        initialAuthState: TestAuthState = .signedOut,
        switchStartsBlocked: Bool = false,
        switchErrorMessage: String? = nil
    ) {
        self.initialAuthState = initialAuthState
        self.switchCompletionGate = OneShotGate(isOpen: switchStartsBlocked == false)
        self.switchErrorMessage = switchErrorMessage
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
        logoutCalls += 1
        await logoutSignal.signal()
    }

    func switchAccount(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async throws {
        switchCalls += 1
        switchedAccountKeys.append(accountKey)
        await switchStartSignal.signal()
        await switchCompletionGate.wait()
        if let switchErrorMessage {
            throw ReviewError.io(switchErrorMessage)
        }
        if let account = auth.savedAccounts.first(where: { $0.accountKey == accountKey }) {
            auth.updateAccount(account)
        }
        await switchSignal.signal()
    }

    func removeAccount(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async {
        removeCalls += 1
        removedAccountKeys.append(accountKey)

        let remainingAccounts = auth.savedAccounts.filter { $0.accountKey != accountKey }
        auth.updateSavedAccounts(remainingAccounts)

        if auth.account?.accountKey == accountKey {
            auth.updateAccount(remainingAccounts.first)
        } else if let currentAccount = auth.account,
                  remainingAccounts.contains(where: { $0.accountKey == currentAccount.accountKey }) == false
        {
            auth.updateAccount(nil)
        }

        await removeSignal.signal()
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

    func logoutCallCount() -> Int {
        logoutCalls
    }

    func waitForLogoutCallCount(_ count: Int) async {
        if logoutCalls >= count {
            return
        }
        await logoutSignal.wait(untilCount: count)
    }

    func waitForSwitchAccountCallCount(_ count: Int) async {
        if await switchSignal.count() >= count {
            return
        }
        await switchSignal.wait(untilCount: count)
    }

    func waitForSwitchAccountStartCallCount(_ count: Int) async {
        if await switchStartSignal.count() >= count {
            return
        }
        await switchStartSignal.wait(untilCount: count)
    }

    func lastSwitchedAccountKey() -> String? {
        switchedAccountKeys.last
    }

    func switchAccountCallCount() -> Int {
        switchCalls
    }

    func releaseSwitchAccount() async {
        await switchCompletionGate.open()
    }

    func waitForRemoveAccountCallCount(_ count: Int) async {
        if removeCalls >= count {
            return
        }
        await removeSignal.wait(untilCount: count)
    }

    func lastRemovedAccountKey() -> String? {
        removedAccountKeys.last
    }
}
