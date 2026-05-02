import AppKit
import ObjectiveC.runtime
import ReviewApplication
import ReviewDomain

@MainActor
final class ReviewMonitorLogScrollView: NSScrollView {
    private static let scrollerImpPairSelector = NSSelectorFromString("scrollerImpPair")
    private static let overlayScrollersShownSelector = NSSelectorFromString("overlayScrollersShown")
    private static let hideOverlayScrollersSelector = NSSelectorFromString("hideOverlayScrollers")
    private static let beginHideOverlayScrollersSelector = NSSelectorFromString("_beginHideOverlayScrollers")

    private typealias ObjectGetter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    private typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
    private typealias VoidMethod = @convention(c) (AnyObject, Selector) -> Void

    private final class DocumentContainerView: NSView {
        var measuredTextHeight: @MainActor () -> CGFloat = { 0 }

        override var isFlipped: Bool {
            true
        }

        override var intrinsicContentSize: NSSize {
            NSSize(
                width: NSView.noIntrinsicMetric,
                height: measuredTextHeight()
            )
        }
    }

    enum ScrollRestorationTarget: Equatable {
        case top
        case offset(CGFloat)
        case bottom
    }

#if DEBUG
    enum OverlayScrollerBridgeModeForTesting {
        case live
        case missingScrollerImpPair
        case missingOverlayScrollersShown
        case missingHideMethods
    }
#endif

    private let documentContainerView = DocumentContainerView()
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
    private(set) var overlayScrollerHideRequestCount = 0
    private var overlayScrollersShownOverrideForTesting: Bool?
    private var overlayScrollerBridgeModeForTesting: OverlayScrollerBridgeModeForTesting = .live
#endif

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.allowsNonContiguousLayout = true

        let textView = NSTextView(frame: NSRect.zero, textContainer: textContainer)
        textView.minSize = NSSize.zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.translatesAutoresizingMaskIntoConstraints = false

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

        documentContainerView.translatesAutoresizingMaskIntoConstraints = false
        documentContainerView.measuredTextHeight = { [weak self] in
            self?.measuredTextHeight() ?? 0
        }
        documentContainerView.addSubview(textView)
        documentView = documentContainerView
        NSLayoutConstraint.activate([
            documentContainerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            documentContainerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            documentContainerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            documentContainerView.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            documentContainerView.heightAnchor.constraint(greaterThanOrEqualTo: contentView.heightAnchor),
            textView.topAnchor.constraint(equalTo: documentContainerView.topAnchor),
            textView.leadingAnchor.constraint(equalTo: documentContainerView.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: documentContainerView.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: documentContainerView.bottomAnchor),
        ])
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
        invalidateDocumentLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func tile() {
        let shouldPreserveBottom = displayedText.isEmpty == false && isPinnedToBottom()
        super.tile()
        syncTextContainerWidthToTextView()
        invalidateDocumentLayout()
        if shouldPreserveBottom {
            scrollToBottom(countAsAutoFollow: false)
        }
    }

    override func layout() {
        super.layout()
        syncTextContainerWidthToTextView()
        invalidateDocumentLayout()
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
        syncTextContainerWidthToTextView()
        invalidateDocumentLayout()
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
            syncTextContainerWidthToTextView()
            invalidateDocumentLayout()
            restoreScrollPosition(restorationTarget, countAsAutoFollow: countBottomRestoreAsAutoFollow)
            return contentView.bounds.origin != previousOrigin
        }

        replaceAllText(with: text)
        displayedText = text
        syncTextContainerWidthToTextView()
        invalidateDocumentLayout()
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

    private func invalidateDocumentLayout() {
        documentContainerView.invalidateIntrinsicContentSize()
    }

