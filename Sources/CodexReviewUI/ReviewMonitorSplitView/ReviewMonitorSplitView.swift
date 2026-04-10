import AppKit
import CodexReviewModel
import ObservationBridge
import ReviewRuntime
import SwiftUI

@available(macOS 26.0, *)
@MainActor
final class ReviewMonitorSplitViewController: NSSplitViewController, NSToolbarDelegate {
    private static let autosaveName = NSSplitView.AutosaveName("CodexReviewMCP.ReviewMonitorSplitView")

    private let store: CodexReviewStore
    private let uiState: ReviewMonitorUIState
    private var sidebarPaneViewController: ReviewMonitorSidebarPaneViewController?
    private var contentPaneViewController: ReviewMonitorContentPaneViewController?
    private var statusAccessoryViewController: ReviewMonitorServerStatusAccessoryViewController?
    private var sidebarItem: NSSplitViewItem?
    private var contentItem: NSSplitViewItem?
    private var toolbar: NSToolbar?
    private var observationHandles: Set<ObservationHandle> = []
    private weak var attachedWindow: NSWindow?

    init(store: CodexReviewStore, uiState: ReviewMonitorUIState = ReviewMonitorUIState()) {
        self.store = store
        self.uiState = uiState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarPaneViewController = ReviewMonitorSidebarPaneViewController(
            store: store,
            uiState: uiState
        )
        let contentPaneViewController = ReviewMonitorContentPaneViewController(uiState: uiState)
        let statusAccessoryViewController = ReviewMonitorServerStatusAccessoryViewController(store: store)
        if #available(macOS 26.1, *) {
            statusAccessoryViewController.preferredScrollEdgeEffectStyle = .soft
        }
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarPaneViewController)
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.minimumThickness = 220
        sidebarItem.preferredThicknessFraction = 0.22
        sidebarItem.titlebarSeparatorStyle = .none
        sidebarItem.addBottomAlignedAccessoryViewController(statusAccessoryViewController)

        let contentItem = NSSplitViewItem(viewController: contentPaneViewController)
        contentItem.minimumThickness = 300
        contentItem.automaticallyAdjustsSafeAreaInsets = true

        self.sidebarPaneViewController = sidebarPaneViewController
        self.contentPaneViewController = contentPaneViewController
        self.statusAccessoryViewController = statusAccessoryViewController
        self.sidebarItem = sidebarItem
        self.contentItem = contentItem

        sidebarPaneViewController.loadViewIfNeeded()
        contentPaneViewController.loadViewIfNeeded()
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
    }

    func attach(to window: NSWindow) {
        loadViewIfNeeded()
        guard attachedWindow !== window else {
            return
        }

        attachedWindow = window
        // macOS 26 applies NSSplitView autosave reliably only after the split view is in a window.
        splitView.identifier = NSUserInterfaceItemIdentifier(Self.autosaveName)
        splitView.autosaveName = Self.autosaveName
        installToolbarIfNeeded(on: window)
        bindJobEntry(to: window)
    }

    func detachFromWindow() {
        observationHandles.removeAll()
        attachedWindow = nil
    }

    private func bindJobEntry(to window: NSWindow) {
        observationHandles.removeAll()

        if let selectedJob = uiState.selectedJobEntry {
            window.title = selectedJob.targetSummary
            window.subtitle = selectedJob.cwd
        } else {
            window.subtitle = ""
        }

        uiState.observe(\.selectedJobEntry?.targetSummary) { [weak window] targetSummary in
            guard let window else {
                return
            }
            window.title = targetSummary ?? ""
        }
        .store(in: &observationHandles)

        uiState.observe(\.selectedJobEntry?.cwd) { [weak window] cwd in
            guard let window else {
                return
            }
            window.subtitle = cwd ?? ""
        }
        .store(in: &observationHandles)
    }

    private func installToolbarIfNeeded(on window: NSWindow) {
        if toolbar == nil {
            let toolbar = NSToolbar(identifier: "CodexReviewMCP.ReviewMonitor.Toolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
            self.toolbar = toolbar
        }

        if window.toolbar !== toolbar {
            window.styleMask.insert(.fullSizeContentView)
            window.toolbarStyle = .unified
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .line
            window.toolbar = toolbar
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .flexibleSpace,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .space,
            .flexibleSpace,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .toggleSidebar:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.autovalidates = true
            return item

        case .sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitView,
                dividerIndex: 0
            )

        default:
            return nil
        }
    }
}

@available(macOS 26.0, *)
@MainActor
final class ReviewMonitorSidebarPaneViewController: NSViewController {
    private let store: CodexReviewStore
    private let sidebarViewController: ReviewMonitorSidebarViewController
    private let unavailableViewController: MCPServerUnavailableViewController
    private var observationHandles: Set<ObservationHandle> = []
    private var displayedViewConstraints: [NSLayoutConstraint] = []
    private(set) weak var displayedViewController: NSViewController?

