import AppKit
import SwiftUI
import CodexReviewModel

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


struct StatusView: View {
    let store: CodexReviewStore

    var body: some View {
        VStack{
            AccountStatusView(account: store.auth.account)
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
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        }
        .padding(8)
    }

    var accountDisplayName: String {
        if let account = store.auth.account {
            return account.displayName
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
        case .failed, .stopped, .starting:
            true
        case .running:
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
    account: CodexAccount? = makeStatusPreviewAccount(),
    serverState: CodexReviewServerState = .running
) -> CodexReviewStore {
    let store = ReviewMonitorPreviewContent.makeStore()
    let runningServerURL = store.serverURL
    store.auth.updatePhase(authPhase)
    store.auth.updateAccount(account)
    store.serverState = serverState
    store.serverURL = serverState == .running ? runningServerURL : nil
    return store
}
@MainActor
private func makeStatusPreviewAccount() -> CodexAccount {
    let account = CodexAccount(email: "review@example.com", planType: "pro")
    account.updateRateLimits(
        sessionLimits: .init(
            usedFraction: 0.34,
            windowDurationMinutes: 300,
            resetsAt: Date(timeIntervalSince1970: 1_735_776_000)
        ),
        weeklyLimits: .init(
            usedFraction: 0.61,
            windowDurationMinutes: 10080,
            resetsAt: Date(timeIntervalSince1970: 1_736_380_800)
        )
    )
    return account
}
#endif
