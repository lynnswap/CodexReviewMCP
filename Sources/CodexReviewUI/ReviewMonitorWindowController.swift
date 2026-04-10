import AppKit
import CodexReviewModel
import ObservationBridge
import SwiftUI

@available(macOS 26.0, *)
@MainActor
public final class ReviewMonitorWindowController: NSWindowController {
    enum DisplayedContentKind: Equatable, Sendable {
        case splitView
        case signInView
    }

    private static let frameAutosaveName = NSWindow.FrameAutosaveName("CodexReviewMonitor.MainWindow")
    private let store: CodexReviewStore
    private let splitViewController: ReviewMonitorSplitViewController
    private let signInViewController: NSHostingController<SignInView>
    private let rootContentViewController: ReviewMonitorWindowContentViewController
    private let browserURLOpener: @MainActor (URL) -> Void
    private var observationHandles: Set<ObservationHandle> = []
    private var openedBrowserURL: String?
    private var displayedContentKind: DisplayedContentKind?
    private var authRefreshTask: Task<Void, Never>?

    public convenience init(store: CodexReviewStore) {
        self.init(
            store: store,
            browserURLOpener: { url in
                _ = NSWorkspace.shared.open(url)
            },
            performInitialAuthRefresh: true
        )
    }

    package init(
        store: CodexReviewStore,
        browserURLOpener: @escaping @MainActor (URL) -> Void,
        performInitialAuthRefresh: Bool
    ) {
        let splitViewController = ReviewMonitorSplitViewController(store: store)
        splitViewController.loadViewIfNeeded()
        let signInViewController = NSHostingController(rootView: SignInView(store: store))
        signInViewController.sizingOptions = []
        let contentViewController = ReviewMonitorWindowContentViewController()

        let window = NSWindow(contentViewController: contentViewController)
        window.setContentSize(NSSize(width: 900, height: 600))

        self.store = store
        self.splitViewController = splitViewController
        self.signInViewController = signInViewController
        self.rootContentViewController = contentViewController
        self.browserURLOpener = browserURLOpener
        super.init(window: window)

        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.setFrameAutosaveName(Self.frameAutosaveName)

        bindAuthPresentation()
        updatePresentedContent(isAuthenticated: store.auth.state.isAuthenticated)
        handleBrowserURL(store.auth.state.progress?.browserURL)

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
    }

    private func bindAuthPresentation() {
        store.auth.observe(\.state) { [weak self] state in
            guard let self else {
                return
            }
            self.updatePresentedContent(isAuthenticated: state.isAuthenticated)
            self.handleBrowserURL(state.progress?.browserURL)
        }
        .store(in: &observationHandles)
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
        window.title = "Untitled"
        window.subtitle = ""
        rootContentViewController.setContentViewController(splitViewController)
        splitViewController.attach(to: window)
        displayedContentKind = .splitView
    }

    private func showSignInView(in window: NSWindow) {
        splitViewController.detachFromWindow()
        window.toolbar = nil
        window.title = ""
        window.subtitle = ""
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        rootContentViewController.setContentViewController(signInViewController)
        displayedContentKind = .signInView
    }

    private func handleBrowserURL(_ browserURL: String?) {
        guard let browserURL = browserURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              browserURL.isEmpty == false
        else {
            openedBrowserURL = nil
            return
        }

        guard openedBrowserURL != browserURL,
              let url = URL(string: browserURL)
        else {
            return
        }

        openedBrowserURL = browserURL
        browserURLOpener(url)
    }
}

@available(macOS 26.0, *)
@MainActor
private final class ReviewMonitorWindowContentViewController: NSViewController {
    private weak var displayedContentViewController: NSViewController?

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

    func setContentViewController(_ contentViewController: NSViewController) {
        loadViewIfNeeded()
        guard displayedContentViewController !== contentViewController else {
            return
        }

        if let displayedContentViewController {
            displayedContentViewController.view.removeFromSuperview()
            displayedContentViewController.removeFromParent()
        }

        displayedContentViewController = contentViewController
        addChild(contentViewController)
        let contentView = contentViewController.view
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

    var displayedContentKindForTesting: DisplayedContentKind {
        guard let displayedContentKind else {
            fatalError("ReviewMonitorWindowController did not select content yet.")
        }
        return displayedContentKind
    }
}
#endif
