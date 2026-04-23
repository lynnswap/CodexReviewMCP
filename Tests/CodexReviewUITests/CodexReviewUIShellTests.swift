import AppKit
import Foundation
import SwiftUI
import Testing
@_spi(Testing) @testable import ReviewApp
@_spi(PreviewSupport) @testable import CodexReviewUI
import ReviewTestSupport
import ReviewDomain
import ReviewRuntime

@Suite(.serialized)
@MainActor
struct CodexReviewUIShellTests {
    @Test func bindingStoreAppliesInitialState() {
        let store = CodexReviewStore.makePreviewStore()
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
        let store = CodexReviewStore.makePreviewStore()
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
        let store = CodexReviewStore.makePreviewStore()
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
        let store = CodexReviewStore.makePreviewStore()
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
        let store = CodexReviewStore.makePreviewStore()
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
        let store = CodexReviewStore.makePreviewStore()
        let uiState = ReviewMonitorUIState()
        let viewController = ReviewMonitorServerStatusAccessoryViewController(
            store: store,
            uiState: uiState
        )
        viewController.loadViewIfNeeded()

        #expect(viewController.observationHandleCountForTesting == 1)
    }

    @Test func contentPanePinsDisplayedContentToSafeArea() {
        let store = CodexReviewStore.makePreviewStore()
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
        let store = CodexReviewStore.makePreviewStore()
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
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(store: store)
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }

        #expect(window.toolbar != nil)
        #expect(harness.windowController.windowContentKindForTesting == .splitView)
        #expect(
            viewController.toolbarIdentifiersForTesting ==
                [
                    .toggleSidebar,
                    .flexibleSpace,
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
        let store = CodexReviewStore.makePreviewStore()
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
        let store = CodexReviewStore.makePreviewStore()
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

        #expect(windowController.windowContentKindForTesting == .splitView)
        #expect(window.toolbar != nil)
    }

    @Test func windowControllerKeepsSplitViewForUnsavedCurrentSession() {
        let store = CodexReviewStore.makePreviewStore()
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

        #expect(windowController.windowContentKindForTesting == .splitView)
        #expect(window.toolbar != nil)
    }

    @Test func windowControllerShowsSignInViewWhenSignedOut() {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(
            store: store,
            authState: .signedOut
        )
        let window = harness.window
        defer { window.close() }

        #expect(harness.windowController.windowContentKindForTesting == .signInView)
        #expect(window.toolbar == nil)
        #expect(window.titleVisibility == .hidden)
        #expect(window.title == "")
        #expect(window.subtitle == "")
        #expect(window.isMovableByWindowBackground)
    }

    @Test func windowControllerForceSplitViewShowsSplitViewWhenSignedOut() {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(
            store: store,
            authState: .signedOut,
            forceSplitView: true
        )
        let window = harness.window
        defer { window.close() }

        #expect(harness.windowController.windowContentKindForTesting == .splitView)
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
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(
            store: store,
            authState: .signedIn(accountID: "review@example.com")
        )
        let window = harness.window
        defer { window.close() }

        applyTestAuthState(auth: store.auth, state: .signedOut)
        try await waitForWindowContentKind(harness.windowController, .signInView)
        try await waitForEmbeddedContentSubviewCount(harness.windowController, 1)

        #expect(harness.windowController.embeddedContentSubviewCountForTesting == 1)
        #expect(window.toolbar == nil)
        #expect(window.title == "")
        #expect(window.subtitle == "")
        #expect(window.isMovableByWindowBackground)
    }

    @Test func windowControllerCrossfadesBackToSplitViewAfterAuthentication() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(
            store: store,
            authState: .signedOut
        )
        let window = harness.window
        defer { window.close() }

        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        try await waitForWindowContentKind(harness.windowController, .splitView)
        try await waitForEmbeddedContentSubviewCount(harness.windowController, 1)

