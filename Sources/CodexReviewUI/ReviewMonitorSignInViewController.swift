import AppKit
import CodexReviewModel
import ObservationBridge
import SwiftUI

@available(macOS 26.0, *)
@MainActor
final class ReviewMonitorSignInViewController: NSHostingController<SignInView> {
    var onAuthenticationStateChanged: (@MainActor (Bool) -> Void)?

    private let auth: CodexReviewAuthModel
    private let browserURLOpener: @MainActor (URL) -> Void
    private var observationHandles: Set<ObservationHandle> = []
    private var openedBrowserURL: String?

    init(
        store: CodexReviewStore,
        browserURLOpener: @escaping @MainActor (URL) -> Void
    ) {
        self.auth = store.auth
        self.browserURLOpener = browserURLOpener
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
            self.onAuthenticationStateChanged?(state.isAuthenticated)
            self.handleBrowserURL(state.progress?.browserURL)
        }
        .store(in: &observationHandles)

        emitCurrentState()
    }

    private func emitCurrentState() {
        onAuthenticationStateChanged?(auth.state.isAuthenticated)
        handleBrowserURL(auth.state.progress?.browserURL)
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
