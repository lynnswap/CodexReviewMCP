import AppKit
import CodexReviewModel
import SwiftUI

func maskedReviewAccountEmail(_ email: String) -> String {
    let parts = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2,
          parts[0].isEmpty == false,
          parts[1].isEmpty == false
    else {
        return maskedReviewAccountEmailSegment(email)
    }
    return "\(maskedReviewAccountEmailSegment(String(parts[0])))@\(parts[1])"
}

private func maskedReviewAccountEmailSegment(_ segment: String) -> String {
    let characters = Array(segment)
    switch characters.count {
    case 0:
        return segment
    case 1 ... 2:
        return String(characters.prefix(1)) + "…"
    case 3 ... 4:
        return String(characters.prefix(1)) + "…" + String(characters.suffix(1))
    default:
        return String(characters.prefix(2)) + "…" + String(characters.suffix(2))
    }
}

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

    #if DEBUG
    var renderedContentHeightForTesting: CGFloat {
        hostingView?.fittingSize.height ?? 0
    }

    var displayedEmailForTesting: String {
        hostingView?.rootView.displayedEmailForTesting ?? ""
    }

    var isSwitchingForTesting: Bool {
        hostingView?.rootView.isSwitchingForTesting ?? false
    }
    #endif
}

struct ReviewMonitorAccountRowView: View {
    var account: CodexAccount?

    private var fullEmail: String {
        account?.email ?? ""
    }

    private var displayedEmail: String {
        maskedReviewAccountEmail(fullEmail)
    }

    var body: some View {
        GroupBox {
            AccountRateLimitGaugesView(account: account)
                .padding(4)
        } label: {
            ReviewMonitorAccountEmailLabelView(
                displayedEmail: displayedEmail,
                fullEmail: fullEmail
            )
        }
        .overlay {
            if let account{
                ZStack{
                    if account.isSwitching {
                        ProgressView()
                            .accessibilityIdentifier("review-monitor.account-row-switching")
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: account.isSwitching)
            }
        }
    }

    #if DEBUG
    var displayedEmailForTesting: String {
        displayedEmail
    }

    var isSwitchingForTesting: Bool {
        account?.isSwitching == true
    }
    #endif
}

private struct ReviewMonitorAccountEmailLabelView: View {
    let displayedEmail: String
    let fullEmail: String

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: displayedEmail)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: fullEmail))
    }
}
