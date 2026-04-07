import AppKit
import ReviewRuntime

@MainActor
final class ReviewMonitorLogScrollView: NSScrollView {
    let textView: NSTextView
    private let storage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private let textContainer: NSTextContainer
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
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.allowsNonContiguousLayout = true

        let textView = NSTextView(frame: NSRect.zero, textContainer: textContainer)
        textView.minSize = NSSize.zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = NSView.AutoresizingMask(arrayLiteral: .width)

        self.storage = storage
        self.layoutManager = layoutManager
        self.textContainer = textContainer
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
        textView.usesRuler = false
        textView.usesInspectorBar = false
        textView.drawsBackground = false
        textView.textColor = NSColor.textColor
        textView.typingAttributes = baseAttributes
        textView.writingToolsBehavior = NSWritingToolsBehavior.none
        textView.setAccessibilityIdentifier("review-monitor.activity-log")
        textView.font = baseFont
        updateDocumentGeometry()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        let shouldPreserveBottom = displayedText.isEmpty == false && isPinnedToBottom()
        super.layout()
        updateDocumentGeometry()
        if shouldPreserveBottom {
            scrollToBottom(countAsAutoFollow: false)
        }
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
        updateDocumentGeometry()
        layoutSubtreeIfNeeded()
#if DEBUG
        appendCount += 1
#endif
        if shouldAutoFollow {
            scrollToBottom(countAsAutoFollow: true)
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
        updateDocumentGeometry()
        layoutSubtreeIfNeeded()
#if DEBUG
        reloadCount += 1
#endif
        if shouldAutoFollow {
            scrollToBottom(countAsAutoFollow: true)
        } else {
            restoreScrollOrigin(preservedOrigin)
        }
        return true
    }

    private func appendToTextStorage(_ suffix: String) {
        storage.beginEditing()
        storage.replaceCharacters(
            in: NSRange(location: storage.length, length: 0),
            with: NSAttributedString(string: suffix, attributes: baseAttributes)
        )
        storage.endEditing()
    }

    private func replaceAllText(with text: String) {
        storage.beginEditing()
        storage.replaceCharacters(
            in: NSRange(location: 0, length: storage.length),
            with: NSAttributedString(string: text, attributes: baseAttributes)
        )
        storage.endEditing()
    }

    private func updateDocumentGeometry() {
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let targetSize = NSSize(
            width: max(0, contentSize.width),
            height: max(contentSize.height, ceil(usedRect.height + textView.textContainerInset.height * 2))
        )

        if textView.frame.size != targetSize {
            textView.frame = NSRect(origin: .zero, size: targetSize)
        }
    }

    private func scrollToBottom(countAsAutoFollow: Bool) {
        guard let documentView else {
            return
        }
        let maxY = max(0, documentView.frame.height - contentView.bounds.height)
        let targetOrigin = contentView.constrainBoundsRect(
            NSRect(origin: NSPoint(x: 0, y: maxY), size: contentView.bounds.size)
        ).origin
        contentView.scroll(to: targetOrigin)
        reflectScrolledClipView(contentView)
#if DEBUG
        if countAsAutoFollow {
            autoFollowCount += 1
        }
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

    var usesTextKit1ForTesting: Bool {
        textView.textLayoutManager == nil
    }

    var isEditableForTesting: Bool {
        textView.isEditable
    }

    var isSelectableForTesting: Bool {
        textView.isSelectable
    }

    var writingToolsDisabledForTesting: Bool {
        textView.writingToolsBehavior == .none
    }

    var isPinnedToBottomForTesting: Bool {
        isPinnedToBottom()
    }

    func scrollToTopForTesting() {
        restoreScrollOrigin(.zero)
    }

    func scrollToBottomForTesting() {
        scrollToBottom(countAsAutoFollow: false)
    }
}
#endif