    @discardableResult
    private func syncTextContainerWidthToTextView() -> Bool {
        let targetWidth = max(0, textView.bounds.width - textView.textContainerInset.width * 2)
        let targetSize = NSSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
        guard abs(textContainer.containerSize.width - targetSize.width) > 0.5 ||
              textContainer.containerSize.height != targetSize.height
        else {
            return false
        }

        textContainer.containerSize = targetSize
        if storage.length > 0 {
            let fullRange = NSRange(location: 0, length: storage.length)
            layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: fullRange)
        }
        documentContainerView.invalidateIntrinsicContentSize()
        return true
    }

    private func measuredTextHeight() -> CGFloat {
        syncTextContainerWidthToTextView()
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return ceil(usedRect.height + textView.textContainerInset.height * 2)
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
        hideOverlayScrollerAfterProgrammaticScrollIfNeeded()
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

    private func hideOverlayScrollerAfterProgrammaticScrollIfNeeded() {
        guard scrollerStyle == .overlay,
              maximumVerticalScrollOffset() > 0.5,
              let scrollerImpPair = scrollerImpPairForOverlayControl(),
              overlayScrollersShown(on: scrollerImpPair) == true,
              requestOverlayScrollersHide(on: scrollerImpPair)
        else {
            return
        }

#if DEBUG
        overlayScrollerHideRequestCount += 1
#endif
    }

    private func scrollerImpPairForOverlayControl() -> NSObject? {
#if DEBUG
        if overlayScrollerBridgeModeForTesting == .missingScrollerImpPair {
            return nil
        }
#endif
        return objectValue(for: Self.scrollerImpPairSelector, on: self)
    }

    private func overlayScrollersShown(on scrollerImpPair: NSObject) -> Bool? {
#if DEBUG
        if let overlayScrollersShownOverrideForTesting {
            return overlayScrollersShownOverrideForTesting
        }
        if overlayScrollerBridgeModeForTesting == .missingOverlayScrollersShown {
            return nil
        }
#endif
        return boolValue(for: Self.overlayScrollersShownSelector, on: scrollerImpPair)
    }

    private func requestOverlayScrollersHide(on scrollerImpPair: NSObject) -> Bool {
#if DEBUG
        if overlayScrollerBridgeModeForTesting == .missingHideMethods {
            return false
        }
#endif
        if invokeVoidSelector(Self.hideOverlayScrollersSelector, on: scrollerImpPair) {
            return true
        }
        return invokeVoidSelector(Self.beginHideOverlayScrollersSelector, on: scrollerImpPair)
    }

    private func objectValue(for selector: Selector, on object: NSObject) -> NSObject? {
        guard let method = resolvedMethod(for: selector, on: object) else {
            return nil
        }
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: ObjectGetter.self)
        return function(object, selector)?.takeUnretainedValue() as? NSObject
    }

    private func boolValue(for selector: Selector, on object: NSObject) -> Bool? {
        guard let method = resolvedMethod(for: selector, on: object) else {
            return nil
        }
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: BoolGetter.self)
        return function(object, selector)
    }

    private func invokeVoidSelector(_ selector: Selector, on object: NSObject) -> Bool {
        guard let method = resolvedMethod(for: selector, on: object) else {
            return false
        }
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: VoidMethod.self)
        function(object, selector)
        return true
    }

    private func resolvedMethod(for selector: Selector, on object: NSObject) -> Method? {
        guard object.responds(to: selector) else {
            return nil
        }
        return class_getInstanceMethod(type(of: object), selector)
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
        documentContainerView.frame
    }

    var textContainerSizeForTesting: NSSize {
        syncTextContainerWidthToTextView()
        return textContainer.containerSize
    }

    var textContainerInsetForTesting: NSSize {
        textView.textContainerInset
    }

    func scrollToBottomForTesting() {
        scrollToBottom(countAsAutoFollow: false)
    }

    var overlayScrollerHideRequestCountForTesting: Int {
        overlayScrollerHideRequestCount
    }

    func setScrollerStyleForTesting(_ style: NSScroller.Style) {
        scrollerStyle = style
    }

    func setOverlayScrollersShownForTesting(_ isShown: Bool?) {
        overlayScrollersShownOverrideForTesting = isShown
    }

    func setOverlayScrollerBridgeModeForTesting(_ mode: OverlayScrollerBridgeModeForTesting) {
        overlayScrollerBridgeModeForTesting = mode
    }
}
#endif