    init(store: CodexReviewStore, uiState: ReviewMonitorUIState) {
        self.store = store
        self.sidebarViewController = ReviewMonitorSidebarViewController(uiState: uiState)
        self.unavailableViewController = MCPServerUnavailableViewController(store: store)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        sidebarViewController.loadViewIfNeeded()
        unavailableViewController.loadViewIfNeeded()
        sidebarViewController.bind(store: store)
        bindObservation()
        updatePresentation()
    }

    private func bindObservation() {
        observationHandles.removeAll()
        store.observe(\.serverState) { [weak self] _ in
            guard let self else {
                return
            }
            self.updatePresentation()
        }
        .store(in: &observationHandles)
    }

    private func updatePresentation() {
        let desiredViewController: NSViewController
        if case .failed = store.serverState {
            desiredViewController = unavailableViewController
        } else {
            desiredViewController = sidebarViewController
        }
        setDisplayedViewController(desiredViewController)
    }

    private func setDisplayedViewController(_ viewController: NSViewController) {
        loadViewIfNeeded()
        guard displayedViewController !== viewController else {
            return
        }

        if let displayedViewController {
            NSLayoutConstraint.deactivate(displayedViewConstraints)
            displayedViewConstraints.removeAll()
            displayedViewController.view.removeFromSuperview()
            displayedViewController.removeFromParent()
        }

        addChild(viewController)
        displayedViewController = viewController
        displayedViewConstraints = embed(viewController)
    }

    @discardableResult
    private func embed(_ viewController: NSViewController) -> [NSLayoutConstraint] {
        let contentView = viewController.view
        let safeArea = view.safeAreaLayoutGuide
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView)

        let constraints = [
            contentView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        return constraints
    }
}

@available(macOS 26.0, *)
@MainActor
final class ReviewMonitorContentPaneViewController: NSViewController {
    enum ContentPresentationForTesting: Equatable {
        case empty
        case detail
    }

    private let uiState: ReviewMonitorUIState
    private let transportViewController = ReviewMonitorTransportViewController()
    private let emptyStateViewController = ReviewMonitorDetailEmptyStateViewController()
    private var observationHandles: Set<ObservationHandle> = []
    private var displayedViewConstraints: [NSLayoutConstraint] = []
    private(set) weak var displayedViewController: NSViewController?
#if DEBUG
    private var renderCountForTestingStorage = 0
    private var renderWaitersForTesting: [Int: [CheckedContinuation<Void, Never>]] = [:]
#endif

    init(uiState: ReviewMonitorUIState) {
        self.uiState = uiState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        transportViewController.loadViewIfNeeded()
        emptyStateViewController.loadViewIfNeeded()
        bindObservation()
        updatePresentation(selectedJob: uiState.selectedJobEntry)
    }

    private func bindObservation() {
        observationHandles.removeAll()
        uiState.observe(\.selectedJobEntry) { [weak self] selectedJob in
            guard let self else {
                return
            }
            self.updatePresentation(selectedJob: selectedJob)
        }
        .store(in: &observationHandles)
    }

    private func updatePresentation(selectedJob: CodexReviewJob?) {
        let desiredViewController: NSViewController
        if let selectedJob {
            transportViewController.displayJob(selectedJob)
            desiredViewController = transportViewController
        } else {
            transportViewController.clearDisplayedJob()
            desiredViewController = emptyStateViewController
        }
        setDisplayedViewController(desiredViewController)
    }

    private func setDisplayedViewController(_ viewController: NSViewController) {
        loadViewIfNeeded()
        guard displayedViewController !== viewController else {
            return
        }

        if let displayedViewController {
            NSLayoutConstraint.deactivate(displayedViewConstraints)
            displayedViewConstraints.removeAll()
            displayedViewController.view.removeFromSuperview()
            displayedViewController.removeFromParent()
        }

        addChild(viewController)
        displayedViewController = viewController
        displayedViewConstraints = embed(viewController)
        noteRenderForTesting()
    }

    @discardableResult
    private func embed(_ viewController: NSViewController) -> [NSLayoutConstraint] {
        let contentView = viewController.view
        let safeArea = view.safeAreaLayoutGuide
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView)

        let constraints = [
            contentView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        return constraints
    }

    private func noteRenderForTesting() {
#if DEBUG
        renderCountForTestingStorage += 1
        let readyCounts = renderWaitersForTesting.keys.filter { $0 <= renderCountForTestingStorage }
        for count in readyCounts {
            let continuations = renderWaitersForTesting.removeValue(forKey: count) ?? []
            for continuation in continuations {
                continuation.resume()
            }
        }
#endif
    }
}

@available(macOS 26.0, *)
@MainActor
private final class ReviewMonitorDetailEmptyStateViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let emptyStateView = ReviewMonitorViewFactory.makeEmptyStateView(
            title: "Select a job",
            description: "Choose a review from the list.",
            titleAccessibilityIdentifier: "review-monitor.detail-empty.title",
            descriptionAccessibilityIdentifier: "review-monitor.detail-empty.description"
        )
        let safeArea = view.safeAreaLayoutGuide
        view.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            emptyStateView.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: safeArea.centerYAnchor),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: safeArea.leadingAnchor, constant: 24),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: safeArea.trailingAnchor, constant: -24),
        ])
    }
}

