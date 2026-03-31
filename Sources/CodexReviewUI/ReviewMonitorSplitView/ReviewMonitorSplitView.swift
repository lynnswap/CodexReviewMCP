import AppKit
import SwiftUI
import CodexReviewModel

@MainActor
struct ReviewMonitorSplitViewRepresentable: NSViewControllerRepresentable {
    let store: CodexReviewStore

    func makeNSViewController(context: Context) -> ReviewMonitorSplitViewController {
        let viewController = ReviewMonitorSplitViewController()
        viewController.loadViewIfNeeded()
        viewController.bind(store: store)
        return viewController
    }

    func updateNSViewController(_ nsViewController: ReviewMonitorSplitViewController, context: Context) {
        _ = nsViewController
        _ = context
    }
}

@MainActor
final class ReviewMonitorSplitViewController: NSSplitViewController {
    private static let autosaveName = NSSplitView.AutosaveName("CodexReviewMCP.ReviewMonitorSplitView")

    private let uiState = ReviewMonitorUIState()
    private lazy var sidebarViewController = ReviewMonitorSidebarViewController(uiState: uiState)
    private lazy var transportViewController = ReviewMonitorTransportViewController(uiState: uiState)

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.autosaveName = Self.autosaveName

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        let contentItem = NSSplitViewItem(viewController: transportViewController)
        contentItem.minimumThickness = 300
        splitViewItems = [sidebarItem, contentItem]
    }

    func bind(store: CodexReviewStore) {
        sidebarViewController.bind(store: store)
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorSplitViewController {
    var sidebarViewControllerForTesting: ReviewMonitorSidebarViewController {
        sidebarViewController
    }

    var transportViewControllerForTesting: ReviewMonitorTransportViewController {
        transportViewController
    }
}
#endif
