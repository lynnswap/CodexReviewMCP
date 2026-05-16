import AppKit
import ObservationBridge
import ReviewApplication
import ReviewDomain

@MainActor
final class ReviewMonitorTransportViewController: NSViewController {
    private enum DisplayedSelection: Equatable {
        case job(String)
        case workspace(String)
    }

    private let uiState: ReviewMonitorUIState
    private let store: CodexReviewStore
    private let logScrollView = ReviewMonitorLogScrollView()
    private let workspaceFindingsView = ReviewMonitorWorkspaceFindingsView()
    private let emptyStateView = ReviewMonitorViewFactory.makeEmptyStateView(
        title: "Select a workspace or review",
        description: "Choose a workspace or review from the list.",
        titleAccessibilityIdentifier: "review-monitor.detail-empty.title",
        descriptionAccessibilityIdentifier: "review-monitor.detail-empty.description"
    )
    private var displayedContentConstraints: [NSLayoutConstraint] = []
    private let uiStateObservationScope = ObservationScope()
    private let selectedJobObservationScope = ObservationScope()
    private let selectedWorkspaceObservationScope = ObservationScope()
    private let selectedWorkspaceJobsObservationScope = ObservationScope()
    private var boundJob: CodexReviewJob?
    private var boundWorkspace: CodexReviewWorkspace?
    private var displayedSelection: DisplayedSelection?
    private var logScrollTargetsByJobID: [String: ReviewMonitorLogScrollView.ScrollRestorationTarget] = [:]
#if DEBUG
    private var renderCountForTestingStorage = 0
    private var renderWaitersForTesting: [Int: [CheckedContinuation<Void, Never>]] = [:]
#endif

    init(store: CodexReviewStore, uiState: ReviewMonitorUIState) {
        self.store = store
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
        updatePresentation(selection: uiState.selection)
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard performDisplayedTextFinderAction(sender) else {
            super.performTextFinderAction(sender)
            return
        }
    }