@available(macOS 26.0, *)
@MainActor
private final class MCPServerUnavailableViewController: NSViewController {
    private let store: CodexReviewStore

    init(store: CodexReviewStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSHostingView(rootView: MCPServerUnavailableView(store: store))
    }
}

#if DEBUG
@available(macOS 26.0, *)
@MainActor
extension ReviewMonitorSplitViewController {
    enum SidebarPresentationForTesting: Equatable {
        case jobList
        case unavailable
    }

    var sidebarViewControllerForTesting: ReviewMonitorSidebarViewController {
        guard let sidebarPaneViewController else {
            fatalError("Sidebar pane view controller is not configured yet.")
        }
        return sidebarPaneViewController.sidebarViewControllerForTesting
    }

    var sidebarPresentationForTesting: SidebarPresentationForTesting {
        guard let sidebarPaneViewController else {
            fatalError("Sidebar pane view controller is not configured yet.")
        }
        switch sidebarPaneViewController.presentationForTesting {
        case .jobList:
            return .jobList
        case .unavailable:
            return .unavailable
        }
    }

    var sidebarAccessoryCountForTesting: Int {
        sidebarItem?.bottomAlignedAccessoryViewControllers.count ?? 0
    }

    var contentAccessoryCountForTesting: Int {
        contentItem?.bottomAlignedAccessoryViewControllers.count ?? 0
    }

    var contentPaneViewControllerForTesting: ReviewMonitorContentPaneViewController {
        guard let contentPaneViewController else {
            fatalError("Content pane view controller is not configured yet.")
        }
        contentPaneViewController.loadViewIfNeeded()
        return contentPaneViewController
    }

    var transportViewControllerForTesting: ReviewMonitorTransportViewController {
        contentPaneViewControllerForTesting.transportViewControllerForTesting
    }

    var toolbarIdentifiersForTesting: [NSToolbarItem.Identifier] {
        toolbar?.items.map(\.itemIdentifier) ?? []
    }

    var sidebarAllowsFullHeightLayoutForTesting: Bool {
        sidebarItem?.allowsFullHeightLayout ?? false
    }

    var contentAutomaticallyAdjustsSafeAreaInsetsForTesting: Bool {
        contentItem?.automaticallyAdjustsSafeAreaInsets ?? false
    }
}

@available(macOS 26.0, *)
@MainActor
extension ReviewMonitorSidebarPaneViewController {
    enum SidebarPresentationForTesting: Equatable {
        case jobList
        case unavailable
    }

    var sidebarViewControllerForTesting: ReviewMonitorSidebarViewController {
        sidebarViewController.loadViewIfNeeded()
        return sidebarViewController
    }

    var presentationForTesting: SidebarPresentationForTesting {
        if displayedViewController === sidebarViewController {
            return .jobList
        }
        if displayedViewController === unavailableViewController {
            return .unavailable
        }
        fatalError("Unknown sidebar presentation.")
    }
}

@available(macOS 26.0, *)
@MainActor
extension ReviewMonitorContentPaneViewController {
    struct RenderSnapshotForTesting: Equatable {
        let title: String?
        let summary: String?
        let log: String
        let isShowingEmptyState: Bool
    }

    var transportViewControllerForTesting: ReviewMonitorTransportViewController {
        transportViewController.loadViewIfNeeded()
        return transportViewController
    }

    var isShowingEmptyStateForTesting: Bool {
        displayedViewController === emptyStateViewController
    }

    var displayedTitleForTesting: String? {
        renderSnapshotForTesting.title
    }

    var viewFrameForTesting: NSRect {
        view.frame
    }

    var safeAreaFrameForTesting: NSRect {
        view.safeAreaRect
    }

    var displayedViewFrameForTesting: NSRect {
        displayedViewController?.view.frame ?? .zero
    }

    var activeDisplayedViewConstraintCountForTesting: Int {
        displayedViewConstraints.filter(\.isActive).count
    }

    var displayedSummaryForTesting: String? {
        renderSnapshotForTesting.summary
    }

    var renderCountForTesting: Int {
        renderCountForTestingStorage
    }

    var renderSnapshotForTesting: RenderSnapshotForTesting {
        if isShowingEmptyStateForTesting {
            return .init(
                title: nil,
                summary: nil,
                log: "",
                isShowingEmptyState: true
            )
        }
        let transportSnapshot = transportViewController.renderSnapshotForTesting
        return .init(
            title: transportSnapshot.title,
            summary: transportSnapshot.summary,
            log: transportSnapshot.log,
            isShowingEmptyState: false
        )
    }

    func waitForRenderCountForTesting(_ targetCount: Int) async {
        if renderCountForTestingStorage >= targetCount {
            return
        }
        await withCheckedContinuation { continuation in
            if renderCountForTestingStorage >= targetCount {
                continuation.resume()
                return
            }
            renderWaitersForTesting[targetCount, default: []].append(continuation)
        }
    }
}
#endif
