import AppKit
import CodexReviewModel
import ObservationBridge
import ReviewRuntime

@MainActor
final class ReviewMonitorSidebarViewController: NSViewController, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    private enum Identifier {
        static let jobItem = NSUserInterfaceItemIdentifier("ReviewMonitorJobs.Item")
        static let sectionHeader = NSUserInterfaceItemIdentifier("ReviewMonitorJobs.SectionHeader")
    }

    private weak var store: CodexReviewStore?
    private let uiState: ReviewMonitorUIState
    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private let emptyStateView = ReviewMonitorViewFactory.makeEmptyStateView(
        title: "No review jobs",
        description: "Start a review through the embedded server to see workspaces here."
    )
    private lazy var dataSource = makeDataSource()

    private var storeObservationHandles: Set<ObservationHandle> = []
    private var workspaceObservationHandles: Set<ObservationHandle> = []
    private var isApplyingSnapshot = false

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
        configureCollectionView()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let contentSize = scrollView.contentSize
        let width = max(1, contentSize.width)
        if collectionView.frame.width != width {
            collectionView.setFrameSize(NSSize(width: width, height: collectionView.frame.height))
        }
        collectionView.collectionViewLayout?.invalidateLayout()
        let layoutHeight = collectionView.collectionViewLayout?.collectionViewContentSize.height ?? 0
        let height = max(contentSize.height, layoutHeight)
        if collectionView.frame.size != NSSize(width: width, height: height) {
            collectionView.setFrameSize(NSSize(width: width, height: height))
        }
    }

    func bind(store: CodexReviewStore) {
        self.store = store
        bindObservation(store: store)
        applyWorkspaceSnapshot(workspaces: store.workspaces)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        shouldSelectItemsAt indexPaths: Set<IndexPath>
    ) -> Set<IndexPath> {
        Set(indexPaths.filter { job(at: $0) != nil })
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        _ = indexPaths
        updateSelectedJobFromCollectionView()
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didDeselectItemsAt indexPaths: Set<IndexPath>
    ) {
        _ = indexPaths
        updateSelectedJobFromCollectionView()
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        _ = indexPath
        let width = max(1, floor(collectionView.bounds.width - 1))
        return NSSize(width: width, height: 46)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        referenceSizeForHeaderInSection section: Int
    ) -> NSSize {
        guard section < dataSource.snapshot().sectionIdentifiers.count else {
            return .zero
        }
        return NSSize(width: collectionView.bounds.width, height: 28)
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

    private func configureCollectionView() {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        layout.headerReferenceSize = NSSize(width: 1, height: 28)

        collectionView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        collectionView.autoresizingMask = [.width]
        collectionView.collectionViewLayout = layout
        collectionView.setAccessibilityIdentifier("review-monitor.job-list")
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsEmptySelection = true
        collectionView.allowsMultipleSelection = false
        collectionView.delegate = self
        collectionView.register(
            ReviewMonitorJobItem.self,
            forItemWithIdentifier: Identifier.jobItem
        )
        collectionView.register(
            ReviewMonitorSectionHeaderView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: Identifier.sectionHeader
        )

        scrollView.documentView = collectionView
    }

    private func makeDataSource() -> NSCollectionViewDiffableDataSource<CodexReviewWorkspace, CodexReviewJob> {
        let dataSource = NSCollectionViewDiffableDataSource<CodexReviewWorkspace, CodexReviewJob>(
            collectionView: collectionView
        ) { collectionView, indexPath, job in
            guard let item = collectionView.makeItem(
                withIdentifier: Identifier.jobItem,
                for: indexPath
            ) as? ReviewMonitorJobItem else {
                return nil
            }
            item.configure(with: job)
            return item
        }

        dataSource.supplementaryViewProvider = { [weak dataSource] collectionView, kind, indexPath in
            guard kind == NSCollectionView.elementKindSectionHeader,
                  let dataSource,
                  let header = collectionView.makeSupplementaryView(
                    ofKind: kind,
                    withIdentifier: Identifier.sectionHeader,
                    for: indexPath
                  ) as? ReviewMonitorSectionHeaderView
            else {
                return nil
            }

            let snapshot = dataSource.snapshot()
            guard indexPath.section < snapshot.sectionIdentifiers.count else {
                return nil
            }
            let workspace = snapshot.sectionIdentifiers[indexPath.section]
            header.configure(
                title: workspace.displayTitle,
                toolTip: workspace.cwd
            )
            return header
        }

        return dataSource
    }

    private func bindObservation(store: CodexReviewStore) {
        storeObservationHandles.removeAll()
        rebindWorkspaceObservations(workspaces: store.workspaces)
        store.observe([\.workspaces]) { [weak self, weak store] in
            guard let self, let store else {
                return
            }
            self.rebindWorkspaceObservations(workspaces: store.workspaces)
            self.applyWorkspaceSnapshot(workspaces: store.workspaces)
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
                self.applyJobsSnapshot(for: workspace, allWorkspaces: store.workspaces)
            }
            .store(in: &workspaceObservationHandles)
        }
    }

    private func applyWorkspaceSnapshot(workspaces: [CodexReviewWorkspace]) {
        clearSelectionIfNeeded(for: workspaces)
        var snapshot = NSDiffableDataSourceSnapshot<CodexReviewWorkspace, CodexReviewJob>()

        for workspace in workspaces {
            snapshot.appendSections([workspace])
            snapshot.appendItems(workspace.jobs, toSection: workspace)
        }

        isApplyingSnapshot = true
        dataSource.apply(snapshot, animatingDifferences: view.window != nil) { [weak self] in
            guard let self else {
                return
            }
            self.isApplyingSnapshot = false
            self.reconcileSelectionAfterSnapshot()
        }
        updateEmptyState(itemCount: totalJobCount(in: workspaces))
    }

    private func applyJobsSnapshot(
        for workspace: CodexReviewWorkspace,
        allWorkspaces: [CodexReviewWorkspace]
    ) {
        clearSelectionIfNeeded(for: allWorkspaces)
        guard allWorkspaces.contains(workspace), workspace.jobs.isEmpty == false else {
            applyWorkspaceSnapshot(workspaces: allWorkspaces)
            return
        }

        var snapshot = dataSource.snapshot()
        guard snapshot.sectionIdentifiers.contains(workspace) else {
            applyWorkspaceSnapshot(workspaces: allWorkspaces)
            return
        }

        snapshot.deleteItems(snapshot.itemIdentifiers(inSection: workspace))
        snapshot.appendItems(workspace.jobs, toSection: workspace)

        isApplyingSnapshot = true
        dataSource.apply(snapshot, animatingDifferences: view.window != nil) { [weak self] in
            guard let self else {
                return
            }
            self.isApplyingSnapshot = false
            self.reconcileSelectionAfterSnapshot()
        }
        updateEmptyState(itemCount: totalJobCount(in: allWorkspaces))
    }

    private func reconcileSelectionAfterSnapshot() {
        guard let selectedJob = uiState.selectedJobEntry else {
            if collectionView.selectionIndexPaths.isEmpty == false {
                collectionView.deselectItems(at: collectionView.selectionIndexPaths)
            }
            return
        }

        guard containsJob(id: selectedJob.id) else {
            uiState.selectedJobEntry = nil
            collectionView.deselectItems(at: collectionView.selectionIndexPaths)
            return
        }

        guard let indexPath = indexPath(for: selectedJob) else {
            return
        }

        if let currentJob = job(at: indexPath), currentJob !== selectedJob {
            uiState.selectedJobEntry = currentJob
        }

        let selection = Set([indexPath])
        guard collectionView.selectionIndexPaths != selection else {
            return
        }
        collectionView.selectItems(at: selection, scrollPosition: [])
    }

    private func updateSelectedJobFromCollectionView() {
        guard isApplyingSnapshot == false else {
            return
        }
        guard let indexPath = collectionView.selectionIndexPaths.first else {
            uiState.selectedJobEntry = nil
            return
        }
        uiState.selectedJobEntry = job(at: indexPath)
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
        if collectionView.selectionIndexPaths.isEmpty == false {
            collectionView.deselectItems(at: collectionView.selectionIndexPaths)
        }
    }

    private func totalJobCount(in workspaces: [CodexReviewWorkspace]) -> Int {
        workspaces.reduce(into: 0) { $0 += $1.jobs.count }
    }

    private func job(at indexPath: IndexPath) -> CodexReviewJob? {
        let snapshot = dataSource.snapshot()
        guard indexPath.section < snapshot.sectionIdentifiers.count else {
            return nil
        }

        let section = snapshot.sectionIdentifiers[indexPath.section]
        let jobs = snapshot.itemIdentifiers(inSection: section)
        guard indexPath.item < jobs.count else {
            return nil
        }
        return jobs[indexPath.item]
    }

    private func indexPath(for job: CodexReviewJob) -> IndexPath? {
        let snapshot = dataSource.snapshot()
        for (sectionIndex, section) in snapshot.sectionIdentifiers.enumerated() {
            let jobs = snapshot.itemIdentifiers(inSection: section)
            guard let itemIndex = jobs.firstIndex(of: job) else {
                continue
            }
            return IndexPath(item: itemIndex, section: sectionIndex)
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
}

#if DEBUG
@MainActor
extension ReviewMonitorSidebarViewController {
    var displayedSectionTitlesForTesting: [String] {
        dataSource.snapshot().sectionIdentifiers.map(\.displayTitle)
    }

    var selectedJobForTesting: CodexReviewJob? {
        guard let indexPath = collectionView.selectionIndexPaths.first else {
            return nil
        }
        return job(at: indexPath)
    }

    var isShowingEmptyStateForTesting: Bool {
        emptyStateView.isHidden == false
    }

    func selectJobForTesting(_ job: CodexReviewJob) {
        guard let indexPath = indexPath(for: job) else {
            return
        }
        collectionView.selectItems(at: [indexPath], scrollPosition: [])
        uiState.selectedJobEntry = job
    }

    func clearSelectionForTesting() {
        collectionView.deselectItems(at: collectionView.selectionIndexPaths)
        uiState.selectedJobEntry = nil
    }
}
#endif

@MainActor
private final class ReviewMonitorJobItem: NSCollectionViewItem {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var observationHandles: Set<ObservationHandle> = []

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        updateSelectionAppearance()
    }

    override var isSelected: Bool {
        didSet {
            updateSelectionAppearance()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        observationHandles.removeAll()
    }

    func configure(with job: CodexReviewJob) {
        representedObject = job
        render(job)
        observationHandles.removeAll()
        job.observe(
            [
                \.targetSummary,
                \.status,
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
        view.wantsLayer = true
        view.layer?.cornerRadius = 6

        titleLabel.font = .preferredFont(forTextStyle: .body)
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6)
        ])
    }

    private func render(_ job: CodexReviewJob) {
        titleLabel.stringValue = job.displayTitle
        subtitleLabel.stringValue = "\(job.status.displayText) • \(job.sessionID) • \(job.cwd)"
        view.toolTip = job.cwd
    }

    private func updateSelectionAppearance() {
        view.layer?.backgroundColor = (
            isSelected ? NSColor.selectedContentBackgroundColor : .clear
        ).cgColor
        titleLabel.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
        subtitleLabel.textColor = isSelected ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }
}

@MainActor
private final class ReviewMonitorSectionHeaderView: NSView, NSCollectionViewElement {
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

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.stringValue = ""
        toolTip = nil
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
