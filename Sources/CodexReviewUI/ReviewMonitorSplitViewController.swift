import AppKit
import CodexReviewModel
import Foundation
import ObservationBridge
import ReviewRuntime
import ReviewDomain

@MainActor
final class ReviewMonitorSplitViewController: NSSplitViewController, NSToolbarDelegate {
    private static let autosaveName = NSSplitView.AutosaveName("CodexReviewMCP.ReviewMonitorSplitView")
    private static let addAccountToolbarItemIdentifier = NSToolbarItem.Identifier(
        "CodexReviewMCP.ReviewMonitor.Toolbar.AddAccount"
    )

    private let store: CodexReviewStore
    private let uiState: ReviewMonitorUIState
    private var sidebarViewController: ReviewMonitorSidebarViewController?
    private var transportViewController: ReviewMonitorTransportViewController?
    private var sidebarItem: NSSplitViewItem?
    private var contentItem: NSSplitViewItem?
    private var toolbar: NSToolbar?
    private var addAccountToolbarView: AddAccountToolbarItemView?
    private var observationHandles: Set<ObservationHandle> = []
    private var sidebarCollapseObservation: NSKeyValueObservation?
    private weak var attachedWindow: NSWindow?

    init(store: CodexReviewStore, uiState: ReviewMonitorUIState = ReviewMonitorUIState()) {
        self.store = store
        self.uiState = uiState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarViewController = ReviewMonitorSidebarViewController(
            store: store,
            uiState: uiState
        )
        let transportViewController = ReviewMonitorTransportViewController(uiState: uiState)
        let sidebarSegmentedAccessoryViewController = ReviewMonitorSidebarSegmentedAccessoryViewController(
            uiState: uiState
        )
        let statusAccessoryViewController = ReviewMonitorServerStatusAccessoryViewController(
            store: store,
            uiState: uiState
        )
        if #available(macOS 26.1, *) {
            sidebarSegmentedAccessoryViewController.preferredScrollEdgeEffectStyle = .soft
            statusAccessoryViewController.preferredScrollEdgeEffectStyle = .soft
        }
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.minimumThickness = 220
        sidebarItem.preferredThicknessFraction = 0.22
        sidebarItem.titlebarSeparatorStyle = .none
        sidebarItem.addTopAlignedAccessoryViewController(sidebarSegmentedAccessoryViewController)
        sidebarItem.addBottomAlignedAccessoryViewController(statusAccessoryViewController)

        let contentItem = NSSplitViewItem(viewController: transportViewController)
        contentItem.minimumThickness = 300
        contentItem.automaticallyAdjustsSafeAreaInsets = true

