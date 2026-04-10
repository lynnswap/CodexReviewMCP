import AppKit
import CodexReviewModel
import ObservationBridge

@available(macOS 26.0, *)
@MainActor
final class ReviewMonitorSplitViewController: NSSplitViewController, NSToolbarDelegate {
    private static let autosaveName = NSSplitView.AutosaveName("CodexReviewMCP.ReviewMonitorSplitView")

    private let store: CodexReviewStore
    private let uiState: ReviewMonitorUIState
    private var sidebarViewController: ReviewMonitorSidebarViewController?
    private var transportViewController: ReviewMonitorTransportViewController?
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

        let sidebarViewController = ReviewMonitorSidebarViewController(uiState: uiState)
        let transportViewController = ReviewMonitorTransportViewController(uiState: uiState)
        let statusAccessoryViewController = ReviewMonitorServerStatusAccessoryViewController(store: store)
        if #available(macOS 26.1, *){
            statusAccessoryViewController.preferredScrollEdgeEffectStyle = .soft
        }
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.minimumThickness = 220
        sidebarItem.preferredThicknessFraction = 0.22
        sidebarItem.titlebarSeparatorStyle = .none
        sidebarItem.addBottomAlignedAccessoryViewController(statusAccessoryViewController)

        let contentItem = NSSplitViewItem(viewController: transportViewController)
        contentItem.minimumThickness = 300
        contentItem.automaticallyAdjustsSafeAreaInsets = true

        self.sidebarViewController = sidebarViewController
        self.transportViewController = transportViewController
        self.statusAccessoryViewController = statusAccessoryViewController
        self.sidebarItem = sidebarItem
        self.contentItem = contentItem

        sidebarViewController.loadViewIfNeeded()
        transportViewController.loadViewIfNeeded()
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        sidebarViewController.bind(store: store)
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

#if DEBUG
@available(macOS 26.0, *)
@MainActor
extension ReviewMonitorSplitViewController {
    var sidebarViewControllerForTesting: ReviewMonitorSidebarViewController {
        guard let sidebarViewController else {
            fatalError("Sidebar view controller is not configured yet.")
        }
        sidebarViewController.loadViewIfNeeded()
        return sidebarViewController
    }

    var sidebarAccessoryCountForTesting: Int {
        sidebarItem?.bottomAlignedAccessoryViewControllers.count ?? 0
    }

    var contentAccessoryCountForTesting: Int {
        contentItem?.bottomAlignedAccessoryViewControllers.count ?? 0
    }

    var transportViewControllerForTesting: ReviewMonitorTransportViewController {
        guard let transportViewController else {
            fatalError("Transport view controller is not configured yet.")
        }
        transportViewController.loadViewIfNeeded()
        return transportViewController
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
#endif
