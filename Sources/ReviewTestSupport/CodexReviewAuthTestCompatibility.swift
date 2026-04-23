import ReviewApp
import ReviewDomain

@MainActor
extension CodexReviewAuthModel {
    public var account: CodexAccount? {
        selectedAccount
    }

    public func updateAccount(_ account: CodexAccount?) {
        guard let account else {
            updateSelectedAccount(nil)
            return
        }
        if let existingAccountID = savedAccounts.first(where: { $0.accountKey == account.accountKey })?.id {
            updateSelectedAccount(existingAccountID)
            return
        }
        updateDetachedSelectedAccount(account)
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