        self.sidebarViewController = sidebarViewController
        self.transportViewController = transportViewController
        self.sidebarItem = sidebarItem
        self.contentItem = contentItem
        sidebarCollapseObservation = sidebarItem.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.updateAddAccountToolbarItemVisibility()
            }
        }

        sidebarViewController.loadViewIfNeeded()
        transportViewController.loadViewIfNeeded()
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
    }

    func attach(to window: NSWindow) {
        loadViewIfNeeded()
        guard attachedWindow !== window else {
            return
        }

        attachedWindow = window
        // macOS 26 applies NSSplitView autosave reliably only after the split view is in a window.
        splitView.identifier = NSUserInterfaceItemIdentifier(Self.autosaveName)
        splitView.autosaveName = Self.autosaveName
        installToolbarIfNeeded(on: window)
        bindJobEntry(to: window)
    }

    func detachFromWindow() {
        observationHandles.removeAll()
        attachedWindow = nil
    }

    private func bindJobEntry(to window: NSWindow) {
        observationHandles.removeAll()

        if let selectedJob = uiState.selectedJobEntry {
            window.title = selectedJob.targetSummary
            window.subtitle = selectedJob.cwd
        } else {
            window.subtitle = ""
        }

        uiState.observe(\.selectedJobEntry?.targetSummary) { [weak window] targetSummary in
            guard let window else {
                return
            }
            window.title = targetSummary ?? ""
        }
        .store(in: &observationHandles)

        uiState.observe(\.selectedJobEntry?.cwd) { [weak window] cwd in
            guard let window else {
                return
            }
            window.subtitle = cwd ?? ""
        }
        .store(in: &observationHandles)

        uiState.observe(\.sidebarSelection) { [weak self] _ in
            self?.updateAddAccountToolbarItemVisibility()
        }
        .store(in: &observationHandles)

        store.auth.observe(\.phase) { [weak self] _ in
            self?.updateAddAccountToolbarItemVisibility()
        }
        .store(in: &observationHandles)
    }

    private func installToolbarIfNeeded(on window: NSWindow) {
        if toolbar == nil {
            let toolbar = NSToolbar(identifier: "CodexReviewMCP.ReviewMonitor.Toolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
            self.toolbar = toolbar
        }

        if window.toolbar !== toolbar {
            window.styleMask.insert(.fullSizeContentView)
            window.toolbarStyle = .unified
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .automatic
            window.toolbar = toolbar
        }

        updateAddAccountToolbarItemVisibility()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .flexibleSpace,
            Self.addAccountToolbarItemIdentifier,
            .sidebarTrackingSeparator,
            .flexibleSpace,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            Self.addAccountToolbarItemIdentifier,
            .sidebarTrackingSeparator,
            .space,
            .flexibleSpace,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .toggleSidebar:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.autovalidates = true
            return item

        case Self.addAccountToolbarItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = resolvedAddAccountToolbarView()
            item.menuFormRepresentation = resolvedAddAccountToolbarMenuItem()
            item.visibilityPriority = .high
            item.isHidden = shouldHideAddAccountToolbarItem
            return item

        case .sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitView,
                dividerIndex: 0
            )

        default:
            return nil
        }
    }

    private func performAddAccountToolbarItemAction() {
        ReviewMonitorAddAccountAction.perform(store: store)
    }

    private func cancelAddAccountToolbarItemAction() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.store.auth.cancelAuthentication()
        }
    }

    @objc
    private func performAddAccountToolbarOverflowAction(_ sender: Any?) {
        _ = sender
        if store.auth.isAuthenticating {
            cancelAddAccountToolbarItemAction()
        } else {
            performAddAccountToolbarItemAction()
        }
    }

    private func resolvedAddAccountToolbarView() -> AddAccountToolbarItemView {
        if let addAccountToolbarView {
            return addAccountToolbarView
        }

        let view = AddAccountToolbarItemView(
            store: store,
            onAddAccount: { [weak self] in
                self?.performAddAccountToolbarItemAction()
            },
            onCancel: { [weak self] in
                self?.cancelAddAccountToolbarItemAction()
            }
        )
        addAccountToolbarView = view
        return view
    }

    private func resolvedAddAccountToolbarMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: store.auth.isAuthenticating ? "Cancel Sign-In" : "Add Account",
            action: #selector(performAddAccountToolbarOverflowAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }

    private func updateAddAccountToolbarItemVisibility() {
        guard let toolbar else {
            return
        }

        guard let item = toolbar.items.first(where: { $0.itemIdentifier == Self.addAccountToolbarItemIdentifier }) else {
            return
        }
        item.menuFormRepresentation = resolvedAddAccountToolbarMenuItem()
        item.isHidden = shouldHideAddAccountToolbarItem
    }

    private var shouldHideAddAccountToolbarItem: Bool {
        if store.auth.isAuthenticating {
            return false
        }
        return uiState.sidebarSelection != .account || sidebarItem?.isCollapsed != false
    }
}

@MainActor
private final class AddAccountToolbarItemView: NSView {
    enum Mode: Equatable {
        case add
        case progress
    }

#if DEBUG
    private struct StableModeWaiterForTesting {
        let mode: Mode
        let continuation: CheckedContinuation<Void, Never>
    }
#endif

