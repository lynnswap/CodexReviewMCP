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

    var body: some View {
        Section(account.accountKey){
            Button("Switch", systemImage: "arrow.triangle.swap") {
                auth.requestSwitchAccount(account, requiresConfirmation: store.hasRunningJobs)
            }
            .disabled(isCurrentAccount)
            
            Button("Refresh", systemImage: "arrow.clockwise") {
                refreshRateLimits()
            }
        }
        Section{
            AccountRateLimitsSectionView(account:account)
        }
        Section{
            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role:.destructive) {
                auth.requestRemoveAccount(account, requiresConfirmation: false)
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
