import AppKit
import SwiftUI
import CodexReviewModel
import ObservationBridge

@MainActor
final class ReviewMonitorServerStatusAccessoryViewController: NSSplitViewItemAccessoryViewController {
    private let store: CodexReviewStore
    private let uiState: ReviewMonitorUIState
    private var observationHandles: Set<ObservationHandle> = []
    private var shouldHideStatusAccessory = false

    private var hostingView: NSHostingView<StatusView>? {
        view as? NSHostingView<StatusView>
    }

    init(store: CodexReviewStore, uiState: ReviewMonitorUIState) {
        self.store = store
        self.uiState = uiState
        super.init(nibName: nil, bundle: nil)

        automaticallyAppliesContentInsets = true
        view = NSHostingView(rootView: StatusView(store: store))
        updateVisibility(animated: false)
        bindObservation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func bindObservation() {
        uiState.observe(\.sidebarSelection) { [weak self] _ in
            guard let self else {
                return
            }
            self.updateVisibility(animated: true)
        }
        .store(in: &observationHandles)
        store.auth.observe(\.account) { [weak self] _ in
            self?.refreshStatusView()
        }
        .store(in: &observationHandles)
        store.auth.observe(\.savedAccounts) { [weak self] _ in
            self?.refreshStatusView()
        }
        .store(in: &observationHandles)
    }

    private func refreshStatusView() {
        hostingView?.rootView = StatusView(store: store)
    }

    private func updateVisibility(animated: Bool) {
        let shouldHide = uiState.sidebarSelection == .account
        shouldHideStatusAccessory = shouldHide
        guard animated else {
            isHidden = shouldHide
            view.alphaValue = shouldHide ? 0 : 1
            return
        }

        if shouldHide {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                view.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.shouldHideStatusAccessory else {
                        return
                    }
                    self.isHidden = true
                }
            }
        } else {
            isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                view.animator().alphaValue = 1
            }
        }
    }
}


struct StatusView: View {
    private enum PrimaryAccountAction {
        case none
        case signOut
    }

    let store: CodexReviewStore
    let auth: CodexReviewAuthModel

    init(store: CodexReviewStore) {
        self.store = store
        self.auth = store.auth
    }
    
    private var account: CodexAccount? {
        auth.account
    }

    private var savedAccounts: [CodexAccount] {
        auth.savedAccounts
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
        auth.isAuthenticated
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
                try await auth.signOutActiveAccount()
            }
        }
    }

    func addAccount() {
        ReviewMonitorAddAccountAction.perform(store: store)
    }

    func refreshRateLimits(for account: CodexAccount) {
        Task {
            await auth.refreshSavedAccountRateLimits(accountKey: account.accountKey)
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
                try await auth.switchAccount(accountKey: account.accountKey)
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
                try await auth.removeAccount(accountKey: account.accountKey)
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
                try await auth.signOutActiveAccount()
            }
        }
    }

    func performAccountMutation(
        errorTitle: String,
        operation: @escaping @Sendable () async throws -> Void
    ) async {
        do {
            try await operation()
            if let warningMessage = auth.warningMessage {
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

    var currentAccountEmailForTesting: String? {
        account?.email
    }

    var remainingRateLimitPercentsForTesting: [Int] {
        ratelimits.map(\.remainingPercent)
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
    account: CodexAccount? = nil,
    serverState: CodexReviewServerState = .running
) -> CodexReviewStore {
    let store = ReviewMonitorPreviewContent.makeStore()
    let runningServerURL = store.serverURL
    let previewAccounts = ReviewMonitorPreviewContent.makePreviewAccounts()
    let resolvedAccount = account ?? previewAccounts.first
    store.auth.updatePhase(authPhase)
    store.auth.updateSavedAccounts(previewAccounts)
    store.auth.updateAccount(resolvedAccount)
    store.serverState = serverState
    store.serverURL = serverState == .running ? runningServerURL : nil
    return store
}
@MainActor
func makeStatusPreviewAccount() -> CodexAccount {
    ReviewMonitorPreviewContent.makePreviewAccount()
}
#endif
