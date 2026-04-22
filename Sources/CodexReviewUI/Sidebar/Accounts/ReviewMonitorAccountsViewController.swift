import AppKit
import CodexReviewModel
import Observation
import SwiftUI

private struct ReviewMonitorAccountsListView: View {
    let store: CodexReviewStore

    private var accounts: [CodexAccount] {
        store.auth.savedAccounts
    }

    private var unsavedCurrentAccount: CodexAccount? {
        guard let currentAccount = store.auth.account else {
            return nil
        }
        guard accounts.contains(where: { $0.accountKey == currentAccount.accountKey }) == false else {
            return nil
        }
        return currentAccount
    }

    var body: some View {
        @Bindable var auth = store.auth
        
        List {
            if let unsavedCurrentAccount {
                accountRow(unsavedCurrentAccount, auth: auth)
                    .moveDisabled(true)
            }
            ForEach(accounts) { account in
                accountRow(account, auth: auth)
            }
            .onMove(perform: handleMove)
        }
        .animation(.default,value:accounts)
        .accessibilityIdentifier("review-monitor.account-list")
        .alert(
            auth.pendingAccountActionConfirmationTitle,
            isPresented: $auth.isPresentingPendingAccountActionConfirmation
        ) {
            Button(auth.pendingAccountActionConfirmationButtonTitle) {
                auth.confirmPendingAccountAction()
            }
            Button("Cancel", role: .cancel) {
                auth.cancelPendingAccountAction()
            }
        } message: {
            Text(auth.pendingAccountActionConfirmationMessage)
        }
        .alert(
            auth.accountActionAlertTitle,
            isPresented: $auth.isPresentingAccountActionAlert
        ) {
            Button("OK", role: .cancel) {
                auth.dismissAccountActionAlert()
            }
        } message: {
            Text(auth.accountActionAlertMessage)
        }
    }

    private func handleMove(
        fromOffsets sourceOffsets: IndexSet,
        toOffset destination: Int
    ) {
        guard sourceOffsets.count == 1,
              let sourceIndex = sourceOffsets.first,
              accounts.indices.contains(sourceIndex)
        else {
            return
        }

        let destinationIndex = max(
            0,
            min(
                destination > sourceIndex ? destination - 1 : destination,
                accounts.count - 1
            )
        )
        guard destinationIndex != sourceIndex else {
            return
        }

        let accountKey = accounts[sourceIndex].accountKey
        Task { @MainActor in
            do {
                try await store.auth.reorderSavedAccount(accountKey: accountKey, toIndex: destinationIndex)
            } catch {
                store.auth.presentAccountActionAlert(
                    title: "Failed to Reorder Accounts",
                    message: error.localizedDescription
                )
            }
        }
    }

    @ViewBuilder
    private func accountRow(
        _ account: CodexAccount,
        auth: CodexReviewAuthModel
    ) -> some View {
        let isSelected = auth.account == account
        Label {
            VStack {
                HStack {
                    Text(account.maskedEmail)
                        .textScale(.secondary)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                RowView(
                    store: store,
                    account: account
                )
            }
        } icon: {
            FocusRingSelectionIndicator(
                isSelected: isSelected
            )
            .accessibilityHidden(true)
            .contentShape(.circle)
            .onTapGesture {
                requestAccountRowSwitch(account, auth: auth)
            }
        }
        .contextMenu {
            AccountContextMenuView(
                store: store,
                account: account
            )
        }
        .listRowBackground(
            RoundedRectangle(
                cornerRadius: 8,
                style: .continuous
            )
            .fill(isSelected
                ? AnyShapeStyle(.background)
                : AnyShapeStyle(.clear)
            )
            .padding(.horizontal, 10)
        )
    }

    private func requestAccountRowSwitch(
        _ account: CodexAccount,
        auth: CodexReviewAuthModel
    ) {
        guard auth.switchActionIsDisabled(for: account) == false else {
            return
        }
        auth.requestSwitchAccount(
            account,
            requiresConfirmation: store.hasRunningJobs
                && auth.switchActionRequiresRunningJobsConfirmation(for: account)
        )
    }
}

private struct FocusRingSelectionIndicator: NSViewRepresentable {
    let isSelected: Bool

    func makeNSView(context: Context) -> NSButton {
        let button = (NSClassFromString("SwiftUI.FocusRingNSButton") as? NSButton.Type)?
            .init(frame: .zero) ?? NSButton(frame: .zero)
        configure(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        configure(button)
    }

    private func configure(_ button: NSButton) {
        button.setButtonType(.radio)
        button.title = ""
        button.state = isSelected ? .on : .off
        button.isEnabled = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.frame.size = CGSize(width: 16, height: 16)
    }
}

private struct RowView: View{
    var store: CodexReviewStore
    var account: CodexAccount
    var body: some View{
        Menu {
            AccountContextMenuView(
                store: store,
                account: account
            )
        } label: {
            AccountRateLimitGaugesView(
                account: account
            )
            .textScale(.secondary)
            .foregroundStyle(.secondary)
            .controlSize(.mini)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .overlay {
            if account.isSwitching {
                ProgressView()
                    .accessibilityIdentifier("review-monitor.account-row-switching")
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: account.isSwitching)
    }
}

@MainActor
final class ReviewMonitorAccountsViewController: NSViewController {
    private let store: CodexReviewStore
    private var hostingView: NSHostingView<ReviewMonitorAccountsListView>?

    init(store: CodexReviewStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
    }

    private func configureHierarchy() {
        let hostingView = NSHostingView(
            rootView: ReviewMonitorAccountsListView(store: store)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        self.hostingView = hostingView

        view.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

#if DEBUG
private extension ReviewMonitorAccountsListView {
    var showsAuthenticationProgressRowForTesting: Bool {
        false
    }

    func tapAccountRowForTesting(_ account: CodexAccount) {
        requestAccountRowSwitch(account, auth: store.auth)
    }
}

@MainActor
extension ReviewMonitorAccountsViewController {
    var showsAuthenticationProgressRowForTesting: Bool {
        hostingView?.rootView.showsAuthenticationProgressRowForTesting ?? false
    }

    func tapAccountRowForTesting(_ account: CodexAccount) {
        hostingView?.rootView.tapAccountRowForTesting(account)
    }
}

#Preview {
    ReviewMonitorAccountsViewController(
        store: makeReviewMonitorAccountsPreviewStore()
    )
}

@MainActor
private func makeReviewMonitorAccountsPreviewStore() -> CodexReviewStore {
    ReviewMonitorPreviewContent.makeStore()
}
#endif
