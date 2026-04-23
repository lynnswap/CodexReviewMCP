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

        var updatedSavedAccounts = savedAccounts.map(savedAccountPayload(from:))
        updatedSavedAccounts.append(savedAccountPayload(from: account))
        applySavedAccountStates(updatedSavedAccounts)
        updateSelectedAccount(
            savedAccounts.first(where: { $0.accountKey == account.accountKey })?.id
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
