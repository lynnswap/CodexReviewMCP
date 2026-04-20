import Foundation
import Observation

package enum CodexReviewReasoningEffort: String, CaseIterable, Codable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh

    package var displayText: String {
        switch self {
        case .none:
            "None"
        case .minimal:
            "Minimal"
        case .low:
            "Low"
        case .medium:
            "Medium"
        case .high:
            "High"
        case .xhigh:
            "Extra high"
        }
    }
}

package enum CodexReviewServiceTier: String, CaseIterable, Codable, Sendable {
    case fast
    case flex

    package var displayText: String {
        switch self {
        case .fast:
            "Fast"
        case .flex:
            "Flex"
        }
    }
}

package struct CodexReviewReasoningOption: Codable, Identifiable, Equatable, Sendable {
    package let reasoningEffort: CodexReviewReasoningEffort
    package let description: String

    package var id: String {
        reasoningEffort.rawValue
    }

    package init(
        reasoningEffort: CodexReviewReasoningEffort,
        description: String
    ) {
        self.reasoningEffort = reasoningEffort
        self.description = description
    }
}

package struct CodexReviewModelCatalogItem: Codable, Identifiable, Equatable, Sendable {
    package let id: String
    package let model: String
    package let displayName: String
    package let hidden: Bool
    package let supportedReasoningEfforts: [CodexReviewReasoningOption]
    package let defaultReasoningEffort: CodexReviewReasoningEffort
    package let supportedServiceTiers: [CodexReviewServiceTier]

    private enum CodingKeys: String, CodingKey {
        case id
        case model
        case displayName
        case hidden
        case supportedReasoningEfforts
        case defaultReasoningEffort
        case supportedServiceTiers = "additionalSpeedTiers"
    }

    package init(
        id: String,
        model: String,
        displayName: String,
        hidden: Bool,
        supportedReasoningEfforts: [CodexReviewReasoningOption],
        defaultReasoningEffort: CodexReviewReasoningEffort,
        supportedServiceTiers: [CodexReviewServiceTier]
    ) {
        self.id = id
        self.model = model
        self.displayName = displayName
        self.hidden = hidden
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedServiceTiers = supportedServiceTiers
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        model = try container.decode(String.self, forKey: .model)
        displayName = try container.decode(String.self, forKey: .displayName)
        hidden = try container.decode(Bool.self, forKey: .hidden)
        supportedReasoningEfforts = try container.decode(
            [CodexReviewReasoningOption].self,
            forKey: .supportedReasoningEfforts
        )
        defaultReasoningEffort = try container.decode(
            CodexReviewReasoningEffort.self,
            forKey: .defaultReasoningEffort
        )
        supportedServiceTiers = (try container.decodeIfPresent(
            [String].self,
            forKey: .supportedServiceTiers
        ) ?? []).compactMap(CodexReviewServiceTier.init(rawValue:))
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(model, forKey: .model)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(hidden, forKey: .hidden)
        try container.encode(supportedReasoningEfforts, forKey: .supportedReasoningEfforts)
        try container.encode(defaultReasoningEffort, forKey: .defaultReasoningEffort)
        try container.encode(
            supportedServiceTiers.map(\.rawValue),
            forKey: .supportedServiceTiers
        )
    }

}

package struct CodexReviewSettingsSnapshot: Equatable, Sendable {
    package var model: String?
    package var reasoningEffort: CodexReviewReasoningEffort?
    package var serviceTier: CodexReviewServiceTier?
    package var models: [CodexReviewModelCatalogItem]

    package init(
        model: String? = nil,
        reasoningEffort: CodexReviewReasoningEffort? = nil,
        serviceTier: CodexReviewServiceTier? = nil,
        models: [CodexReviewModelCatalogItem] = []
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.models = models
    }
}

