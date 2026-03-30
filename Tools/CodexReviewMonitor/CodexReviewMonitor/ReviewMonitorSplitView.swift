import AppKit
import CodexReviewMCP
import SwiftUI

@MainActor
struct ReviewMonitorSplitViewRepresentable: NSViewControllerRepresentable {
    let store: CodexReviewStore
    let onRestart: () -> Void

    func makeNSViewController(context: Context) -> ReviewMonitorSplitViewController {
        let viewController = ReviewMonitorSplitViewController()
        viewController.loadViewIfNeeded()
        viewController.bind(store: store, onRestart: onRestart)
        return viewController
    }

    func updateNSViewController(_ nsViewController: ReviewMonitorSplitViewController, context: Context) {
        _ = nsViewController
        _ = context
    }
}

@MainActor
final class ReviewMonitorSplitViewController: NSSplitViewController {
    private static let autosaveName = NSSplitView.AutosaveName("CodexReviewMCP.ReviewMonitorSplitView")

    private let sidebarViewController = ReviewMonitorSidebarViewController()
    private let transportViewController = ReviewMonitorTransportViewController()
    private let reasoningViewController = ReviewMonitorReasoningViewController()

    private var store: CodexReviewStore?
    private var onRestart: (() -> Void)?
    private var jobsByID: [String: CodexReviewJob] = [:]
    private var selectedJobID: String?
    private var currentServerState: CodexReviewServerState = .stopped
    private var currentEndpointURL: URL?
    private var stateObservationTask: Task<Void, Never>?
    private var jobObservationTask: Task<Void, Never>?

    var sidebarViewControllerForTesting: ReviewMonitorSidebarViewController {
        sidebarViewController
    }

    var listViewControllerForTesting: ReviewMonitorJobListViewController {
        sidebarViewController.listViewControllerForTesting
    }

    var transportViewControllerForTesting: ReviewMonitorTransportViewController {
        transportViewController
    }

    var reasoningViewControllerForTesting: ReviewMonitorReasoningViewController {
        reasoningViewController
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.autosaveName = Self.autosaveName

        sidebarViewController.onSelectionChanged = { [weak self] jobID in
            self?.handleSelectionChange(jobID)
        }

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        let contentItem = NSSplitViewItem(viewController: transportViewController)
        contentItem.minimumThickness = 300
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: reasoningViewController)

        splitViewItems = [sidebarItem, contentItem, inspectorItem]
    }

    deinit {
        stateObservationTask?.cancel()
        jobObservationTask?.cancel()
    }

    func bind(store: CodexReviewStore, onRestart: @escaping () -> Void) {
        self.store = store
        self.onRestart = onRestart
        currentServerState = store.serverState
        currentEndpointURL = store.endpointURL
        render(jobs: store.jobStore.jobs)
        observeStateChanges()
        observeJobChanges()
    }

    func apply(
        serverState: CodexReviewServerState,
        endpointURL: URL?,
        jobs: [CodexReviewJob],
        onRestart: @escaping () -> Void
    ) {
        currentServerState = serverState
        currentEndpointURL = endpointURL
        self.onRestart = onRestart
        render(jobs: jobs)
    }

    private func render(jobs: [CodexReviewJob]) {
        jobsByID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        let resolvedSelection = preferredSelectionJobID(in: jobs, current: selectedJobID)
        selectedJobID = resolvedSelection

        sidebarViewController.apply(
            serverState: currentServerState,
            endpointURL: currentEndpointURL,
            jobs: jobs,
            selectedJobID: resolvedSelection,
            onRestart: onRestart ?? {}
        )

        let selectedJob = resolvedSelection.flatMap { jobsByID[$0] }
        transportViewController.display(selectedJob)
        reasoningViewController.display(selectedJob)
    }

    private func handleSelectionChange(_ jobID: String?) {
        selectedJobID = jobID
        let selectedJob = jobID.flatMap { jobsByID[$0] }
        transportViewController.display(selectedJob)
        reasoningViewController.display(selectedJob)
    }

    private func observeStateChanges() {
        stateObservationTask?.cancel()
        guard let store else {
            return
        }
        stateObservationTask = Task { @MainActor [weak self] in
            let changes = store.changes()
            for await _ in changes {
                guard let self, self.store === store else {
                    return
                }
                self.currentServerState = store.serverState
                self.currentEndpointURL = store.endpointURL
                self.render(jobs: store.jobStore.jobs)
            }
        }
    }

    private func observeJobChanges() {
        jobObservationTask?.cancel()
        guard let store else {
            return
        }
        let jobStore = store.jobStore
        jobObservationTask = Task { @MainActor [weak self] in
            let changes = jobStore.changes()
            for await _ in changes {
                guard let self, self.store === store else {
                    return
                }
                self.render(jobs: jobStore.jobs)
            }
        }
    }
}

