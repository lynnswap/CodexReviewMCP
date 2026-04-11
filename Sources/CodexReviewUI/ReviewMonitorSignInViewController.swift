import AppKit
import CodexReviewModel
import ObservationBridge
import SwiftUI

@available(macOS 26.0, *)
@MainActor
final class ReviewMonitorSignInViewController: NSHostingController<SignInView> {
    var onAuthenticationStateChanged: (@MainActor (CodexReviewAuthModel.State) -> Void)?

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

        auth.observe(\.state) { [weak self] state in
            guard let self else {
                return
            }
            self.onAuthenticationStateChanged?(state)
        }
        .store(in: &observationHandles)

        emitCurrentState()
    }

    private func emitCurrentState() {
        onAuthenticationStateChanged?(auth.state)
    }

    func performPrimaryAction() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if self.auth.isAuthenticating {
                await self.store.auth.cancelAuthentication()
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
            await self.store.auth.beginAuthentication()
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
