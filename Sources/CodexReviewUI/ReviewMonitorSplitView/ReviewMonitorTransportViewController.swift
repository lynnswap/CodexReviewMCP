import AppKit
import ObservationBridge
import CodexReviewModel
import ReviewRuntime

@MainActor
final class ReviewMonitorTransportViewController: NSViewController {
    private let headerStack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "Select a job")
    private let metadataStack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let cwdLabel = NSTextField(labelWithString: "")
    private let modelLabel = NSTextField(labelWithString: "")
    private let threadLabel = NSTextField(labelWithString: "")
    private let turnLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let sectionTitleLabel = NSTextField(labelWithString: "Review Log")
    private let logScrollView = ReviewMonitorLogScrollView()
    private let uiState: ReviewMonitorUIState
    private let emptyStateView = ReviewMonitorViewFactory.makeEmptyStateView(
        title: "Select a job",
        description: "Choose a review from the list."
    )
    private var uiStateObservationHandles: Set<ObservationHandle> = []
    private var selectedJobObservationHandles: Set<ObservationHandle> = []
    private var selectedJobObservationGeneration: UInt64 = 0
    private var showingEmptyState = true
#if DEBUG
    private var renderCountForTestingStorage = 0
    private var renderWaitersForTesting: [Int: [CheckedContinuation<Void, Never>]] = [:]
