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
    private var selectedJobObservationHandles: Set<ObservationHandle> = []

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
        titleLabel.isHidden = true
        metadataStack.isHidden = true
        summaryLabel.isHidden = true
        sectionTitleLabel.isHidden = true
        logScrollView.isHidden = true
        emptyStateView.isHidden = false
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
        uiState.selectedJobEntry?.observe(\.targetSummary) { [weak self] newValue in
            guard let self else {
                return
            }
            let hasSelection = self.uiState.selectedJobEntry != nil
            self.titleLabel.isHidden = hasSelection == false
            self.metadataStack.isHidden = hasSelection == false
            self.summaryLabel.isHidden = hasSelection == false
            self.sectionTitleLabel.isHidden = hasSelection == false
            self.logScrollView.isHidden = hasSelection == false
            self.emptyStateView.isHidden = hasSelection
            self.titleLabel.stringValue = newValue
            if hasSelection == false {
                self.statusLabel.stringValue = ""
                self.cwdLabel.stringValue = ""
                self.modelLabel.stringValue = ""
                self.threadLabel.stringValue = ""
                self.turnLabel.stringValue = ""
                self.summaryLabel.stringValue = ""
                self.logScrollView.clear()
            }
        }
        .store(in: &selectedJobObservationHandles)
        uiState.selectedJobEntry?.observe(\.status) { [weak self] newValue in
            guard let self else {
                return
            }
            self.statusLabel.stringValue = "Status: \(newValue.displayText)"
        }
        .store(in: &selectedJobObservationHandles)
        uiState.selectedJobEntry?.observe(\.cwd) { [weak self] newValue in
            guard let self else {
                return
            }
            self.cwdLabel.stringValue = "CWD: \(newValue)"
        }
        .store(in: &selectedJobObservationHandles)
        uiState.selectedJobEntry?.observe(\.model) { [weak self] newValue in
            guard let self else {
                return
            }
            self.modelLabel.stringValue = newValue.map { "Model: \($0)" } ?? ""
        }
        .store(in: &selectedJobObservationHandles)
        uiState.selectedJobEntry?.observe(\.summary) { [weak self] newValue in
            guard let self else {
                return
            }
            self.summaryLabel.isHidden = newValue.isEmpty
            self.summaryLabel.stringValue = newValue
        }
        .store(in: &selectedJobObservationHandles)
        uiState.selectedJobEntry?.observe(\.threadID) { [weak self] newValue in
            guard let self else {
                return
            }
            self.threadLabel.stringValue = newValue.map { "Thread: \($0)" } ?? ""
        }
        .store(in: &selectedJobObservationHandles)
        uiState.selectedJobEntry?.observe(\.turnID) { [weak self] newValue in
            guard let self else {
                return
            }
            self.turnLabel.stringValue = newValue.map { "Turn: \($0)" } ?? ""
        }
        .store(in: &selectedJobObservationHandles)
        uiState.selectedJobEntry?.observe(\.reviewEntries) { [weak self] newValue in
            guard let self else {
                return
            }
            self.logScrollView.setText(newValue.map(\.text).joined(separator: "\n\n"))
        }
        .store(in: &selectedJobObservationHandles)
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorTransportViewController {
    var displayedTitleForTesting: String? {
        titleLabel.isHidden ? nil : titleLabel.stringValue
    }

    var displayedActivityLogForTesting: String {
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
