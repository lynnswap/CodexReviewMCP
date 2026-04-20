import AppKit
import CodexReviewModel

@MainActor
enum ReviewMonitorAddAccountAction {
    static func perform(store: CodexReviewStore) {
        Task {
            guard await confirmJobCancellationIfNeeded(
                store: store,
                title: "Add Account?",
                message: "If this sign-in becomes the active session, running review jobs may stop after the account change is applied."
            ) else {
                return
            }

            let auth = store.auth
            let previousFailureCount = auth.authenticationFailureCount
            let previousWarningMessage = auth.warningMessage
            await auth.beginAuthentication()
            if auth.authenticationFailureCount != previousFailureCount,
               let message = auth.errorMessage
            {
                await presentFailure(
                    title: "Failed to Add Account",
                    message: message
                )
            } else if let warningMessage = auth.warningMessage,
                      warningMessage != previousWarningMessage
            {
                await presentFailure(
                    title: "Account Updated With Warning",
                    message: warningMessage
                )
            }
        }
    }

    private static func confirmJobCancellationIfNeeded(
        store: CodexReviewStore,
        title: String,
        message: String
    ) async -> Bool {
        guard store.hasRunningJobs else {
            return true
        }

        return await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    private static func presentFailure(
        title: String,
        message: String
    ) async {
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
