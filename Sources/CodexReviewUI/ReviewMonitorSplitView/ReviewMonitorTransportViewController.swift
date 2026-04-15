import AppKit
import ObservationBridge
import CodexReviewModel
import ReviewRuntime

@MainActor
final class ReviewMonitorTransportViewController: NSViewController {
    private let uiState: ReviewMonitorUIState
    private let logScrollView = ReviewMonitorLogScrollView()
    private let emptyStateView = ReviewMonitorViewFactory.makeEmptyStateView(
        title: "Select a job",
        description: "Choose a review from the list.",
        titleAccessibilityIdentifier: "review-monitor.detail-empty.title",
        descriptionAccessibilityIdentifier: "review-monitor.detail-empty.description"
    )
    private var displayedContentConstraints: [NSLayoutConstraint] = []
    private var uiStateObservationHandles: Set<ObservationHandle> = []
    private var selectedJobObservationHandles: Set<ObservationHandle> = []
    private var boundJob: CodexReviewJob?
    private var logScrollTargetsByJobID: [String: ReviewMonitorLogScrollView.ScrollRestorationTarget] = [:]
#if DEBUG
    private var renderCountForTestingStorage = 0
    private var renderWaitersForTesting: [Int: [CheckedContinuation<Void, Never>]] = [:]
#endif

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
        bindObservation()
        updatePresentation(selectedJob: uiState.selectedJobEntry)
    }

    private func configureHierarchy() {
        let safeArea = view.safeAreaLayoutGuide
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(logScrollView)
        view.addSubview(emptyStateView)

        displayedContentConstraints = [
            logScrollView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            logScrollView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            logScrollView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            logScrollView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
        ]

        NSLayoutConstraint.activate(
            displayedContentConstraints
            + [
                emptyStateView.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
                emptyStateView.centerYAnchor.constraint(equalTo: safeArea.centerYAnchor),
                emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: safeArea.leadingAnchor, constant: 24),
                emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: safeArea.trailingAnchor, constant: -24),
            ]
        )
    }

    private func bindObservation() {
        uiStateObservationHandles.removeAll()
        uiState.observe(\.selectedJobEntry) { [weak self] selectedJob in
            guard let self else {
                return
            }
            self.updatePresentation(selectedJob: selectedJob)
        }
        .store(in: &uiStateObservationHandles)
    }

    private func updatePresentation(selectedJob: CodexReviewJob?) {
        let previousJobID = boundJob?.id
        let wasShowingEmptyState = emptyStateView.isHidden == false
        if let selectedJob {
            displayJob(selectedJob)
            emptyStateView.isHidden = true
            logScrollView.isHidden = false
        } else {
            clearDisplayedJob()
            emptyStateView.isHidden = false
            logScrollView.isHidden = true
        }

        let nextJobID = selectedJob?.id
        let isShowingEmptyState = selectedJob == nil
        if previousJobID != nextJobID || wasShowingEmptyState != isShowingEmptyState {
            noteRenderForTesting()
        }
    }

    private func displayJob(_ selectedJob: CodexReviewJob) {
        cacheBoundJobScrollTarget()
        selectedJobObservationHandles.removeAll()
        boundJob = selectedJob

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

    private func clearDisplayedJob() {
        cacheBoundJobScrollTarget()
        selectedJobObservationHandles.removeAll()
        boundJob = nil
        if logScrollView.clear() {
            noteRenderForTesting()
        }
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
        logScrollView.replaceText(
            text,
            restoring: restorationTarget,
            allowIncrementalUpdate: allowIncrementalUpdate
        )
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

    private func cacheBoundJobScrollTarget() {
        guard let boundJob else {
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

    var viewFrameForTesting: NSRect {
        view.frame
    }

    var safeAreaFrameForTesting: NSRect {
        view.safeAreaRect
    }

    var displayedViewFrameForTesting: NSRect {
        view.safeAreaRect
    }

    var activeDisplayedViewConstraintCountForTesting: Int {
        displayedContentConstraints.filter(\.isActive).count
    }

    var renderSnapshotForTesting: RenderSnapshotForTesting {
        if isShowingEmptyStateForTesting {
            return .init(
                title: nil,
                summary: nil,
                log: "",
                isShowingEmptyState: true
            )
        }
        return .init(
            title: displayedTitleForTesting,
            summary: displayedSummaryForTesting,
            log: displayedLogForTesting,
            isShowingEmptyState: false
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

    var logTextViewFrameForTesting: NSRect {
        logScrollView.textViewFrameForTesting
    }

    var logDocumentViewFrameForTesting: NSRect {
        logScrollView.documentViewFrameForTesting
    }

    var logTextContainerSizeForTesting: NSSize {
        logScrollView.textContainerSizeForTesting
    }

    var logTextContainerInsetForTesting: NSSize {
        logScrollView.textContainerInsetForTesting
    }

    func scrollLogToBottomForTesting() {
        logScrollView.scrollToBottomForTesting()
    }

    var isLogPinnedToBottomForTesting: Bool {
        logScrollView.isPinnedToBottomForTesting
    }
}
#endif
