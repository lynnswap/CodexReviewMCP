import AppKit
import CodexReviewModel
import ObservationBridge
import ReviewJobs
import ReviewRuntime
import SwiftUI

@MainActor
final class ReviewMonitorSidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private enum Identifier {
        static let tableColumn = NSUserInterfaceItemIdentifier("ReviewMonitorJobs.Column")
        static let jobCell = NSUserInterfaceItemIdentifier("ReviewMonitorJobs.JobCell")
        static let workspaceCell = NSUserInterfaceItemIdentifier("ReviewMonitorJobs.WorkspaceCell")
    }

    private enum SidebarItem: Hashable {
        case workspace(CodexReviewWorkspace)
        case job(CodexReviewJob)

        var workspace: CodexReviewWorkspace? {
            guard case let .workspace(workspace) = self else {
                return nil
            }
            return workspace
        }

        var job: CodexReviewJob? {
            guard case let .job(job) = self else {
                return nil
            }
            return job
        }
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
    private var rootItems: [SidebarItem] = []
    private var childItemsByWorkspace: [String: [SidebarItem]] = [:]
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
        outlineView.floatsGroupRows = false
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
            workspace.observe(\.jobs) { [weak self, weak store] _ in
                guard let self, let store else {
                    return
                }
                self.reloadJobs(for: workspace, allWorkspaces: store.workspaces)
            }
            .store(in: &workspaceObservationHandles)
        }
    }

    private func reloadOutline(workspaces: [CodexReviewWorkspace]) {
        clearSelectionIfNeeded(for: workspaces)
        rebuildItems(from: workspaces)

        isReconcilingSelection = true
        outlineView.reloadData()
        expandAllWorkspaceItems()
        reconcileSelectionAfterReload()
        isReconcilingSelection = false
        updateOutlineViewFrame()
        updateEmptyState(itemCount: totalJobCount(in: workspaces))
    }

    private func rebuildItems(from workspaces: [CodexReviewWorkspace]) {
        rootItems = workspaces.map(SidebarItem.workspace)
        childItemsByWorkspace = workspaces.reduce(into: [:]) { partialResult, workspace in
            partialResult[workspace.cwd] = workspace.jobs.map(SidebarItem.job)
        }
    }

    private func expandAllWorkspaceItems() {
        for item in rootItems {
            outlineView.expandItem(item)
        }
    }

    private func reloadJobs(
        for workspace: CodexReviewWorkspace,
        allWorkspaces: [CodexReviewWorkspace]
    ) {
        clearSelectionIfNeeded(for: allWorkspaces)
        guard allWorkspaces.contains(workspace),
              let workspaceItem = workspaceItem(for: workspace)
        else {
            reloadOutline(workspaces: allWorkspaces)
            return
        }

        childItemsByWorkspace[workspace.cwd] = workspace.jobs.map(SidebarItem.job)

        isReconcilingSelection = true
        outlineView.reloadItem(workspaceItem, reloadChildren: true)
        outlineView.expandItem(workspaceItem)
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

        guard containsJob(id: selectedJob.id) else {
            uiState.selectedJobEntry = nil
            outlineView.deselectAll(nil)
            return
        }

        guard let row = row(forJobID: selectedJob.id) else {
            return
        }

        if let currentJob = job(atRow: row), currentJob !== selectedJob {
            uiState.selectedJobEntry = currentJob
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
        job.terminalError = CodexReviewTerminalError(source: .cancelled, message: message)
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

    private func sidebarItem(from item: Any?) -> SidebarItem? {
        item as? SidebarItem
    }

    private func childItems(for workspace: CodexReviewWorkspace) -> [SidebarItem] {
        childItemsByWorkspace[workspace.cwd] ?? []
    }

    private func workspaceItem(for workspace: CodexReviewWorkspace) -> SidebarItem? {
        rootItems.first { $0.workspace == workspace }
    }

    private func shouldAllowSelection(of item: SidebarItem) -> Bool {
        item.job != nil
    }

    private func job(atRow row: Int) -> CodexReviewJob? {
        guard row >= 0,
              let item = outlineView.item(atRow: row)
        else {
            return nil
        }
        return sidebarItem(from: item)?.job
    }

    private func isWorkspaceRow(_ row: Int) -> Bool {
        guard row >= 0,
              let item = outlineView.item(atRow: row)
        else {
            return false
        }
        return sidebarItem(from: item)?.workspace != nil
    }

    private func row(for workspace: CodexReviewWorkspace) -> Int? {
        guard outlineView.numberOfRows > 0 else {
            return nil
        }
        for row in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: row),
                  sidebarItem(from: item)?.workspace == workspace
            else {
                continue
            }
            return row
        }
        return nil
    }

    private func row(forJobID jobID: String) -> Int? {
        guard outlineView.numberOfRows > 0 else {
            return nil
        }
        for row in 0..<outlineView.numberOfRows {
            if job(atRow: row)?.id == jobID {
                return row
            }
        }
        return nil
    }

    private func containsJob(id: String) -> Bool {
        guard let store else {
            return false
        }
        return containsJob(id: id, in: store.workspaces)
    }

    private func containsJob(id: String, in workspaces: [CodexReviewWorkspace]) -> Bool {
        for workspace in workspaces {
            if workspace.jobs.contains(where: { $0.id == id }) {
                return true
            }
        }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = sidebarItem(from: item) else {
            return rootItems.count
        }
        guard let workspace = item.workspace else {
            return 0
        }
        return childItems(for: workspace).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = sidebarItem(from: item) else {
            return rootItems[index]
        }
        guard let workspace = item.workspace else {
            preconditionFailure("Jobs do not have child items.")
        }
        return childItems(for: workspace)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = sidebarItem(from: item),
              let workspace = item.workspace
        else {
            return false
        }
        return childItems(for: workspace).isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        sidebarItem(from: item)?.workspace != nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = sidebarItem(from: item) else {
            return false
        }
        return shouldAllowSelection(of: item)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        _ = notification
        updateSelectedJobFromOutlineView()
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let item = sidebarItem(from: item) else {
            return 0
        }
        return item.workspace != nil ? 28 : 46
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        _ = tableColumn
        guard let item = sidebarItem(from: item) else {
            return nil
        }

        switch item {
        case let .workspace(workspace):
            let view = (outlineView.makeView(withIdentifier: Identifier.workspaceCell, owner: self) as? ReviewMonitorWorkspaceCellView)
                ?? ReviewMonitorWorkspaceCellView()
            view.identifier = Identifier.workspaceCell
            view.configure(title: workspace.displayTitle, toolTip: workspace.cwd)
            return view

        case let .job(job):
            let view = (outlineView.makeView(withIdentifier: Identifier.jobCell, owner: self) as? ReviewMonitorJobCellView)
                ?? ReviewMonitorJobCellView()
            view.identifier = Identifier.jobCell
            view.configure(with: job) { [weak self] in
                self?.triggerCancellation(for: job)
            }
            return view
        }
    }

}

