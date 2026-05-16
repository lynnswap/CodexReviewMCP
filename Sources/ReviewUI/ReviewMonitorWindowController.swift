import AppKit
import ReviewApplication

@MainActor
func configureReviewMonitorWindowBase(_ window: NSWindow) {
    window.isOpaque = true
    window.backgroundColor = .windowBackgroundColor
    window.isMovableByWindowBackground = false
    window.styleMask.insert(.fullSizeContentView)
    window.toolbarStyle = .unified
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = false
    window.titlebarSeparatorStyle = .automatic
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
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 900, height: 600)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        configureReviewMonitorWindowBase(window)
        window.contentViewController = rootViewController

        self.rootViewController = rootViewController
        super.init(window: window)

        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(Self.frameAutosaveName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
