import AppKit
import ReviewApp
import ObservationBridge
import SwiftUI
import ReviewDomain

@MainActor
final class ReviewMonitorSignInViewController: NSHostingController<SignInView> {
    var onAuthenticationStateChanged: (@MainActor () -> Void)?

    private let store: CodexReviewStore
    private let auth: CodexReviewAuthModel
    private var observationHandles: Set<ObservationHandle> = []
    private var isRestarting = false

    init(store: CodexReviewStore) {
        self.store = store
        self.auth = store.auth
        super.init(rootView: SignInView(store: store))
        rootView = SignInView(store: store) { [weak self] in
            self?.performPrimaryAction()
        }
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func startObservingAuth() {
        guard observationHandles.isEmpty else {
            emitCurrentState()
            return
        }

        auth.observe(\.phase) { [weak self] _ in
            guard let self else {
                return
            }
            self.onAuthenticationStateChanged?()
        }
        .store(in: &observationHandles)
        auth.observe(\.account) { [weak self] _ in
            guard let self else {
                return
            }
            self.onAuthenticationStateChanged?()
        }
        .store(in: &observationHandles)
        auth.observe(\.savedAccounts) { [weak self] _ in
            guard let self else {
                return
            }
            self.onAuthenticationStateChanged?()
        }
        .store(in: &observationHandles)

        emitCurrentState()
    }

    private func emitCurrentState() {
        onAuthenticationStateChanged?()
    }

    func performPrimaryAction() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if self.auth.isAuthenticating {
                await self.store.cancelAuthentication()
                return
            }

            guard self.auth.isAuthenticated == false else {
                return
            }
            if self.requiresServerRestartBeforeAuthentication {
                guard self.isRestarting == false else {
                    return
                }
                self.isRestarting = true
                defer {
                    self.isRestarting = false
                }
                await self.store.restart()
            }
            guard self.auth.isAuthenticated == false,
                  self.auth.isAuthenticating == false
            else {
                return
            }
            await self.store.signIn()
        }
    }

    private var requiresServerRestartBeforeAuthentication: Bool {
        switch store.serverState {
        case .failed, .stopped:
            true
        case .running, .starting:
            false
        }
    }
}
