import AppKit
import CodexReviewModel
import SwiftUI

@MainActor
final class ReviewMonitorAccountRowTableView: NSTableRowView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        selectionHighlightStyle = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

@MainActor
final class ReviewMonitorAccountCellView: NSTableCellView {
    private var hostingView: NSHostingView<ReviewMonitorAccountRowView>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(with account: CodexAccount) {
        objectValue = account
        toolTip = account.email
        if let hostingView {
            hostingView.rootView.account = account
        } else {
            let hostingView = NSHostingView(rootView: ReviewMonitorAccountRowView(account: account))
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.setAccessibilityIdentifier("review-monitor.account-row")
            addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: topAnchor),
                hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
                hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            self.hostingView = hostingView
        }
    }
}

struct ReviewMonitorAccountRowView: View {
    var account: CodexAccount?

    var body: some View {
        GroupBox {
            AccountRateLimitGaugesView(account: account)
                .padding(4)
        } label: {
            Text(account?.email ?? "")
        }
    }
}
