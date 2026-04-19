import CodexReviewModel
import SwiftUI

struct ReviewMonitorAccountRowView: View {
    var account: CodexAccount

    var body: some View {
        AccountRateLimitGaugesView(
            account: account
        )
        .overlay {
            if account.isSwitching {
                ProgressView()
                    .accessibilityIdentifier("review-monitor.account-row-switching")
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: account.isSwitching)
    }

    #if DEBUG
    var displayedEmailForTesting: String {
        account.maskedEmail
    }

    var isSwitchingForTesting: Bool {
        account.isSwitching
    }
    #endif
}
