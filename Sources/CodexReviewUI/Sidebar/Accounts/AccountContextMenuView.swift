import CodexReviewModel
import SwiftUI

struct AccountContextMenuView: View {
    let auth: CodexReviewAuthModel
    let account: CodexAccount
    let switchAction: @MainActor () -> Void

    private var isCurrentAccount: Bool {
        auth.account?.accountKey == account.accountKey
    }

    var body: some View {
        Button("Switch") {
            switchAction()
        }
        .disabled(isCurrentAccount)
    }
}

#if DEBUG
#Preview {
    let auth = CodexReviewAuthModel(controller: CodexReviewPreviewAuthController())
    let currentAccount = CodexAccount(email: "current@example.com")
    let otherAccount = CodexAccount(email: "other@example.com")
    auth.updateSavedAccounts([currentAccount, otherAccount])
    auth.updateAccount(currentAccount)
    return AccountContextMenuView(
        auth: auth,
        account: otherAccount,
        switchAction: {}
    )
}
#endif
