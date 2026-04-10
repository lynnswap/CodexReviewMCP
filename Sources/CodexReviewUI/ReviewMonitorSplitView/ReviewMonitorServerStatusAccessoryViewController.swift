import AppKit
import SwiftUI
import CodexReviewModel

@available(macOS 26.0, *)
@MainActor
final class ReviewMonitorServerStatusAccessoryViewController: NSSplitViewItemAccessoryViewController {
    init(store: CodexReviewStore) {
        super.init(nibName: nil, bundle: nil)

        automaticallyAppliesContentInsets = true
        view = NSHostingView(rootView: StatusView(store: store))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}


@available(macOS 26.0, *)
private struct StatusView: View {
    let store: CodexReviewStore

    var body: some View {
        Menu {
            Label(accountDisplayName, systemImage: "person.circle.fill")
            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                Task {
                    await store.auth.logout()
                }
            }
            .disabled(isSignedIn == false)
        } label: {
            Label("Settings", systemImage: "gear")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var accountDisplayName: String {
        if let accountID = store.auth.accountID,
           accountID.isEmpty == false {
            return accountID
        }
        return "Unknown"
    }

    private var isSignedIn: Bool {
        store.auth.isAuthenticated
    }
}


#if DEBUG
@available(macOS 26.0, *)
#Preview("Signed In") {
    let store = makeStatusPreviewStore()
    return StatusView(store: store)
        .padding()
}
@MainActor
func makeStatusPreviewStore() -> CodexReviewStore {
    let store = ReviewMonitorPreviewContent.makeStore()
    store.auth.updateState(.signedIn(accountID: "review@example.com"))
    return store
}
#endif
