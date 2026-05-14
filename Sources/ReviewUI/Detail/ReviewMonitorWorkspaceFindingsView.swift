import AppKit

@MainActor
final class ReviewMonitorWorkspaceFindingsView: NSView {
    struct Entry {
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

    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let noFindingsStateView = ReviewMonitorViewFactory.makeEmptyStateView(
        title: "No findings",
        description: "No structured review findings are available for this workspace.",
        titleAccessibilityIdentifier: "review-monitor.workspace-findings-empty.title",
        descriptionAccessibilityIdentifier: "review-monitor.workspace-findings-empty.description"
    )
    private var displayedText = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    @discardableResult
    func render(entries: [Entry]) -> Bool {
        let nextText = entries.map(\.displayText).joined(separator: "\n\n")
        guard displayedText != nextText else {
            updateVisibility(hasFindings: entries.isEmpty == false)
            return false
        }

        displayedText = nextText
        replaceRows(with: entries)
        updateVisibility(hasFindings: entries.isEmpty == false)
        return true
    }

    @discardableResult
    func clear() -> Bool {
        let changed = displayedText.isEmpty == false
            || scrollView.isHidden == false
            || noFindingsStateView.isHidden == false
        displayedText = ""
        removeRows()
        scrollView.isHidden = true
        noFindingsStateView.isHidden = true
        return changed
    }

    private func configureHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.spacing = 12
        stackView.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        scrollView.documentView = stackView

        noFindingsStateView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(noFindingsStateView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            noFindingsStateView.centerXAnchor.constraint(equalTo: centerXAnchor),
            noFindingsStateView.centerYAnchor.constraint(equalTo: centerYAnchor),
            noFindingsStateView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            noFindingsStateView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])

        clear()
    }

    private func replaceRows(with entries: [Entry]) {
        removeRows()
        for entry in entries {
            stackView.addArrangedSubview(ReviewMonitorWorkspaceFindingRowView(entry: entry))
        }
    }

    private func removeRows() {
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func updateVisibility(hasFindings: Bool) {
        scrollView.isHidden = hasFindings == false
        noFindingsStateView.isHidden = hasFindings
    }
}

@MainActor
private final class ReviewMonitorWorkspaceFindingRowView: NSView {
    private let stackView = NSStackView()

    init(entry: ReviewMonitorWorkspaceFindingsView.Entry) {
        super.init(frame: .zero)
        configureHierarchy(entry: entry)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func configureHierarchy(entry: ReviewMonitorWorkspaceFindingsView.Entry) {
        translatesAutoresizingMaskIntoConstraints = false

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

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.spacing = 4
        stackView.setViews([titleLabel, bodyLabel, metadataLabel], in: .top)
        stackView.setAccessibilityIdentifier("review-monitor.workspace-finding-row")

        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorWorkspaceFindingsView {
    var displayedTextForTesting: String {
        displayedText
    }

    var isShowingNoFindingsStateForTesting: Bool {
        noFindingsStateView.isHidden == false
    }

    var isShowingFindingsListForTesting: Bool {
        scrollView.isHidden == false
    }

    var rowWidthsForTesting: [CGFloat] {
        layoutSubtreeIfNeeded()
        stackView.layoutSubtreeIfNeeded()
        return stackView.arrangedSubviews.map(\.frame.width)
    }

    var contentWidthForTesting: CGFloat {
        layoutSubtreeIfNeeded()
        return scrollView.contentView.bounds.width
    }
}
#endif
