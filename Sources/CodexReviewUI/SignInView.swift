import SwiftUI
import CodexReviewModel

struct SignInView: View {
    let store: CodexReviewStore
    let onPrimaryAction: @MainActor () -> Void

    init(
        store: CodexReviewStore,
        onPrimaryAction: @escaping @MainActor () -> Void = {}
    ) {
        self.store = store
        self.onPrimaryAction = onPrimaryAction
    }

    var body: some View {
        ContentUnavailableView {
            Text("Welcome to CodexReviewMCP")
                .font(.largeTitle)
                .fontDesign(.rounded)
                .fontWidth(.compressed)
                .fontWeight(.semibold)
                .scenePadding(.bottom)
            
            Button(role: authenticationActionRole) {
                onPrimaryAction()
            } label: {
                LabeledContent {
                    if store.auth.isAuthenticating {
                        ProgressView()
                            .controlSize(.small)
                    }
                } label: {
                    Text(authenticationActionTitle)
                }
                .padding(.vertical, 4)
            }
            .buttonSizing(.flexible)
            .buttonBorderShape(.capsule)
            .buttonStyle(.glassProminent)
            .tint(store.auth.isAuthenticating ? .clear : .none)
            
        } description: {
            if let descriptionText {
                Text(descriptionText)
            }
        }
        .animation(.default, value: store.auth.isAuthenticating)
        .scenePadding()
    }

    var authenticationActionTitle: String {
        store.auth.isAuthenticating ? "Cancel" : "Sign in with ChatGPT"
    }

    var authenticationActionRole: ButtonRole? {
        store.auth.isAuthenticating ? .cancel : .confirm
    }

    var descriptionText: String? {
        store.auth.errorMessage ?? serverFailureMessage
    }

    var serverFailureMessage: String? {
        guard case .failed(let message) = store.serverState else {
            return nil
        }
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedMessage.isEmpty ? nil : trimmedMessage
    }
}

struct AuthenticationButtonStyle: PrimitiveButtonStyle {
    let isAuthenticating: Bool

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if isAuthenticating {
            Button(configuration)
                .buttonStyle(.glass)
        } else {
            Button(configuration)
                .buttonStyle(.glassProminent)
        }
    }
}
#if DEBUG
#Preview("Signed Out") {
    SignInView(store: makeSignInPreviewStore())
}

#Preview("Authenticating") {
    SignInView(store: makeAuthenticatingSignInPreviewStore())
}

@MainActor
func makeSignInPreviewStore() -> CodexReviewStore {
    ReviewMonitorPreviewContent.makeStore()
}

@MainActor
func makeAuthenticatingSignInPreviewStore() -> CodexReviewStore {
    let store = makeSignInPreviewStore()
    store.auth.updateState(
        .signingIn(
            .init(
                title: "Sign in with ChatGPT",
                detail: "Open the browser to continue.",
                browserURL: "https://auth.openai.com/oauth/authorize"
            )
        )
    )
    return store
}
#endif