        #expect(harness.windowController.embeddedContentSubviewCountForTesting == 1)
        #expect(window.toolbar != nil)
        #expect(window.titleVisibility == .visible)
        #expect(window.titlebarSeparatorStyle == .automatic)
        #expect(window.isMovableByWindowBackground == false)
    }

    @Test func windowControllerRapidAuthFlipsKeepLatestContentEmbedded() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(
            store: store,
            authState: .signedIn(accountID: "review@example.com")
        )
        let window = harness.window
        defer { window.close() }

        applyTestAuthState(auth: store.auth, state: .signedOut)
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        try await waitForWindowContentKind(harness.windowController, .splitView)
        try await waitForEmbeddedContentSubviewCount(harness.windowController, 1)
        try await Task.sleep(for: .milliseconds(300))
        try await waitForEmbeddedContentSubviewCount(harness.windowController, 1)

        #expect(harness.windowController.embeddedContentSubviewCountForTesting == 1)
        #expect(harness.windowController.isSplitViewEmbeddedForTesting)
        #expect(harness.windowController.isSignInViewEmbeddedForTesting == false)
        #expect(window.toolbar != nil)
    }

    @Test func windowControllerRapidAuthFlipsDoNotAccumulateEmbeddedConstraints() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(
            store: store,
            authState: .signedIn(accountID: "review@example.com")
        )
        defer { harness.window.close() }

        applyTestAuthState(auth: store.auth, state: .signedOut)
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        applyTestAuthState(auth: store.auth, state: .signedOut)
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))

        try await waitForWindowContentKind(harness.windowController, .splitView)
        try await waitForEmbeddedContentSubviewCount(harness.windowController, 1)
        try await Task.sleep(for: .milliseconds(300))

        #expect(harness.windowController.embeddedContentSubviewCountForTesting == 1)
        #expect(harness.windowController.isSplitViewEmbeddedForTesting)
    }

    @Test func windowControllerPreservesWindowSizeWhenSwitchingToSignInView() async throws {
        let store = CodexReviewStore.makePreviewStore()
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
        try await waitForWindowContentKind(harness.windowController, .signInView)
        window.layoutIfNeeded()
        let afterSize = window.frame.size

        #expect(abs(beforeSize.width - afterSize.width) < 0.5)
        #expect(abs(beforeSize.height - afterSize.height) < 0.5)
    }

    @Test func windowControllerKeepsSplitViewAfterAuthFailure() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(
            store: store,
            authState: .signedIn(accountID: "review@example.com")
        )
        let window = harness.window
        defer { window.close() }

        applyTestAuthState(auth: store.auth, state: .failed("Authentication failed."))
        await Task.yield()

        #expect(harness.windowController.windowContentKindForTesting == .splitView)
        #expect(window.toolbar != nil)
    }

    @Test func windowControllerKeepsSignInViewPresentedWhileAuthenticating() async throws {
        let store = CodexReviewStore.makePreviewStore()
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
        try await waitForWindowContentKind(harness.windowController, .signInView)

        #expect(harness.windowController.windowContentKindForTesting == .signInView)
    }

    @Test func windowControllerKeepsSplitViewWhileAuthenticatedRetryAuthenticates() async throws {
        let store = CodexReviewStore.makePreviewStore()
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
        try await waitForWindowContentKind(harness.windowController, .splitView)
        try await waitForEmbeddedContentSubviewCount(harness.windowController, 1)

        #expect(harness.windowController.windowContentKindForTesting == .splitView)
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
        let store = CodexReviewStore.makePreviewStore()
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
        let store = CodexReviewStore.makePreviewStore()
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
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, workspaces: makeWorkspaces(from: [job]))
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 520, height: 420)
        )
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        try await waitForWindowContentKind(harness.windowController, .splitView)
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
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, workspaces: makeWorkspaces(from: [job]))
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 960, height: 600)
        )
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        try await waitForWindowContentKind(harness.windowController, .splitView)
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
        let store = CodexReviewStore.makePreviewStore()
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
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, workspaces: makeWorkspaces(from: [job]))
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 520, height: 420)
        )
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        try await waitForWindowContentKind(harness.windowController, .splitView)
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
}
