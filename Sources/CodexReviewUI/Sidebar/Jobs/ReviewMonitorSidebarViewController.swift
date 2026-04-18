import AppKit
import CodexReviewModel
import ObservationBridge
import ReviewRuntime
import SwiftUI

@MainActor
final class ReviewMonitorSidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    enum PresentationForTesting: Equatable {
        case unavailable
        case empty
        case jobList
        case accountList
    }

    private enum Identifier {
        static let tableColumn = NSUserInterfaceItemIdentifier("ReviewMonitorJobs.Column")
        static let jobCell = NSUserInterfaceItemIdentifier("ReviewMonitorJobs.JobCell")
        static let workspaceCell = NSUserInterfaceItemIdentifier("ReviewMonitorJobs.WorkspaceCell")
    }

    private enum DragType {
        static let sidebarItem = NSPasteboard.PasteboardType("dev.codexreviewmcp.sidebar-item")
    }

    private enum SidebarDragPayload: Codable, Equatable {
        case workspace(cwd: String)
        case job(id: String, cwd: String)
    }

    private struct SidebarResolvedDrop {
        enum Operation {
            case none
            case reorderWorkspace(cwd: String, toIndex: Int)
            case reorderJob(id: String, cwd: String, toIndex: Int)
        }

        let operation: Operation
        let dropItem: Any?
        let dropChildIndex: Int
    }

    private let store: CodexReviewStore
    private let uiState: ReviewMonitorUIState
    private let scrollView = NSScrollView()
    private let outlineView = ReviewMonitorSidebarOutlineView()
    private let accountsViewController: ReviewMonitorAccountsViewController
    private let emptyStateView = ReviewMonitorViewFactory.makeEmptyStateView(
        title: "No review jobs",
        description: "Start a review through the embedded server to see workspaces here.",
        titleAccessibilityIdentifier: "review-monitor.sidebar-empty.title",
        descriptionAccessibilityIdentifier: "review-monitor.sidebar-empty.description"
    )
    private let unavailableView: NSHostingView<MCPServerUnavailableView>

    private var storeObservationHandles: Set<ObservationHandle> = []
    private var workspaceObservationHandles: Set<ObservationHandle> = []
    private var isReconcilingSelection = false

    init(store: CodexReviewStore, uiState: ReviewMonitorUIState) {
        self.store = store
        self.uiState = uiState
        self.accountsViewController = ReviewMonitorAccountsViewController(store: store)
        self.unavailableView = NSHostingView(rootView: MCPServerUnavailableView(store: store))
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
        reloadOutline(workspaces: store.workspaces)
        updatePresentation()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
    }

    private func configureHierarchy() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        view.addSubview(scrollView)
        view.addSubview(emptyStateView)
        addChild(accountsViewController)
        accountsViewController.view.translatesAutoresizingMaskIntoConstraints = false
        accountsViewController.view.isHidden = true
        view.addSubview(accountsViewController.view)
        unavailableView.translatesAutoresizingMaskIntoConstraints = false
        unavailableView.isHidden = true
        view.addSubview(unavailableView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),

            accountsViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            accountsViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            accountsViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            accountsViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            unavailableView.topAnchor.constraint(equalTo: view.topAnchor),
            unavailableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            unavailableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            unavailableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
        outlineView.floatsGroupRows = true
        outlineView.backgroundColor = .clear
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.intercellSpacing = NSSize(width: 0, height: 12)
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.setAccessibilityIdentifier("review-monitor.job-list")
        outlineView.registerForDraggedTypes([DragType.sidebarItem])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask([], forLocal: false)
        outlineView.draggingDestinationFeedbackStyle = .gap
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.inertRowEvaluator = { [weak self] row in
            self?.isWorkspaceRow(row) ?? false
        }
        outlineView.contextMenuProvider = { [weak self] point in
            self?.makeContextMenu(at: point)
        }
        outlineView.draggingExitedHandler = { [weak self] in
            self?.clearDropTarget()
        }

        scrollView.documentView = outlineView
    }

    private func bindObservation() {
        storeObservationHandles.removeAll()
        rebindWorkspaceObservations(workspaces: store.workspaces)
        store.observe(\.serverState) { [weak self] _ in
            guard let self else {
                return
            }
            self.updatePresentation()
        }
        .store(in: &storeObservationHandles)
        uiState.observe(\.sidebarSelection) { [weak self] _ in
            guard let self else {
                return
            }
            self.updatePresentation()
        }
        .store(in: &storeObservationHandles)
        store.observe([\.workspaces]) { [weak self] in
            guard let self else {
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
            workspace.observe([\.jobs, \.isExpanded]) { [weak self, weak workspace] in
                guard let self else {
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
        updatePresentation()
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
        updatePresentation()
    }

    private func updatePresentation() {
        switch presentationForCurrentState {
        case .unavailable:
            unavailableView.isHidden = false
            scrollView.isHidden = true
            emptyStateView.isHidden = true
            accountsViewController.view.isHidden = true
        case .empty:
            unavailableView.isHidden = true
            scrollView.isHidden = true
            emptyStateView.isHidden = false
            accountsViewController.view.isHidden = true
        case .jobList:
            unavailableView.isHidden = true
            scrollView.isHidden = false
            emptyStateView.isHidden = true
            accountsViewController.view.isHidden = true
        case .accountList:
            unavailableView.isHidden = true
            scrollView.isHidden = true
            emptyStateView.isHidden = true
            accountsViewController.view.isHidden = false
        }
    }

    private var presentationForCurrentState: PresentationForTesting {
        if uiState.sidebarSelection == .account {
            return .accountList
        }
        if case .failed = store.serverState {
            return .unavailable
        }
        return totalJobCount(in: store.workspaces) > 0 ? .jobList : .empty
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
              job.cancellationRequested == false
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
        do {
            try store.recordCancellationFailure(
                jobID: job.id,
                sessionID: job.sessionID,
                message: message
            )
        } catch {
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
        store.workspaces
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

    private func workspaceIndex(cwd: String) -> Int? {
        workspaces().firstIndex(where: { $0.cwd == cwd })
    }

    private func workspace(containing job: CodexReviewJob) -> CodexReviewWorkspace? {
        workspaces().first(where: { workspace in
            workspace.jobs.contains(where: { $0.id == job.id })
        })
    }

    private func dragPayload(for item: Any) -> SidebarDragPayload? {
        if let workspace = workspace(from: item) {
            return .workspace(cwd: workspace.cwd)
        }
        if let job = job(from: item) {
            return .job(id: job.id, cwd: job.cwd)
        }
        return nil
    }

    private func makePasteboardItem(for payload: SidebarDragPayload) -> NSPasteboardItem? {
        guard let data = try? JSONEncoder().encode(payload) else {
            return nil
        }
        let item = NSPasteboardItem()
        item.setData(data, forType: DragType.sidebarItem)
        return item
    }

    private func dragPayload(from draggingInfo: any NSDraggingInfo) -> SidebarDragPayload? {
        guard let draggingSource = draggingInfo.draggingSource as? NSOutlineView,
              draggingSource === outlineView,
              let data = draggingInfo.draggingPasteboard.data(forType: DragType.sidebarItem)
        else {
            return nil
        }
        return try? JSONDecoder().decode(SidebarDragPayload.self, from: data)
    }

    private func clearDropTarget() {
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
    }

    private func resolvedDrop(
        for payload: SidebarDragPayload,
        draggingInfo: (any NSDraggingInfo)? = nil,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> SidebarResolvedDrop? {
        switch payload {
        case .workspace(let cwd):
            resolvedWorkspaceDrop(
                cwd: cwd,
                draggingInfo: draggingInfo,
                proposedItem: proposedItem,
                proposedChildIndex: index
            )
        case .job(let id, let cwd):
            resolvedJobDrop(
                id: id,
                cwd: cwd,
                proposedItem: proposedItem,
                proposedChildIndex: index
            )
        }
    }

    private func resolvedWorkspaceDrop(
        cwd: String,
        draggingInfo: (any NSDraggingInfo)?,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> SidebarResolvedDrop? {
        guard let sourceIndex = workspaceIndex(cwd: cwd),
              let insertionIndex = resolvedWorkspaceInsertionIndex(
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
        let clampedDestinationIndex = max(0, min(destinationIndex, workspaces().count - 1))
        let operation: SidebarResolvedDrop.Operation = clampedDestinationIndex == sourceIndex
            ? .none
            : .reorderWorkspace(cwd: cwd, toIndex: clampedDestinationIndex)
        return SidebarResolvedDrop(
            operation: operation,
            dropItem: nil,
            dropChildIndex: insertionIndex
        )
    }

    private func resolvedWorkspaceInsertionIndex(
        draggingInfo: (any NSDraggingInfo)?,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> Int? {
        resolvedWorkspaceInsertionIndex(
            draggingLocation: draggingInfo.map { outlineView.convert($0.draggingLocation, from: nil) },
            proposedItem: proposedItem,
            proposedChildIndex: index
        )
    }

    private func resolvedWorkspaceInsertionIndex(
        draggingLocation: NSPoint?,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> Int? {
        if proposedItem == nil,
           index != NSOutlineViewDropOnItemIndex
        {
            return max(0, min(index, workspaces().count))
        }

        if let blankAreaInsertionIndex = blankAreaWorkspaceInsertionIndex(draggingLocation: draggingLocation) {
            return blankAreaInsertionIndex
        }

        guard let targetWorkspace = workspace(from: proposedItem),
              let workspaceIndex = workspaceIndex(cwd: targetWorkspace.cwd)
        else {
            return nil
        }

        return workspaceInsertionIndex(
            aroundWorkspace: targetWorkspace,
            defaultIndex: workspaceIndex,
            draggingLocation: draggingLocation
        )
    }

    private func blankAreaWorkspaceInsertionIndex(
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
            return workspaces().count
        }

        return nil
    }

    private func workspaceInsertionIndex(
        aroundWorkspace workspace: CodexReviewWorkspace,
        defaultIndex: Int,
        draggingLocation: NSPoint?
    ) -> Int {
        guard let draggingLocation,
              let sectionRect = workspaceSectionRect(for: workspace)
        else {
            return max(0, min(defaultIndex, workspaces().count))
        }

        let insertionIndex = draggingLocation.y < sectionRect.midY
            ? (workspaceIndex(cwd: workspace.cwd) ?? defaultIndex)
            : workspaceIndex(cwd: workspace.cwd).map { $0 + 1 } ?? defaultIndex
        return max(0, min(insertionIndex, workspaces().count))
    }

    private func workspaceSectionRect(for workspace: CodexReviewWorkspace) -> NSRect? {
        guard let workspaceRow = row(for: workspace) else {
            return nil
        }

        var sectionRect = outlineView.rect(ofRow: workspaceRow)
        guard workspace.isExpanded,
              let lastJob = workspace.jobs.last,
              let lastJobRow = row(forJobID: lastJob.id)
        else {
            return sectionRect
        }

        sectionRect = sectionRect.union(outlineView.rect(ofRow: lastJobRow))
        return sectionRect
    }

    private func resolvedJobDrop(
        id: String,
        cwd: String,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> SidebarResolvedDrop? {
        guard let destination = resolvedJobDropDestination(
            proposedItem: proposedItem,
            proposedChildIndex: index
        ),
        destination.workspace.cwd == cwd,
        let sourceIndex = destination.workspace.jobs.firstIndex(where: { $0.id == id })
        else {
            return nil
        }

        let insertionIndex = max(0, min(destination.childIndex, destination.workspace.jobs.count))
        let destinationIndex = insertionIndex > sourceIndex
            ? insertionIndex - 1
            : insertionIndex
        let clampedDestinationIndex = max(0, min(destinationIndex, destination.workspace.jobs.count - 1))
        let operation: SidebarResolvedDrop.Operation = clampedDestinationIndex == sourceIndex
            ? .none
            : .reorderJob(id: id, cwd: cwd, toIndex: clampedDestinationIndex)
        return SidebarResolvedDrop(
            operation: operation,
            dropItem: destination.workspace,
            dropChildIndex: insertionIndex
        )
    }

    private func resolvedJobDropDestination(
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> (workspace: CodexReviewWorkspace, childIndex: Int)? {
        if let workspace = workspace(from: proposedItem),
           index != NSOutlineViewDropOnItemIndex
        {
            return (workspace, index)
        }

        guard let job = job(from: proposedItem),
              index == NSOutlineViewDropOnItemIndex,
              let workspace = workspace(containing: job),
              let jobIndex = workspace.jobs.firstIndex(where: { $0.id == job.id })
        else {
            return nil
        }
        return (workspace, jobIndex)
    }

    @discardableResult
    private func applyResolvedDrop(_ resolvedDrop: SidebarResolvedDrop) -> Bool {
        switch resolvedDrop.operation {
        case .none:
            return true
        case .reorderWorkspace(let cwd, let toIndex):
            store.reorderWorkspace(cwd: cwd, toIndex: toIndex)
            reloadOutline(workspaces: store.workspaces)
            return true
        case .reorderJob(let id, let cwd, let toIndex):
            store.reorderJob(id: id, inWorkspace: cwd, toIndex: toIndex)
            reloadOutline(workspaces: store.workspaces)
            return true
        }
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

    func outlineView(
        _ outlineView: NSOutlineView,
        pasteboardWriterForItem item: Any
    ) -> (any NSPasteboardWriting)? {
        guard let payload = dragPayload(for: item) else {
            return nil
        }
        return makePasteboardItem(for: payload)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let payload = dragPayload(from: info),
              let resolvedDrop = resolvedDrop(
                for: payload,
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
        guard let payload = dragPayload(from: info),
              let resolvedDrop = resolvedDrop(
                for: payload,
                draggingInfo: info,
                proposedItem: item,
                proposedChildIndex: index
              )
        else {
            return false
        }
        return applyResolvedDrop(resolvedDrop)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        _ = notification
        updateSelectedJobFromOutlineView()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let workspace = workspace(from: notification.userInfo?["NSObject"]) else {
            return
        }
        if workspace.isExpanded == false {
            workspace.isExpanded = true
        }

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
        if workspace.isExpanded {
            workspace.isExpanded = false
        }
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
    var presentationForTesting: PresentationForTesting {
        presentationForCurrentState
    }

    var displayedSectionTitlesForTesting: [String] {
        var titles: [String] = []
        for row in 0..<outlineView.numberOfRows {
            guard let workspace = workspace(from: outlineView.item(atRow: row)) else {
                continue
            }
            titles.append(workspace.displayTitle)
        }
        return titles
    }

    var selectedJobForTesting: CodexReviewJob? {
        uiState.selectedJobEntry
    }

    var accountsViewControllerForTesting: ReviewMonitorAccountsViewController {
        accountsViewController.loadViewIfNeeded()
        return accountsViewController
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

    func displayedJobIDsForTesting(in workspace: CodexReviewWorkspace) -> [String] {
        var jobIDs: [String] = []
        for row in 0..<outlineView.numberOfRows {
            guard let job = job(from: outlineView.item(atRow: row)),
                  job.cwd == workspace.cwd
            else {
                continue
            }
            jobIDs.append(job.id)
        }
        return jobIDs
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
        outlineView.performInertClickForTesting(at: point)
    }

    func presentContextMenuForTesting(
        for job: CodexReviewJob,
        presenter: @escaping (NSMenu) -> Void
    ) {
        view.layoutSubtreeIfNeeded()
        guard let row = row(forJobID: job.id) else {
            preconditionFailure("Job row is not visible.")
        }
        let rect = outlineView.rect(ofRow: row)
        let point = NSPoint(x: rect.midX, y: rect.midY)
        outlineView.presentContextMenuForTesting(at: point, presenter: presenter)
    }

    func focusSidebarForTesting() {
        _ = view.window?.makeFirstResponder(outlineView)
    }

    var sidebarHasFirstResponderForTesting: Bool {
        view.window?.firstResponder === outlineView
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

    func workspaceIsExpandedForTesting(_ workspace: CodexReviewWorkspace) -> Bool {
        workspace.isExpanded
    }

    func toggleWorkspaceDisclosureForTesting(_ workspace: CodexReviewWorkspace) {
        guard row(for: workspace) != nil else {
            preconditionFailure("Workspace row is not visible.")
        }
        workspace.isExpanded.toggle()
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

    var sidebarVisibleHeightForTesting: CGFloat {
        scrollView.documentVisibleRect.height
    }

    var sidebarDocumentHeightForTesting: CGFloat {
        outlineView.frame.height
    }

    var sidebarOutlineContentHeightForTesting: CGFloat {
        guard outlineView.numberOfRows > 0 else {
            return 0
        }
        return outlineView.rect(ofRow: outlineView.numberOfRows - 1).maxY
    }

    var sidebarMaximumVerticalScrollOffsetForTesting: CGFloat {
        max(0, sidebarDocumentHeightForTesting - sidebarVisibleHeightForTesting)
    }

    var sidebarVisibleRectForTesting: NSRect {
        outlineView.visibleRect
    }

    var sidebarFirstRowRectForTesting: NSRect {
        guard outlineView.numberOfRows > 0 else {
            return .zero
        }
        return outlineView.rect(ofRow: 0)
    }

    var sidebarLastRowRectForTesting: NSRect {
        guard outlineView.numberOfRows > 0 else {
            return .zero
        }
        return outlineView.rect(ofRow: outlineView.numberOfRows - 1)
    }

    @discardableResult
    func performWorkspaceDropForTesting(
        _ workspace: CodexReviewWorkspace,
        toIndex index: Int
    ) -> Bool {
        guard let resolvedDrop = resolvedDrop(
            for: .workspace(cwd: workspace.cwd),
            proposedItem: nil,
            proposedChildIndex: index
        ) else {
            return false
        }
        return applyResolvedDrop(resolvedDrop)
    }

    @discardableResult
    func performWorkspaceDropForTesting(
        _ workspace: CodexReviewWorkspace,
        proposedWorkspace targetWorkspace: CodexReviewWorkspace
    ) -> Bool {
        guard let resolvedDrop = resolvedDrop(
            for: .workspace(cwd: workspace.cwd),
            proposedItem: targetWorkspace,
            proposedChildIndex: NSOutlineViewDropOnItemIndex
        ) else {
            return false
        }
        return applyResolvedDrop(resolvedDrop)
    }

    func workspaceDropIsRejectedForTesting(
        _ workspace: CodexReviewWorkspace,
        proposedJob targetJob: CodexReviewJob
    ) -> Bool {
        resolvedDrop(
            for: .workspace(cwd: workspace.cwd),
            proposedItem: targetJob,
            proposedChildIndex: NSOutlineViewDropOnItemIndex
        ) == nil
    }

    func workspaceInsertionIndexForTesting(
        _ workspace: CodexReviewWorkspace,
        hoveringBelowMidpoint: Bool
    ) -> Int? {
        guard let sectionRect = workspaceSectionRect(for: workspace) else {
            return nil
        }
        let point = NSPoint(
            x: sectionRect.midX,
            y: hoveringBelowMidpoint ? sectionRect.midY + 1 : sectionRect.midY - 1
        )
        return resolvedWorkspaceInsertionIndex(
            draggingLocation: point,
            proposedItem: workspace,
            proposedChildIndex: NSOutlineViewDropOnItemIndex
        )
    }

    func blankAreaWorkspaceInsertionIndexForTesting(atEnd: Bool) -> Int? {
        guard outlineView.numberOfRows > 0 else {
            return nil
        }
        let rowRect = outlineView.rect(ofRow: atEnd ? outlineView.numberOfRows - 1 : 0)
        let point = NSPoint(
            x: rowRect.midX,
            y: atEnd ? rowRect.maxY + 1 : rowRect.minY - 1
        )
        return resolvedWorkspaceInsertionIndex(
            draggingLocation: point,
            proposedItem: nil,
            proposedChildIndex: NSOutlineViewDropOnItemIndex
        )
    }

    @discardableResult
    func performJobDropForTesting(
        _ job: CodexReviewJob,
        proposedWorkspace: CodexReviewWorkspace,
        childIndex: Int
    ) -> Bool {
        guard let resolvedDrop = resolvedDrop(
            for: .job(id: job.id, cwd: job.cwd),
            proposedItem: proposedWorkspace,
            proposedChildIndex: childIndex
        ) else {
            return false
        }
        return applyResolvedDrop(resolvedDrop)
    }

    func jobDropIsRejectedForTesting(_ job: CodexReviewJob) -> Bool {
        resolvedDrop(
            for: .job(id: job.id, cwd: job.cwd),
            proposedItem: nil,
            proposedChildIndex: NSOutlineViewDropOnItemIndex
        ) == nil
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
    var draggingExitedHandler: (() -> Void)?
    private var isPresentingContextMenu = false
    private weak var contextMenuFirstResponder: NSResponder?
    private var previousContextMenu: NSMenu?

    override var acceptsFirstResponder: Bool {
        isPresentingContextMenu ? false : super.acceptsFirstResponder
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        handlePrimaryInteraction(at: point) {
            super.mouseDown(with: event)
        }
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

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        draggingExitedHandler?()
        super.draggingExited(sender)
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        guard isPresentingContextMenu else {
            return
        }
        endContextMenuPresentation()
    }

    private func shouldSuppressSelectionClearing(at point: NSPoint) -> Bool {
        guard selectedRow != -1 else {
            return false
        }
        return row(at: point) == -1
    }

    private func handlePrimaryInteraction(
        at point: NSPoint,
        action: () -> Void
    ) {
        guard shouldSuppressSelectionClearing(at: point) == false else {
            return
        }

        let clickedRow = row(at: point)
        let shouldRestoreSelection = selectedRow != -1
            && clickedRow != -1
            && (inertRowEvaluator?(clickedRow) ?? false)
        let preservedItem = shouldRestoreSelection ? item(atRow: selectedRow) : nil
        action()
        guard shouldRestoreSelection,
              let preservedItem
        else {
            return
        }
        let restoredRow = row(forItem: preservedItem)
        guard restoredRow != -1 else {
            deselectAll(nil)
            return
        }
        guard selectedRow != restoredRow else {
            return
        }
        selectRowIndexes(IndexSet(integer: restoredRow), byExtendingSelection: false)
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

    private func beginContextMenuPresentation(with contextMenu: NSMenu) {
        previousContextMenu = menu
        menu = contextMenu
        isPresentingContextMenu = true

        guard let window else {
            contextMenuFirstResponder = nil
            return
        }

        let previousFirstResponder = window.firstResponder
        guard previousFirstResponder.map(isSidebarFirstResponder(_:)) ?? false else {
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
    func performInertClickForTesting(at point: NSPoint) {
        handlePrimaryInteraction(at: point) {
            deselectAll(nil)
        }
    }

    func suppressesSelectionClearingForTesting(at point: NSPoint) -> Bool {
        shouldSuppressSelectionClearing(at: point)
    }

    func presentContextMenuForTesting(
        at point: NSPoint,
        presenter: @escaping (NSMenu) -> Void
    ) {
        guard window != nil else {
            fatalError("Sidebar outline view must be attached to a window for context menu testing.")
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
            hostingView.rootView.job = job
        } else {
            let hostingView = NSHostingView(
                rootView: ReviewMonitorJobRowView(job: job)
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
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let contentStack = NSStackView()

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
        iconView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        titleLabel.stringValue = workspace.displayTitle
        toolTip = workspace.cwd
    }

    private func configureHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyDown
        iconView.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .preferredFont(forTextStyle: .footnote)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        imageView = iconView
        textField = titleLabel

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 4
        contentStack.detachesHiddenViews = true
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(titleLabel)

        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}
