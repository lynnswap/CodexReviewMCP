import AppKit
import CodexReviewModel
import Observation
import SwiftUI

private struct ReviewMonitorAccountsListView: View {
    let store: CodexReviewStore

    private var accounts: [CodexAccount] {
        store.auth.savedAccounts
    }

    var body: some View {
        @Bindable var auth = store.auth

        List {
            ForEach(accounts) { account in
                Section {
                    Menu {
                        AccountContextMenuView(
                            store: store,
                            account: account
                        )
                    } label: {
                        ReviewMonitorAccountRowView(account: account)
                            .contentShape(.rect)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                } header: {
                    Text(account.maskedEmail)
                }
            }
            .onMove(perform: handleMove)
        }
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
}

@MainActor
final class ReviewMonitorAccountsViewController: NSViewController {
    private let store: CodexReviewStore

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
