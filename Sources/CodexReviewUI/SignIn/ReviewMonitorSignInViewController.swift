import AppKit
import ReviewApp
import SwiftUI
import ReviewDomain

@MainActor
final class ReviewMonitorSignInViewController: NSHostingController<SignInView> {
    init(store: CodexReviewStore) {
        super.init(rootView: SignInView(store: store))
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func performPrimaryAction() {
        Task { @MainActor in
            await rootView.store.performPrimaryAuthenticationAction()
        }
    }
}
