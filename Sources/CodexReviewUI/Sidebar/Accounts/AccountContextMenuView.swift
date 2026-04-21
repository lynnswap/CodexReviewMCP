import CodexReviewModel
import SwiftUI

struct AccountContextMenuView: View {
    let store: CodexReviewStore
    let account: CodexAccount

    private var auth: CodexReviewAuthModel {
        store.auth
    }

    private var isCurrentAccount: Bool {
        auth.account?.accountKey == account.accountKey
    }

    private var isPersistedActiveAccount: Bool {
        auth.savedAccounts.first(where: \.isActive)?.accountKey == account.accountKey
    }

    var sectionTitle: String {
        account.email
    }

    var destructiveActionTitle: String {
        "Sign Out"
    }

    var destructiveActionSystemImage: String {
        "rectangle.portrait.and.arrow.right"
    }

    func requestDestructiveAccountAction() {
        if isCurrentAccount {
            auth.requestSignOutActiveAccount(requiresConfirmation: store.hasRunningJobs)
        } else {
            auth.requestRemoveAccount(account, requiresConfirmation: false)
        }
    }

    var body: some View {
        Section(sectionTitle){
            Button("Switch", systemImage: "arrow.triangle.swap") {
                auth.requestSwitchAccount(account, requiresConfirmation: store.hasRunningJobs)
            }
            .disabled(isPersistedActiveAccount)
            
            Button("Refresh", systemImage: "arrow.clockwise") {
                refreshRateLimits()
            }
        }
        Section{
            AccountRateLimitsSectionView(account:account)
        }
        Section{
            Button(destructiveActionTitle, systemImage: destructiveActionSystemImage, role:.destructive) {
                requestDestructiveAccountAction()
            }
        }
    }

    private func refreshRateLimits() {
        Task {
            await auth.refreshSavedAccountRateLimits(accountKey: account.accountKey)
        }
    }
}

#if DEBUG
#Preview {
    let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
    let currentAccount = CodexAccount(email: "current@example.com")
    let otherAccount = CodexAccount(email: "other@example.com")
    store.auth.updateSavedAccounts([currentAccount, otherAccount])
    store.auth.updateAccount(currentAccount)
    return AccountContextMenuView(
        store: store,
        account: otherAccount
    )
}
#endif
