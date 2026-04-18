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
    
    private var account: CodexAccount? {
        store.auth.account
    }

    private var savedAccounts: [CodexAccount] {
        store.auth.savedAccounts
    }
    
    private var ratelimits: [CodexRateLimitWindow] {
        account?.rateLimits ?? []
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
        showsServerRestartAction || primaryAccountAction == .signOut || savedAccounts.isEmpty == false
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
            AccountRateLimitGaugesView(account: account)
                .transition(.blurReplace)
                .animation(.default, value: account)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .padding(8)
    }
    
    @ViewBuilder
    private var accountMenu: some View{
        Menu {
            if let account {
                Section("Current") {
                    Label(account.email, systemImage: "checkmark.circle.fill")
                    Button("Refresh Rate Limits", systemImage: "arrow.clockwise") {
                        refreshRateLimits(for: account)
                    }
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                        confirmAndSignOut()
                    }
                }
            }

            Section("Accounts") {
                ForEach(savedAccounts) { savedAccount in
                    Menu(savedAccount.email) {
                        if savedAccount.isActive == false {
                            Button("Switch", systemImage: "arrow.triangle.swap") {
                                confirmAndSwitch(to: savedAccount)
                            }
                        }
                        Button("Refresh Rate Limits", systemImage: "arrow.clockwise") {
                            refreshRateLimits(for: savedAccount)
                        }
                        Button("Remove", systemImage: "trash") {
                            confirmAndRemove(savedAccount)
                        }
                        if savedAccount.rateLimits.isEmpty == false {
                            Divider()
                            ForEach(savedAccount.rateLimits) { window in
                                Text("\(window.formattedDuration): \(window.remainingPercent)%")
                            }
                        }
                    }
                }
            }

            Divider()
            Button("Add Account", systemImage: "plus") {
                addAccount()
            }
        } label: {
            Text("Account")
        }
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
            window.formattedDuration
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
            await performAccountMutation(
                errorTitle: "Failed to Sign Out"
            ) {
                try await store.auth.signOutActiveAccount()
            }
        }
    }

    func addAccount() {
        Task {
            guard await confirmJobCancellationIfNeeded(
                title: "Add Account?",
                message: "If this sign-in becomes the active session, running review jobs may stop after the account change is applied."
            ) else {
                return
            }
            let previousFailureCount = store.auth.authenticationFailureCount
            await store.auth.beginAuthentication()
            if store.auth.authenticationFailureCount != previousFailureCount,
               let message = store.auth.errorMessage
            {
                await presentAccountActionFailure(
                    title: "Failed to Add Account",
                    message: message
                )
            } else if let warningMessage = store.auth.warningMessage {
                await presentAccountActionFailure(
                    title: "Account Updated With Warning",
                    message: warningMessage
                )
            }
        }
    }

    func refreshRateLimits(for account: CodexAccount) {
        Task {
            await store.auth.refreshSavedAccountRateLimits(accountKey: account.accountKey)
        }
    }

    func confirmAndSwitch(to account: CodexAccount) {
        Task {
            guard await confirmJobCancellationIfNeeded(
                title: "Switch Account?",
                message: "Running review jobs may stop after the account change is applied."
            ) else {
                return
            }
            await performAccountMutation(
                errorTitle: "Failed to Switch Account"
            ) {
                try await store.auth.switchAccount(accountKey: account.accountKey)
            }
        }
    }

    func confirmAndRemove(_ account: CodexAccount) {
        Task {
            if account.isActive {
                guard await confirmJobCancellationIfNeeded(
                    title: "Remove Account?",
                    message: "Running review jobs may stop after the account change is applied."
                ) else {
                    return
                }
            }
            await performAccountMutation(
                errorTitle: "Failed to Remove Account"
            ) {
                try await store.auth.removeAccount(accountKey: account.accountKey)
            }
        }
    }

    func confirmAndSignOut() {
        Task {
            guard await confirmJobCancellationIfNeeded(
                title: "Sign Out?",
                message: "Running review jobs may stop after the account change is applied."
            ) else {
                return
            }
            await performAccountMutation(
                errorTitle: "Failed to Sign Out"
            ) {
                try await store.auth.signOutActiveAccount()
            }
        }
    }

    func performAccountMutation(
        errorTitle: String,
        operation: @escaping @Sendable () async throws -> Void
    ) async {
        do {
            try await operation()
            if let warningMessage = store.auth.warningMessage {
                await presentAccountActionFailure(
                    title: "Account Updated With Warning",
                    message: warningMessage
                )
            }
        } catch {
            await presentAccountActionFailure(
                title: errorTitle,
                error: error
            )
        }
    }

    func presentAccountActionFailure(
        title: String,
        error: Error
    ) async {
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = description.isEmpty ? "Request failed." : description
        await presentAccountActionFailure(
            title: title,
            message: message
        )
    }

    func presentAccountActionFailure(
        title: String,
        message: String
    ) async {
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func confirmJobCancellationIfNeeded(
        title: String,
        message: String
    ) async -> Bool {
        guard store.hasRunningJobs else {
            return true
        }

        let confirmed = await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
        guard confirmed else {
            return false
        }
        return true
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
    store.auth.updateSavedAccounts(account.map { [$0] } ?? [])
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
