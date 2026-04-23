import AppKit
import ReviewApp

@MainActor
private func configureReviewMonitorWindowBase(_ window: NSWindow) {
    window.isOpaque = false
    window.backgroundColor = .clear
    window.styleMask.insert(.fullSizeContentView)
    window.toolbarStyle = .unified
}

@Observable
public final class ReviewMonitorWindowController: NSWindowController {
    private static let frameAutosaveName = NSWindow.FrameAutosaveName("CodexReviewMonitor.MainWindow")
    private let rootViewController: ReviewMonitorRootViewController

    public init(store: CodexReviewStore) {
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let rootViewController = ReviewMonitorRootViewController(
            store: store,
            uiState: uiState
        )
        let window = NSWindow(contentViewController: rootViewController)
        window.setContentSize(NSSize(width: 900, height: 600))

        self.rootViewController = rootViewController
        super.init(window: window)

        window.isReleasedWhenClosed = false
        configureReviewMonitorWindowBase(window)
        window.setFrameAutosaveName(Self.frameAutosaveName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
