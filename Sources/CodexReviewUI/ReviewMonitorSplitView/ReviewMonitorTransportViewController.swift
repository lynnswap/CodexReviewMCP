import AppKit
import ObservationBridge
import CodexReviewModel
import ReviewRuntime

@MainActor
final class ReviewMonitorTransportViewController: NSViewController {
    private let logScrollView = ReviewMonitorLogScrollView()
    private let uiState: ReviewMonitorUIState
    private let emptyStateView = ReviewMonitorViewFactory.makeEmptyStateView(
        title: "Select a job",
        description: "Choose a review from the list."
    )
    private var uiStateObservationHandles: Set<ObservationHandle> = []
    private var selectedJobObservationHandles: Set<ObservationHandle> = []
    private var boundJob: CodexReviewJob?
    private var showingEmptyState = true
    private var logScrollTargetsByJobID: [String: ReviewMonitorLogScrollView.ScrollRestorationTarget] = [:]
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
        bindSelectedJob(uiState.selectedJobEntry)
    }

    private func configureHierarchy() {
        let safeArea = view.safeAreaLayoutGuide

        view.addSubview(logScrollView)
        view.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            logScrollView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            logScrollView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            logScrollView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            logScrollView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),

            emptyStateView.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: safeArea.centerYAnchor),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: safeArea.leadingAnchor, constant: 24),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: safeArea.trailingAnchor, constant: -24)
        ])
    }

    private func bindObservation() {
        uiStateObservationHandles.removeAll()
        uiState.observe(\.selectedJobEntry) { [weak self] selectedJob in
            guard let self, self.isViewLoaded else {
                return
            }
            self.bindSelectedJob(selectedJob)
        }
        .store(in: &uiStateObservationHandles)
    }

    private func bindSelectedJob(_ selectedJob: CodexReviewJob?) {
        cacheBoundJobScrollTarget()
        selectedJobObservationHandles.removeAll()
        boundJob = selectedJob

        guard let selectedJob else {
            renderEmptyState()
            return
        }

        renderSelectedJob(
            selectedJob,
            restorationTarget: restorationTarget(selectedJob),
            allowIncrementalUpdate: false
        )

        selectedJob.observe(\.reviewMonitorLogText) { [weak self] text in
            guard let self else {
                return
            }
            let logChanged = self.renderBoundJobLog(text)
            if logChanged {
                self.noteRenderForTesting()
            }
        }
        .store(in: &selectedJobObservationHandles)
    }

    private func renderSelectedJob(
        _ job: CodexReviewJob,
        restorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget,
        allowIncrementalUpdate: Bool
    ) {
        let logChanged = renderSelectedJobLog(
            job.reviewMonitorLogText,
            restorationTarget: restorationTarget,
            allowIncrementalUpdate: allowIncrementalUpdate
        )
        if logChanged {
            noteRenderForTesting()
        }
    }

    @discardableResult
    private func renderSelectedJobLog(
        _ text: String,
        restorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget,
        allowIncrementalUpdate: Bool
    ) -> Bool {
        let visibilityChanged = showJobContentIfNeeded()
        if visibilityChanged {
            view.layoutSubtreeIfNeeded()
        }
        let logChanged = logScrollView.replaceText(
            text,
            restoring: restorationTarget,
            allowIncrementalUpdate: allowIncrementalUpdate
        )
        return visibilityChanged || logChanged
    }

    @discardableResult
    private func renderBoundJobLog(_ text: String) -> Bool {
        guard boundJob != nil else {
            return false
        }
        return renderSelectedJobLog(
            text,
            restorationTarget: logScrollView.currentScrollRestorationTarget,
            allowIncrementalUpdate: true
        )
    }

    @discardableResult
    private func showJobContentIfNeeded() -> Bool {
        guard showingEmptyState else {
            return false
        }

        logScrollView.isHidden = false
        emptyStateView.isHidden = true
        showingEmptyState = false
        return true
    }

    private func renderEmptyState() {
        let clearedLog = logScrollView.clear()
        let wasEmpty = showingEmptyState

        logScrollView.isHidden = true
        emptyStateView.isHidden = false
        showingEmptyState = true

        if wasEmpty == false || clearedLog {
            noteRenderForTesting()
        }
    }

    private func cacheBoundJobScrollTarget() {
        guard let boundJob, showingEmptyState == false else {
            return
        }
        logScrollTargetsByJobID[boundJob.id] = logScrollView.currentScrollRestorationTarget
    }

    private func restorationTarget(
        _ job: CodexReviewJob
    ) -> ReviewMonitorLogScrollView.ScrollRestorationTarget {
        return logScrollTargetsByJobID[job.id] ?? .bottom
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
        nil
    }

    var displayedLogForTesting: String {
        logScrollView.displayedTextForTesting
    }

    var displayedSummaryForTesting: String? {
        nil
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

    var logUsesTextKit1ForTesting: Bool {
        logScrollView.usesTextKit1ForTesting
    }

    var logIsEditableForTesting: Bool {
        logScrollView.isEditableForTesting
    }

    var logIsSelectableForTesting: Bool {
        logScrollView.isSelectableForTesting
    }

    var logWritingToolsDisabledForTesting: Bool {
        logScrollView.writingToolsDisabledForTesting
    }

    var logFrameForTesting: NSRect {
        logScrollView.frame
    }

    var safeAreaFrameForTesting: NSRect {
        view.safeAreaRect
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

    func scrollLogToOffsetForTesting(_ y: CGFloat) {
        logScrollView.scrollToOffsetForTesting(y)
    }

    var logVerticalScrollOffsetForTesting: CGFloat {
        logScrollView.verticalScrollOffsetForTesting
    }

    func scrollLogToBottomForTesting() {
        logScrollView.scrollToBottomForTesting()
    }

    var isLogPinnedToBottomForTesting: Bool {
        logScrollView.isPinnedToBottomForTesting
    }
}
#endif
