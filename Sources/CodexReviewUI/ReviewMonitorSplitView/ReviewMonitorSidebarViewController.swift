import AppKit
import CodexReviewModel
import ObservationBridge
import ReviewRuntime
import SwiftUI

@MainActor
final class ReviewMonitorSidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private enum Identifier {
        static let tableColumn = NSUserInterfaceItemIdentifier("ReviewMonitorJobs.Column")
        static let jobCell = NSUserInterfaceItemIdentifier("ReviewMonitorJobs.JobCell")
        static let workspaceCell = NSUserInterfaceItemIdentifier("ReviewMonitorJobs.WorkspaceCell")
    }

    private weak var store: CodexReviewStore?
    private let uiState: ReviewMonitorUIState
    private let scrollView = NSScrollView()
    private let outlineView = ReviewMonitorSidebarOutlineView()
    private let emptyStateView = ReviewMonitorViewFactory.makeEmptyStateView(
        title: "No review jobs",
        description: "Start a review through the embedded server to see workspaces here."
    )

    private var storeObservationHandles: Set<ObservationHandle> = []
    private var workspaceObservationHandles: Set<ObservationHandle> = []
    private var isReconcilingSelection = false

    init(uiState: ReviewMonitorUIState) {
        self.uiState = uiState
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
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateOutlineViewFrame()
    }

    func bind(store: CodexReviewStore) {
        self.store = store
        bindObservation(store: store)
        reloadOutline(workspaces: store.workspaces)
    }

    private func configureHierarchy() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        view.addSubview(scrollView)
        view.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
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
        outlineView.rowSizeStyle = .default
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = true
        outlineView.backgroundColor = .clear
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.setAccessibilityIdentifier("review-monitor.job-list")
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.inertRowEvaluator = { [weak self] row in
            self?.isWorkspaceRow(row) ?? false
        }
        outlineView.contextMenuProvider = { [weak self] point in
            self?.makeContextMenu(at: point)
        }

        scrollView.documentView = outlineView
    }

    private func bindObservation(store: CodexReviewStore) {
        storeObservationHandles.removeAll()
        rebindWorkspaceObservations(workspaces: store.workspaces)
        store.observe([\.workspaces]) { [weak self, weak store] in
            guard let self, let store else {
                return
            }
            self.rebindWorkspaceObservations(workspaces: store.workspaces)
            self.reloadOutline(workspaces: store.workspaces)
        }
        .store(in: &storeObservationHandles)
    }

    private func rebindWorkspaceObservations(workspaces: [CodexReviewWorkspace]) {
        workspaceObservationHandles.removeAll()

        for workspace in workspaces {
            workspace.observe([\.jobs, \.isExpanded]) { [weak self, weak store, weak workspace] in
                guard let self, let store else {
                    return
                }
                guard let workspace else {
                    self.reloadOutline(workspaces: store.workspaces)
                    return
                }
                self.reloadWorkspace(workspace, allWorkspaces: store.workspaces)
            }
            .store(in: &workspaceObservationHandles)
        }
    }

    private func reloadOutline(workspaces: [CodexReviewWorkspace]) {
        clearSelectionIfNeeded(for: workspaces)

        isReconcilingSelection = true
        outlineView.reloadData()
        applyWorkspaceExpansionState(for: workspaces)
        reconcileSelectionAfterReload()
        isReconcilingSelection = false
        updateOutlineViewFrame()
        updateEmptyState(itemCount: totalJobCount(in: workspaces))
    }

    private func applyWorkspaceExpansionState(for workspaces: [CodexReviewWorkspace]) {
        for workspace in workspaces {
            if workspace.isExpanded {
                outlineView.expandItem(workspace)
            } else {
                outlineView.collapseItem(workspace)
            }
        }
    }

    private func reloadWorkspace(
        _ workspace: CodexReviewWorkspace,
        allWorkspaces: [CodexReviewWorkspace]
    ) {
        clearSelectionIfNeeded(for: allWorkspaces)
        guard let workspace = allWorkspaces.first(where: { $0 === workspace })
        else {
            reloadOutline(workspaces: allWorkspaces)
            return
        }

        isReconcilingSelection = true
        outlineView.reloadItem(workspace, reloadChildren: true)
        applyWorkspaceExpansionState(for: [workspace])
        reconcileSelectionAfterReload()
        isReconcilingSelection = false
        updateOutlineViewFrame()
        updateEmptyState(itemCount: totalJobCount(in: allWorkspaces))
    }

    private func reconcileSelectionAfterReload() {
        guard let selectedJob = uiState.selectedJobEntry else {
            if outlineView.selectedRow != -1 {
                outlineView.deselectAll(nil)
            }
            return
        }

        guard let currentJob = job(withID: selectedJob.id) else {
            uiState.selectedJobEntry = nil
            outlineView.deselectAll(nil)
            return
        }

        if currentJob !== selectedJob {
            uiState.selectedJobEntry = currentJob
        }

        guard let row = row(forJobID: currentJob.id) else {
            return
        }

        guard outlineView.selectedRow != row else {
            return
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func updateSelectedJobFromOutlineView() {
        guard isReconcilingSelection == false else {
            return
        }
        guard outlineView.selectedRow != -1 else {
            if let selectedJob = uiState.selectedJobEntry,
               containsJob(id: selectedJob.id)
            {
                return
            }
            uiState.selectedJobEntry = nil
            return
        }
        uiState.selectedJobEntry = job(atRow: outlineView.selectedRow)
    }

    private func triggerCancellation(for job: CodexReviewJob) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await performCancellation(for: job)
        }
    }

    private func makeContextMenu(at point: NSPoint) -> NSMenu? {
        let row = outlineView.row(at: point)
        guard row != -1,
              let job = job(atRow: row)
        else {
            return nil
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let cancelItem = NSMenuItem(
            title: "Cancel",
            action: #selector(handleCancelMenuItem(_:)),
            keyEquivalent: ""
        )
        cancelItem.target = self
        cancelItem.representedObject = job
        cancelItem.isEnabled = job.isTerminal == false && job.cancellationRequested == false
        menu.addItem(cancelItem)
        return menu
    }

    @objc
    private func handleCancelMenuItem(_ sender: NSMenuItem) {
        guard let job = sender.representedObject as? CodexReviewJob else {
            return
        }
        triggerCancellation(for: job)
    }

    private func requestCancellation(for job: CodexReviewJob) async throws {
        guard job.isTerminal == false,
              job.cancellationRequested == false,
              let store
        else {
            return
        }
        try await store.cancelReview(
            jobID: job.id,
            sessionID: job.sessionID
        )
    }

    private func performCancellation(for job: CodexReviewJob) async {
        do {
            try await requestCancellation(for: job)
        } catch {
            handleCancellationFailure(error, for: job)
        }
    }

    private func handleCancellationFailure(_ error: Error, for job: CodexReviewJob) {
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = description.isEmpty ? "Failed to cancel review." : description
        if let store {
            do {
                try store.recordCancellationFailure(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    message: message
                )
            } catch {
                applyCancellationFailure(message: message, to: job)
            }
        } else {
            applyCancellationFailure(message: message, to: job)
        }

        guard view.window != nil else {
            return
        }

        let presentedError: any Error
        if description.isEmpty {
            presentedError = NSError(
                domain: "CodexReviewUI.ReviewMonitorSidebarViewController",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        } else {
            presentedError = error
        }
        _ = presentError(presentedError)
    }

    private func applyCancellationFailure(message: String, to job: CodexReviewJob) {
        if message == "Failed to cancel review." {
            job.summary = message
        } else {
            job.summary = "Failed to cancel review: \(message)"
        }
        job.errorMessage = message
    }

    private func updateEmptyState(itemCount: Int) {
        let hasJobs = itemCount > 0
        scrollView.isHidden = hasJobs == false
        emptyStateView.isHidden = hasJobs
    }

    private func clearSelectionIfNeeded(for workspaces: [CodexReviewWorkspace]) {
        guard let selectedJob = uiState.selectedJobEntry,
              containsJob(id: selectedJob.id, in: workspaces) == false
        else {
            return
        }
        uiState.selectedJobEntry = nil
        if outlineView.selectedRow != -1 {
            outlineView.deselectAll(nil)
        }
    }

    private func totalJobCount(in workspaces: [CodexReviewWorkspace]) -> Int {
        workspaces.reduce(into: 0) { $0 += $1.jobs.count }
    }

    private func updateOutlineViewFrame() {
        let contentSize = scrollView.contentSize
        let width = max(1, contentSize.width)
        let height = max(contentSize.height, outlineContentHeight)
        let size = NSSize(width: width, height: height)
        guard outlineView.frame.size != size else {
            return
        }
        outlineView.setFrameSize(size)
    }

    private var outlineContentHeight: CGFloat {
        guard outlineView.numberOfRows > 0 else {
            return 0
        }
        return outlineView.rect(ofRow: outlineView.numberOfRows - 1).maxY
    }

    private func workspace(from item: Any?) -> CodexReviewWorkspace? {
        item as? CodexReviewWorkspace
    }

    private func job(from item: Any?) -> CodexReviewJob? {
        item as? CodexReviewJob
    }

    private func shouldAllowSelection(of item: Any?) -> Bool {
        job(from: item) != nil
    }

    private func workspaces() -> [CodexReviewWorkspace] {
        store?.workspaces ?? []
    }

    private func job(atRow row: Int) -> CodexReviewJob? {
        guard row >= 0,
              let item = outlineView.item(atRow: row)
        else {
            return nil
        }
        return job(from: item)
    }

    private func isWorkspaceRow(_ row: Int) -> Bool {
        guard row >= 0,
              let item = outlineView.item(atRow: row)
        else {
            return false
        }
        return workspace(from: item) != nil
    }

    private func row(for workspace: CodexReviewWorkspace) -> Int? {
        let row = outlineView.row(forItem: workspace)
        return row == -1 ? nil : row
    }

    private func row(forJobID jobID: String) -> Int? {
        guard let job = job(withID: jobID) else {
            return nil
        }
        let row = outlineView.row(forItem: job)
        return row == -1 ? nil : row
    }

    private func containsJob(id: String) -> Bool {
        job(withID: id) != nil
    }

    private func containsJob(id: String, in workspaces: [CodexReviewWorkspace]) -> Bool {
        job(withID: id, in: workspaces) != nil
    }

    private func job(withID id: String) -> CodexReviewJob? {
        job(withID: id, in: workspaces())
    }

    private func job(withID id: String, in workspaces: [CodexReviewWorkspace]) -> CodexReviewJob? {
        for workspace in workspaces {
            if let job = workspace.jobs.first(where: { $0.id == id }) {
                return job
            }
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let workspace = workspace(from: item) else {
            return workspaces().count
        }
        return workspace.jobs.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let workspace = workspace(from: item) else {
            return workspaces()[index]
        }
        return workspace.jobs[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let workspace = workspace(from: item) else {
            return false
        }
        return workspace.jobs.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        workspace(from: item) != nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        self.outlineView(outlineView, isItemExpandable: item)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        shouldAllowSelection(of: item)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        _ = notification
        updateSelectedJobFromOutlineView()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let workspace = workspace(from: notification.userInfo?["NSObject"]) else {
            return
        }
        workspace.isExpanded = true

        guard let selectedJob = uiState.selectedJobEntry,
              selectedJob.cwd == workspace.cwd,
              let row = row(forJobID: selectedJob.id)
        else {
            return
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let workspace = workspace(from: notification.userInfo?["NSObject"]) else {
            return
        }
        workspace.isExpanded = false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        if workspace(from: item) != nil {
            return ReviewMonitorWorkspaceRowView()
        }
        if job(from: item) != nil {
            return ReviewMonitorJobTableRowView()
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if workspace(from: item) != nil {
            return 28
        }
        if job(from: item) != nil {
            return 46
        }
        return 0
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        _ = tableColumn
        if let workspace = workspace(from: item) {
            let view = (outlineView.makeView(withIdentifier: Identifier.workspaceCell, owner: self) as? ReviewMonitorWorkspaceCellView)
                ?? ReviewMonitorWorkspaceCellView()
            view.identifier = Identifier.workspaceCell
            view.configure(workspace)
            return view
        }

        if let job = job(from: item) {
            let view = (outlineView.makeView(withIdentifier: Identifier.jobCell, owner: self) as? ReviewMonitorJobCellView)
                ?? ReviewMonitorJobCellView()
            view.identifier = Identifier.jobCell
            view.configure(with: job) 
            return view
        }
        return nil
    }

}

#if DEBUG
@MainActor
extension ReviewMonitorSidebarViewController {
    var displayedSectionTitlesForTesting: [String] {
        workspaces().map(\.displayTitle)
    }

    var selectedJobForTesting: CodexReviewJob? {
        uiState.selectedJobEntry
    }

    var isShowingEmptyStateForTesting: Bool {
        emptyStateView.isHidden == false
    }

    func selectJobForTesting(_ job: CodexReviewJob) {
        guard let row = row(forJobID: job.id) else {
            return
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func clearSelectionForTesting() {
        uiState.selectedJobEntry = nil
        outlineView.deselectAll(nil)
    }

    var allWorkspaceRowsExpandedForTesting: Bool {
        workspaces().allSatisfy { $0.isExpanded && outlineView.isItemExpanded($0) }
    }

    func workspaceIsSelectableForTesting(_ workspace: CodexReviewWorkspace) -> Bool {
        shouldAllowSelection(of: workspace)
    }

    var floatsGroupRowsEnabledForTesting: Bool {
        outlineView.floatsGroupRows
    }

    func jobRowUsesReviewMonitorJobRowViewForTesting(_ job: CodexReviewJob) -> Bool {
        guard let row = row(forJobID: job.id),
              let cellView = outlineView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: true
              ) as? ReviewMonitorJobCellView
        else {
            return false
        }
        return cellView.isHostingReviewMonitorJobRowViewForTesting
    }

    func cancelJobForTesting(_ job: CodexReviewJob) async {
        await performCancellation(for: job)
    }

    func clickBlankAreaForTesting() {
        view.layoutSubtreeIfNeeded()
        let point = blankPointForTesting()
        precondition(
            outlineView.suppressesSelectionClearingForTesting(at: point),
            "Expected a blank click target outside any job item."
        )
        outlineView.mouseDown(with: mouseEventForTesting(at: point))
    }

    func clickWorkspaceHeaderForTesting(_ workspace: CodexReviewWorkspace) {
        view.layoutSubtreeIfNeeded()
        guard let row = row(for: workspace) else {
            preconditionFailure("Workspace row is not visible.")
        }
        let rect = outlineView.rect(ofRow: row)
        let point = NSPoint(x: rect.midX, y: rect.midY)
        precondition(
            outlineView.suppressesSelectionClearingForTesting(at: point),
            "Expected workspace header clicks to preserve selection."
        )
        outlineView.mouseDown(with: mouseEventForTesting(at: point))
    }

    func toggleWorkspaceDisclosureForTesting(_ workspace: CodexReviewWorkspace) {
        guard row(for: workspace) != nil else {
            preconditionFailure("Workspace row is not visible.")
        }
        workspace.isExpanded.toggle()
    }

    func workspaceIsExpandedForTesting(_ workspace: CodexReviewWorkspace) -> Bool {
        workspace.isExpanded
    }

    func workspaceRowIsFloatingForTesting(_ workspace: CodexReviewWorkspace) -> Bool {
        guard let row = row(for: workspace),
              let rowView = outlineView.rowView(atRow: row, makeIfNecessary: true)
        else {
            return false
        }
        return rowView.isFloating
    }

    func scrollSidebarToOffsetForTesting(_ yOffset: CGFloat) {
        let clampedOffset = max(0, yOffset)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedOffset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        view.layoutSubtreeIfNeeded()
    }

    private func blankPointForTesting() -> NSPoint {
        let blankY: CGFloat
        if outlineView.numberOfRows > 0 {
            blankY = outlineView.rect(ofRow: outlineView.numberOfRows - 1).maxY + 10
        } else {
            blankY = outlineView.bounds.midY
        }
        let x = min(outlineView.bounds.maxX - 1, max(1, outlineView.bounds.midX))
        let y = min(outlineView.bounds.maxY - 1, max(1, blankY))
        return NSPoint(x: x, y: y)
    }

    private func mouseEventForTesting(at point: NSPoint) -> NSEvent {
        guard let window = view.window else {
            fatalError("Sidebar view controller must be attached to a window for click testing.")
        }
        let locationInWindow = outlineView.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            fatalError("Failed to create a synthetic mouse event.")
        }
        return event
    }
}
#endif

@MainActor
private final class ReviewMonitorSidebarOutlineView: NSOutlineView {
    var inertRowEvaluator: ((Int) -> Bool)?
    var contextMenuProvider: ((NSPoint) -> NSMenu?)?
    private var isPresentingContextMenu = false

    override var acceptsFirstResponder: Bool {
        isPresentingContextMenu ? false : super.acceptsFirstResponder
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard shouldSuppressSelectionClearing(at: point) == false else {
            return
        }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let contextMenu = contextMenuProvider?(point) else {
            super.rightMouseDown(with: event)
            return
        }

        let previousFirstResponder = window?.firstResponder
        let shouldRestoreFirstResponder = previousFirstResponder.map(isSidebarFirstResponder(_:)) ?? false
        if shouldRestoreFirstResponder {
            isPresentingContextMenu = true
            _ = window?.makeFirstResponder(nil)
        }
        let previousMenu = menu
        menu = contextMenu
        defer {
            menu = previousMenu
            if shouldRestoreFirstResponder {
                restoreFirstResponder(previousFirstResponder)
            }
            isPresentingContextMenu = false
        }
        super.rightMouseDown(with: event)
    }

    private func shouldSuppressSelectionClearing(at point: NSPoint) -> Bool {
        guard selectedRow != -1 else {
            return false
        }
        let clickedRow = row(at: point)
        if clickedRow == -1 {
            return true
        }
        return inertRowEvaluator?(clickedRow) ?? false
    }

    private func isSidebarFirstResponder(_ responder: NSResponder) -> Bool {
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

#if DEBUG
    func suppressesSelectionClearingForTesting(at point: NSPoint) -> Bool {
        shouldSuppressSelectionClearing(at: point)
    }

#endif
}

@MainActor
private final class ReviewMonitorWorkspaceRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set { }
    }
}

@MainActor
private final class ReviewMonitorJobTableRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set { }
    }
}

@MainActor
private final class ReviewMonitorJobCellView: NSTableCellView {
    private var hostingView: NSHostingView<ReviewMonitorJobRowView>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(with job: CodexReviewJob) {
        objectValue = job
        toolTip = job.cwd
        if let hostingView {
            hostingView.rootView = ReviewMonitorJobRowView(
                job: job
            )
        } else {
            let hostingView = NSHostingView(
                rootView: ReviewMonitorJobRowView(
                    job: job
                )
            )
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.setAccessibilityIdentifier("review-monitor.job-row")
            addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: topAnchor),
                hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
                hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            self.hostingView = hostingView
        }
    }

    private func configureHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false
    }

    #if DEBUG
    var isHostingReviewMonitorJobRowViewForTesting: Bool {
        hostingView != nil
    }
    #endif
}

@MainActor
private final class ReviewMonitorWorkspaceCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(_ workspace: CodexReviewWorkspace) {
        objectValue = workspace
        titleLabel.stringValue = workspace.displayTitle
        toolTip = workspace.cwd
    }

    private func configureHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }
}