    private let store: CodexReviewStore
    private let auth: CodexReviewAuthModel
    private let onAddAccount: @MainActor () -> Void
    private let onCancel: @MainActor () -> Void
    private var observationHandles: Set<ObservationHandle> = []
    private var displayedMode: Mode = .add
    private var pendingMode: Mode?
    private var isAnimatingModeTransition = false

    private let rootStackView = NSStackView()
    private let addButton = NSButton()
    private let progressButton = AddAccountToolbarProgressButton()

#if DEBUG
    private var stableModeWaitersForTesting: [UUID: StableModeWaiterForTesting] = [:]
#endif

    var mode: Mode {
        auth.isAuthenticating ? .progress : .add
    }

    init(
        store: CodexReviewStore,
        onAddAccount: @escaping @MainActor () -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.store = store
        auth = store.auth
        self.onAddAccount = onAddAccount
        self.onCancel = onCancel
        super.init(frame: .zero)
        configureHierarchy()
        startObservingAuth()
        updateForAuthState(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        rootStackView.fittingSize
    }

    private func configureHierarchy() {
        addButton.bezelStyle = .toolbar
        addButton.image = NSImage(
            systemSymbolName: "person.badge.plus",
            accessibilityDescription: "Add Account"
        )
        addButton.imagePosition = .imageOnly
        addButton.setButtonType(.momentaryPushIn)
        addButton.target = self
        addButton.action = #selector(handleAddAccount)
        addButton.toolTip = "Add Account"
        addButton.setAccessibilityLabel("Add Account")

        progressButton.target = self
        progressButton.action = #selector(handleCancel)

        rootStackView.orientation = .horizontal
        rootStackView.alignment = .centerY
        rootStackView.translatesAutoresizingMaskIntoConstraints = false
        rootStackView.addArrangedSubview(addButton)
        rootStackView.addArrangedSubview(progressButton)
        addSubview(rootStackView)

        NSLayoutConstraint.activate([
            rootStackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStackView.topAnchor.constraint(equalTo: topAnchor),
            rootStackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func startObservingAuth() {
        guard observationHandles.isEmpty else {
            updateForAuthState(animated: false)
            return
        }

        auth.observe(\.phase) { [weak self] _ in
            self?.updateForAuthState(animated: true)
        }
        .store(in: &observationHandles)
    }

    private func updateForAuthState(animated: Bool) {
        let targetMode = mode
        let detail = auth.progress?.detail
        toolTip = nil
        progressButton.toolTip = targetMode == .progress ? "Cancel sign-in" : nil
        progressButton.setProgressDetailToolTip(detail)

        guard targetMode != displayedMode else {
            if isAnimatingModeTransition {
                pendingMode = targetMode
                return
            }
            pendingMode = nil
            applyMode(targetMode)
            return
        }

        pendingMode = targetMode
        guard animated, window != nil else {
            pendingMode = nil
            alphaValue = 1
            applyMode(targetMode)
            return
        }

        guard isAnimatingModeTransition == false else {
            return
        }

        animateModeTransition(to: targetMode)
    }

    private func applyMode(_ mode: Mode) {
        displayedMode = mode
        if pendingMode == mode {
            pendingMode = nil
        }
        let isAuthenticating = mode == .progress
        addButton.isHidden = isAuthenticating
        progressButton.isHidden = isAuthenticating == false

        if isAuthenticating {
            progressButton.startProgressAnimation()
        } else {
            progressButton.stopProgressAnimation()
        }

        invalidateIntrinsicContentSize()
        needsLayout = true
        notifyStableModeWaitersForTestingIfNeeded()
    }

    private func animateModeTransition(to targetMode: Mode) {
        isAnimatingModeTransition = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            MainActor.assumeIsolated {
                animator().alphaValue = 0
            }
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.applyMode(targetMode)
                self.alphaValue = 0

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    context.allowsImplicitAnimation = true
                    MainActor.assumeIsolated {
                        self.animator().alphaValue = 1
                    }
                } completionHandler: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else {
                            return
                        }

                        self.isAnimatingModeTransition = false
                        if let pendingMode = self.pendingMode,
                           pendingMode != self.displayedMode
                        {
                            self.animateModeTransition(to: pendingMode)
                            return
                        }
                        self.notifyStableModeWaitersForTestingIfNeeded()
                    }
                }
            }
        }
    }

    @objc
    private func handleAddAccount() {
        onAddAccount()
    }

    @objc
    private func handleCancel() {
        onCancel()
    }

    func performCancelForTesting() {
        handleCancel()
    }

