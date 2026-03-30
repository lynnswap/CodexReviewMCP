import AppKit
import CodexReviewMCP

@MainActor
enum ReviewMonitorJobSection: Int, Hashable, CaseIterable {
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
final class ReviewMonitorSidebarViewController: NSViewController, NSTableViewDelegate {
    private enum Identifier {
        static let tableColumn = NSUserInterfaceItemIdentifier("ReviewMonitorJobs.Column")
        static let jobCell = NSUserInterfaceItemIdentifier("ReviewMonitorJobs.Cell")
        static let sectionHeader = NSUserInterfaceItemIdentifier("ReviewMonitorJobs.SectionHeader")
    }

    private weak var store: CodexReviewStore?
    private let uiState: ReviewMonitorUIState
    private let stackView = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "Server: Stopped")
    private let serverURLLabel = NSTextField(labelWithString: "Server unavailable")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let restartButton = NSButton(title: "Restart", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let tableView = NSTableView(frame: .zero)
    private let tableColumn = NSTableColumn(identifier: Identifier.tableColumn)
    private let emptyStateView = ReviewMonitorViewFactory.makeEmptyStateView(
        title: "No active reviews",
        description: "Start a review through the embedded server to see it here."
    )
    private lazy var dataSource = makeDataSource()

    private var observationHandles: Set<ObservationHandle> = []

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
        configureTableView()
    }

    func bind(store: CodexReviewStore) {
        self.store = store
        bindObservation(store: store)
        applyServerState(
            serverState: store.serverState,
            serverURL: store.serverURL
        )
        applySection(.active, jobs: store.activeJobs)
        applySection(.recent, jobs: store.recentJobs)
        ensureSelection()
    }

    func applyServerState(
        serverState: CodexReviewServerState,
        serverURL: URL?
    ) {
        statusLabel.stringValue = "Server: \(serverState.displayText)"
        serverURLLabel.stringValue = serverURL?.absoluteString ?? "Server unavailable"
        errorLabel.stringValue = serverState.failureMessage ?? ""
        errorLabel.isHidden = serverState.failureMessage == nil
        restartButton.isEnabled = serverState.isRestartAvailable
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        dataSource.itemIdentifier(forRow: row) != nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        _ = notification
        if tableView.selectedRow < 0 {
            uiState.selectedJobEntry = nil
            return
        }
        uiState.selectedJobEntry = dataSource.itemIdentifier(forRow: tableView.selectedRow)
    }

    private func configureHierarchy() {
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 10

        serverURLLabel.font = .preferredFont(forTextStyle: .footnote)
        serverURLLabel.textColor = .secondaryLabelColor
        serverURLLabel.lineBreakMode = .byTruncatingMiddle
        serverURLLabel.maximumNumberOfLines = 2

        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        restartButton.bezelStyle = .rounded
        restartButton.target = self
        restartButton.action = #selector(restartPressed)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        view.addSubview(stackView)
        view.addSubview(scrollView)
        view.addSubview(emptyStateView)

        stackView.addArrangedSubview(statusLabel)
        stackView.addArrangedSubview(serverURLLabel)
        stackView.addArrangedSubview(errorLabel)
        stackView.addArrangedSubview(restartButton)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: stackView.bottomAnchor, constant: 16),
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

