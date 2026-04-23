import ReviewApp
import SwiftUI
import ReviewDomain

struct AccountContextMenuView: View {
    let store: CodexReviewStore
    let account: CodexAccount

    private var auth: CodexReviewAuthModel {
        store.auth
    }

    private func requestDestructiveAccountAction() {
        if auth.account?.accountKey == account.accountKey {
            store.requestSignOutActiveAccount(requiresConfirmation: store.hasRunningJobs)
        } else {
            store.requestRemoveAccount(account, requiresConfirmation: false)
        }
    }

    var body: some View {
        Section(account.email){
            Button("Switch", systemImage: "arrow.triangle.swap") {
                store.requestSwitchAccount(
                    account,
                    requiresConfirmation: store.hasRunningJobs
                        && store.switchActionRequiresRunningJobsConfirmation(for: account)
                )
            }
            .disabled(store.switchActionIsDisabled(for: account))
            
            Button("Refresh", systemImage: "arrow.clockwise") {
                refreshRateLimits()
            }
        }
        Section{
            AccountRateLimitsSectionView(account:account)
        }
        Section{
            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role:.destructive) {
                requestDestructiveAccountAction()
            }
        }
    }

    private func refreshRateLimits() {
        Task {
            await store.refreshSavedAccountRateLimits(accountKey: account.accountKey)
        }
    }
}

#if DEBUG
#Preview {
    let currentAccount = CodexAccount(email: "current@example.com")
    let otherAccount = CodexAccount(email: "other@example.com")
    let store: CodexReviewStore = {
        let store = CodexReviewStore.makePreviewStore()
        store.auth.updateSavedAccounts([currentAccount, otherAccount])
        store.auth.updateAccount(currentAccount)
        return store
    }()
    AccountContextMenuView(
        store: store,
        account: otherAccount
    )
}
#endif
