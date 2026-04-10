import AppKit
import CodexReviewModel

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
    private var authRefreshTask: Task<Void, Never>?
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
        window.isOpaque = false
        window.backgroundColor = .clear
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.setFrameAutosaveName(Self.frameAutosaveName)

        signInViewController.onAuthenticationStateChanged = { [weak self] isAuthenticated in
            guard let self else {
                return
            }
            if self.displayedContentKind == nil {
                self.updatePresentedContent(isAuthenticated: isAuthenticated)
            } else {
                self.schedulePresentedContentUpdate(isAuthenticated: isAuthenticated)
            }
        }
        signInViewController.startObservingAuth()

        if performInitialAuthRefresh {
            authRefreshTask = Task { [store] in
                await store.auth.refresh()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        authRefreshTask?.cancel()
        presentedContentUpdateTask?.cancel()
    }

    private func schedulePresentedContentUpdate(isAuthenticated: Bool) {
        presentedContentUpdateTask?.cancel()
        presentedContentUpdateTask = Task { @MainActor [weak self] in
            await Task.yield()
            self?.updatePresentedContent(isAuthenticated: isAuthenticated)
        }
    }

    private func updatePresentedContent(isAuthenticated: Bool) {
        guard let window else {
            return
        }

        switch isAuthenticated {
        case true:
            guard displayedContentKind != .splitView else {
                return
            }
            showSplitView(in: window)
        case false:
            guard displayedContentKind != .signInView else {
                return
            }
            showSignInView(in: window)
        }
    }

    private func showSplitView(in window: NSWindow) {
        window.isMovableByWindowBackground = false
        window.title = "Untitled"
        window.subtitle = ""
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
private final class ReviewMonitorWindowContentViewController: NSViewController {
    private weak var displayedContentViewController: NSViewController?
    private var displayedContentConstraints: [NSLayoutConstraint] = []
    private var embeddedConstraintsByControllerID: [ObjectIdentifier: [NSLayoutConstraint]] = [:]

    init() {
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
            let outgoingContentViewControllerID = ObjectIdentifier(outgoingContentViewController)
            displayedContentViewController = contentViewController
            displayedContentConstraints = embed(contentViewController)
            embeddedConstraintsByControllerID[ObjectIdentifier(contentViewController)] = displayedContentConstraints
            transition(
                from: outgoingContentViewController,
                to: contentViewController,
                options: [.crossfade]
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.removeEmbeddedContent(for: outgoingContentViewControllerID)
                }
            }
            return
        }

        removeEmbeddedContent(for: ObjectIdentifier(outgoingContentViewController))
        self.displayedContentViewController = contentViewController
        displayedContentConstraints = embed(contentViewController)
        embeddedConstraintsByControllerID[ObjectIdentifier(contentViewController)] = displayedContentConstraints
    }

    @discardableResult
    private func embed(_ contentViewController: NSViewController) -> [NSLayoutConstraint] {
        let contentView = contentViewController.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView)

        let constraints = [
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        return constraints
    }

    private func removeEmbeddedContent(for controllerID: ObjectIdentifier) {
        if let constraints = embeddedConstraintsByControllerID.removeValue(forKey: controllerID) {
            NSLayoutConstraint.deactivate(constraints)
        }

        guard let viewController = children.first(where: { ObjectIdentifier($0) == controllerID }) else {
            return
        }
        viewController.view.removeFromSuperview()
        viewController.removeFromParent()
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
    let contentViewController = ReviewMonitorWindowContentViewController()
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
}
#endif