@MainActor
private func preferredSelectionJobID(
    in jobs: [CodexReviewJob],
    current: String?
) -> String? {
    if let current, jobs.contains(where: { $0.id == current }) {
        return current
    }
    return jobs.first(where: { $0.isTerminal == false })?.id ?? jobs.first?.id
}

@MainActor
private enum ReviewMonitorJobSection: Int, Hashable, CaseIterable {
    case active
    case recent

    var title: String {
        switch self {
        case .active:
            "Active"
        case .recent:
            "Recent"
        }
    }
}

@MainActor
final class ReviewMonitorJobListViewController: NSViewController, NSTableViewDelegate {
    private struct SectionedJobIDs: Equatable {
        var active: [String]
        var recent: [String]
    }

    private struct CellDisplayState: Equatable {
        var title: String
        var subtitle: String

        init(job: CodexReviewJob) {
            title = job.displayTitle
            subtitle = "\(job.status.displayText) • \(job.sessionID) • \(job.cwd)"
        }
    }

    private enum Identifier {
        static let tableColumn = NSUserInterfaceItemIdentifier("ReviewMonitorJobs.Column")
        static let jobCell = NSUserInterfaceItemIdentifier("ReviewMonitorJobs.Cell")
        static let sectionHeader = NSUserInterfaceItemIdentifier("ReviewMonitorJobs.SectionHeader")
    }

    var onSelectionChanged: ((String?) -> Void)?

    private let scrollView = NSScrollView()
    private let tableView = NSTableView(frame: .zero)
    private let tableColumn = NSTableColumn(identifier: Identifier.tableColumn)
    private let emptyStateView = ReviewMonitorViewFactory.makeEmptyStateView(
        title: "No active reviews",
        description: "Start a review through the embedded server to see it here."
    )
    private lazy var dataSource = makeDataSource()

    private var jobsByID: [String: CodexReviewJob] = [:]
    private var sectionedJobIDs = SectionedJobIDs(active: [], recent: [])
    private var cellStatesByID: [String: CellDisplayState] = [:]

    var displayedSectionTitlesForTesting: [String] {
        dataSource.snapshot().sectionIdentifiers.map(\.title)
    }

    var selectedJobIDForTesting: String? {
        guard tableView.selectedRow >= 0 else {
            return nil
        }
        return dataSource.itemIdentifier(forRow: tableView.selectedRow)
    }

    var isShowingEmptyStateForTesting: Bool {
        emptyStateView.isHidden == false
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        configureTableView()
    }

