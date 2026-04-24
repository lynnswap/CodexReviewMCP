import AppKit
import ObservationBridge
import ReviewApp
import ReviewDomain
import SwiftUI

@MainActor
final class ReviewMonitorAccountsViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private enum Identifier {
        static let tableColumn = NSUserInterfaceItemIdentifier("ReviewMonitorAccounts.Column")
        static let accountCell = NSUserInterfaceItemIdentifier("ReviewMonitorAccounts.AccountCell")
    }

    private enum DragType {
        static let account = NSPasteboard.PasteboardType("dev.codexreviewmcp.account")
    }

    private let store: CodexReviewStore
    private let scrollView = NSScrollView()
    private let outlineView = ReviewMonitorAccountsOutlineView()

    private var authObservationHandles: Set<ObservationHandle> = []
    private var isApplyingAuthSelection = false
    private var presentedPendingAccountAction: CodexReviewAuthModel.PendingAccountAction?
    private var presentedAccountActionAlert: CodexReviewAuthModel.AccountActionAlert?

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
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        presentAccountPromptsIfNeeded()
    }

    private var auth: CodexReviewAuthModel {
        store.auth
    }

    private var accounts: [CodexAccount] {
        auth.accounts
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
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.setAccessibilityIdentifier("review-monitor.account-list")
        outlineView.registerForDraggedTypes([DragType.account])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask([], forLocal: false)
        outlineView.draggingDestinationFeedbackStyle = .gap
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.contextMenuProvider = { [weak self] point in
            self?.makeContextMenu(at: point)
        }

        scrollView.documentView = outlineView
    }

    private func bindObservation() {
        authObservationHandles.removeAll()

        auth.observe([\.persistedAccounts]) { [weak self] in
            self?.reloadAccounts()
        }
        .store(in: &authObservationHandles)

        auth.observe([\.selectedAccount]) { [weak self] in
            self?.reconcileSelection()
        }
        .store(in: &authObservationHandles)

        auth.observe([\.pendingAccountAction, \.accountActionAlert]) { [weak self] in
            self?.presentAccountPromptsIfNeeded()
        }
        .store(in: &authObservationHandles)
    }

    private func reloadAccounts() {
        outlineView.reloadData()
        reconcileSelection()
    }

    private func reconcileSelection() {
        guard let selectedAccount = auth.selectedAccount,
              let row = row(forAccountKey: selectedAccount.accountKey)
        else {
            if outlineView.selectedRow != -1 {
                outlineView.deselectAll(nil)
            }
            return
        }

        guard outlineView.selectedRow != row else {
            return
        }
        selectAccountRow(row)
    }

    private func selectAccountRow(_ row: Int) {
        let wasApplyingAuthSelection = isApplyingAuthSelection
        isApplyingAuthSelection = true
        defer {
            isApplyingAuthSelection = wasApplyingAuthSelection
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func performReorder(accountKey: String, toIndex destinationIndex: Int) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                try await store.reorderPersistedAccount(accountKey: accountKey, toIndex: destinationIndex)
            } catch {
                store.auth.presentAccountActionAlert(
                    title: "Failed to Reorder Accounts",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func presentAccountPromptsIfNeeded() {
        presentPendingAccountActionIfNeeded()
        presentAccountActionAlertIfNeeded()
    }

    private func presentPendingAccountActionIfNeeded() {
        guard let action = auth.pendingAccountAction else {
            presentedPendingAccountAction = nil
            return
        }
        guard presentedPendingAccountAction != action,
              let window = view.window
        else {
            return
        }

        presentedPendingAccountAction = action

        let alert = NSAlert()
        alert.messageText = String(localized: action.confirmationTitle)
        alert.informativeText = String(localized: action.confirmationMessage)
        alert.addButton(withTitle: String(localized: action.confirmationButtonTitle))
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.presentedPendingAccountAction = nil
                guard self.auth.pendingAccountAction == action else {
                    self.reconcileSelection()
                    self.presentAccountPromptsIfNeeded()
                    return
                }
                if response == .alertFirstButtonReturn {
                    self.store.confirmPendingAccountAction()
                } else {
                    self.store.cancelPendingAccountAction()
                    self.reconcileSelection()
                }
                self.presentAccountPromptsIfNeeded()
            }
        }
    }

    private func presentAccountActionAlertIfNeeded() {
        guard let accountActionAlert = auth.accountActionAlert else {
            presentedAccountActionAlert = nil
            reconcileSelection()
            return
        }
        guard presentedAccountActionAlert != accountActionAlert,
              let window = view.window
        else {
            return
        }

        presentedAccountActionAlert = accountActionAlert
        reconcileSelection()

        let alert = NSAlert()
        alert.messageText = String(localized: accountActionAlert.title)
        alert.informativeText = accountActionAlert.message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.presentedAccountActionAlert = nil
                if self.auth.accountActionAlert == accountActionAlert {
                    self.store.dismissAccountActionAlert()
                }
                self.reconcileSelection()
                self.presentAccountPromptsIfNeeded()
            }
        }
    }

    private func makeContextMenu(at point: NSPoint) -> NSMenu? {
        let row = outlineView.row(at: point)
        guard row != -1,
              let account = account(atRow: row)
        else {
            return nil
        }

        return NSHostingMenu(
            rootView: AccountContextMenuView(
                store: store,
                account: account
            )
        )
    }

    private func account(from item: Any?) -> CodexAccount? {
        item as? CodexAccount
    }

    private func account(atRow row: Int) -> CodexAccount? {
        guard row >= 0,
              let item = outlineView.item(atRow: row)
        else {
            return nil
        }
        return account(from: item)
    }

    private func row(for account: CodexAccount) -> Int? {
        row(forAccountKey: account.accountKey)
    }

    private func row(forAccountKey accountKey: String) -> Int? {
        guard let account = accounts.first(where: { $0.accountKey == accountKey }) else {
            return nil
        }
        let row = outlineView.row(forItem: account)
        return row == -1 ? nil : row
    }

    private func persistedAccountIndex(accountKey: String) -> Int? {
        auth.persistedAccounts.firstIndex { $0.accountKey == accountKey }
    }

    private func dragAccountKey(from draggingInfo: any NSDraggingInfo) -> String? {
        draggingInfo.draggingPasteboard.string(forType: DragType.account)
    }

    private func resolvedDropIndex(
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> Int? {
        let persistedCount = auth.persistedAccounts.count
        guard persistedCount > 1 else {
            return nil
        }

        if let account = account(from: item) {
            guard let accountIndex = persistedAccountIndex(accountKey: account.accountKey) else {
                return nil
            }
            return accountIndex
        }

        guard item == nil else {
            return nil
        }

        let rawIndex = index == NSOutlineViewDropOnItemIndex ? persistedCount : index
        return max(0, min(rawIndex, persistedCount))
    }

    private func reorderDestinationIndex(accountKey: String, dropIndex: Int) -> Int? {
        let persistedCount = auth.persistedAccounts.count
        guard let sourceIndex = persistedAccountIndex(accountKey: accountKey),
              persistedCount > 1
        else {
            return nil
        }

        let clampedDropIndex = max(0, min(dropIndex, persistedCount))
        let adjustedDropIndex = clampedDropIndex > sourceIndex
            ? clampedDropIndex - 1
            : clampedDropIndex
        return max(0, min(adjustedDropIndex, persistedCount - 1))
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? accounts.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        accounts[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        isApplyingAuthSelection && account(from: item) != nil
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard account(from: item) != nil else {
            return nil
        }
        return ReviewMonitorAccountTableRowView()
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let account = account(from: item) else {
            return nil
        }

        let view = (outlineView.makeView(withIdentifier: Identifier.accountCell, owner: self) as? ReviewMonitorAccountCellView)
            ?? ReviewMonitorAccountCellView(store: store)
        view.identifier = Identifier.accountCell
        view.configure(account: account)
        return view
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        pasteboardWriterForItem item: Any
    ) -> (any NSPasteboardWriting)? {
        guard let account = account(from: item),
              auth.persistedAccounts.count > 1,
              persistedAccountIndex(accountKey: account.accountKey) != nil
        else {
            return nil
        }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(account.accountKey, forType: DragType.account)
        return pasteboardItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let accountKey = dragAccountKey(from: info),
              persistedAccountIndex(accountKey: accountKey) != nil,
              let dropIndex = resolvedDropIndex(proposedItem: item, proposedChildIndex: index)
        else {
            return []
        }

        outlineView.setDropItem(nil, dropChildIndex: dropIndex)
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: any NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let accountKey = dragAccountKey(from: info),
              persistedAccountIndex(accountKey: accountKey) != nil,
              let dropIndex = resolvedDropIndex(proposedItem: item, proposedChildIndex: index),
              let destinationIndex = reorderDestinationIndex(accountKey: accountKey, dropIndex: dropIndex)
        else {
            return false
        }

        performReorder(accountKey: accountKey, toIndex: destinationIndex)
        return true
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorAccountsViewController {
    var displayedAccountEmailsForTesting: [String] {
        (0..<outlineView.numberOfRows).compactMap { row in
            account(atRow: row)?.email
        }
    }

    var accountListUsesOutlineViewForTesting: Bool {
        scrollView.documentView === outlineView
    }

    func focusAccountListForTesting() {
        _ = view.window?.makeFirstResponder(outlineView)
    }

    var accountListHasFirstResponderForTesting: Bool {
        view.window?.firstResponder === outlineView
    }

    var selectedAccountEmailForTesting: String? {
        guard outlineView.selectedRow != -1 else {
            return nil
        }
        return account(atRow: outlineView.selectedRow)?.email
    }

    func selectAccountRowForTesting(_ account: CodexAccount) {
        guard let row = row(for: account) else {
            preconditionFailure("Account row is not visible.")
        }
        selectAccountRow(row)
    }

    var isPresentingContextMenuForTesting: Bool {
        outlineView.isPresentingContextMenuForTesting
    }

    var acceptsFirstResponderForTesting: Bool {
        outlineView.acceptsFirstResponderForTesting
    }

    var hasTemporaryContextMenuForTesting: Bool {
        outlineView.menu != nil
    }

    func presentContextMenuForTesting(
        for account: CodexAccount,
        presenter: @escaping (NSMenu) -> Void
    ) {
        view.layoutSubtreeIfNeeded()
        guard let row = row(for: account) else {
            preconditionFailure("Account row is not visible.")
        }
        let rect = outlineView.rect(ofRow: row)
        let point = NSPoint(x: rect.midX, y: rect.midY)
        outlineView.presentContextMenuForTesting(at: point, presenter: presenter)
    }

    func accountRowUsesReviewMonitorAccountCellViewForTesting(_ account: CodexAccount) -> Bool {
        guard let row = row(for: account),
              outlineView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: true
              ) is ReviewMonitorAccountCellView
        else {
            return false
        }
        return true
    }

    func accountRowUsesSwiftUIRowViewForTesting(_ account: CodexAccount) -> Bool {
        guard let row = row(for: account),
              let cellView = outlineView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: true
              ) as? ReviewMonitorAccountCellView
        else {
            return false
        }
        return cellView.isHostingReviewMonitorAccountRowViewForTesting
    }

    func allowsUserSelectionForTesting(_ account: CodexAccount) -> Bool {
        guard let row = row(for: account) else {
            preconditionFailure("Account row is not visible.")
        }
        return outlineView(
            outlineView,
            shouldSelectItem: outlineView.item(atRow: row) as Any
        )
    }

    @discardableResult
    func performAccountDropForTesting(
        _ account: CodexAccount,
        proposedChildIndex index: Int
    ) async -> Bool {
        guard let dropIndex = resolvedDropIndex(proposedItem: nil, proposedChildIndex: index),
              let destinationIndex = reorderDestinationIndex(accountKey: account.accountKey, dropIndex: dropIndex)
        else {
            return false
        }

        do {
            try await store.reorderPersistedAccount(
                accountKey: account.accountKey,
                toIndex: destinationIndex
            )
            return true
        } catch {
            return false
        }
    }
}
#endif

@MainActor
private final class ReviewMonitorAccountsOutlineView: NSOutlineView {
    var contextMenuProvider: ((NSPoint) -> NSMenu?)?
    private var isPresentingContextMenu = false
    private weak var contextMenuFirstResponder: NSResponder?
    private var previousContextMenu: NSMenu?

    override var acceptsFirstResponder: Bool {
        isPresentingContextMenu ? false : super.acceptsFirstResponder
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let contextMenu = contextMenuProvider?(point) else {
            super.rightMouseDown(with: event)
            return
        }

        beginContextMenuPresentation(with: contextMenu)
        super.rightMouseDown(with: event)

        if isPresentingContextMenu {
            endContextMenuPresentation()
        }
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        guard isPresentingContextMenu else {
            return
        }
        endContextMenuPresentation()
    }

    private func isAccountListFirstResponder(_ responder: NSResponder) -> Bool {
        if responder === self {
            return true
        }
        guard let view = responder as? NSView else {
            return false
        }
        return view === self || view.isDescendant(of: self)
    }

    private func restoreFirstResponder(_ responder: NSResponder?) {
        guard let window else {
            return
        }
        if let view = responder as? NSView, view.window === window {
            _ = window.makeFirstResponder(view)
            return
        }
        _ = window.makeFirstResponder(self)
    }

    private func beginContextMenuPresentation(with contextMenu: NSMenu) {
        previousContextMenu = menu
        menu = contextMenu
        isPresentingContextMenu = true

        guard let window else {
            contextMenuFirstResponder = nil
            return
        }

        let previousFirstResponder = window.firstResponder
        guard previousFirstResponder.map(isAccountListFirstResponder(_:)) ?? false else {
            contextMenuFirstResponder = nil
            return
        }

        contextMenuFirstResponder = previousFirstResponder
        _ = window.makeFirstResponder(nil)
    }

    private func endContextMenuPresentation() {
        let previousFirstResponder = contextMenuFirstResponder
        let previousContextMenu = previousContextMenu

        contextMenuFirstResponder = nil
        self.previousContextMenu = nil
        isPresentingContextMenu = false
        menu = previousContextMenu

        guard let previousFirstResponder else {
            return
        }
        restoreFirstResponder(previousFirstResponder)
    }

#if DEBUG
    func presentContextMenuForTesting(
        at point: NSPoint,
        presenter: @escaping (NSMenu) -> Void
    ) {
        guard window != nil else {
            fatalError("Accounts outline view must be attached to a window for context menu testing.")
        }
        guard let contextMenu = contextMenuProvider?(point) else {
            return
        }
        beginContextMenuPresentation(with: contextMenu)
        presenter(contextMenu)
        if isPresentingContextMenu {
            endContextMenuPresentation()
        }
    }

    var isPresentingContextMenuForTesting: Bool {
        isPresentingContextMenu
    }

    var acceptsFirstResponderForTesting: Bool {
        acceptsFirstResponder
    }
#endif
}

@MainActor
private final class ReviewMonitorAccountTableRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set { }
    }
}

@MainActor
private final class ReviewMonitorAccountCellView: NSTableCellView {
    private let hostingView: NSHostingView<ReviewMonitorAccountRowView>

    init(store: CodexReviewStore) {
        hostingView = NSHostingView(rootView: ReviewMonitorAccountRowView(store: store))
        super.init(frame: .zero)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(account: CodexAccount) {
        objectValue = account
        toolTip = account.email
        hostingView.rootView.account = account
    }

    private func configureHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.setAccessibilityIdentifier("review-monitor.account-row")
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    #if DEBUG
    var isHostingReviewMonitorAccountRowViewForTesting: Bool {
        hostingView.rootView.account != nil
    }
    #endif
}