#if DEBUG
    var displayedModeForTesting: Mode {
        displayedMode
    }

    func waitForStableModeForTesting(_ mode: Mode) async {
        if isStableModeForTesting(mode) {
            return
        }

        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isStableModeForTesting(mode) {
                    continuation.resume()
                    return
                }
                stableModeWaitersForTesting[waiterID] = .init(
                    mode: mode,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelStableModeWaiterForTesting(waiterID)
            }
        }
    }

    private func isStableModeForTesting(_ mode: Mode) -> Bool {
        displayedMode == mode && pendingMode == nil && isAnimatingModeTransition == false
    }

    private func notifyStableModeWaitersForTestingIfNeeded() {
        guard stableModeWaitersForTesting.isEmpty == false else {
            return
        }

        let readyWaiterIDs = stableModeWaitersForTesting.compactMap { id, waiter in
            isStableModeForTesting(waiter.mode) ? id : nil
        }
        let readyContinuations = readyWaiterIDs.compactMap { id in
            stableModeWaitersForTesting.removeValue(forKey: id)?.continuation
        }
        for continuation in readyContinuations {
            continuation.resume()
        }
    }

    private func cancelStableModeWaiterForTesting(_ waiterID: UUID) {
        guard let waiter = stableModeWaitersForTesting.removeValue(forKey: waiterID) else {
            return
        }
        waiter.continuation.resume()
    }
#endif
}

