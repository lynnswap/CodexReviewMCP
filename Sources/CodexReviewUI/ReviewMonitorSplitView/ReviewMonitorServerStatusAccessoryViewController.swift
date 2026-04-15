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

    private static let placeholderRateLimits: [CodexRateLimitWindow] = [
        CodexRateLimitWindow(
            windowDurationMinutes: 1,
            usedPercent: 0
        ),
        CodexRateLimitWindow(
            windowDurationMinutes: 2,
            usedPercent: 0
        ),
    ]
    
    private var account: CodexAccount? {
        store.auth.account
    }
    
    private var ratelimits: [CodexRateLimitWindow] {
        account?.rateLimits ?? []
    }

    private var displayedRateLimits: [CodexRateLimitWindow] {
        ratelimits.isEmpty ? Self.placeholderRateLimits : ratelimits
    }

    private var showsRedactedRateLimits: Bool {
        return account?.rateLimits.isEmpty == true
    }

    var body: some View {
        Menu {
            ratelimitsSection
            
            Divider()
            
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
            
            accountMenu
        } label: {
            labelView
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .padding(8)
    }
    
    @ViewBuilder
    private var accountMenu: some View{
        Menu{
            Button{
                performLogout()
            }label:{
                Label("Sign Out",systemImage:"rectangle.portrait.and.arrow.right")
                if let account{
                    Text(account.email)
                }
            }
            .disabled(canSignOut == false)
        }label:{
            Text("Account")
        }
    }
    
    @ViewBuilder
    private var labelView: some View{
        Group {
            VStack {
                ForEach(displayedRateLimits) { window in
                    gaugeView(window)
                        .transaction(value: account?.id) { transaction in
                            transaction.disablesAnimations = true
                        }
                }
            }
            .redacted(reason: showsRedactedRateLimits ? .placeholder : [])
            .animation(.easeInOut, value: showsRedactedRateLimits)
        }
        .gaugeStyle(.accessoryLinearCapacity)
        .transition(.blurReplace)
        .animation(.default, value: account)
    }
    
    @ViewBuilder
    private func gaugeView(
        _ window: CodexRateLimitWindow
    ) -> some View {
        Gauge(value: Double(window.usedPercent), in: 0...100) {
            HStack {
                durationText(for: window)
                Spacer(minLength: 0)
                if let resetsAt = limitResetDate(for: window) {
                    Text(resetsAt, style: .offset)
                        .foregroundStyle(.secondary)
                }else{
                    Text(
                        Double(window.usedPercent) / 100,
                        format: .percent.precision(.fractionLength(0))
                    )
                    .contentTransition(.numericText(value: Double(window.usedPercent)))
                }
            }
        }
        .animation(.default,value:window.usedPercent)
    }
    @ViewBuilder
    private var ratelimitsSection: some View {
        Section("Rate limits"){
            ForEach(ratelimits) { window in
                ratelimitsRow(window)
            }
        }
    }
    @ViewBuilder
    private func ratelimitsRow(
        _ window: CodexRateLimitWindow
    ) -> some View {
        Button{
        }label:{
            durationText(for: window)
            let resetsAt = window.resetsAt ?? .distantFuture
            Text(rateLimitDetailsText(for: resetsAt))
        }
    }

    @ViewBuilder
    private func durationText(for window: CodexRateLimitWindow) -> some View {
        Text(
            duration(for: window),
            format: .units(
                allowed: [.days,.hours,.weeks],
                width: .wide,
                maximumUnitCount: 2
            )
        )
    }

    private func limitResetDate(for window: CodexRateLimitWindow) -> Date? {
        guard window.usedPercent >= 100 else {
            return nil
        }
        return window.resetsAt
    }

    private func duration(for window: CodexRateLimitWindow) -> Duration {
        .seconds(window.windowDurationMinutes * 60)
    }

    private func rateLimitDetailsText(for resetsAt: Date) -> AttributedString {
        var details = AttributedString(resetsAt.formatted(.dateTime))
        details.append(AttributedString("\n"))
        details.append(Date.now.formatted(.offset(to: resetsAt, sign: .never)))
        return details
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
func makeStatusPreviewAccount() -> CodexAccount {
    let account = CodexAccount(email: "review@example.com", planType: "pro")
    account.updateRateLimits(
        [
            (
                windowDurationMinutes: 300,
                usedPercent: 34,
                resetsAt: Date(timeIntervalSince1970: 1_735_776_000)
            ),
            (
                windowDurationMinutes: 10_080,
                usedPercent: 61,
                resetsAt: Date(timeIntervalSince1970: 1_736_380_800)
            ),
        ]
    )
    return account
}
#endif
