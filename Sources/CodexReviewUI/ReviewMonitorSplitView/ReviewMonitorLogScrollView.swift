import AppKit
import ReviewRuntime

@MainActor
final class ReviewMonitorLogScrollView: NSScrollView {
    enum ScrollRestorationTarget: Equatable {
        case top
        case offset(CGFloat)
        case bottom
    }

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
        textView.autoresizingMask = [.width]

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
        textView.textContainerInset = NSSize(width: 4, height: 6)
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
        updateTextViewGeometry()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func tile() {
        let shouldPreserveBottom = displayedText.isEmpty == false && isPinnedToBottom()
        super.tile()
        updateTextViewGeometry()
        if shouldPreserveBottom {
            scrollToBottom(countAsAutoFollow: false)
        }
    }

    @discardableResult
    func clear() -> Bool {
        applyReload("", restoring: .top, countBottomRestoreAsAutoFollow: false)
    }

    @discardableResult
    func replaceText(
        _ text: String,
        restoring restorationTarget: ScrollRestorationTarget,
        allowIncrementalUpdate: Bool
    ) -> Bool {
        if allowIncrementalUpdate, let suffix = appendedSuffix(for: text) {
            return applyAppend(suffix)
        }
        return applyReload(text, restoring: restorationTarget, countBottomRestoreAsAutoFollow: false)
    }

    @discardableResult
    private func applyAppend(_ suffix: String) -> Bool {
        guard suffix.isEmpty == false else {
            return false
        }

        let shouldAutoFollow = isPinnedToBottom()
        appendToTextStorage(suffix)
        displayedText += suffix
        updateTextViewGeometry()
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
    private func applyReload(
        _ text: String,
        restoring restorationTarget: ScrollRestorationTarget,
        countBottomRestoreAsAutoFollow: Bool
    ) -> Bool {
        if displayedText == text {
            let previousOrigin = contentView.bounds.origin
            restoreScrollPosition(restorationTarget, countAsAutoFollow: countBottomRestoreAsAutoFollow)
            return contentView.bounds.origin != previousOrigin
        }

        replaceAllText(with: text)
        displayedText = text
        updateTextViewGeometry()
        layoutSubtreeIfNeeded()
#if DEBUG
        reloadCount += 1
#endif
        restoreScrollPosition(restorationTarget, countAsAutoFollow: countBottomRestoreAsAutoFollow)
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

    private func appendedSuffix(for text: String) -> String? {
        guard text.count > displayedText.count,
              text.hasPrefix(displayedText)
        else {
            return nil
        }
        let suffixStart = text.index(text.startIndex, offsetBy: displayedText.count)
        return String(text[suffixStart...])
    }

    private func updateTextViewGeometry() {
        let targetWidth = max(1, contentView.bounds.width)
        if abs(textView.frame.width - targetWidth) > 0.5 {
            textView.setFrameSize(NSSize(width: targetWidth, height: textView.frame.height))
        }

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let textHeight = ceil(usedRect.height + textView.textContainerInset.height * 2)
        let targetHeight = max(contentView.bounds.height, textHeight)
        if abs(textView.frame.height - targetHeight) > 0.5 {
            textView.setFrameSize(NSSize(width: textView.frame.width, height: targetHeight))
        }
    }

    private func scrollToBottom(countAsAutoFollow: Bool) {
        restoreScrollOrigin(NSPoint(x: 0, y: maximumVerticalScrollOffset()))
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

    private func restoreScrollPosition(
        _ restorationTarget: ScrollRestorationTarget,
        countAsAutoFollow: Bool
    ) {
        switch restorationTarget {
        case .top:
            restoreScrollOrigin(.zero)
        case .offset(let y):
            restoreScrollOrigin(NSPoint(x: 0, y: y))
        case .bottom:
            scrollToBottom(countAsAutoFollow: countAsAutoFollow)
        }
    }

    var currentScrollRestorationTarget: ScrollRestorationTarget {
        guard displayedText.isEmpty == false else {
            return .top
        }

        let maxOffset = maximumVerticalScrollOffset()
        guard maxOffset > 0 else {
            return .top
        }

        let offset = contentView.bounds.origin.y
        if abs(offset - maxOffset) < 0.5 {
            return .bottom
        }

        return offset > 0 ? .offset(offset) : .top
    }

    private func maximumVerticalScrollOffset() -> CGFloat {
        guard let documentView else {
            return 0
        }
        return max(0, documentView.frame.height - contentView.bounds.height)
    }

    private func isPinnedToBottom() -> Bool {
        let maxOffset = maximumVerticalScrollOffset()
        guard maxOffset > 0 else {
            return true
        }
        return maxOffset - contentView.bounds.origin.y < 24
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

    func scrollToOffsetForTesting(_ y: CGFloat) {
        restoreScrollOrigin(NSPoint(x: 0, y: y))
    }

    var verticalScrollOffsetForTesting: CGFloat {
        contentView.bounds.origin.y
    }

    var textViewFrameForTesting: NSRect {
        textView.frame
    }

    var documentViewFrameForTesting: NSRect {
        textView.frame
    }

    func scrollToBottomForTesting() {
        scrollToBottom(countAsAutoFollow: false)
    }
}
#endif