@MainActor
@Observable
package final class SettingsStore {
    private struct Selection: Equatable {
        let model: String?
        let reasoningEffort: CodexReviewReasoningEffort?
        let serviceTier: CodexReviewServiceTier?
    }

    package var selectedModel: String? {
        didSet {
            scheduleSelectionChange(trigger: .model)
        }
    }
    package var selectedReasoningEffort: CodexReviewReasoningEffort? {
        didSet {
            scheduleSelectionChange(trigger: .reasoningEffort)
        }
    }
    package var selectedServiceTier: CodexReviewServiceTier? {
        didSet {
            scheduleSelectionChange(trigger: .serviceTier)
        }
    }
    package private(set) var models: [CodexReviewModelCatalogItem]
    package private(set) var isLoading = false
    package private(set) var lastErrorMessage: String?

    @ObservationIgnored
    private let backend: any CodexReviewStoreBackend
    @ObservationIgnored
    private var suppressSelectionObservation = false
    @ObservationIgnored
    private var lastObservedSelection: Selection

    private enum SelectionTrigger {
        case model
        case reasoningEffort
        case serviceTier
    }

    package init(
        backend: any CodexReviewStoreBackend,
        snapshot: CodexReviewSettingsSnapshot
    ) {
        self.backend = backend
        self.selectedModel = snapshot.model
        self.selectedReasoningEffort = snapshot.reasoningEffort
        self.selectedServiceTier = snapshot.serviceTier
        self.models = snapshot.models
        self.lastObservedSelection = .init(
            model: snapshot.model,
            reasoningEffort: snapshot.reasoningEffort,
            serviceTier: snapshot.serviceTier
        )
        applyNormalizedSelection(
            normalizeSelection(
                model: snapshot.model,
                reasoningEffort: snapshot.reasoningEffort,
                serviceTier: snapshot.serviceTier,
                catalog: snapshot.models
            ),
            catalog: snapshot.models
        )
    }

    package var displayedModels: [CodexReviewModelCatalogItem] {
        models.filter { modelItem in
            modelItem.hidden == false || modelItem.model == selectedModel
        }
    }

    package var selectedModelItem: CodexReviewModelCatalogItem? {
        models.first(where: { $0.model == selectedModel })
    }

    package var availableReasoningOptions: [CodexReviewReasoningOption] {
        selectedModelItem?.supportedReasoningEfforts ?? []
    }

    package var availableServiceTiers: [CodexReviewServiceTier] {
        selectedModelItem?.supportedServiceTiers ?? []
    }

    package var currentModelDisplayText: String {
        selectedModelItem?.displayName ?? selectedModel ?? "Model"
    }

    package var currentReasoningDisplayText: String {
        effectiveReasoningEffort?.displayText ?? "Reasoning"
    }

    package var currentServiceTierDisplayText: String {
        selectedServiceTier?.displayText ?? "Normal"
    }

    package var effectiveReasoningEffort: CodexReviewReasoningEffort? {
        selectedReasoningEffort ?? selectedModelItem?.defaultReasoningEffort
    }

    package func refreshIfRunning(
        serverState: CodexReviewServerState
    ) async {
        guard case .running = serverState else {
            return
        }
        await refresh()
    }

    package func refresh() async {
        guard isLoading == false else {
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let snapshot = try await backend.refreshSettings()
            apply(snapshot: snapshot)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    package func updateModel(_ model: String) async {
        await applySelectionChange(
            trigger: .model,
            previous: currentSelection(),
            candidate: .init(
                model: model,
                reasoningEffort: selectedReasoningEffort,
                serviceTier: selectedServiceTier
            )
        )
    }

    package func updateReasoningEffort(_ reasoningEffort: CodexReviewReasoningEffort) async {
        await applySelectionChange(
            trigger: .reasoningEffort,
            previous: currentSelection(),
            candidate: .init(
                model: selectedModel,
                reasoningEffort: reasoningEffort,
                serviceTier: selectedServiceTier
            )
        )
    }

    package func updateServiceTier(_ serviceTier: CodexReviewServiceTier?) async {
        await applySelectionChange(
            trigger: .serviceTier,
            previous: currentSelection(),
            candidate: .init(
                model: selectedModel,
                reasoningEffort: selectedReasoningEffort,
                serviceTier: serviceTier
            )
        )
    }

    package func loadForTesting(snapshot: CodexReviewSettingsSnapshot) {
        apply(snapshot: snapshot)
        lastErrorMessage = nil
        isLoading = false
    }

    private func persist(
        previous: CodexReviewSettingsSnapshot,
        operation: @escaping () async throws -> Void
    ) async {
        guard isLoading == false else {
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            try await operation()
            lastErrorMessage = nil
        } catch {
            apply(snapshot: previous)
            lastErrorMessage = error.localizedDescription
        }
    }

    private func apply(snapshot: CodexReviewSettingsSnapshot) {
        models = snapshot.models
        applyNormalizedSelection(
            normalizeSelection(
                model: snapshot.model,
                reasoningEffort: snapshot.reasoningEffort,
                serviceTier: snapshot.serviceTier,
                catalog: snapshot.models
            ),
            catalog: snapshot.models
        )
    }

    private func snapshot() -> CodexReviewSettingsSnapshot {
        snapshot(selection: currentSelection())
    }

    private func snapshot(selection: Selection) -> CodexReviewSettingsSnapshot {
        .init(
            model: selection.model,
            reasoningEffort: selection.reasoningEffort,
            serviceTier: selection.serviceTier,
            models: models
        )
    }

    private func applyNormalizedSelection(
        _ selection: Selection,
        catalog: [CodexReviewModelCatalogItem]
    ) {
        suppressSelectionObservation = true
        models = catalog
        selectedModel = selection.model
        selectedReasoningEffort = selection.reasoningEffort
        selectedServiceTier = selection.serviceTier
        suppressSelectionObservation = false
        lastObservedSelection = selection
    }

    private func normalizeSelection(
        model: String?,
        reasoningEffort: CodexReviewReasoningEffort?,
        serviceTier: CodexReviewServiceTier?,
        catalog: [CodexReviewModelCatalogItem]
    ) -> Selection {
        guard let model else {
            return .init(
                model: nil,
                reasoningEffort: nil,
                serviceTier: nil
            )
        }
        guard let selectedModel = catalog.first(where: { $0.model == model }) else {
            return .init(
                model: model,
                reasoningEffort: reasoningEffort,
                serviceTier: serviceTier
            )
        }

        let supportedReasoningEfforts = selectedModel.supportedReasoningEfforts.map(\.reasoningEffort)
        let resolvedReasoningEffort: CodexReviewReasoningEffort? = if supportedReasoningEfforts.isEmpty {
            nil
        } else if let reasoningEffort, supportedReasoningEfforts.contains(reasoningEffort) {
            reasoningEffort
        } else if supportedReasoningEfforts.contains(selectedModel.defaultReasoningEffort) {
            selectedModel.defaultReasoningEffort
        } else {
            supportedReasoningEfforts.first
        }

        let resolvedServiceTier: CodexReviewServiceTier? = if let serviceTier,
            selectedModel.supportedServiceTiers.contains(serviceTier)
        {
            serviceTier
        } else {
            nil
        }

        return .init(
            model: model,
            reasoningEffort: resolvedReasoningEffort,
            serviceTier: resolvedServiceTier
        )
    }

    private func currentSelection() -> Selection {
        .init(
            model: selectedModel,
            reasoningEffort: selectedReasoningEffort,
            serviceTier: selectedServiceTier
        )
    }

    private func scheduleSelectionChange(trigger: SelectionTrigger) {
        guard suppressSelectionObservation == false else {
            return
        }
        let previous = lastObservedSelection
        let candidate = currentSelection()
        guard candidate != previous else {
            return
        }
        lastObservedSelection = candidate
        Task { @MainActor in
            await self.applySelectionChange(
                trigger: trigger,
                previous: previous,
                candidate: candidate
            )
        }
    }

    private func applySelectionChange(
        trigger: SelectionTrigger,
        previous: Selection,
        candidate: Selection
    ) async {
        guard isLoading == false else {
            return
        }

        let normalized = normalizeSelection(
            model: candidate.model,
            reasoningEffort: candidate.reasoningEffort,
            serviceTier: candidate.serviceTier,
            catalog: models
        )
        if normalized != currentSelection() {
            applyNormalizedSelection(normalized, catalog: models)
        } else {
            lastObservedSelection = normalized
        }
        guard normalized != previous else {
            return
        }

        switch trigger {
        case .model:
            guard let model = normalized.model else {
                return
            }
            await persist(
                previous: snapshot(selection: previous),
                operation: {
                    try await self.backend.updateSettingsModel(
                        model,
                        reasoningEffort: normalized.reasoningEffort,
                        serviceTier: normalized.serviceTier
                    )
                }
            )
        case .reasoningEffort:
            await persist(
                previous: snapshot(selection: previous),
                operation: {
                    try await self.backend.updateSettingsReasoningEffort(
                        normalized.reasoningEffort
                    )
                }
            )
        case .serviceTier:
            await persist(
                previous: snapshot(selection: previous),
                operation: {
                    try await self.backend.updateSettingsServiceTier(
                        normalized.serviceTier
                    )
                }
            )
        }
    }
}
