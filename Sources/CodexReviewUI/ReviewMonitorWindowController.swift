import AppKit
import ReviewApp
import ReviewDomain

@MainActor
private func configureReviewMonitorWindowBase(_ window: NSWindow) {
    window.isOpaque = false
    window.backgroundColor = .clear
    window.styleMask.insert(.fullSizeContentView)
    window.toolbarStyle = .unified
}

@MainActor
private func configureReviewMonitorWindowForSplitPresentation(_ window: NSWindow) {
    window.isMovableByWindowBackground = false
    window.title = "Untitled"
    window.subtitle = ""
    window.titleVisibility = .visible
    window.titlebarSeparatorStyle = .automatic
}

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
    private let auth: CodexReviewAuthModel
    private let forceSplitView: Bool
    private var displayedContentKind: DisplayedContentKind?
    private var presentedContentUpdateTask: Task<Void, Never>?

    public convenience init(
        store: CodexReviewStore,
        forceSplitView: Bool = false
    ) {
        self.init(
            store: store,
            performInitialAuthRefresh: true,
            forceSplitView: forceSplitView
        )
    }

    package init(
        store: CodexReviewStore,
        performInitialAuthRefresh: Bool,
        forceSplitView: Bool = false
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
        self.auth = store.auth
        self.forceSplitView = forceSplitView
        super.init(window: window)

        window.isReleasedWhenClosed = false
        configureReviewMonitorWindowBase(window)
        window.setFrameAutosaveName(Self.frameAutosaveName)

        signInViewController.onAuthenticationStateChanged = { [weak self] in
            guard let self else {
                return
            }
            if self.displayedContentKind == nil {
                self.updatePresentedContent()
            } else {
                self.schedulePresentedContentUpdate()
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

    private func schedulePresentedContentUpdate() {
        presentedContentUpdateTask?.cancel()
        presentedContentUpdateTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard Task.isCancelled == false else {
                return
            }
            self?.updatePresentedContent()
        }
    }

    private func updatePresentedContent() {
        guard let window else {
            return
        }

        switch desiredContentKind() {
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

    private func desiredContentKind() -> DisplayedContentKind {
        if forceSplitView {
            return .splitView
        }
        if auth.isAuthenticating,
           displayedContentKind == .splitView {
            return .splitView
        }
        if auth.account != nil {
            return .splitView
        }
        if auth.hasSavedAccounts {
            return .splitView
        }
        if auth.errorMessage != nil,
           displayedContentKind == .splitView {
            return .splitView
        }
        if auth.isAuthenticating {
            return .signInView
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

@MainActor
private final class ReviewMonitorWindowHostView: NSVisualEffectView {
    var onWindowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?(window)
    }
}

@MainActor
private final class ReviewMonitorWindowContentViewController: NSViewController {
    private weak var displayedContentViewController: NSViewController?
    private var displayedContentConstraints: [NSLayoutConstraint] = []
    private var embeddedConstraintsByControllerID: [ObjectIdentifier: [NSLayoutConstraint]] = [:]
    private var contentTransitionGeneration = 0
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
            contentTransitionGeneration += 1
            displayedContentViewController = contentViewController
            addChild(contentViewController)
            displayedContentConstraints = embed(contentViewController)
            embeddedConstraintsByControllerID[ObjectIdentifier(contentViewController)] = displayedContentConstraints
            return
        }

        let outgoingContentViewController = currentContentViewController
        contentTransitionGeneration += 1
        let transitionGeneration = contentTransitionGeneration
        if contentViewController.parent !== self {
            addChild(contentViewController)
        }
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
                    guard self.contentTransitionGeneration == transitionGeneration,
                          self.displayedContentViewController === contentViewController
                    else {
                        if self.displayedContentViewController !== contentViewController {
                            self.removeEmbeddedContent(for: contentViewController)
                        }
                        return
                    }
                    let embeddedConstraints = self.replacePinnedConstraints(contentViewController)
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

    @discardableResult
    private func replacePinnedConstraints(_ contentViewController: NSViewController) -> [NSLayoutConstraint] {
        let controllerID = ObjectIdentifier(contentViewController)
        if let existingConstraints = embeddedConstraintsByControllerID[controllerID] {
            NSLayoutConstraint.deactivate(existingConstraints)
        }
        return pin(contentViewController)
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
@MainActor
func makeReviewMonitorPreviewContentViewController() -> NSViewController {
    makeReviewMonitorPreviewContentViewControllerForPreview()
}

@MainActor
func makeReviewMonitorPreviewContentViewControllerForPreview(
    authPhase: CodexReviewAuthModel.Phase = .signedOut,
    account: CodexAccount? = nil,
    serverState: CodexReviewServerState = .running
) -> NSViewController {
    let store: CodexReviewStore
    switch serverState {
    case .running:
        store = ReviewMonitorPreviewContent.makeStore()
    case .failed, .starting, .stopped:
        store = CodexReviewStore.makePreviewStore()
        store.serverState = serverState
        store.serverURL = nil
    }
    let previewAccounts = ReviewMonitorPreviewContent.makePreviewAccounts()
    let resolvedAccount = account ?? previewAccounts.first
    store.auth.updatePhase(authPhase)
    store.auth.updateSavedAccounts(previewAccounts)
    store.auth.updateAccount(resolvedAccount)
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
