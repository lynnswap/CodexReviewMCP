import AppKit
import CodexReviewModel
import ObservationBridge
import SwiftUI

@available(macOS 26.0, *)
@MainActor
final class ReviewMonitorSignInViewController: NSHostingController<SignInView> {
    var onAuthenticationStateChanged: (@MainActor (CodexReviewAuthModel.State) -> Void)?

    private let auth: CodexReviewAuthModel
    private var observationHandles: Set<ObservationHandle> = []

    init(store: CodexReviewStore) {
        self.auth = store.auth
        super.init(rootView: SignInView(store: store))
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
}