    private func configureHierarchy() {
        let safeArea = view.safeAreaLayoutGuide
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(logScrollView)
        view.addSubview(workspaceFindingsView)
        view.addSubview(emptyStateView)

        displayedContentConstraints = [
            logScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            logScrollView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            logScrollView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            logScrollView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
        ]

        NSLayoutConstraint.activate(
            displayedContentConstraints
            + [
                workspaceFindingsView.topAnchor.constraint(equalTo: view.topAnchor),
                workspaceFindingsView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
                workspaceFindingsView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
                workspaceFindingsView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),

                emptyStateView.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
                emptyStateView.centerYAnchor.constraint(equalTo: safeArea.centerYAnchor),
                emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: safeArea.leadingAnchor, constant: 24),
                emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: safeArea.trailingAnchor, constant: -24),
            ]
        )
    }

    private func bindObservation() {
        uiStateObservationScope.cancelAll()
        uiState.observe(\.selection) { [weak self] selection in
            guard let self else {
                return
            }
            self.updatePresentation(selection: selection)
        }
        .store(in: uiStateObservationScope)
    }

    private func updatePresentation(selection: ReviewMonitorSelection?) {
        let previousSelection = displayedSelection
        switch selection {
        case .job(let selectedJob):
            clearDisplayedWorkspace()
            displayJob(selectedJob)
            emptyStateView.isHidden = true
            logScrollView.isHidden = false
            workspaceFindingsView.isHidden = true
            displayedSelection = .job(selectedJob.id)

        case .workspace(let selectedWorkspace):
            clearDisplayedJob()
            displayWorkspace(selectedWorkspace)
            emptyStateView.isHidden = true
            logScrollView.isHidden = true
            workspaceFindingsView.isHidden = false
            displayedSelection = .workspace(selectedWorkspace.cwd)

        case nil:
            clearDisplayedJob()
            clearDisplayedWorkspace()
            emptyStateView.isHidden = false
            logScrollView.isHidden = true
            workspaceFindingsView.isHidden = true
            displayedSelection = nil
        }

        if previousSelection != displayedSelection {
            noteRenderForTesting()
        }
    }

    private func displayJob(_ selectedJob: CodexReviewJob) {
        cacheBoundJobScrollTarget()
        selectedJobObservationScope.cancelAll()
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
        .store(in: selectedJobObservationScope)
    }

    private func clearDisplayedJob() {
        cacheBoundJobScrollTarget()
        selectedJobObservationScope.cancelAll()
        boundJob = nil
        if logScrollView.clear() {
            noteRenderForTesting()
        }
    }

    private func displayWorkspace(_ workspace: CodexReviewWorkspace) {
        if boundWorkspace !== workspace {
            selectedWorkspaceObservationScope.cancelAll()
            selectedWorkspaceJobsObservationScope.cancelAll()
            boundWorkspace = workspace
            bindWorkspaceObservation(workspace)
            bindWorkspaceJobObservations(workspace)
        }
        if renderWorkspaceFindings(workspace) {
            noteRenderForTesting()
        }
    }

    private func clearDisplayedWorkspace() {
        selectedWorkspaceObservationScope.cancelAll()
        selectedWorkspaceJobsObservationScope.cancelAll()
        boundWorkspace = nil
        if workspaceFindingsView.clear() {
            noteRenderForTesting()
        }
        workspaceFindingsView.isHidden = true
    }

    private func bindWorkspaceObservation(_ workspace: CodexReviewWorkspace) {
        store.observe([\.jobs]) { [weak self, weak workspace] in
            guard let self,
                  let workspace,
                  self.boundWorkspace === workspace
            else {
                return
            }
            self.bindWorkspaceJobObservations(workspace)
            if self.renderWorkspaceFindings(workspace) {
                self.noteRenderForTesting()
            }
        }
        .store(in: selectedWorkspaceObservationScope)
    }

    private func bindWorkspaceJobObservations(_ workspace: CodexReviewWorkspace) {
        selectedWorkspaceJobsObservationScope.update {
            for job in store.orderedJobs(in: workspace) {
                job.observe([\.core, \.targetSummary, \.sortOrder]) { [weak self, weak workspace] in
                    guard let self,
                          let workspace,
                          self.boundWorkspace === workspace
                    else {
                        return
                    }
                    if self.renderWorkspaceFindings(workspace) {
                        self.noteRenderForTesting()
                    }
                }
                .store(in: selectedWorkspaceJobsObservationScope)
            }
        }
    }

    @discardableResult
    private func renderWorkspaceFindings(_ workspace: CodexReviewWorkspace) -> Bool {
        let entries = workspaceFindingEntries(for: workspace)
        return workspaceFindingsView.render(entries: entries)
    }

    private func workspaceFindingEntries(
        for workspace: CodexReviewWorkspace
    ) -> [ReviewMonitorWorkspaceFindingsView.Entry] {
        store.orderedJobs(in: workspace).flatMap { job -> [ReviewMonitorWorkspaceFindingsView.Entry] in
            guard let result = job.core.output.reviewResult,
                  result.state == .hasFindings
            else {
                return []
            }
            let threadID = workspaceFindingThreadID(for: job)
            return result.findings.map { finding in
                ReviewMonitorWorkspaceFindingsView.Entry(
                    threadID: threadID,
                    targetSummary: job.targetSummary,
                    priority: finding.priority,
                    title: finding.title,
                    body: finding.body,
                    locationText: locationText(for: finding.location, in: workspace)
                )
            }
        }
    }

    private func locationText(
        for location: ParsedReviewFindingLocation?,
        in workspace: CodexReviewWorkspace
    ) -> String? {
        guard let location else {
            return nil
        }

        let workspacePrefix = workspace.cwd.hasSuffix("/") ? workspace.cwd : workspace.cwd + "/"
        let path: String
        if location.path.hasPrefix(workspacePrefix) {
            path = String(location.path.dropFirst(workspacePrefix.count))
        } else {
            path = location.path
        }
        return "\(path):\(location.startLine)-\(location.endLine)"
    }

    private func workspaceFindingThreadID(for job: CodexReviewJob) -> String {
        if let reviewThreadID = nonEmptyID(job.core.run.reviewThreadID) {
            return reviewThreadID
        }
        if let threadID = nonEmptyID(job.core.run.threadID) {
            return threadID
        }
        return job.id
    }

    private func nonEmptyID(_ id: String?) -> String? {
        guard let id else {
            return nil
        }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

    @discardableResult
    func performDisplayedTextFinderAction(_ sender: Any?) -> Bool {
        switch displayedSelection {
        case .job:
            return logScrollView.performDisplayedTextFinderAction(sender)
        case .workspace:
            return workspaceFindingsView.performDisplayedTextFinderAction(sender)
        case nil:
            return false
        }
    }

    func validateDisplayedTextFinderAction(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch displayedSelection {
        case .job:
            return logScrollView.validateDisplayedTextFinderAction(item)
        case .workspace:
            return workspaceFindingsView.validateDisplayedTextFinderAction(item)
        case nil:
            return false
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

    struct WorkspaceFindingSnapshotForTesting: Equatable {
        let text: String
        let isShowingNoFindingsState: Bool
        let isShowingFindingsList: Bool
    }

    var displayedTitleForTesting: String? {
        nil
    }

    var displayedLogForTesting: String {
        logScrollView.displayedTextForTesting
    }

    var displayedWorkspaceFindingsForTesting: String {
        workspaceFindingsView.displayedTextForTesting
    }

    var displayedSummaryForTesting: String? {
        nil
    }

    var isShowingEmptyStateForTesting: Bool {
        emptyStateView.isHidden == false
    }

    var isShowingNoFindingsStateForTesting: Bool {
        workspaceFindingsView.isShowingNoFindingsStateForTesting
    }

    var isShowingWorkspaceFindingsListForTesting: Bool {
        workspaceFindingsView.isShowingFindingsListForTesting
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

    var logUsesFindBarForTesting: Bool {
        logScrollView.usesFindBarForTesting
    }

    var logIsIncrementalSearchingEnabledForTesting: Bool {
        logScrollView.isIncrementalSearchingEnabledForTesting
    }

    var logFindBarVisibleForTesting: Bool {
        logScrollView.isFindBarVisibleForTesting
    }

    var logWritingToolsDisabledForTesting: Bool {
        logScrollView.writingToolsDisabledForTesting
    }

    var logOverlayScrollerHideRequestCountForTesting: Int {
        logScrollView.overlayScrollerHideRequestCountForTesting
    }

    var logFrameForTesting: NSRect {
        logScrollView.frame
    }

    var viewFrameForTesting: NSRect {
        view.frame
    }

    var viewBoundsForTesting: NSRect {
        view.bounds
    }

    var safeAreaFrameForTesting: NSRect {
        view.safeAreaRect
    }

    var displayedViewFrameForTesting: NSRect {
        logScrollView.frame
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

    var workspaceFindingSnapshotForTesting: WorkspaceFindingSnapshotForTesting {
        .init(
            text: displayedWorkspaceFindingsForTesting,
            isShowingNoFindingsState: isShowingNoFindingsStateForTesting,
            isShowingFindingsList: isShowingWorkspaceFindingsListForTesting
        )
    }

    var workspaceFindingsContentWidthForTesting: CGFloat {
        view.layoutSubtreeIfNeeded()
        return workspaceFindingsView.contentWidthForTesting
    }

    var workspaceFindingsFrameForTesting: NSRect {
        workspaceFindingsView.frame
    }

    var workspaceFindingsTextContainerWidthForTesting: CGFloat {
        view.layoutSubtreeIfNeeded()
        return workspaceFindingsView.textContainerWidthForTesting
    }

    var workspaceFindingsScrollFrameForTesting: NSRect {
        workspaceFindingsView.scrollFrameForTesting
    }

    var workspaceFindingsDocumentFrameForTesting: NSRect {
        workspaceFindingsView.documentFrameForTesting
    }

    var workspaceFindingsContentInsetsForTesting: NSEdgeInsets {
        workspaceFindingsView.contentInsetsForTesting
    }

    var workspaceFindingsVerticalScrollOffsetForTesting: CGFloat {
        workspaceFindingsView.verticalScrollOffsetForTesting
    }

    var workspaceFindingsMinimumVerticalScrollOffsetForTesting: CGFloat {
        workspaceFindingsView.minimumVerticalScrollOffsetForTesting
    }

    var workspaceFindingsMaximumVerticalScrollOffsetForTesting: CGFloat {
        workspaceFindingsView.maximumVerticalScrollOffsetForTesting
    }

    var workspaceFindingsAutomaticallyAdjustsContentInsetsForTesting: Bool {
        workspaceFindingsView.automaticallyAdjustsContentInsetsForTesting
    }

    var workspaceFindingsTextIsSelectableForTesting: Bool {
        workspaceFindingsView.isTextSelectableForTesting
    }

    var workspaceFindingsTextIsEditableForTesting: Bool {
        workspaceFindingsView.isTextEditableForTesting
    }

    var workspaceFindingsUsesFindBarForTesting: Bool {
        workspaceFindingsView.usesFindBarForTesting
    }

    var workspaceFindingsIsIncrementalSearchingEnabledForTesting: Bool {
        workspaceFindingsView.isIncrementalSearchingEnabledForTesting
    }

    var workspaceFindingsFindBarVisibleForTesting: Bool {
        workspaceFindingsView.isFindBarVisibleForTesting
    }

    var workspaceFindingsPriorityPrefixCountForTesting: Int {
        workspaceFindingsView.priorityPrefixCountForTesting
    }

    var workspaceFindingsTextAttachmentCountForTesting: Int {
        workspaceFindingsView.textAttachmentCountForTesting
    }

    var workspaceFindingsThreadBackgroundRangeCountForTesting: Int {
        workspaceFindingsView.threadBackgroundRangeCountForTesting
    }

    var workspaceFindingsAccessibilityValueForTesting: String? {
        workspaceFindingsView.accessibilityValueForTesting
    }

    var workspaceFindingsRenderedStorageStringForTesting: String {
        workspaceFindingsView.renderedStorageStringForTesting
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

    var logMinimumVerticalScrollOffsetForTesting: CGFloat {
        logScrollView.minimumVerticalScrollOffsetForTesting
    }

    var logMaximumVerticalScrollOffsetForTesting: CGFloat {
        logScrollView.maximumVerticalScrollOffsetForTesting
    }

    var logTextViewFrameForTesting: NSRect {
        logScrollView.textViewFrameForTesting
    }

    var logDocumentViewFrameForTesting: NSRect {
        logScrollView.documentViewFrameForTesting
    }

    var logContentInsetsForTesting: NSEdgeInsets {
        logScrollView.contentInsetsForTesting
    }

    var logAutomaticallyAdjustsContentInsetsForTesting: Bool {
        logScrollView.automaticallyAdjustsContentInsetsForTesting
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

    func setLogScrollerStyleForTesting(_ style: NSScroller.Style) {
        logScrollView.setScrollerStyleForTesting(style)
    }

    func setLogOverlayScrollersShownForTesting(_ isShown: Bool?) {
        logScrollView.setOverlayScrollersShownForTesting(isShown)
    }

    func setLogOverlayScrollerBridgeModeForTesting(
        _ mode: ReviewMonitorLogScrollView.OverlayScrollerBridgeModeForTesting
    ) {
        logScrollView.setOverlayScrollerBridgeModeForTesting(mode)
    }
}
#endif