    private func makeDataSource() -> NSTableViewDiffableDataSource<ReviewMonitorJobSection, CodexReviewJob> {
        let dataSource = NSTableViewDiffableDataSource<ReviewMonitorJobSection, CodexReviewJob>(tableView: tableView) { tableView, _, _, job in
            let cell = self.makeCell(in: tableView)
            cell.configure(with: job)
            return cell
        }

        dataSource.sectionHeaderViewProvider = { tableView, _, section in
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

    private func bindObservation(store: CodexReviewStore) {
        observationHandles.removeAll()
        store.observe([\.serverState, \.serverURL]) { [weak self, weak store] in
            guard let self, let store else {
                return
            }
            self.applyServerState(
                serverState: store.serverState,
                serverURL: store.serverURL
            )
        }
        .store(in: &observationHandles)

        store.observe([\.activeJobs]) { [weak self, weak store] in
            guard let self, let store else {
                return
            }
            self.applySection(.active, jobs: store.activeJobs)
        }
        .store(in: &observationHandles)

        store.observe([\.recentJobs]) { [weak self, weak store] in
            guard let self, let store else {
                return
            }
            self.applySection(.recent, jobs: store.recentJobs)
        }
        .store(in: &observationHandles)

        uiState.observe(\.selectedJobEntry) { [weak self] selectedJob in
            self?.syncSelection(to: selectedJob)
        }
        .store(in: &observationHandles)
    }

    private func applySection(_ section: ReviewMonitorJobSection, jobs: [CodexReviewJob]) {
        var snapshot = dataSource.snapshot()
        let hasSection = snapshot.sectionIdentifiers.contains(section)
        if jobs.isEmpty {
            if hasSection {
                snapshot.deleteSections([section])
            }
        } else {
            if hasSection {
                snapshot.deleteItems(snapshot.itemIdentifiers(inSection: section))
            } else {
                switch section {
                case .active:
                    if let firstSection = snapshot.sectionIdentifiers.first {
                        snapshot.insertSections([.active], beforeSection: firstSection)
                    } else {
                        snapshot.appendSections([.active])
                    }
                case .recent:
                    if snapshot.sectionIdentifiers.contains(.active) {
                        snapshot.appendSections([.recent])
                    } else if let firstSection = snapshot.sectionIdentifiers.first {
                        snapshot.insertSections([.recent], beforeSection: firstSection)
                    } else {
                        snapshot.appendSections([.recent])
                    }
                }
            }
            snapshot.appendItems(jobs, toSection: section)
        }
        dataSource.apply(snapshot, animatingDifferences: view.window != nil) { [weak self] in
            self?.ensureSelection()
        }
        updateEmptyState()
    }

    private func updateEmptyState() {
        let hasJobs = dataSource.snapshot().numberOfItems > 0
        scrollView.isHidden = hasJobs == false
        emptyStateView.isHidden = hasJobs
    }

    private func ensureSelection() {
        let visibleJobs = dataSource.snapshot().itemIdentifiers
        if let selectedJob = uiState.selectedJobEntry,
           visibleJobs.contains(selectedJob) {
            syncSelection(to: selectedJob)
            return
        }

        let replacementJob = visibleJobs.first
        if uiState.selectedJobEntry != replacementJob {
            uiState.selectedJobEntry = replacementJob
        }
        syncSelection(to: replacementJob)
    }

    private func syncSelection(to selectedJob: CodexReviewJob?) {
        guard let selectedJob, let row = dataSource.row(forItemIdentifier: selectedJob) else {
            if tableView.selectedRow != -1 {
                tableView.deselectAll(nil)
            }
            return
        }
        if tableView.selectedRow != row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    @objc private func restartPressed() {
        guard let store else {
            return
        }
        Task {
            await store.restart()
        }
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorSidebarViewController {
    var statusTextForTesting: String {
        statusLabel.stringValue
    }

    var serverURLTextForTesting: String {
        serverURLLabel.stringValue
    }

    var restartEnabledForTesting: Bool {
        restartButton.isEnabled
    }

    var displayedSectionTitlesForTesting: [String] {
        dataSource.snapshot().sectionIdentifiers.map(\.title)
    }

    var selectedJobForTesting: CodexReviewJob? {
        guard tableView.selectedRow >= 0 else {
            return nil
        }
        return dataSource.itemIdentifier(forRow: tableView.selectedRow)
    }

    var isShowingEmptyStateForTesting: Bool {
        emptyStateView.isHidden == false
    }

    func applySectionForTesting(_ section: ReviewMonitorJobSection, jobs: [CodexReviewJob]) {
        applySection(section, jobs: jobs)
    }

    func selectJobForTesting(_ job: CodexReviewJob) {
        guard let row = dataSource.row(forItemIdentifier: job) else {
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        uiState.selectedJobEntry = job
    }

    func clearSelectionForTesting() {
        tableView.deselectAll(nil)
        uiState.selectedJobEntry = nil
    }
}
#endif

@MainActor
private final class ReviewMonitorJobCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var observationHandles: Set<ObservationHandle> = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(with job: CodexReviewJob) {
        render(job)
        observationHandles.removeAll()
        job.observe(
            [
                \.targetSummary,
                \.status,
                \.sessionID,
                \.cwd,
            ]
        ) { [weak self, weak job] in
            guard let self, let job else {
                return
            }
            self.render(job)
        }
        .store(in: &observationHandles)
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

    private func render(_ job: CodexReviewJob) {
        titleLabel.stringValue = job.displayTitle
        subtitleLabel.stringValue = "\(job.status.displayText) • \(job.sessionID) • \(job.cwd)"
        toolTip = job.cwd
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
