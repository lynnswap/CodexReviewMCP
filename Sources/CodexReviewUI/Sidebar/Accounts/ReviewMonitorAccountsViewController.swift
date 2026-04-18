import AppKit
import CodexReviewModel
import ObservationBridge
import SwiftUI

@MainActor
final class ReviewMonitorAccountsViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private enum Identifier {
        static let tableColumn = NSUserInterfaceItemIdentifier("ReviewMonitorAccounts.Column")
        static let accountCell = NSUserInterfaceItemIdentifier("ReviewMonitorAccounts.AccountCell")
    }

    private let store: CodexReviewStore
    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private var observationHandles: Set<ObservationHandle> = []
    private var isReconcilingSelection = false

    private var accounts: [CodexAccount] {
        store.auth.savedAccounts
    }

    private var activeAccountKey: UUID? {
        store.auth.account?.accountKey
    }

    init(store: CodexReviewStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        configureOutlineView()
        bindObservation()
        reloadAccounts()
    }

    private func configureHierarchy() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureOutlineView() {
        let tableColumn = NSTableColumn(identifier: Identifier.tableColumn)
        tableColumn.resizingMask = .autoresizingMask

        outlineView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        outlineView.autoresizingMask = [.width]
        outlineView.addTableColumn(tableColumn)
        outlineView.outlineTableColumn = tableColumn
        outlineView.headerView = nil
        outlineView.indentationPerLevel = 0
        outlineView.indentationMarkerFollowsCell = false
        outlineView.rowSizeStyle = .custom
        outlineView.usesAutomaticRowHeights = true
        outlineView.style = .sourceList
        outlineView.backgroundColor = .clear
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.intercellSpacing = NSSize(width: 0, height: 12)
        outlineView.allowsEmptySelection = false
        outlineView.allowsMultipleSelection = false
        outlineView.setAccessibilityIdentifier("review-monitor.account-list")
        outlineView.dataSource = self
        outlineView.delegate = self

        scrollView.documentView = outlineView
    }

    private func bindObservation() {
        observationHandles.removeAll()
        store.auth.observe(\.account) { [weak self] _ in
            guard let self else {
                return
            }
            self.reconcileSelection()
        }
        .store(in: &observationHandles)
        store.auth.observe(\.savedAccounts) { [weak self] _ in
            guard let self else {
                return
            }
            self.reloadAccounts()
        }
        .store(in: &observationHandles)
    }

    private func reloadAccounts() {
        outlineView.reloadData()
        reconcileSelection()
    }

    private func reconcileSelection() {
        isReconcilingSelection = true
        defer {
            isReconcilingSelection = false
        }
        outlineView.selectRowIndexes(selectionIndexSet(), byExtendingSelection: false)
    }

    private func selectionIndexSet() -> IndexSet {
        guard let activeAccountKey,
              let index = accounts.firstIndex(where: { $0.accountKey == activeAccountKey })
        else {
            return []
        }
        return IndexSet(integer: index)
    }

    func outlineView(
        _: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        item == nil ? accounts.count : 0
    }

    func outlineView(
        _: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        precondition(item == nil, "Account list rows do not have children.")
        return accounts[index]
    }

    func outlineView(
        _: NSOutlineView,
        isItemExpandable _: Any
    ) -> Bool {
        false
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet
    ) -> IndexSet {
        guard isReconcilingSelection == false else {
            return proposedSelectionIndexes
        }
        guard let row = proposedSelectionIndexes.first,
              let account = outlineView.item(atRow: row) as? CodexAccount
        else {
            return selectionIndexSet()
        }
        if account.accountKey != activeAccountKey {
            requestSwitchAccount(accountKey: account.accountKey)
        }
        return selectionIndexSet()
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor _: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let account = item as? CodexAccount else {
            return nil
        }

        let cell = outlineView.makeView(
            withIdentifier: Identifier.accountCell,
            owner: self
        ) as? ReviewMonitorAccountCellView ?? ReviewMonitorAccountCellView()
        cell.identifier = Identifier.accountCell
        cell.configure(with: account)
        return cell
    }

    func outlineView(
        _: NSOutlineView,
        rowViewForItem item: Any
    ) -> NSTableRowView? {
        guard item is CodexAccount else {
            return nil
        }
        return ReviewMonitorAccountRowTableView()
    }

    private func requestSwitchAccount(accountKey: UUID) {
        if store.hasRunningJobs, confirmSwitchAccount() == false {
            return
        }
        switchAccount(accountKey: accountKey)
    }

    private func switchAccount(accountKey: UUID) {
        Task { @MainActor in
            do {
                try await store.auth.switchAccount(accountKey: accountKey)
                if let warningMessage = store.auth.warningMessage {
                    presentAccountActionMessage(
                        title: "Account Updated With Warning",
                        message: warningMessage
                    )
                }
            } catch {
                let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                presentAccountActionMessage(
                    title: "Failed to Switch Account",
                    message: description.isEmpty ? "Request failed." : description
                )
            }
        }
    }

    private func confirmSwitchAccount() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Switch Account?"
        alert.informativeText = "Running review jobs may stop after the account change is applied."
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentAccountActionMessage(
        title: String,
        message: String
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

@MainActor
private final class ReviewMonitorAccountRowTableView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

@MainActor
private final class ReviewMonitorAccountCellView: NSTableCellView {
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

private struct ReviewMonitorAccountRowView: View {
    var account: CodexAccount?

    var body: some View {
        GroupBox{
            AccountRateLimitGaugesView(account: account)
                .padding(4)
        } label: {
            Text(account?.email ?? "")
        }
    }
}

#if DEBUG
#Preview {
    ReviewMonitorAccountsViewController(
        store: makeReviewMonitorAccountsPreviewStore()
    )
}

@MainActor
private func makeReviewMonitorAccountsPreviewStore() -> CodexReviewStore {
    ReviewMonitorPreviewContent.makeStore()
}
#endif
