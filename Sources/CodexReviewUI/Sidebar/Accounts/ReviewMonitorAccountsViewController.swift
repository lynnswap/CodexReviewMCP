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

    private enum DragType {
        static let account = NSPasteboard.PasteboardType("dev.codexreviewmcp.account-item")
    }

    private struct AccountResolvedDrop {
        enum Operation {
            case none
            case reorderAccount(accountKey: String, toIndex: Int)
        }

        let operation: Operation
        let dropItem: Any?
        let dropChildIndex: Int
    }

    private let store: CodexReviewStore
    private let scrollView = NSScrollView()
    private let outlineView = ReviewMonitorAccountsOutlineView()
    private var observationHandles: Set<ObservationHandle> = []
    private var isReconcilingSelection = false
    private var isDraggingAccountReorder = false
    private var isApplyingAccountReorder = false

    private var accounts: [CodexAccount] {
        store.auth.savedAccounts
    }

    private var suppressesSelectionDrivenAccountSwitch: Bool {
        isDraggingAccountReorder || isApplyingAccountReorder
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
        outlineView.registerForDraggedTypes([DragType.account])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask([], forLocal: false)
        outlineView.draggingDestinationFeedbackStyle = .gap
        outlineView.contextMenuProvider = { [weak self] point in
            self?.makeContextMenu(at: point)
        }
        outlineView.primarySelectionHandler = { [weak self] row in
            self?.handlePrimarySelection(at: row)
        }
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
            self.scheduleSelectionReconciliation()
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

    private func scheduleSelectionReconciliation() {
        Task { @MainActor [weak self] in
            self?.reconcileSelection()
        }
    }

    private func reconcileSelection() {
        let targetSelection = selectionIndexSet()
        guard outlineView.selectedRowIndexes != targetSelection else {
            return
        }
        isReconcilingSelection = true
        defer {
            isReconcilingSelection = false
        }
        if targetSelection.isEmpty {
            let previousAllowsEmptySelection = outlineView.allowsEmptySelection
            outlineView.allowsEmptySelection = true
            outlineView.deselectAll(nil)
            outlineView.allowsEmptySelection = previousAllowsEmptySelection
        } else {
            outlineView.selectRowIndexes(targetSelection, byExtendingSelection: false)
        }
    }

    private func selectionIndexSet() -> IndexSet {
        guard let activeAccountKey = store.auth.account?.accountKey,
              let index = accounts.firstIndex(where: { $0.accountKey == activeAccountKey })
        else {
            return []
        }
        return IndexSet(integer: index)
    }

    private func dragAccountKey(for item: Any) -> String? {
        (item as? CodexAccount)?.accountKey
    }

    private func makePasteboardItem(for accountKey: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(accountKey, forType: DragType.account)
        return item
    }

    private func dragAccountKey(from draggingInfo: any NSDraggingInfo) -> String? {
        guard let draggingSource = draggingInfo.draggingSource as? NSOutlineView,
              draggingSource === outlineView,
              let accountKeyString = draggingInfo.draggingPasteboard.string(forType: DragType.account)
        else {
            return nil
        }
        return accountKeyString
    }

    private func clearDropTarget() {
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
    }

    private func resolvedDrop(
        for accountKey: String,
        draggingInfo: (any NSDraggingInfo)? = nil,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> AccountResolvedDrop? {
        guard let sourceIndex = accounts.firstIndex(where: { $0.accountKey == accountKey }),
              let insertionIndex = resolvedAccountInsertionIndex(
                draggingInfo: draggingInfo,
                proposedItem: proposedItem,
                proposedChildIndex: index
              )
        else {
            return nil
        }

        let destinationIndex = insertionIndex > sourceIndex
            ? insertionIndex - 1
            : insertionIndex
        let clampedDestinationIndex = max(0, min(destinationIndex, accounts.count - 1))
        let operation: AccountResolvedDrop.Operation = clampedDestinationIndex == sourceIndex
            ? .none
            : .reorderAccount(accountKey: accountKey, toIndex: clampedDestinationIndex)
        return AccountResolvedDrop(
            operation: operation,
            dropItem: nil,
            dropChildIndex: insertionIndex
        )
    }

    private func resolvedAccountInsertionIndex(
        draggingInfo: (any NSDraggingInfo)?,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> Int? {
        resolvedAccountInsertionIndex(
            draggingLocation: draggingInfo.map { outlineView.convert($0.draggingLocation, from: nil) },
            proposedItem: proposedItem,
            proposedChildIndex: index
        )
    }

    private func resolvedAccountInsertionIndex(
        draggingLocation: NSPoint?,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> Int? {
        if proposedItem == nil,
           index != NSOutlineViewDropOnItemIndex
        {
            return max(0, min(index, accounts.count))
        }

        if let blankAreaInsertionIndex = blankAreaAccountInsertionIndex(draggingLocation: draggingLocation) {
            return blankAreaInsertionIndex
        }

        guard let targetAccount = proposedItem as? CodexAccount,
              let targetIndex = accounts.firstIndex(where: { $0.accountKey == targetAccount.accountKey })
        else {
            return nil
        }

        guard let draggingLocation,
              let targetRow = row(for: targetAccount)
        else {
            return targetIndex
        }

        let rowRect = outlineView.rect(ofRow: targetRow)
        let insertionIndex = draggingLocation.y < rowRect.midY
            ? targetIndex
            : targetIndex + 1
        return max(0, min(insertionIndex, accounts.count))
    }

    private func blankAreaAccountInsertionIndex(
        draggingLocation: NSPoint?
    ) -> Int? {
        guard let draggingLocation,
              outlineView.numberOfRows > 0
        else {
            return nil
        }

        let firstRowRect = outlineView.rect(ofRow: 0)
        if draggingLocation.y < firstRowRect.minY {
            return 0
        }

        let lastRowRect = outlineView.rect(ofRow: outlineView.numberOfRows - 1)
        if draggingLocation.y > lastRowRect.maxY {
            return accounts.count
        }

        return nil
    }

    private func row(for account: CodexAccount) -> Int? {
        let row = outlineView.row(forItem: account)
        return row == -1 ? nil : row
    }

    @discardableResult
    private func applyResolvedDrop(_ resolvedDrop: AccountResolvedDrop) -> Bool {
        switch resolvedDrop.operation {
        case .none:
            return true
        case .reorderAccount(let accountKey, let toIndex):
            isApplyingAccountReorder = true
            Task { @MainActor [weak self] in
                await self?.reorderAccount(accountKey: accountKey, toIndex: toIndex)
            }
            return true
        }
    }

    @discardableResult
    private func reorderAccount(
        accountKey: String,
        toIndex: Int
    ) async -> Bool {
        isApplyingAccountReorder = true
        defer {
            isApplyingAccountReorder = false
            reconcileSelection()
        }
        do {
            try await store.auth.reorderSavedAccount(accountKey: accountKey, toIndex: toIndex)
            outlineView.reloadData()
            reconcileSelection()
            return true
        } catch {
            let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            presentAccountActionMessage(
                title: "Failed to Reorder Accounts",
                message: description.isEmpty ? "Request failed." : description
            )
            return false
        }
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
        if suppressesSelectionDrivenAccountSwitch {
            return outlineView.selectedRowIndexes
        }
        return proposedSelectionIndexes
    }

    func outlineViewSelectionDidChange(_: Notification) {
        handleSelectionChange(
            eventType: NSApp.currentEvent?.type,
            selectedAccount: currentSelectedAccount()
        )
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

    func outlineView(
        _ outlineView: NSOutlineView,
        pasteboardWriterForItem item: Any
    ) -> (any NSPasteboardWriting)? {
        guard let accountKey = dragAccountKey(for: item) else {
            return nil
        }
        return makePasteboardItem(for: accountKey)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let accountKey = dragAccountKey(from: info),
              let resolvedDrop = resolvedDrop(
                for: accountKey,
                draggingInfo: info,
                proposedItem: item,
                proposedChildIndex: index
              )
        else {
            clearDropTarget()
            return []
        }

        outlineView.setDropItem(resolvedDrop.dropItem, dropChildIndex: resolvedDrop.dropChildIndex)
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: any NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        defer {
            clearDropTarget()
        }
        guard let accountKey = dragAccountKey(from: info),
              let resolvedDrop = resolvedDrop(
                for: accountKey,
                draggingInfo: info,
                proposedItem: item,
                proposedChildIndex: index
              )
        else {
            return false
        }
        return applyResolvedDrop(resolvedDrop)
    }

    func outlineView(
        _: NSOutlineView,
        draggingSession _: NSDraggingSession,
        willBeginAt _: NSPoint,
        forItems _: [Any]
    ) {
        isDraggingAccountReorder = true
        outlineView.noteDraggingSessionWillBegin()
    }

    func outlineView(
        _: NSOutlineView,
        draggingSession _: NSDraggingSession,
        endedAt _: NSPoint,
        operation _: NSDragOperation
    ) {
        isDraggingAccountReorder = false
        scheduleSelectionReconciliation()
    }

    private func requestSwitchAccount(_ account: CodexAccount) {
        if store.hasRunningJobs, confirmSwitchAccount() == false {
            return
        }
        switchAccount(account)
    }

    private func handlePrimarySelection(at row: Int) {
        guard row != -1,
              let account = outlineView.item(atRow: row) as? CodexAccount,
              account.accountKey != store.auth.account?.accountKey
        else {
            return
        }
        requestSwitchAccount(account)
    }

    private func currentSelectedAccount() -> CodexAccount? {
        guard outlineView.selectedRow != -1 else {
            return nil
        }
        return outlineView.item(atRow: outlineView.selectedRow) as? CodexAccount
    }

    private func handleSelectionChange(
        eventType: NSEvent.EventType?,
        selectedAccount: CodexAccount?
    ) {
        guard isReconcilingSelection == false else {
            return
        }
        guard suppressesSelectionDrivenAccountSwitch == false else {
            scheduleSelectionReconciliation()
            return
        }
        guard outlineView.isPresentingContextMenuSelection == false else {
            scheduleSelectionReconciliation()
            return
        }
        guard shouldSwitchAccountOnSelectionChange(for: eventType),
              let selectedAccount,
              selectedAccount.accountKey != store.auth.account?.accountKey
        else {
            scheduleSelectionReconciliation()
            return
        }
        requestSwitchAccount(selectedAccount)
        scheduleSelectionReconciliation()
    }

    private func shouldSwitchAccountOnSelectionChange(
        for eventType: NSEvent.EventType?
    ) -> Bool {
        switch eventType {
        case .keyDown:
            true
        default:
            false
        }
    }

    private func makeContextMenu(at point: NSPoint) -> NSMenu? {
        let row = outlineView.row(at: point)
        guard row != -1,
              let account = outlineView.item(atRow: row) as? CodexAccount
        else {
            return nil
        }

        return NSHostingMenu(
            rootView: AccountContextMenuView(
                auth: store.auth,
                account: account,
                switchAction: { [weak self] in
                    self?.requestSwitchAccount(account)
                }
            )
        )
    }

    private func switchAccount(_ account: CodexAccount) {
        Task { @MainActor in
            do {
                try await store.auth.switchAccount(accountKey: account.accountKey)
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
private final class ReviewMonitorAccountsOutlineView: NSOutlineView {
    var contextMenuProvider: ((NSPoint) -> NSMenu?)?
    var primarySelectionHandler: ((Int) -> Void)?
    private var isPresentingContextMenu = false
    private weak var contextMenuFirstResponder: NSResponder?
    private var previousContextMenu: NSMenu?
    private var didBeginDraggingSession = false

    override var acceptsFirstResponder: Bool {
        isPresentingContextMenu ? false : super.acceptsFirstResponder
    }

    var isPresentingContextMenuSelection: Bool {
        isPresentingContextMenu
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard shouldSuppressSelectionClearing(at: point) == false else {
            return
        }
        didBeginDraggingSession = false
        let preservedSelection = preservedSelectedItem()
        super.mouseDown(with: event)
        if didBeginDraggingSession {
            restoreSelectionIfNeeded(preservedSelection)
            return
        }
        let selectedRowAfterClick = selectedRow
        restoreSelectionIfNeeded(preservedSelection)
        primarySelectionHandler?(selectedRowAfterClick)
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return contextMenuProvider?(point) ?? super.menu(for: event)
    }

    func noteDraggingSessionWillBegin() {
        didBeginDraggingSession = true
    }

    private func shouldSuppressSelectionClearing(at point: NSPoint) -> Bool {
        guard selectedRow != -1 else {
            return false
        }
        return row(at: point) == -1
    }

    private func preservedSelectedItem() -> Any? {
        guard selectedRow != -1 else {
            return nil
        }
        return item(atRow: selectedRow)
    }

    private func restoreSelectionIfNeeded(_ preservedSelection: Any?) {
        guard let preservedSelection else {
            return
        }
        let restoredRow = row(forItem: preservedSelection)
        guard restoredRow != -1,
              selectedRow != restoredRow
        else {
            return
        }
        selectRowIndexes(IndexSet(integer: restoredRow), byExtendingSelection: false)
    }

    private func isOutlineFirstResponder(_ responder: NSResponder) -> Bool {
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
        guard previousFirstResponder.map(isOutlineFirstResponder(_:)) ?? false else {
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
}

#if DEBUG
@MainActor
extension ReviewMonitorAccountsViewController {
    var displayedAccountEmailsForTesting: [String] {
        accounts.map(\.email)
    }

    var selectedAccountEmailForTesting: String? {
        guard outlineView.selectedRow != -1,
              let account = outlineView.item(atRow: outlineView.selectedRow) as? CodexAccount
        else {
            return nil
        }
        return account.email
    }

    func performSwitchMenuActionForTesting(_ account: CodexAccount) {
        requestSwitchAccount(account)
    }

    func performSelectionChangeForTesting(
        selecting account: CodexAccount,
        eventType: NSEvent.EventType?
    ) {
        handleSelectionChange(eventType: eventType, selectedAccount: account)
    }

    @discardableResult
    func performAccountDropForTesting(
        _ account: CodexAccount,
        toIndex index: Int
    ) async -> Bool {
        guard let resolvedDrop = resolvedDrop(
            for: account.accountKey,
            proposedItem: nil,
            proposedChildIndex: index
        ) else {
            return false
        }
        switch resolvedDrop.operation {
        case .none:
            return true
        case .reorderAccount(let accountKey, let toIndex):
            return await reorderAccount(accountKey: accountKey, toIndex: toIndex)
        }
    }
}

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