    func apply(jobs: [CodexReviewJob], selectedJobID: String?) {
        jobsByID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })

        let activeJobs = jobs.filter { $0.isTerminal == false }
        let recentJobs = jobs.filter(\.isTerminal)
        let newSectionedJobIDs = SectionedJobIDs(
            active: activeJobs.map(\.id),
            recent: recentJobs.map(\.id)
        )
        let previousCellStates = cellStatesByID
        cellStatesByID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, CellDisplayState(job: $0)) })

        if sectionedJobIDs != newSectionedJobIDs {
            var snapshot = NSDiffableDataSourceSnapshot<ReviewMonitorJobSection, String>()
            if activeJobs.isEmpty == false {
                snapshot.appendSections([.active])
                snapshot.appendItems(newSectionedJobIDs.active, toSection: .active)
            }
            if recentJobs.isEmpty == false {
                snapshot.appendSections([.recent])
                snapshot.appendItems(newSectionedJobIDs.recent, toSection: .recent)
            }
            dataSource.apply(snapshot, animatingDifferences: view.window != nil)
            sectionedJobIDs = newSectionedJobIDs
            tableView.reloadData()
        } else {
            let rowsToReload = IndexSet(
                jobs.compactMap { job in
                    guard previousCellStates[job.id] != CellDisplayState(job: job) else {
                        return nil
                    }
                    return dataSource.row(forItemIdentifier: job.id)
                }
            )
            if rowsToReload.isEmpty == false {
                tableView.reloadData(
                    forRowIndexes: rowsToReload,
                    columnIndexes: IndexSet(integer: tableView.column(withIdentifier: Identifier.tableColumn))
                )
            }
        }
        syncSelection(selectedJobID)

        let hasJobs = jobs.isEmpty == false
        scrollView.isHidden = hasJobs == false
        emptyStateView.isHidden = hasJobs
    }

    func selectJobForTesting(id: String) {
        guard let row = dataSource.row(forItemIdentifier: id) else {
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        dataSource.itemIdentifier(forRow: row) != nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        _ = notification
        guard tableView.selectedRow >= 0 else {
            onSelectionChanged?(nil)
            return
        }
        onSelectionChanged?(dataSource.itemIdentifier(forRow: tableView.selectedRow))
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

    private func configureTableView() {
        tableColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(tableColumn)
        tableView.setAccessibilityIdentifier("review-monitor.job-list")
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = dataSource
        tableView.style = .fullWidth
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 46
        tableView.intercellSpacing = .zero
        tableView.usesAlternatingRowBackgroundColors = false

        scrollView.documentView = tableView
    }

    private func makeDataSource() -> NSTableViewDiffableDataSource<ReviewMonitorJobSection, String> {
        let dataSource = NSTableViewDiffableDataSource<ReviewMonitorJobSection, String>(tableView: tableView) { [weak self] tableView, _, _, jobID in
            guard let self, let job = self.jobsByID[jobID] else {
                return NSView()
            }
            let cell = self.makeCell(in: tableView)
            cell.configure(with: job)
            return cell
        }

        dataSource.sectionHeaderViewProvider = { [weak self] tableView, _, section in
            guard let self else {
                return NSView()
            }
            let header = self.makeSectionHeader(in: tableView)
            header.configure(title: section.title)
            return header
        }

        return dataSource
    }

    private func makeCell(in tableView: NSTableView) -> ReviewMonitorJobCellView {
        if let cell = tableView.makeView(withIdentifier: Identifier.jobCell, owner: nil) as? ReviewMonitorJobCellView {
            return cell
        }
        let cell = ReviewMonitorJobCellView(frame: .zero)
        cell.identifier = Identifier.jobCell
        return cell
    }

    private func makeSectionHeader(in tableView: NSTableView) -> ReviewMonitorSectionHeaderView {
        if let view = tableView.makeView(withIdentifier: Identifier.sectionHeader, owner: nil) as? ReviewMonitorSectionHeaderView {
            return view
        }
        let view = ReviewMonitorSectionHeaderView(frame: .zero)
        view.identifier = Identifier.sectionHeader
        return view
    }

    private func syncSelection(_ selectedJobID: String?) {
        guard let selectedJobID, let row = dataSource.row(forItemIdentifier: selectedJobID) else {
            if tableView.selectedRow != -1 {
                tableView.deselectAll(nil)
            }
            return
        }
        if tableView.selectedRow != row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }
}

@MainActor
private func reviewMonitorMetadataText(for job: CodexReviewJob) -> String {
    var parts: [String] = [
        "Status: \(job.status.displayText)",
        "Session: \(job.sessionID)",
        "CWD: \(job.cwd)"
    ]
    if let model = job.model {
        parts.append("Model: \(model)")
    }
    parts.append("Job: \(job.id)")
    if let threadID = job.threadID {
        parts.append("Thread: \(threadID)")
    }
    if let turnID = job.turnID {
        parts.append("Turn: \(turnID)")
    }
    return parts.joined(separator: "\n")
}

@MainActor
final class ReviewMonitorTransportViewController: NSViewController {
    private let headerStack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "Select a job")
    private let metadataLabel = NSTextField(wrappingLabelWithString: "Choose a running or recent review from the list.")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let sectionTitleLabel = NSTextField(labelWithString: "Review Log")
    private let textScrollView: NSScrollView
    private let textView: NSTextView
    private let emptyStateView = ReviewMonitorViewFactory.makeEmptyStateView(
        title: "Select a job",
        description: "Choose a running or recent review from the list."
    )

    var displayedTitleForTesting: String? {
        titleLabel.isHidden ? nil : titleLabel.stringValue
    }

    var displayedActivityLogForTesting: String {
        textView.string
    }

    var displayedSummaryForTesting: String? {
        summaryLabel.isHidden ? nil : summaryLabel.stringValue
    }

    var isShowingEmptyStateForTesting: Bool {
        emptyStateView.isHidden == false
    }

    init() {
        let scrollableTextView = NSTextView.scrollableTextView()
        guard let textView = scrollableTextView.documentView as? NSTextView else {
            fatalError("Expected NSTextView.scrollableTextView() document view to be NSTextView")
        }
        self.textScrollView = scrollableTextView
        self.textView = textView
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
        display(nil)
    }

    func display(_ job: CodexReviewJob?) {
        guard let job else {
            titleLabel.isHidden = true
            metadataLabel.isHidden = true
            summaryLabel.isHidden = true
            sectionTitleLabel.isHidden = true
            textScrollView.isHidden = true
            emptyStateView.isHidden = false
            updateLogText("")
            return
        }

        titleLabel.isHidden = false
        metadataLabel.isHidden = false
        summaryLabel.isHidden = job.summary.isEmpty
        sectionTitleLabel.isHidden = false
        textScrollView.isHidden = false
        emptyStateView.isHidden = true

        titleLabel.stringValue = job.displayTitle
        metadataLabel.stringValue = reviewMonitorMetadataText(for: job)
        summaryLabel.stringValue = job.summary
        updateLogText(job.reviewLogText)
    }

    private func configureHierarchy() {
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 6

        titleLabel.font = .preferredFont(forTextStyle: .title3)
        metadataLabel.font = .preferredFont(forTextStyle: .subheadline)
        metadataLabel.textColor = .secondaryLabelColor
        summaryLabel.font = .preferredFont(forTextStyle: .body)
        summaryLabel.textColor = .secondaryLabelColor
        sectionTitleLabel.font = .preferredFont(forTextStyle: .headline)
        sectionTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        textScrollView.translatesAutoresizingMaskIntoConstraints = false
        textScrollView.drawsBackground = false
        textScrollView.borderType = .noBorder
        textScrollView.hasVerticalScroller = true
        textScrollView.autohidesScrollers = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.setAccessibilityIdentifier("review-monitor.activity-log")
        textView.font = .monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize,
            weight: .regular
        )

        view.addSubview(headerStack)
        view.addSubview(sectionTitleLabel)
        view.addSubview(textScrollView)
        view.addSubview(emptyStateView)

        headerStack.addArrangedSubview(titleLabel)
        headerStack.addArrangedSubview(metadataLabel)
        headerStack.addArrangedSubview(summaryLabel)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            sectionTitleLabel.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            sectionTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            sectionTitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            textScrollView.topAnchor.constraint(equalTo: sectionTitleLabel.bottomAnchor, constant: 8),
            textScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),

            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    private func updateLogText(_ text: String) {
        let shouldStickToBottom = isPinnedToBottom()
        if textView.string != text {
            textView.string = text
        }
        if shouldStickToBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func isPinnedToBottom() -> Bool {
        guard let documentView = textScrollView.documentView else {
            return true
        }
        let visibleMaxY = textScrollView.contentView.bounds.maxY
        let documentMaxY = documentView.frame.maxY
        return documentMaxY - visibleMaxY < 24
    }
}

