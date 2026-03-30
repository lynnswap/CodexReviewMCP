import AppKit
import CodexReviewMCP
import ReviewJobs

@MainActor
func reviewMonitorMetadataText(for job: CodexReviewJob) -> String {
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
        description: "Choose a running or recent review from the list."
    )
    private var uiStateObservationHandles: Set<ObservationHandle> = []
    private var selectedJobObservationHandles: Set<ObservationHandle> = []
    private var selectedJobObservationGeneration: UInt64 = 0

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
        renderEmptyState()
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
                \.cwd,
                \.model,
                \.summary,
                \.threadID,
                \.turnID,
                \.logEntries,
            ]
        ) { [weak self, weak selectedJob] in
            guard let self, let selectedJob,
                  self.selectedJobObservationGeneration == generation
            else {
                return
            }
            self.renderSelectedJob(selectedJob)
        }
        .store(in: &selectedJobObservationHandles)
    }

    private func renderSelectedJob(_ job: CodexReviewJob) {
        titleLabel.stringValue = job.displayTitle
        statusLabel.stringValue = "Status: \(job.status.displayText)"
        cwdLabel.stringValue = "CWD: \(job.cwd)"
        modelLabel.stringValue = job.model.map { "Model: \($0)" } ?? ""
        threadLabel.stringValue = job.threadID.map { "Thread: \($0)" } ?? ""
        turnLabel.stringValue = job.turnID.map { "Turn: \($0)" } ?? ""
        summaryLabel.stringValue = job.summary
        summaryLabel.isHidden = job.summary.isEmpty
        logScrollView.setText(job.logText)

        titleLabel.isHidden = false
        metadataStack.isHidden = false
        sectionTitleLabel.isHidden = false
        logScrollView.isHidden = false
        emptyStateView.isHidden = true
    }

    private func renderEmptyState() {
        titleLabel.stringValue = ""
        statusLabel.stringValue = ""
        cwdLabel.stringValue = ""
        modelLabel.stringValue = ""
        threadLabel.stringValue = ""
        turnLabel.stringValue = ""
        summaryLabel.stringValue = ""
        logScrollView.clear()

        titleLabel.isHidden = true
        metadataStack.isHidden = true
        summaryLabel.isHidden = true
        sectionTitleLabel.isHidden = true
        logScrollView.isHidden = true
        emptyStateView.isHidden = false
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorTransportViewController {
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
}
#endif
