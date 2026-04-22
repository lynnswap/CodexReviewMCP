import ReviewApp
import SwiftUI
import ReviewDomain

struct AccountContextMenuView: View {
    let store: CodexReviewStore
    let account: CodexAccount

    private var auth: CodexReviewAuthModel {
        store.auth
    }

    private var isCurrentAccount: Bool {
        auth.account?.accountKey == account.accountKey
    }

    private var isSwitchActionDisabled: Bool {
        auth.switchActionIsDisabled(for: account)
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
            store.requestSignOutActiveAccount(requiresConfirmation: store.hasRunningJobs)
        } else {
            store.requestRemoveAccount(account, requiresConfirmation: false)
        }
    }

    var body: some View {
        Section(sectionTitle){
            Button("Switch", systemImage: "arrow.triangle.swap") {
                store.requestSwitchAccount(
                    account,
                    requiresConfirmation: store.hasRunningJobs
                        && auth.switchActionRequiresRunningJobsConfirmation(for: account)
                )
            }
            .disabled(isSwitchActionDisabled)
            
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
