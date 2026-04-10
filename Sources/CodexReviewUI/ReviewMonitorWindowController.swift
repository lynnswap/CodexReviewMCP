import AppKit
import CodexReviewModel

@available(macOS 26.0, *)
@MainActor
private func configureReviewMonitorWindowBase(_ window: NSWindow) {
    window.isOpaque = false
    window.backgroundColor = .clear
    window.styleMask.insert(.fullSizeContentView)
    window.toolbarStyle = .unified
}

@available(macOS 26.0, *)
@MainActor
private func configureReviewMonitorWindowForSplitPresentation(_ window: NSWindow) {
    window.isMovableByWindowBackground = false
    window.title = "Untitled"
    window.subtitle = ""
}

@available(macOS 26.0, *)
@MainActor
public final class ReviewMonitorWindowController: NSWindowController {
    enum DisplayedContentKind: Equatable, Sendable {
        case splitView
        case signInView
    }

    private static let frameAutosaveName = NSWindow.FrameAutosaveName("CodexReviewMonitor.MainWindow")
    private let splitViewController: ReviewMonitorSplitViewController
    private let signInViewController: ReviewMonitorSignInViewController
    private let rootContentViewController: ReviewMonitorWindowContentViewController
    private var displayedContentKind: DisplayedContentKind?
    private var presentedContentUpdateTask: Task<Void, Never>?

    public convenience init(store: CodexReviewStore) {
        self.init(
            store: store,
            performInitialAuthRefresh: true
        )
    }

    package init(
        store: CodexReviewStore,
        performInitialAuthRefresh: Bool
    ) {
        let splitViewController = ReviewMonitorSplitViewController(store: store)
        splitViewController.loadViewIfNeeded()
        let signInViewController = ReviewMonitorSignInViewController(store: store)
        let contentViewController = ReviewMonitorWindowContentViewController()

        let window = NSWindow(contentViewController: contentViewController)
        window.setContentSize(NSSize(width: 900, height: 600))

        self.splitViewController = splitViewController
        self.signInViewController = signInViewController
        self.rootContentViewController = contentViewController
        super.init(window: window)

        window.isReleasedWhenClosed = false
        configureReviewMonitorWindowBase(window)
        window.setFrameAutosaveName(Self.frameAutosaveName)

        signInViewController.onAuthenticationStateChanged = { [weak self] state in
            guard let self else {
                return
            }
            if self.displayedContentKind == nil {
                self.updatePresentedContent(authState: state)
            } else {
                self.schedulePresentedContentUpdate(authState: state)
            }
        }
        signInViewController.startObservingAuth()
        _ = performInitialAuthRefresh
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        presentedContentUpdateTask?.cancel()
    }

    private func schedulePresentedContentUpdate(authState: CodexReviewAuthModel.State) {
        presentedContentUpdateTask?.cancel()
        presentedContentUpdateTask = Task { @MainActor [weak self] in
            await Task.yield()
            self?.updatePresentedContent(authState: authState)
        }
    }

    private func updatePresentedContent(authState: CodexReviewAuthModel.State) {
        guard let window else {
            return
        }

        switch desiredContentKind(for: authState) {
        case .splitView:
            guard displayedContentKind != .splitView else {
                return
            }
            showSplitView(in: window)
        case .signInView:
            guard displayedContentKind != .signInView else {
                return
            }
            showSignInView(in: window)
        }
    }

    private func desiredContentKind(
        for authState: CodexReviewAuthModel.State
    ) -> DisplayedContentKind {
        if authState.isAuthenticated {
            return .splitView
        }
        if authState.progress != nil {
            if displayedContentKind == .splitView {
                return .splitView
            }
            return .signInView
        }
        if authState.errorMessage != nil,
           displayedContentKind == .splitView {
            return .splitView
        }
        return .signInView
    }

    private func showSplitView(in window: NSWindow) {
        configureReviewMonitorWindowForSplitPresentation(window)
        splitViewController.attach(to: window)
        rootContentViewController.setContentViewController(
            splitViewController,
            animated: displayedContentKind != nil
        )
        displayedContentKind = .splitView
    }

    private func showSignInView(in window: NSWindow) {
        splitViewController.detachFromWindow()
        window.isMovableByWindowBackground = true
        window.toolbar = nil
        window.title = ""
        window.subtitle = ""
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        rootContentViewController.setContentViewController(
            signInViewController,
            animated: displayedContentKind != nil
        )
        displayedContentKind = .signInView
    }
}

@available(macOS 26.0, *)
@MainActor
private final class ReviewMonitorWindowHostView: NSVisualEffectView {
    var onWindowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?(window)
    }
}

@available(macOS 26.0, *)
@MainActor
private final class ReviewMonitorWindowContentViewController: NSViewController {
    private weak var displayedContentViewController: NSViewController?
    private var displayedContentConstraints: [NSLayoutConstraint] = []
    private var embeddedConstraintsByControllerID: [ObjectIdentifier: [NSLayoutConstraint]] = [:]
    private let onWindowChanged: ((NSWindow?) -> Void)?

