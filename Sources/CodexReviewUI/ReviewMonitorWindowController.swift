import AppKit
import CodexReviewModel

@available(macOS 26.0, *)
@MainActor
public final class ReviewMonitorWindowController: NSWindowController {
    private static let frameAutosaveName = NSWindow.FrameAutosaveName("CodexReviewMonitor.MainWindow")
    private let splitViewController: ReviewMonitorSplitViewController

    public init(store: CodexReviewStore) {
        let splitViewController = ReviewMonitorSplitViewController(store: store)
        splitViewController.loadViewIfNeeded()
        let contentViewController = ReviewMonitorWindowContentViewController(
            splitViewController: splitViewController
        )

        let window = NSWindow(contentViewController: contentViewController)
        window.setContentSize(NSSize(width: 900, height: 600))

        self.splitViewController = splitViewController
        super.init(window: window)

        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.setFrameAutosaveName(Self.frameAutosaveName)

        splitViewController.attach(to: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

@available(macOS 26.0, *)
@MainActor
private final class ReviewMonitorWindowContentViewController: NSViewController {
    private let splitViewController: ReviewMonitorSplitViewController

    init(splitViewController: ReviewMonitorSplitViewController) {
        self.splitViewController = splitViewController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let backgroundView = NSVisualEffectView(frame: .zero)
        backgroundView.material = .underWindowBackground
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        view = backgroundView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(splitViewController)
        let contentView = splitViewController.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

#if DEBUG
@available(macOS 26.0, *)
@MainActor
extension ReviewMonitorWindowController {
    var splitViewControllerForTesting: ReviewMonitorSplitViewController {
        splitViewController
    }
}
#endif
