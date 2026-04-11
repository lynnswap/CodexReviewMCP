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
            if showsAuthenticationAction {
                Button(authenticationActionTitle, systemImage: authenticationActionSystemImage) {
                    performAuthenticationAction()
                }
            }
            if showsServerRestartAction {
                Button("Reset Server", systemImage: "arrow.clockwise") {
                    restartServer()
                }
            }
            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                performLogout()
            }
            .disabled(canSignOut == false)
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

    var canSignOut: Bool {
        store.auth.isAuthenticated && store.auth.isAuthenticating == false
    }

    var canRetryAuthentication: Bool {
        store.auth.errorMessage != nil &&
        store.auth.isAuthenticated == false &&
        store.auth.isAuthenticating == false
    }

    var showsAuthenticationAction: Bool {
        canRetryAuthentication || store.auth.isAuthenticating
    }

    var showsServerRestartAction: Bool {
        switch store.serverState {
        case .failed, .stopped:
            true
        case .running, .starting:
            false
        }
    }

    var authenticationActionTitle: String {
        store.auth.isAuthenticating ? "Cancel" : "Sign in with ChatGPT"
    }

    var authenticationActionSystemImage: String {
        store.auth.isAuthenticating ? "xmark.circle" : "person.badge.key"
    }

    func performAuthenticationAction() {
        Task {
            if store.auth.isAuthenticating {
                await store.auth.cancelAuthentication()
            } else if canRetryAuthentication {
                await store.auth.beginAuthentication()
            }
        }
    }

    func restartServer() {
        Task {
            if store.auth.isAuthenticating {
                await store.auth.cancelAuthentication()
            }
            await store.restart()
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