    init(onWindowChanged: ((NSWindow?) -> Void)? = nil) {
        self.onWindowChanged = onWindowChanged
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let backgroundView = ReviewMonitorWindowHostView(frame: .zero)
        backgroundView.material = .underWindowBackground
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.onWindowChanged = onWindowChanged
        view = backgroundView
    }

    func setContentViewController(
        _ contentViewController: NSViewController,
        animated: Bool
    ) {
        loadViewIfNeeded()
        guard displayedContentViewController !== contentViewController else {
            return
        }

        guard let currentContentViewController = displayedContentViewController else {
            displayedContentViewController = contentViewController
            addChild(contentViewController)
            displayedContentConstraints = embed(contentViewController)
            embeddedConstraintsByControllerID[ObjectIdentifier(contentViewController)] = displayedContentConstraints
            return
        }

        let outgoingContentViewController = currentContentViewController
        addChild(contentViewController)
        if animated {
            let incomingContentView = contentViewController.view
            incomingContentView.frame = view.bounds
            incomingContentView.autoresizingMask = [.width, .height]
            incomingContentView.alphaValue = 0
            displayedContentViewController = contentViewController
            view.addSubview(incomingContentView, positioned: .above, relativeTo: outgoingContentViewController.view)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                outgoingContentViewController.view.animator().alphaValue = 0
                incomingContentView.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    outgoingContentViewController.view.alphaValue = 1
                    incomingContentView.alphaValue = 1
                    let embeddedConstraints = self.pin(contentViewController)
                    self.displayedContentConstraints = embeddedConstraints
                    self.embeddedConstraintsByControllerID[ObjectIdentifier(contentViewController)] = embeddedConstraints
                    self.removeEmbeddedContent(for: outgoingContentViewController)
                }
            }
            return
        }

        removeEmbeddedContent(for: outgoingContentViewController)
        self.displayedContentViewController = contentViewController
        displayedContentConstraints = embed(contentViewController)
        embeddedConstraintsByControllerID[ObjectIdentifier(contentViewController)] = displayedContentConstraints
    }

    @discardableResult
    private func embed(_ contentViewController: NSViewController) -> [NSLayoutConstraint] {
        let contentView = contentViewController.view
        view.addSubview(contentView)
        return pin(contentViewController)
    }

    @discardableResult
    private func pin(_ contentViewController: NSViewController) -> [NSLayoutConstraint] {
        let contentView = contentViewController.view
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let constraints = [
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        return constraints
    }

    private func removeEmbeddedContent(for viewController: NSViewController) {
        let controllerID = ObjectIdentifier(viewController)
        if let constraints = embeddedConstraintsByControllerID.removeValue(forKey: controllerID) {
            NSLayoutConstraint.deactivate(constraints)
        }
        viewController.view.removeFromSuperview()
        if viewController.parent != nil {
            viewController.removeFromParent()
        }
    }
}

#if DEBUG
@available(macOS 26.0, *)
@MainActor
func makeReviewMonitorPreviewContentViewController() -> NSViewController {
    makeReviewMonitorPreviewContentViewControllerForPreview()
}

@available(macOS 26.0, *)
@MainActor
func makeReviewMonitorPreviewContentViewControllerForPreview(
    authState: CodexReviewAuthModel.State = .signedIn(accountID: "review@example.com"),
    serverState: CodexReviewServerState = .running
) -> NSViewController {
    let store: CodexReviewStore
    switch serverState {
    case .running:
        store = ReviewMonitorPreviewContent.makeStore()
    case .failed, .starting, .stopped:
        store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.serverState = serverState
        store.serverURL = nil
    }
    store.auth.updateState(authState)
    let splitViewController = ReviewMonitorSplitViewController(store: store)
    splitViewController.loadViewIfNeeded()
    let contentViewController = ReviewMonitorWindowContentViewController { window in
        guard let window else {
            splitViewController.detachFromWindow()
            return
        }
        configureReviewMonitorWindowBase(window)
        configureReviewMonitorWindowForSplitPresentation(window)
        splitViewController.attach(to: window)
    }
    contentViewController.loadViewIfNeeded()
    contentViewController.setContentViewController(
        splitViewController,
        animated: false
    )
    return contentViewController
}

@available(macOS 26.0, *)
@MainActor
extension ReviewMonitorWindowController {
    var splitViewControllerForTesting: ReviewMonitorSplitViewController {
        splitViewController
    }

    var isSplitViewEmbeddedForTesting: Bool {
        splitViewController.parent === rootContentViewController &&
        splitViewController.view.superview === rootContentViewController.view
    }

    var isSignInViewEmbeddedForTesting: Bool {
        signInViewController.parent === rootContentViewController &&
        signInViewController.view.superview === rootContentViewController.view
    }

    var displayedContentKindForTesting: DisplayedContentKind {
        guard let displayedContentKind else {
            fatalError("ReviewMonitorWindowController did not select content yet.")
        }
        return displayedContentKind
    }

    var embeddedContentSubviewCountForTesting: Int {
        rootContentViewController.view.subviews.count
    }
}
#endif
