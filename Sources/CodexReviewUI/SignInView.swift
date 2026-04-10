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

    var body: some View {
        ContentUnavailableView {
            Text("Welcome to CodexReviewMCP")
                .font(.largeTitle)
                .fontDesign(.rounded)
                .fontWidth(.compressed)
                .fontWeight(.semibold)
                .scenePadding(.bottom)
            Button {
                startAuthentication()
            } label: {
                LabeledContent {
                    if store.auth.isAuthenticating {
                        ProgressView()
                            .controlSize(.small)
                    }
                } label: {
                    Text("Sign in with ChatGPT")
                        .padding(.vertical, 4)
                }
            }
            .disabled(canStartAuthentication == false)
            .buttonSizing(.flexible)
            .buttonBorderShape(.capsule)
            .buttonStyle(.glassProminent)
        } description: {
            if let descriptionText {
                Text(descriptionText)
            }
        }
        .scenePadding()
    }

    var canStartAuthentication: Bool {
        store.auth.isAuthenticating == false && store.auth.isAuthenticated == false
    }

    var descriptionText: String? {
        switch store.auth.state {
        case .failed(let message):
            message
        case .signedOut, .signingIn, .signedIn:
            nil
        }
    }

    func startAuthentication() {
        guard canStartAuthentication else {
            return
        }
        Task {
            await store.auth.beginAuthentication()
        }
    }
}

@available(macOS 26.0, *)
#Preview {
    let store = ReviewMonitorPreviewContent.makeStore()
    SignInView(store: store)
}
