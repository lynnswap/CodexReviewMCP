import ReviewApp
import ReviewDomain

@MainActor
extension CodexReviewAuthModel {
    public var account: CodexAccount? {
        selectedAccount
    }

    public func updateAccount(_ account: CodexAccount?) {
        guard let account else {
            selectPersistedAccount(nil)
            return
        }
        if let existingAccountID = persistedAccounts.first(where: { $0.accountKey == account.accountKey })?.id {
            selectPersistedAccount(existingAccountID)
            return
        }
        updateCurrentAccount(account)
    }

    public func updatePersistedAccounts(_ accounts: [CodexAccount]) {
        applyPersistedAccountStates(accounts.map(savedAccountPayload(from:)))
    }
}

extension CodexAccount {
    public var isActive: Bool {
        false
    }

    public func updateIsActive(_: Bool) {}
}