#endif

    init(uiState: ReviewMonitorUIState) {
        self.uiState = uiState
        super.init(nibName: nil, bundle: nil)
        bindObservation()
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
        if let selectedJob = uiState.selectedJobEntry {
            bindSelectedJob(selectedJob)
        } else {
            renderEmptyState()
        }
    }

    private func configureHierarchy() {
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 6

        titleLabel.font = .preferredFont(forTextStyle: .title3)
        metadataStack.orientation = .vertical
        metadataStack.alignment = .leading
        metadataStack.spacing = 2
        summaryLabel.font = .preferredFont(forTextStyle: .body)
        summaryLabel.textColor = .secondaryLabelColor
        sectionTitleLabel.font = .preferredFont(forTextStyle: .headline)
        sectionTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        for label in [statusLabel, cwdLabel, modelLabel, threadLabel, turnLabel] {
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = .secondaryLabelColor
            metadataStack.addArrangedSubview(label)
        }

        view.addSubview(headerStack)
        view.addSubview(sectionTitleLabel)
        view.addSubview(logScrollView)
        view.addSubview(emptyStateView)

        headerStack.addArrangedSubview(titleLabel)
        headerStack.addArrangedSubview(metadataStack)
        headerStack.addArrangedSubview(summaryLabel)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            sectionTitleLabel.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            sectionTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            sectionTitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            logScrollView.topAnchor.constraint(equalTo: sectionTitleLabel.bottomAnchor, constant: 8),
            logScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            logScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            logScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),

            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    private func bindObservation() {
        uiStateObservationHandles.removeAll()
        uiState.observe(\.selectedJobEntry) { [weak self] selectedJob in
            self?.bindSelectedJob(selectedJob)
        }
        .store(in: &uiStateObservationHandles)
    }

    private func bindSelectedJob(_ selectedJob: CodexReviewJob?) {
        selectedJobObservationGeneration &+= 1
        selectedJobObservationHandles.removeAll()

        guard let selectedJob else {
            renderEmptyState()
            return
        }

        let generation = selectedJobObservationGeneration
        renderSelectedJob(selectedJob)

        selectedJob.observe(
            [
                \.targetSummary,
                \.status,
                \.model,
                \.summary,
                \.threadID,
                \.turnID,
            ]
        ) { [weak self, weak selectedJob] in
            guard let self,
                  let selectedJob,
                  self.selectedJobObservationGeneration == generation
            else {
                return
            }
            if self.renderMetadata(selectedJob) {
                self.noteRenderForTesting()
            }
        }
        .store(in: &selectedJobObservationHandles)

        selectedJob.observe(\.reviewMonitorRevision) { [weak self, weak selectedJob] _ in
            guard let self,
                  let selectedJob,
                  self.selectedJobObservationGeneration == generation
            else {
                return
            }
            if self.renderLogUpdate(selectedJob.lastMonitorUpdate) {
                self.noteRenderForTesting()
            }
        }
        .store(in: &selectedJobObservationHandles)
    }

    private func renderSelectedJob(_ job: CodexReviewJob) {
        let metadataChanged = renderMetadata(job)
        let logChanged = renderLogUpdate(.reload(job.reviewMonitorLogText))
        if metadataChanged || logChanged {
            noteRenderForTesting()
        }
    }

    @discardableResult
    private func renderMetadata(_ job: CodexReviewJob) -> Bool {
        var didChange = showJobContentIfNeeded()

        let title = job.displayTitle
        if titleLabel.stringValue != title {
            titleLabel.stringValue = title
            didChange = true
        }

        let status = "Status: \(job.status.displayText)"
        if statusLabel.stringValue != status {
            statusLabel.stringValue = status
            didChange = true
        }

        let cwd = "CWD: \(job.cwd)"
        if cwdLabel.stringValue != cwd {
            cwdLabel.stringValue = cwd
            didChange = true
        }

        let model = job.model.map { "Model: \($0)" } ?? ""
        if modelLabel.stringValue != model {
            modelLabel.stringValue = model
            didChange = true
        }

        let thread = job.threadID.map { "Thread: \($0)" } ?? ""
        if threadLabel.stringValue != thread {
            threadLabel.stringValue = thread
            didChange = true
        }

        let turn = job.turnID.map { "Turn: \($0)" } ?? ""
        if turnLabel.stringValue != turn {
            turnLabel.stringValue = turn
            didChange = true
        }

        if summaryLabel.stringValue != job.summary {
            summaryLabel.stringValue = job.summary
            didChange = true
        }
        let summaryHidden = job.summary.isEmpty
        if summaryLabel.isHidden != summaryHidden {
            summaryLabel.isHidden = summaryHidden
            didChange = true
        }

        return didChange
    }

    @discardableResult
    private func renderLogUpdate(_ update: ReviewMonitorLogUpdate) -> Bool {
        let visibilityChanged = showJobContentIfNeeded()
        let logChanged = logScrollView.apply(update: update)
        return visibilityChanged || logChanged
    }

    @discardableResult
    private func showJobContentIfNeeded() -> Bool {
        guard showingEmptyState else {
            return false
        }

        titleLabel.isHidden = false
        metadataStack.isHidden = false
        sectionTitleLabel.isHidden = false
        logScrollView.isHidden = false
        emptyStateView.isHidden = true
        showingEmptyState = false
        return true
    }

    private func renderEmptyState() {
        let clearedLog = logScrollView.clear()
        let wasEmpty = showingEmptyState

        titleLabel.stringValue = ""
        statusLabel.stringValue = ""
        cwdLabel.stringValue = ""
        modelLabel.stringValue = ""
        threadLabel.stringValue = ""
        turnLabel.stringValue = ""
        summaryLabel.stringValue = ""

        titleLabel.isHidden = true
        metadataStack.isHidden = true
        summaryLabel.isHidden = true
        sectionTitleLabel.isHidden = true
        logScrollView.isHidden = true
        emptyStateView.isHidden = false
        showingEmptyState = true

        if wasEmpty == false || clearedLog {
            noteRenderForTesting()
        }
    }

    private func noteRenderForTesting() {
#if DEBUG
        renderCountForTestingStorage += 1
        let readyCounts = renderWaitersForTesting.keys.filter { $0 <= renderCountForTestingStorage }
        for count in readyCounts {
            let continuations = renderWaitersForTesting.removeValue(forKey: count) ?? []
            for continuation in continuations {
                continuation.resume()
            }
        }
#endif
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorTransportViewController {
    struct RenderSnapshotForTesting: Equatable {
        let title: String?
        let summary: String?
        let log: String
        let isShowingEmptyState: Bool
    }

    var displayedTitleForTesting: String? {
        titleLabel.isHidden ? nil : titleLabel.stringValue
    }

    var displayedLogForTesting: String {
        logScrollView.displayedTextForTesting
    }

    var displayedSummaryForTesting: String? {
        summaryLabel.isHidden ? nil : summaryLabel.stringValue
    }

    var isShowingEmptyStateForTesting: Bool {
        emptyStateView.isHidden == false
    }

    var renderCountForTesting: Int {
        renderCountForTestingStorage
    }

    var logAppendCountForTesting: Int {
        logScrollView.appendCount
    }

    var logReloadCountForTesting: Int {
        logScrollView.reloadCount
    }

    var logAutoFollowCountForTesting: Int {
        logScrollView.autoFollowCount
    }

    var renderSnapshotForTesting: RenderSnapshotForTesting {
        .init(
            title: displayedTitleForTesting,
            summary: displayedSummaryForTesting,
            log: displayedLogForTesting,
            isShowingEmptyState: isShowingEmptyStateForTesting
        )
    }

    func waitForRenderCountForTesting(_ targetCount: Int) async {
        if renderCountForTestingStorage >= targetCount {
            return
        }
        await withCheckedContinuation { continuation in
            if renderCountForTestingStorage >= targetCount {
                continuation.resume()
                return
            }
            renderWaitersForTesting[targetCount, default: []].append(continuation)
        }
    }

    func flushMainQueueForTesting() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    func scrollLogToTopForTesting() {
        logScrollView.scrollToTopForTesting()
    }

    func scrollLogToBottomForTesting() {
        logScrollView.scrollToBottomForTesting()
    }

    var isLogPinnedToBottomForTesting: Bool {
        logScrollView.isPinnedToBottomForTesting
    }
}
#endif