@MainActor
final class ReviewMonitorReasoningViewController: NSViewController {
    private let headerStack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "Reasoning")
    private let metadataLabel = NSTextField(wrappingLabelWithString: "Select a review to inspect its reasoning summary.")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let reasoningScrollView: NSScrollView
    private let reasoningTextView: NSTextView
    private let placeholderLabel = NSTextField(wrappingLabelWithString: "Reasoning summary is not available yet.")
    private let emptyStateView = ReviewMonitorViewFactory.makeEmptyStateView(
        title: "Select a job",
        description: "Choose a running or recent review from the list."
    )

    var displayedTitleForTesting: String? {
        titleLabel.isHidden ? nil : titleLabel.stringValue
    }

    var displayedReasoningForTesting: String {
        reasoningTextView.string
    }

    var displayedSummaryForTesting: String? {
        summaryLabel.isHidden ? nil : summaryLabel.stringValue
    }

    var isShowingEmptyStateForTesting: Bool {
        emptyStateView.isHidden == false
    }

    init() {
        let reasoningScrollableTextView = NSTextView.scrollableTextView()
        guard let reasoningTextView = reasoningScrollableTextView.documentView as? NSTextView else {
            fatalError("Expected NSTextView.scrollableTextView() document view to be NSTextView")
        }
        self.reasoningScrollView = reasoningScrollableTextView
        self.reasoningTextView = reasoningTextView
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
        display(nil)
    }

    func display(_ job: CodexReviewJob?) {
        guard let job else {
            titleLabel.isHidden = true
            metadataLabel.isHidden = true
            summaryLabel.isHidden = true
            reasoningScrollView.isHidden = true
            placeholderLabel.isHidden = true
            emptyStateView.isHidden = false
            updateReasoningText("")
            return
        }

        titleLabel.isHidden = false
        metadataLabel.isHidden = false
        summaryLabel.isHidden = job.summary.isEmpty
        emptyStateView.isHidden = true

        titleLabel.stringValue = "Reasoning"
        metadataLabel.stringValue = reviewMonitorMetadataText(for: job)
        summaryLabel.stringValue = job.summary
        updateReasoningText(job.reasoningLogText)
    }

    private func configureHierarchy() {
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 6

        titleLabel.font = .preferredFont(forTextStyle: .title3)
        metadataLabel.font = .preferredFont(forTextStyle: .subheadline)
        metadataLabel.textColor = .secondaryLabelColor
        summaryLabel.font = .preferredFont(forTextStyle: .body)
        summaryLabel.textColor = .secondaryLabelColor

        reasoningScrollView.translatesAutoresizingMaskIntoConstraints = false
        reasoningScrollView.drawsBackground = false
        reasoningScrollView.borderType = .noBorder
        reasoningScrollView.hasVerticalScroller = true
        reasoningScrollView.autohidesScrollers = true

        reasoningTextView.isEditable = false
        reasoningTextView.isSelectable = true
        reasoningTextView.drawsBackground = false
        reasoningTextView.setAccessibilityIdentifier("review-monitor.reasoning-log")
        reasoningTextView.font = .preferredFont(forTextStyle: .body)

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.maximumNumberOfLines = 0

        view.addSubview(headerStack)
        view.addSubview(reasoningScrollView)
        view.addSubview(placeholderLabel)
        view.addSubview(emptyStateView)

        headerStack.addArrangedSubview(titleLabel)
        headerStack.addArrangedSubview(metadataLabel)
        headerStack.addArrangedSubview(summaryLabel)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            reasoningScrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            reasoningScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            reasoningScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            reasoningScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),

            placeholderLabel.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            placeholderLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            placeholderLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    private func updateReasoningText(_ text: String) {
        if reasoningTextView.string != text {
            reasoningTextView.string = text
        }
        let hasReasoning = text.isEmpty == false
        reasoningScrollView.isHidden = hasReasoning == false
        placeholderLabel.isHidden = hasReasoning
        if hasReasoning {
            reasoningTextView.scrollToBeginningOfDocument(nil)
        }
    }
}

