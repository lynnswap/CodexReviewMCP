import AppKit
import ReviewApp
import SwiftUI

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

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window else {
            return
        }
        window.isMovableByWindowBackground = true
        window.toolbar = nil
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.title = ""
        window.subtitle = ""
    }
}
