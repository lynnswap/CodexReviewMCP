import AppKit
import SwiftUI
import CodexReviewModel
import ObservationBridge

@available(macOS 26.0, *)
@MainActor
struct ReviewMonitorSplitViewRepresentable: NSViewControllerRepresentable {
    let store: CodexReviewStore

    func makeNSViewController(context: Context) -> ReviewMonitorSplitViewController {
        ReviewMonitorSplitViewController(store: store)
    }

    func updateNSViewController(_ nsViewController: ReviewMonitorSplitViewController, context: Context) {
    }
}

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
    private var didTriggerStoreStart = false

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
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.allowsFullHeightLayout = true
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

    override func viewDidAppear() {
        super.viewDidAppear()
        splitView.identifier = NSUserInterfaceItemIdentifier(Self.autosaveName)
        splitView.autosaveName = Self.autosaveName
        installToolbarIfNeeded()
        bindJobEntry()
        triggerStoreStartIfNeeded()
    }

    private func bindJobEntry() {
        observationHandles.removeAll()

        uiState.observe(\.selectedJobEntry?.targetSummary) { [weak self] targetSummary in
            guard let window = self?.view.window else {
                return
            }
            window.title = targetSummary ?? ""
        }
        .store(in: &observationHandles)

        uiState.observe(\.selectedJobEntry?.cwd) { [weak self] cwd in
            guard let window = self?.view.window else {
                return
            }
            window.subtitle = cwd ?? ""
        }
        .store(in: &observationHandles)
    }

    private func installToolbarIfNeeded() {
        guard let window = view.window else {
            return
        }

        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.titleVisibility = .visible

        if toolbar == nil {
            let toolbar = NSToolbar(identifier: "CodexReviewMCP.ReviewMonitor.Toolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
            self.toolbar = toolbar
        }

        if window.toolbar !== toolbar {
            window.toolbar = toolbar
        }

    }

    private func triggerStoreStartIfNeeded() {
        guard didTriggerStoreStart == false,
              store.shouldAutoStartEmbeddedServer
        else {
            return
        }
        didTriggerStoreStart = true
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.store.start()
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

    var didTriggerStoreStartForTesting: Bool {
        didTriggerStoreStart
    }
}
#endif