#if DEBUG
@MainActor
extension ReviewMonitorSidebarViewController {
    var displayedSectionTitlesForTesting: [String] {
        rootItems.compactMap(\.workspace?.displayTitle)
    }

    var selectedJobForTesting: CodexReviewJob? {
        job(atRow: outlineView.selectedRow)
    }

    var isShowingEmptyStateForTesting: Bool {
        emptyStateView.isHidden == false
    }

    func selectJobForTesting(_ job: CodexReviewJob) {
        guard let row = row(forJobID: job.id) else {
            return
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        uiState.selectedJobEntry = job
    }

    func clearSelectionForTesting() {
        outlineView.deselectAll(nil)
        uiState.selectedJobEntry = nil
    }

    var allWorkspaceRowsExpandedForTesting: Bool {
        rootItems.allSatisfy { outlineView.isItemExpanded($0) }
    }

    func workspaceIsSelectableForTesting(_ workspace: CodexReviewWorkspace) -> Bool {
        shouldAllowSelection(of: .workspace(workspace))
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

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard shouldSuppressSelectionClearing(at: point) == false else {
            return
        }
        super.mouseDown(with: event)
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

#if DEBUG
    func suppressesSelectionClearingForTesting(at point: NSPoint) -> Bool {
        shouldSuppressSelectionClearing(at: point)
    }
#endif
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

    func configure(with job: CodexReviewJob, onCancel: @escaping () -> Void) {
        objectValue = job
        toolTip = job.cwd
        if let hostingView {
            hostingView.rootView = ReviewMonitorJobRowView(
                job: job,
                onCancel: onCancel
            )
        } else {
            let hostingView = NSHostingView(
                rootView: ReviewMonitorJobRowView(
                    job: job,
                    onCancel: onCancel
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

    func configure(title: String, toolTip: String) {
        titleLabel.stringValue = title
        self.toolTip = toolTip
    }

    private func configureHierarchy() {
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
