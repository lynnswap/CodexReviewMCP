import ReviewApp
import ReviewDomain

@MainActor
extension CodexReviewAuthModel {
    public var account: CodexAccount? {
        selectedAccount
    }

    public func updateAccount(_ account: CodexAccount?) {
        updateSelectedAccount(
            account.flatMap { account in
                savedAccounts.first(where: { $0.accountKey == account.accountKey })?.id
            }
        )
    }

    public func updateSavedAccounts(_ accounts: [CodexAccount]) {
        applySavedAccountStates(accounts.map(savedAccountPayload(from:)))
    }
}

extension CodexAccount {
    public var isActive: Bool {
        false
    }

    public func updateIsActive(_: Bool) {}
}
