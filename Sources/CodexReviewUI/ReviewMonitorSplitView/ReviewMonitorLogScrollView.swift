import AppKit
import ReviewRuntime

@MainActor
final class ReviewMonitorLogScrollView: NSScrollView {
    let textView: NSTextView
    private var displayedText = ""
    private let baseFont = NSFont.monospacedSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize,
        weight: .regular
    )
    private var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: NSColor.textColor,
        ]
    }

#if DEBUG
    private(set) var appendCount = 0
    private(set) var reloadCount = 0
    private(set) var autoFollowCount = 0
#endif

    init() {
        let scrollableTextView = NSTextView.scrollablePlainDocumentContentTextView()
        guard let textView = scrollableTextView.documentView as? NSTextView else {
            fatalError("Expected NSTextView.scrollablePlainDocumentContentTextView() document view to be NSTextView")
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
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = false
        textView.enabledTextCheckingTypes = 0
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.textColor = .textColor
        textView.typingAttributes = baseAttributes
        textView.setAccessibilityIdentifier("review-monitor.activity-log")
        textView.font = baseFont
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    @discardableResult
    func apply(update: ReviewMonitorLogUpdate) -> Bool {
        switch update {
        case .append(let suffix):
            applyAppend(suffix)
        case .reload(let text):
            applyReload(text)
        }
    }

    @discardableResult
    func clear() -> Bool {
        apply(update: .reload(""))
    }

    @discardableResult
    private func applyAppend(_ suffix: String) -> Bool {
        guard suffix.isEmpty == false else {
            return false
        }

        let shouldAutoFollow = isPinnedToBottom()
        appendToTextStorage(suffix)
        displayedText += suffix
#if DEBUG
        appendCount += 1
#endif
        if shouldAutoFollow {
            scrollTailRangeToVisible()
        }
        return true
    }

    @discardableResult
    private func applyReload(_ text: String) -> Bool {
        guard displayedText != text else {
            return false
        }

        let shouldAutoFollow = isPinnedToBottom()
        let preservedOrigin = contentView.bounds.origin
        replaceAllText(with: text)
        displayedText = text
#if DEBUG
        reloadCount += 1
#endif
        if shouldAutoFollow {
            scrollTailRangeToVisible()
        } else {
            restoreScrollOrigin(preservedOrigin)
        }
        return true
    }

    private func appendToTextStorage(_ suffix: String) {
        guard let textStorage = textView.textStorage else {
            textView.string += suffix
            return
        }

        textStorage.beginEditing()
        textStorage.replaceCharacters(
            in: NSRange(location: textStorage.length, length: 0),
            with: NSAttributedString(string: suffix, attributes: baseAttributes)
        )
        textStorage.endEditing()
    }

    private func replaceAllText(with text: String) {
        guard let textStorage = textView.textStorage else {
            textView.string = text
            return
        }

        textStorage.beginEditing()
        textStorage.replaceCharacters(
            in: NSRange(location: 0, length: textStorage.length),
            with: NSAttributedString(string: text, attributes: baseAttributes)
        )
        textStorage.endEditing()
    }

    private func scrollTailRangeToVisible() {
        let location = textView.string.utf16.count
        textView.scrollRangeToVisible(NSRange(location: location, length: 0))
#if DEBUG
        autoFollowCount += 1
#endif
    }

    private func restoreScrollOrigin(_ origin: NSPoint) {
        guard let documentView else {
            return
        }
        let maxY = max(0, documentView.frame.height - contentView.bounds.height)
        let clampedOrigin = NSPoint(
            x: 0,
            y: min(max(0, origin.y), maxY)
        )
        contentView.scroll(to: clampedOrigin)
        reflectScrolledClipView(contentView)
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
        displayedText
    }

    var isPinnedToBottomForTesting: Bool {
        isPinnedToBottom()
    }

    func scrollToTopForTesting() {
        restoreScrollOrigin(.zero)
    }

    func scrollToBottomForTesting() {
        scrollTailRangeToVisible()
    }
}
#endif
