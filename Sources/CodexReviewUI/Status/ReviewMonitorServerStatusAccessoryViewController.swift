import AppKit
import SwiftUI
import CodexReviewModel
import ObservationBridge

@MainActor
final class ReviewMonitorServerStatusAccessoryViewController: NSSplitViewItemAccessoryViewController {
    private let store: CodexReviewStore
    private let uiState: ReviewMonitorUIState
    private var observationHandles: Set<ObservationHandle> = []
    private var shouldHideStatusAccessory = false

    init(store: CodexReviewStore, uiState: ReviewMonitorUIState) {
        self.store = store
        self.uiState = uiState
        super.init(nibName: nil, bundle: nil)

        automaticallyAppliesContentInsets = true
        view = NSHostingView(rootView: StatusView(store: store))
        updateVisibility(animated: false)
        bindObservation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func bindObservation() {
        uiState.observe(\.sidebarSelection) { [weak self] _ in
            guard let self else {
                return
            }
            self.updateVisibility(animated: true)
        }
        .store(in: &observationHandles)
    }

    private func updateVisibility(animated: Bool) {
        let shouldHide = uiState.sidebarSelection == .account
        shouldHideStatusAccessory = shouldHide
        guard animated else {
            isHidden = shouldHide
            view.alphaValue = shouldHide ? 0 : 1
            return
        }

        if shouldHide {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                view.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.shouldHideStatusAccessory else {
                        return
                    }
                    self.isHidden = true
                }
            }
        } else {
            isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                view.animator().alphaValue = 1
            }
        }
    }
}

#if DEBUG
extension ReviewMonitorServerStatusAccessoryViewController {
    var observationHandleCountForTesting: Int {
        observationHandles.count
    }
}
#endif


struct AccountRateLimitsSectionView: View {
    let account: CodexAccount?

    var body: some View {
        ForEach(rateLimits) { window in
            rateLimitsRow(window)
        }
    }

    @ViewBuilder
    private func rateLimitsRow(
        _ window: CodexRateLimitWindow
    ) -> some View {
        Button {
        } label: {
            Text(window.formattedDuration)
            if let details = Self.rateLimitDetailsText(for: window) {
                Text(details)
            }
        }
    }

    private var rateLimits: [CodexRateLimitWindow] {
        account?.rateLimits ?? []
    }

    static func rateLimitDetailsText(
        for window: CodexRateLimitWindow
    ) -> AttributedString? {
        guard let resetsAt = window.resetsAt else {
            return nil
        }
        var details = AttributedString(resetsAt.formatted(.dateTime))
        details.append(AttributedString("\n"))
        details.append(Date.now.formatted(.offset(to: resetsAt, sign: .never)))
        return details
    }
}

struct StatusView: View {
    let store: CodexReviewStore
    let auth: CodexReviewAuthModel

    init(store: CodexReviewStore) {
        self.store = store
        self.auth = store.auth
    }

    private var account: CodexAccount? {
        auth.account
    }

    private var showsManagementSection: Bool {
        showsServerRestartAction
    }

    var body: some View {
        Menu {
            Section("Rate limits") {
                AccountRateLimitsSectionView(account: account)
            }

            if showsManagementSection {
                Divider()
                if showsServerRestartAction {
                    Button("Reset Server", systemImage: "arrow.clockwise") {
                        restartServer()
                    }
                }
            }
        } label: {
            AccountRateLimitGaugesView(account: account)
                .transition(.blurReplace)
                .animation(.default, value: account)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .padding(8)
    }

    var showsServerRestartAction: Bool {
        switch store.serverState {
        case .failed, .stopped, .starting:
            true
        case .running:
            false
        }
    }

    func restartServer() {
        Task {
            await store.restart()
        }
    }
}

#if DEBUG

#Preview("Signed In") {
    let store = makeStatusPreviewStore()
    return StatusView(store: store)
        .padding()
}

#Preview("Server Failed") {
    let store = makeStatusPreviewStore(
        serverState: .failed("The embedded server stopped responding.")
    )
    return StatusView(store: store)
        .padding()
}

@MainActor
func makeStatusPreviewStore(
    authPhase: CodexReviewAuthModel.Phase = .signedOut,
    account: CodexAccount? = nil,
    serverState: CodexReviewServerState = .running
) -> CodexReviewStore {
    let store = ReviewMonitorPreviewContent.makeStore()
    let runningServerURL = store.serverURL
    let previewAccounts = ReviewMonitorPreviewContent.makePreviewAccounts()
    let resolvedAccount = account ?? previewAccounts.first
    store.auth.updatePhase(authPhase)
    store.auth.updateSavedAccounts(previewAccounts)
    store.auth.updateAccount(resolvedAccount)
    store.serverState = serverState
    store.serverURL = serverState == .running ? runningServerURL : nil
    return store
}
@MainActor
func makeStatusPreviewAccount() -> CodexAccount {
    ReviewMonitorPreviewContent.makePreviewAccount()
}
#endif
