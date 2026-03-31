import AppKit

@MainActor
enum ReviewMonitorViewFactory {
    static func makeEmptyStateView(title: String, description: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .preferredFont(forTextStyle: .title3)
        titleLabel.alignment = .center

        let descriptionLabel = NSTextField(wrappingLabelWithString: description)
        descriptionLabel.font = .preferredFont(forTextStyle: .body)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.alignment = .center
        descriptionLabel.maximumNumberOfLines = 0

        let stackView = NSStackView(views: [titleLabel, descriptionLabel])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 8
        return stackView
    }
}
