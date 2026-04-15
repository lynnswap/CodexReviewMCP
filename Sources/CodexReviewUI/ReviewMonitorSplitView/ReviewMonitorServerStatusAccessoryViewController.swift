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
    private enum PrimaryAccountAction {
        case none
        case signOut
    }

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
        ratelimits.isEmpty
    }

    private var primaryAccountAction: PrimaryAccountAction {
        if canSignOut {
            return .signOut
        }
        return .none
    }

    private var showsManagementSection: Bool {
        showsServerRestartAction || primaryAccountAction == .signOut
    }

    var body: some View {
        Menu {
            ratelimitsSection

            if showsManagementSection {
                Divider()
                if showsServerRestartAction {
                    Button("Reset Server", systemImage: "arrow.clockwise") {
                        restartServer()
                    }
                }

                accountMenu
            }
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
        if primaryAccountAction == .signOut {
            Menu{
                Button{
                    performLogout()
                }label:{
                    Label("Sign Out",systemImage:"rectangle.portrait.and.arrow.right")
                    if let account{
                        Text(account.email)
                    }
                }
            }label:{
                Text("Account")
            }
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
        let remainingPercent = remainingPercent(for: window)
        Gauge(value: Double(remainingPercent), in: 0...100) {
            HStack {
                durationText(for: window)
                Spacer(minLength: 0)
                if let resetsAt = limitResetDate(for: window) {
                    Text(resetsAt, style: .offset)
                        .foregroundStyle(.secondary)
                }else{
                    Text(
                        Double(remainingPercent) / 100,
                        format: .percent.precision(.fractionLength(0))
                    )
                    .contentTransition(.numericText(value: Double(remainingPercent)))
                }
            }
        }
        .animation(.default, value: remainingPercent)
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
            if let details = rateLimitDetailsText(for: window) {
                Text(details)
            }
        }
    }

    @ViewBuilder
    private func durationText(for window: CodexRateLimitWindow) -> some View {
        Text(
            formattedDuration(for: window)
        )
    }

    private func limitResetDate(for window: CodexRateLimitWindow) -> Date? {
        guard window.usedPercent >= 100 else {
            return nil
        }
        return window.resetsAt
    }

    private func remainingPercent(for window: CodexRateLimitWindow) -> Int {
        max(0, 100 - window.usedPercent)
    }

    private func duration(for window: CodexRateLimitWindow) -> Duration {
        .seconds(window.windowDurationMinutes * 60)
    }

    private func formattedDuration(for window: CodexRateLimitWindow) -> String {
        duration(for: window).formatted(
            .units(
                allowed: [.minutes, .hours, .days, .weeks],
                width: .wide,
                maximumUnitCount: 2
            )
        )
    }

    private func rateLimitDetailsText(for window: CodexRateLimitWindow) -> AttributedString? {
        guard let resetsAt = window.resetsAt else {
            return nil
        }
        var details = AttributedString(resetsAt.formatted(.dateTime))
        details.append(AttributedString("\n"))
        details.append(Date.now.formatted(.offset(to: resetsAt, sign: .never)))
        return details
    }

    var canSignOut: Bool {
        store.auth.isAuthenticated
    }

    var showsServerRestartAction: Bool {
        switch store.serverState {
        case .failed, .stopped, .starting:
            true
        case .running:
            false
        }
    }

    func restartServer() {
        Task {
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
@MainActor
extension StatusView {
    enum PrimaryAccountActionForTesting: Equatable {
        case none
        case signOut
    }

    var showsRedactedRateLimitsForTesting: Bool {
        showsRedactedRateLimits
    }

    var primaryAccountActionForTesting: PrimaryAccountActionForTesting {
        switch primaryAccountAction {
        case .none:
            .none
        case .signOut:
            .signOut
        }
    }

    func rateLimitDetailsTextForTesting(
        _ window: CodexRateLimitWindow
    ) -> AttributedString? {
        rateLimitDetailsText(for: window)
    }

    func performPrimaryAccountActionForTesting() {
        switch primaryAccountAction {
        case .none:
            break
        case .signOut:
            performLogout()
        }
    }
}
#endif

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
