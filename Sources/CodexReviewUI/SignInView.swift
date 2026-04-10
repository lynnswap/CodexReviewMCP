//
//  SignInView.swift
//  CodexReviewMCP
//
//  Created by Kazuki Nakashima on 2026/04/10.
//

import SwiftUI
import CodexReviewModel

@available(macOS 26.0, *)
struct SignInView: View {
    let store: CodexReviewStore
    @State private var isRestarting = false

    var body: some View {
        ContentUnavailableView {
            Text("Welcome to CodexReviewMCP")
                .font(.largeTitle)
                .fontDesign(.rounded)
                .fontWidth(.compressed)
                .fontWeight(.semibold)
                .scenePadding(.bottom)
            
            Button(role: store.auth.isAuthenticating ? .cancel : .confirm) {
                performAuthenticationAction()
            } label: {
                LabeledContent {
                    if store.auth.isAuthenticating {
                        ProgressView()
                            .controlSize(.small)
                    }
                } label: {
                    Text(store.auth.isAuthenticating ? "Cancel" : "Sign in with ChatGPT")
                }
                .padding(.vertical, 4)
            }
            .buttonSizing(.flexible)
            .buttonBorderShape(.capsule)
            .buttonStyle(.glassProminent)
            .tint(store.auth.isAuthenticating ? .clear : .none)

            if showsServerRestartAction {
                Button {
                    restartServer()
                } label: {
                    Label("Reset Server", systemImage: "arrow.clockwise")
                        .padding(.vertical, 8)
                }
                .labelStyle(.titleAndIcon)
                .buttonSizing(.flexible)
                .buttonBorderShape(.capsule)
                .buttonStyle(.bordered)
                .disabled(isRestarting)
            }
            
        } description: {
            if let descriptionText {
                Text(descriptionText)
            }
        }
        .animation(.default, value: store.auth.isAuthenticating)
        .scenePadding()
    }

    var canStartAuthentication: Bool {
        store.auth.isAuthenticating == false && store.auth.isAuthenticated == false
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

    var showsServerRestartAction: Bool {
        switch store.serverState {
        case .failed, .stopped:
            true
        case .running, .starting:
            false
        }
    }

    func performAuthenticationAction() {
        Task {
            if store.auth.isAuthenticating {
                await store.auth.cancelAuthentication()
            } else if canStartAuthentication {
                await store.auth.beginAuthentication()
            }
        }
    }

    func restartServer() {
        guard isRestarting == false else {
            return
        }
        isRestarting = true
        Task { @MainActor in
            defer {
                isRestarting = false
            }
            await store.restart()
        }
    }
}

@available(macOS 26.0, *)
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
@available(macOS 26.0, *)
#Preview("Signed Out") {
    SignInView(store: makeSignInPreviewStore())
}

@available(macOS 26.0, *)
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
