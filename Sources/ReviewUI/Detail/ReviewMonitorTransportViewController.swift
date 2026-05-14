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

    private struct WorkspaceFindingEntry {
        var jobTargetSummary: String
        var title: String
        var body: String
        var locationText: String?

        var displayText: String {
            [
                title,
                body,
                locationText,
                jobTargetSummary,
            ]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: "\n")
        }
    }

    private let uiState: ReviewMonitorUIState
    private let logScrollView = ReviewMonitorLogScrollView()
    private let findingsScrollView = NSScrollView()
    private let findingsStackView = NSStackView()
    private let emptyStateView = ReviewMonitorViewFactory.makeEmptyStateView(
        title: "Select a workspace or review",
        description: "Choose a workspace or review from the list.",
        titleAccessibilityIdentifier: "review-monitor.detail-empty.title",
        descriptionAccessibilityIdentifier: "review-monitor.detail-empty.description"
    )
    private let noFindingsStateView = ReviewMonitorViewFactory.makeEmptyStateView(
        title: "No findings",
        description: "No structured review findings are available for this workspace.",
        titleAccessibilityIdentifier: "review-monitor.workspace-findings-empty.title",
        descriptionAccessibilityIdentifier: "review-monitor.workspace-findings-empty.description"
    )
    private var displayedContentConstraints: [NSLayoutConstraint] = []
    private let uiStateObservationScope = ObservationScope()
    private let selectedJobObservationScope = ObservationScope()
    private let selectedWorkspaceObservationScope = ObservationScope()
    private let selectedWorkspaceJobsObservationScope = ObservationScope()
    private var boundJob: CodexReviewJob?
    private var boundWorkspace: CodexReviewWorkspace?
    private var displayedSelection: DisplayedSelection?
    private var renderedWorkspaceFindingsText = ""
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
        updatePresentation(selection: uiState.selection)
    }

    private func configureHierarchy() {
        let safeArea = view.safeAreaLayoutGuide
        configureFindingsView()
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        noFindingsStateView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(logScrollView)
        view.addSubview(findingsScrollView)
        view.addSubview(emptyStateView)
        view.addSubview(noFindingsStateView)

        displayedContentConstraints = [
            logScrollView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            logScrollView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            logScrollView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            logScrollView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
        ]

        NSLayoutConstraint.activate(
            displayedContentConstraints
            + [
                findingsScrollView.topAnchor.constraint(equalTo: safeArea.topAnchor),
                findingsScrollView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
                findingsScrollView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
                findingsScrollView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),

                emptyStateView.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
                emptyStateView.centerYAnchor.constraint(equalTo: safeArea.centerYAnchor),
                emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: safeArea.leadingAnchor, constant: 24),
                emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: safeArea.trailingAnchor, constant: -24),

                noFindingsStateView.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
                noFindingsStateView.centerYAnchor.constraint(equalTo: safeArea.centerYAnchor),
                noFindingsStateView.leadingAnchor.constraint(greaterThanOrEqualTo: safeArea.leadingAnchor, constant: 24),
                noFindingsStateView.trailingAnchor.constraint(lessThanOrEqualTo: safeArea.trailingAnchor, constant: -24),
            ]
        )
    }

    private func configureFindingsView() {
        findingsScrollView.translatesAutoresizingMaskIntoConstraints = false
        findingsScrollView.drawsBackground = false
        findingsScrollView.borderType = .noBorder
        findingsScrollView.hasVerticalScroller = true
        findingsScrollView.autohidesScrollers = true

        findingsStackView.translatesAutoresizingMaskIntoConstraints = false
        findingsStackView.orientation = .vertical
        findingsStackView.alignment = .width
        findingsStackView.spacing = 12
        findingsStackView.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        findingsScrollView.documentView = findingsStackView

        NSLayoutConstraint.activate([
            findingsStackView.widthAnchor.constraint(equalTo: findingsScrollView.contentView.widthAnchor)
        ])
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
            noFindingsStateView.isHidden = true
            logScrollView.isHidden = false
            findingsScrollView.isHidden = true
            displayedSelection = .job(selectedJob.id)

        case .workspace(let selectedWorkspace):
            clearDisplayedJob()
            displayWorkspace(selectedWorkspace)
            emptyStateView.isHidden = true
            logScrollView.isHidden = true
            displayedSelection = .workspace(selectedWorkspace.cwd)

        case nil:
            clearDisplayedJob()
            clearDisplayedWorkspace()
            emptyStateView.isHidden = false
            noFindingsStateView.isHidden = true
            logScrollView.isHidden = true
            findingsScrollView.isHidden = true
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
        if renderedWorkspaceFindingsText.isEmpty == false {
            renderedWorkspaceFindingsText = ""
            removeFindingRows()
            noteRenderForTesting()
        } else {
            removeFindingRows()
        }
        findingsScrollView.isHidden = true
        noFindingsStateView.isHidden = true
    }

    private func bindWorkspaceObservation(_ workspace: CodexReviewWorkspace) {
        workspace.observe(\.jobs) { [weak self, weak workspace] _ in
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
            for job in workspace.jobs {
                job.observe([\.core, \.targetSummary]) { [weak self, weak workspace] in
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
        let nextText = entries.map(\.displayText).joined(separator: "\n\n")
        guard renderedWorkspaceFindingsText != nextText else {
            updateWorkspaceFindingsVisibility(hasFindings: entries.isEmpty == false)
            return false
        }

        renderedWorkspaceFindingsText = nextText
        removeFindingRows()
        for entry in entries {
            findingsStackView.addArrangedSubview(makeFindingRowView(entry))
        }
        updateWorkspaceFindingsVisibility(hasFindings: entries.isEmpty == false)
        return true
    }

    private func updateWorkspaceFindingsVisibility(hasFindings: Bool) {
        findingsScrollView.isHidden = hasFindings == false
        noFindingsStateView.isHidden = hasFindings
    }

    private func removeFindingRows() {
        for view in findingsStackView.arrangedSubviews {
            findingsStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func workspaceFindingEntries(for workspace: CodexReviewWorkspace) -> [WorkspaceFindingEntry] {
        workspace.jobs.flatMap { job -> [WorkspaceFindingEntry] in
            guard let result = job.core.output.reviewResult,
                  result.state == .hasFindings
            else {
                return []
            }
            return result.findings.map { finding in
                WorkspaceFindingEntry(
                    jobTargetSummary: job.targetSummary,
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

    private func makeFindingRowView(_ entry: WorkspaceFindingEntry) -> NSView {
        let titleLabel = NSTextField(wrappingLabelWithString: entry.title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.maximumNumberOfLines = 0

        let bodyLabel = NSTextField(wrappingLabelWithString: entry.body)
        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.maximumNumberOfLines = 0

        let metadata = [
            entry.locationText,
            entry.jobTargetSummary,
        ]
        .compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        .joined(separator: " | ")
        let metadataLabel = NSTextField(labelWithString: metadata)
        metadataLabel.font = .preferredFont(forTextStyle: .caption1)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingMiddle

        let stackView = NSStackView(views: [titleLabel, bodyLabel, metadataLabel])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.spacing = 4
        stackView.setAccessibilityIdentifier("review-monitor.workspace-finding-row")

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: container.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
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
        renderedWorkspaceFindingsText
    }

    var displayedSummaryForTesting: String? {
        nil
    }

    var isShowingEmptyStateForTesting: Bool {
        emptyStateView.isHidden == false
    }

    var isShowingNoFindingsStateForTesting: Bool {
        noFindingsStateView.isHidden == false
    }

    var isShowingWorkspaceFindingsListForTesting: Bool {
        findingsScrollView.isHidden == false
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

    var logOverlayScrollerHideRequestCountForTesting: Int {
        logScrollView.overlayScrollerHideRequestCountForTesting
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

    var workspaceFindingSnapshotForTesting: WorkspaceFindingSnapshotForTesting {
        .init(
            text: displayedWorkspaceFindingsForTesting,
            isShowingNoFindingsState: isShowingNoFindingsStateForTesting,
            isShowingFindingsList: isShowingWorkspaceFindingsListForTesting
        )
    }

    var workspaceFindingRowWidthsForTesting: [CGFloat] {
        view.layoutSubtreeIfNeeded()
        findingsStackView.layoutSubtreeIfNeeded()
        return findingsStackView.arrangedSubviews.map(\.frame.width)
    }

    var workspaceFindingsContentWidthForTesting: CGFloat {
        view.layoutSubtreeIfNeeded()
        return findingsScrollView.contentView.bounds.width
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