@MainActor
final class ReviewMonitorSidebarViewController: NSViewController {
    var onSelectionChanged: ((String?) -> Void)? {
        get { listViewController.onSelectionChanged }
        set { listViewController.onSelectionChanged = newValue }
    }

    private let stackView = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "Server: Stopped")
    private let endpointLabel = NSTextField(labelWithString: "Endpoint unavailable")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let restartButton = NSButton(title: "Restart", target: nil, action: nil)
    private let listContainerView = NSView()
    private let listViewController = ReviewMonitorJobListViewController()

    private var onRestart: (() -> Void)?

    var statusTextForTesting: String {
        statusLabel.stringValue
    }

    var endpointTextForTesting: String {
        endpointLabel.stringValue
    }

    var restartEnabledForTesting: Bool {
        restartButton.isEnabled
    }

    var listViewControllerForTesting: ReviewMonitorJobListViewController {
        listViewController
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        embedListViewController()
    }

    func apply(
        serverState: CodexReviewServerState,
        endpointURL: URL?,
        jobs: [CodexReviewJob],
        selectedJobID: String?,
        onRestart: @escaping () -> Void
    ) {
        self.onRestart = onRestart
        statusLabel.stringValue = "Server: \(serverState.displayText)"
        endpointLabel.stringValue = endpointURL?.absoluteString ?? "Endpoint unavailable"
        errorLabel.stringValue = serverState.failureMessage ?? ""
        errorLabel.isHidden = serverState.failureMessage == nil
        restartButton.isEnabled = serverState.isRestartAvailable
        listViewController.apply(jobs: jobs, selectedJobID: selectedJobID)
    }

    private func configureHierarchy() {
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 10

        endpointLabel.font = .preferredFont(forTextStyle: .footnote)
        endpointLabel.textColor = .secondaryLabelColor
        endpointLabel.lineBreakMode = .byTruncatingMiddle
        endpointLabel.maximumNumberOfLines = 2

        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        restartButton.bezelStyle = .rounded
        restartButton.target = self
        restartButton.action = #selector(restartPressed)

        listContainerView.translatesAutoresizingMaskIntoConstraints = false

        stackView.addArrangedSubview(statusLabel)
        stackView.addArrangedSubview(endpointLabel)
        stackView.addArrangedSubview(errorLabel)
        stackView.addArrangedSubview(restartButton)

        view.addSubview(stackView)
        view.addSubview(listContainerView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            listContainerView.topAnchor.constraint(equalTo: stackView.bottomAnchor, constant: 16),
            listContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            listContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            listContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func embedListViewController() {
        addChild(listViewController)
        let listView = listViewController.view
        listView.translatesAutoresizingMaskIntoConstraints = false
        listContainerView.addSubview(listView)
        NSLayoutConstraint.activate([
            listView.topAnchor.constraint(equalTo: listContainerView.topAnchor),
            listView.leadingAnchor.constraint(equalTo: listContainerView.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: listContainerView.trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: listContainerView.bottomAnchor)
        ])
    }

    @objc private func restartPressed() {
        onRestart?()
    }
}

@MainActor
private final class ReviewMonitorJobCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(with job: CodexReviewJob) {
        titleLabel.stringValue = job.displayTitle
        subtitleLabel.stringValue = "\(job.status.displayText) • \(job.sessionID) • \(job.cwd)"
        toolTip = job.cwd
    }

    private func configureHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .body)
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }
}

@MainActor
private final class ReviewMonitorSectionHeaderView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(title: String) {
        titleLabel.stringValue = title
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

@MainActor
private enum ReviewMonitorViewFactory {
    static func makeEmptyStateView(title: String, description: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .preferredFont(forTextStyle: .title3)
        titleLabel.alignment = .center

        let descriptionLabel = NSTextField(wrappingLabelWithString: description)
        descriptionLabel.font = .preferredFont(forTextStyle: .body)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.alignment = .center
        descriptionLabel.maximumNumberOfLines = 0

        let stackView = NSStackView(views: [titleLabel, descriptionLabel])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 8
        return stackView
    }
}
