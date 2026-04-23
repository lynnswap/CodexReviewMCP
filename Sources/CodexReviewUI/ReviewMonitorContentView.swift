import AppKit
import ObservationBridge
import ReviewApp
import ReviewDomain
import SwiftUI

@MainActor
final class ReviewMonitorRootViewController: NSViewController {
    private let uiState: ReviewMonitorUIState
    private let store: CodexReviewStore
    private var observationHandles: Set<ObservationHandle> = []

    private lazy var splitViewController = ReviewMonitorSplitViewController(
        store: store,
        uiState: uiState
    )

    private lazy var signInViewController = ReviewMonitorSignInViewController(store: store)

    init(
        store: CodexReviewStore,
        uiState: ReviewMonitorUIState
    ) {
        self.store = store
        self.uiState = uiState
        super.init(nibName: nil, bundle: nil)

        loadViewIfNeeded()
        setContentViewController(uiState.contentKind, animated: false)
        bindWindowState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let backgroundView = NSVisualEffectView()
        backgroundView.material = .underWindowBackground
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        view = backgroundView
    }

    private func bindWindowState() {
        guard observationHandles.isEmpty else {
            return
        }

        uiState.observe(\.contentKind) { [weak self] kind in
            self?.setContentViewController(kind, animated: true)
        }
        .store(in: &observationHandles)
    }

    func applyInitialWindowPresentationIfPossible() {
        guard let window = view.window else {
            return
        }

        switch uiState.presentedContentKind ?? uiState.contentKind {
        case .contentView:
            splitViewController.attach(to: window)
        case .signInView:
            signInViewController.applyWindowPresentation(to: window)
        }
    }

    private func setContentViewController(
        _ kind: ReviewMonitorContentKind,
        animated: Bool
    ) {
        if uiState.presentedContentKind == kind {
            return
        }
        loadViewIfNeeded()

        let incomingContentViewController: NSViewController
        let outgoingContentViewController: NSViewController?
        switch kind {
        case .contentView:
            incomingContentViewController = splitViewController
            outgoingContentViewController = uiState.presentedContentKind == nil ? nil : signInViewController
        case .signInView:
            incomingContentViewController = signInViewController
            outgoingContentViewController = uiState.presentedContentKind == nil ? nil : splitViewController
        }

        if incomingContentViewController.parent == nil {
            addChild(incomingContentViewController)
        }

        if animated,
           let outgoingContentViewController,
           outgoingContentViewController.view.superview === view {
            let incomingContentView = incomingContentViewController.view
            incomingContentView.alphaValue = 0
            view.addSubview(
                incomingContentView,
                positioned: .above,
                relativeTo: outgoingContentViewController.view
            )
            incomingContentView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                incomingContentView.topAnchor.constraint(equalTo: view.topAnchor),
                incomingContentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                incomingContentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                incomingContentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            uiState.presentedContentKind = kind

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                outgoingContentViewController.view.animator().alphaValue = 0
                incomingContentView.animator().alphaValue = 1
            } completionHandler: { [weak self, weak outgoingContentViewController] in
                Task { @MainActor [weak self, weak outgoingContentViewController] in
                    guard let self else {
                        return
                    }
                    incomingContentView.alphaValue = 1
                    outgoingContentViewController?.view.alphaValue = 1
                    guard self.uiState.presentedContentKind == kind else {
                        return
                    }
                    if let outgoingContentViewController {
                        self.removeEmbeddedContent(for: outgoingContentViewController)
                    }
                }
            }
        } else {
            if let outgoingContentViewController {
                removeEmbeddedContent(for: outgoingContentViewController)
            }
            embed(incomingContentViewController)
            uiState.presentedContentKind = kind
        }

        if kind == .signInView {
            signInViewController.applyWindowPresentationIfPossible()
        }
    }

    private func embed(_ contentViewController: NSViewController) {
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

    private func removeEmbeddedContent(for viewController: NSViewController) {
        viewController.view.removeFromSuperview()
        if viewController.parent != nil {
            viewController.removeFromParent()
        }
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorRootViewController {
    var splitViewControllerForTesting: ReviewMonitorSplitViewController {
        splitViewController
    }

    var contentKindForTesting: ReviewMonitorContentKind {
        isShowingSplitViewForTesting ? .contentView : .signInView
    }

    var isSplitViewEmbeddedForTesting: Bool {
        children.first === splitViewController &&
        splitViewController.parent === self &&
        splitViewController.view.superview === view
    }

    var isSignInViewEmbeddedForTesting: Bool {
        children.first === signInViewController &&
        signInViewController.parent === self &&
        signInViewController.view.superview === view
    }

    var isShowingSplitViewForTesting: Bool {
        children.first === splitViewController
    }

    var embeddedContentSubviewCountForTesting: Int {
        view.subviews.count
    }
}

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
    store.auth.applySavedAccountStates(previewAccounts.map(savedAccountPayload(from:)))
    store.auth.updateSelectedAccount(resolvedAccount?.id)
    let uiState = ReviewMonitorUIState(auth: store.auth)
    return ReviewMonitorRootViewController(store: store, uiState: uiState)
}
#endif

#if DEBUG
@MainActor
private struct ReviewMonitorPreviewView: NSViewControllerRepresentable {
    var authPhase: CodexReviewAuthModel.Phase = .signedOut
    var account: CodexAccount?
    var serverState: CodexReviewServerState = .running

    func makeNSViewController(context: Context) -> NSViewController {
        makeReviewMonitorPreviewContentViewControllerForPreview(
            authPhase: authPhase,
            account: account,
            serverState: serverState
        )
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {
    }
}

#Preview("Normal") {
    ReviewMonitorPreviewView()
        .ignoresSafeArea()
}

#Preview("Server Failed") {
    ReviewMonitorPreviewView(
        serverState: .failed("The embedded server stopped responding.")
    )
    .ignoresSafeArea()
}
#endif
