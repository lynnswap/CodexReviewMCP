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
struct StatusView: View {
    let store: CodexReviewStore

    var body: some View {
        Menu {
            Label(accountDisplayName, systemImage: "person.circle.fill")
            if canRetryAuthentication {
                Button("Sign in with ChatGPT", systemImage: "person.badge.key") {
                    performRetryAuthentication()
                }
            }
            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                performLogout()
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

    var accountDisplayName: String {
        if let accountID = store.auth.accountID,
           accountID.isEmpty == false {
            return accountID
        }
        return "Unknown"
    }

    var isSignedIn: Bool {
        store.auth.isAuthenticated
    }

    var canRetryAuthentication: Bool {
        store.auth.errorMessage != nil && store.auth.isAuthenticating == false
    }

    func performRetryAuthentication() {
        Task {
            await store.auth.beginAuthentication()
        }
    }

    func performLogout() {
        Task {
            await store.auth.logout()
        }
    }
}


#if DEBUG
@available(macOS 26.0, *)
#Preview("Signed In") {
    let store = makeStatusPreviewStore()
    return StatusView(store: store)
        .padding()
}

@available(macOS 26.0, *)
#Preview("Server Failed") {
    let store = makeStatusPreviewStore(
        serverState: .failed("The embedded server stopped responding.")
    )
    return StatusView(store: store)
        .padding()
}

@MainActor
func makeStatusPreviewStore(
    authState: CodexReviewAuthModel.State = .signedIn(accountID: "review@example.com"),
    serverState: CodexReviewServerState = .running
) -> CodexReviewStore {
    let store = ReviewMonitorPreviewContent.makeStore()
    let runningServerURL = store.serverURL
    store.auth.updateState(authState)
    store.serverState = serverState
    store.serverURL = serverState == .running ? runningServerURL : nil
    return store
}
#endif