@MainActor
private final class AddAccountToolbarProgressButton: NSButton {
    private let contentStackView = NSStackView()
    private let progressIndicator = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "Cancel")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let contentSize = contentStackView.fittingSize
        return NSSize(width: contentSize.width + 16, height: max(28, contentSize.height + 8))
    }

    private func configure() {
        bezelStyle = .toolbar
        title = ""
        setButtonType(.momentaryPushIn)
        imagePosition = .noImage
        setAccessibilityLabel("Cancel Account Sign-In")

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.setAccessibilityLabel("Account Sign-In Progress")

        titleLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.lineBreakMode = .byClipping

        contentStackView.orientation = .horizontal
        contentStackView.alignment = .centerY
        contentStackView.spacing = 6
        contentStackView.translatesAutoresizingMaskIntoConstraints = false
        contentStackView.addArrangedSubview(progressIndicator)
        contentStackView.addArrangedSubview(titleLabel)

        addSubview(contentStackView)
        NSLayoutConstraint.activate([
            contentStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            contentStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            contentStackView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            contentStackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    func startProgressAnimation() {
        progressIndicator.startAnimation(nil)
    }

    func stopProgressAnimation() {
        progressIndicator.stopAnimation(nil)
    }

    func setProgressDetailToolTip(_ toolTip: String?) {
        progressIndicator.toolTip = toolTip
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorSplitViewController {
    enum AddAccountToolbarItemModeForTesting: Equatable {
        case add
        case progress
    }

    enum SidebarPresentationForTesting: Equatable {
        case jobList
        case accountList
        case unavailable
    }

    var sidebarViewControllerForTesting: ReviewMonitorSidebarViewController {
        guard let sidebarViewController else {
            fatalError("Sidebar pane view controller is not configured yet.")
        }
        sidebarViewController.loadViewIfNeeded()
        return sidebarViewController
    }

    var sidebarPresentationForTesting: SidebarPresentationForTesting {
        switch sidebarViewControllerForTesting.presentationForTesting {
        case .jobList, .empty:
            return .jobList
        case .accountList:
            return .accountList
        case .unavailable:
            return .unavailable
        }
    }

    var sidebarAccessoryCountForTesting: Int {
        sidebarBottomAccessoryCountForTesting
    }

    var sidebarTopAccessoryCountForTesting: Int {
        sidebarItem?.topAlignedAccessoryViewControllers.count ?? 0
    }

    var sidebarBottomAccessoryCountForTesting: Int {
        sidebarItem?.bottomAlignedAccessoryViewControllers.count ?? 0
    }

    var sidebarBottomAccessoryIsHiddenForTesting: Bool {
        sidebarItem?.bottomAlignedAccessoryViewControllers.first?.isHidden ?? false
    }

    var sidebarTopAccessorySegmentAccessibilityDescriptionsForTesting: [String] {
        guard let accessoryViewController = sidebarItem?.topAlignedAccessoryViewControllers.first
            as? ReviewMonitorSidebarSegmentedAccessoryViewController
        else {
            return []
        }
        return accessoryViewController.segmentAccessibilityDescriptionsForTesting
    }

    var contentAccessoryCountForTesting: Int {
        contentItem?.bottomAlignedAccessoryViewControllers.count ?? 0
    }

    var contentPaneViewControllerForTesting: ReviewMonitorTransportViewController {
        transportViewControllerForTesting
    }

    var transportViewControllerForTesting: ReviewMonitorTransportViewController {
        guard let transportViewController else {
            fatalError("Transport view controller is not configured yet.")
        }
        transportViewController.loadViewIfNeeded()
        return transportViewController
    }

    var toolbarIdentifiersForTesting: [NSToolbarItem.Identifier] {
        toolbar?.items.map(\.itemIdentifier) ?? []
    }

    var addAccountToolbarItemIdentifierForTesting: NSToolbarItem.Identifier {
        Self.addAccountToolbarItemIdentifier
    }

    var addAccountToolbarItemIsHiddenForTesting: Bool {
        toolbar?.items
            .first(where: { $0.itemIdentifier == Self.addAccountToolbarItemIdentifier })?
            .isHidden ?? true
    }

    var addAccountToolbarItemModeForTesting: AddAccountToolbarItemModeForTesting? {
        switch addAccountToolbarView?.displayedModeForTesting {
        case .add:
            .add
        case .progress:
            .progress
        case nil:
            nil
        }
    }

    var addAccountToolbarMenuTitleForTesting: String? {
        toolbar?.items
            .first(where: { $0.itemIdentifier == Self.addAccountToolbarItemIdentifier })?
            .menuFormRepresentation?.title
    }

    func waitForAddAccountToolbarItemModeForTesting(
        _ mode: AddAccountToolbarItemModeForTesting
    ) async {
        guard let addAccountToolbarView else {
            fatalError("Add Account toolbar view is not configured yet.")
        }
        let targetMode: AddAccountToolbarItemView.Mode
        switch mode {
        case .add:
            targetMode = .add
        case .progress:
            targetMode = .progress
        }
        await addAccountToolbarView.waitForStableModeForTesting(targetMode)
    }

    func performAddAccountToolbarItemForTesting() {
        performAddAccountToolbarItemAction()
    }

    func performAddAccountToolbarCancelForTesting() {
        addAccountToolbarView?.performCancelForTesting()
    }

    var sidebarAllowsFullHeightLayoutForTesting: Bool {
        sidebarItem?.allowsFullHeightLayout ?? false
    }

    var contentAutomaticallyAdjustsSafeAreaInsetsForTesting: Bool {
        contentItem?.automaticallyAdjustsSafeAreaInsets ?? false
    }
}
#endif
