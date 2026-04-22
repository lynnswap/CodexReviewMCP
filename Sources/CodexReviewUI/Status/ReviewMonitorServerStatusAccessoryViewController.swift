import AppKit
import SwiftUI
import ReviewApp
import ObservationBridge
import ReviewDomain

@MainActor
final class ReviewMonitorServerStatusAccessoryViewController: NSSplitViewItemAccessoryViewController {
    private let store: CodexReviewStore
    private let uiState: ReviewMonitorUIState
    private var observationHandles: Set<ObservationHandle> = []
    private var shouldHideStatusAccessory = false

    init(store: CodexReviewStore, uiState: ReviewMonitorUIState) {
        self.store = store
        self.uiState = uiState
        super.init(nibName: nil, bundle: nil)

        automaticallyAppliesContentInsets = true
        view = NSHostingView(rootView: StatusView(store: store))
        updateVisibility(animated: false)
        bindObservation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func bindObservation() {
        uiState.observe(\.sidebarSelection) { [weak self] _ in
            guard let self else {
                return
            }
            self.updateVisibility(animated: true)
        }
        .store(in: &observationHandles)
    }

    private func updateVisibility(animated: Bool) {
        let shouldHide = uiState.sidebarSelection == .account
        shouldHideStatusAccessory = shouldHide
        guard animated else {
            isHidden = shouldHide
            view.alphaValue = shouldHide ? 0 : 1
            return
        }

        if shouldHide {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                view.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.shouldHideStatusAccessory else {
                        return
                    }
                    self.isHidden = true
                }
            }
        } else {
            isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                view.animator().alphaValue = 1
            }
        }
    }
}

#if DEBUG
extension ReviewMonitorServerStatusAccessoryViewController {
    var observationHandleCountForTesting: Int {
        observationHandles.count
    }
}
#endif

struct AccountRateLimitsSectionView: View {
    let account: CodexAccount?

    var body: some View {
        ForEach(rateLimits) { window in
            GroupBox{
                rateLimitsRow(window)
            }label:{
                Text(window.formattedDuration)
            }
        }
    }

    @ViewBuilder
    private func rateLimitsRow(
        _ window: CodexRateLimitWindow
    ) -> some View {
        if let details = Self.rateLimitDetailsText(for: window) {
            Button {
            } label: {
                Text(details)
            }
        }
    }

    private var rateLimits: [CodexRateLimitWindow] {
        account?.rateLimits ?? []
    }

    static func rateLimitDetailsText(
        for window: CodexRateLimitWindow
    ) -> AttributedString? {
        guard let resetsAt = window.resetsAt else {
            return nil
        }
        var details = AttributedString(resetsAt.formatted(.dateTime))
        details.append(AttributedString("\n"))
        details.append(Date.now.formatted(.offset(to: resetsAt, sign: .never)))
        return details
    }
}

struct StatusView: View {
    var store: CodexReviewStore

    var body: some View {
        let settings = store.settings
        let modelSelection = Binding<String?>(
            get: { settings.selectedModel },
            set: { model in
                Task { @MainActor in
                    if let model {
                        await store.updateSettingsModel(model)
                    } else {
                        await store.clearSettingsModelOverride()
                    }
                }
            }
        )
        let serviceTierSelection = Binding<CodexReviewServiceTier?>(
            get: { settings.selectedServiceTier },
            set: { serviceTier in
                Task { @MainActor in
                    await store.updateSettingsServiceTier(serviceTier)
                }
            }
        )
        let reasoningSelection = Binding<CodexReviewReasoningEffort?>(
            get: { settings.selectedReasoningEffort },
            set: { reasoningEffort in
                Task { @MainActor in
                    if let reasoningEffort {
                        await store.updateSettingsReasoningEffort(reasoningEffort)
                    } else {
                        await store.clearSettingsReasoningEffort()
                    }
                }
            }
        )
        VStack{
            Menu {
                Section(store.auth.account?.email ?? "") {
                    AccountRateLimitsSectionView(account: store.auth.account)
                }
                
                if showsServerRestartAction {
                    Divider()
                    Button("Reset Server", systemImage: "arrow.clockwise") {
                        Task {
                            await store.restart()
                        }
                    }
                }
            } label: {
                AccountRateLimitGaugesView(account: store.auth.account)
                    .transition(.blurReplace)
                    .animation(.default, value: store.auth.account)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            HStack{
                Menu{
                    // Keep this picker aligned with Codex CLI/App behavior and avoid
                    // inventing a synthetic inherited/default row that those clients do not expose.
                    Picker("Model", selection: modelSelection) {
                        ForEach(settings.displayedModels) { item in
                            Text(item.displayName).tag(Optional(item.model))
                        }
                    }
                    .pickerStyle(.inline)
                    
                    Picker("Tier", selection: serviceTierSelection) {
                        Text("Normal").tag(Optional<CodexReviewServiceTier>.none)
                        ForEach(settings.availableServiceTiers, id: \.self) { item in
                            Text(item.displayText).tag(Optional(item))
                        }
                    }
                    .pickerStyle(.inline)
                }label:{
                    Text(settings.currentModelDisplayText)
                }
                Menu{
                    // Deliberately mirror the concrete reasoning choices from the model catalog
                    // instead of adding an extra "default" menu row that upstream clients lack.
                    Picker("Reasoning", selection: reasoningSelection) {
                        ForEach(settings.availableReasoningOptions) { item in
                            Text(item.reasoningEffort.displayText)
                                .tag(Optional(item.reasoningEffort))
                        }
                    }
                    .pickerStyle(.inline)
                }label:{
                    Text(settings.currentReasoningDisplayText)
                }
                Spacer(minLength: 0)
            }
            .disabled(
                store.serverState != .running
                    || settings.isLoading
                    || settings.displayedModels.isEmpty
            )
            .labelsVisibility(.hidden)
        }
        .padding(8)
    }

    private var showsServerRestartAction: Bool {
        switch store.serverState {
        case .failed, .stopped, .starting:
            true
        case .running:
            false
        }
    }
}

#if DEBUG

#Preview("Signed In") {
    let store = makeStatusPreviewStore()
    StatusView(store: store)
        .padding()
}

#Preview("Server Failed") {
    let store = makeStatusPreviewStore(
        serverState: .failed("The embedded server stopped responding.")
    )
    StatusView(store: store)
        .padding()
}

@MainActor
func makeStatusPreviewStore(
    authPhase: CodexReviewAuthModel.Phase = .signedOut,
    account: CodexAccount? = nil,
    serverState: CodexReviewServerState = .running
) -> CodexReviewStore {
    let store = ReviewMonitorPreviewContent.makeStore()
    let runningServerURL = store.serverURL
    let previewAccounts = ReviewMonitorPreviewContent.makePreviewAccounts()
    let resolvedAccount = account ?? previewAccounts.first
    store.auth.updatePhase(authPhase)
    store.auth.updateSavedAccounts(previewAccounts)
    store.auth.updateAccount(resolvedAccount)
    store.serverState = serverState
    store.serverURL = serverState == .running ? runningServerURL : nil
    return store
}
@MainActor
func makeStatusPreviewAccount() -> CodexAccount {
    ReviewMonitorPreviewContent.makePreviewAccount()
}
#endif
