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
        Menu{
            authStatusSection
            if store.serverState.isRestartAvailable{
                Section{
                    Button("Reset Server") {
                        Task {
                            await store.restart()
                        }
                    }
                }
            }
            authMenuSection
        }label:{
            Label("Settings",systemImage:"gear")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .sheet(isPresented: Binding(
            get: { store.auth.isAuthenticating },
            set: { isPresented in
                guard isPresented == false else {
                    return
                }
                Task {
                    await store.auth.cancelAuthentication()
                }
            }
        )) {
            ReviewMonitorAuthSheet(auth: store.auth)
        }
    }
    @ViewBuilder
    private var authStatusSection: some View {
        Section{
            switch store.auth.state{
            case .signingIn(_):
                EmptyView()
            case .signedIn(let accountID):
                Label(accountID ?? "Unknown",systemImage: "person.circle.fill")
            case .signedOut:
                EmptyView()
            case .failed(let reason):
                Label{
                    Text(reason)
                }icon:{
                    Image(systemName: "person.crop.circle.badge.exclamationmark.fill")
                        .symbolRenderingMode(.multicolor)
                        .foregroundStyle(.primary, .yellow)
                }
            }
        }
    }

    @ViewBuilder
    private var authMenuSection: some View {
        switch store.auth.state {
        case .signedIn:
            Button("Sign Out",systemImage:"rectangle.portrait.and.arrow.right") {
                Task {
                    await store.auth.logout()
                }
            }
        case .signingIn:
            Label{
                Text("Authentication in progress")
            }icon:{
                ProgressView()
            }
            Button("Cancel Sign In") {
                Task {
                    await store.auth.cancelAuthentication()
                }
            }
        case .signedOut, .failed:
            Button("Sign in with ChatGPT",systemImage:"person.circle.fill") {
                Task {
                    await store.auth.beginAuthentication()
                }
            }
        }
    }
}


#if DEBUG
@available(macOS 26.0, *)
#Preview("Signed In") {
    let store = makeStatusPreviewStore(state: .signedIn(accountID: "review@example.com"))
    return StatusView(store: store)
        .padding()
}
@MainActor
func makeStatusPreviewStore(state: CodexReviewAuthModel.State) -> CodexReviewStore {
    let store = ReviewMonitorPreviewContent.makeStore()
    store.auth.updateState(state)
    return store
}
#endif
