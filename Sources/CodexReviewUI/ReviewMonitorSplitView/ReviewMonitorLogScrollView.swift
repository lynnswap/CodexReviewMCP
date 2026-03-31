import AppKit

@MainActor
final class ReviewMonitorLogScrollView: NSScrollView {
    let textView: NSTextView

    init() {
        let scrollableTextView = NSTextView.scrollableTextView()
        guard let textView = scrollableTextView.documentView as? NSTextView else {
            fatalError("Expected NSTextView.scrollableTextView() document view to be NSTextView")
        }
        self.textView = textView
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        documentView = textView

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.setAccessibilityIdentifier("review-monitor.activity-log")
        textView.font = .monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize,
            weight: .regular
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func setText(_ text: String) {
        let shouldStickToBottom = isPinnedToBottom()
        if textView.string != text {
            textView.string = text
        }
        if shouldStickToBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    func clear() {
        setText("")
    }

    private func isPinnedToBottom() -> Bool {
        guard let documentView else {
            return true
        }
        let visibleMaxY = contentView.bounds.maxY
        let documentMaxY = documentView.frame.maxY
        return documentMaxY - visibleMaxY < 24
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorLogScrollView {
    var displayedTextForTesting: String {
        textView.string
    }
}
#endif
