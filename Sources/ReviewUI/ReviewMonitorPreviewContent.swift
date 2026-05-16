import Foundation
@_spi(Testing) import ReviewApplication
import ReviewDomain

@_spi(PreviewSupport)
@MainActor
public enum ReviewMonitorPreviewContent {
    private struct PreviewJobDefinition {
        let status: ReviewJobState
        let targetSummary: String
        let summary: String
        let lastAgentMessage: String
        let model: String
        let startedOffset: TimeInterval?
        let endedOffset: TimeInterval?
        let hasFinalReview: Bool
    }

    @MainActor
    private final class PreviewLogStreamer {
        private weak var store: CodexReviewStore?
        private let interval: Duration
        private var task: Task<Void, Never>?
        private var tick = 0
        private let fragments = [
            "delta/sidebar +4 -1",
            "delta/layout +2 -0",
            "delta/selection +1 -1",
            "delta/transport +3 -2",
            "delta/render +5 -3",
            "delta/preview +2 -1",
        ]

        init(store: CodexReviewStore, interval: Duration) {
            self.store = store
            self.interval = interval
            task = Task { [weak self, interval] in
                while Task.isCancelled == false {
                    try? await Task.sleep(for: interval)
                    guard let self, Task.isCancelled == false else {
                        return
                    }
                    self.emitTick()
                }
            }
        }

        deinit {
            task?.cancel()
        }

        private func emitTick() {
            guard let store else {
                task?.cancel()
                return
            }

            let runningJobs = store.orderedJobs
                .filter { $0.core.lifecycle.status == .running }

            guard runningJobs.isEmpty == false else {
                return
            }

            tick += 1
            for (index, job) in runningJobs.enumerated() {
                job.appendLogEntry(
                    .init(
                        kind: .progress,
                        text: streamLine(forJobAt: index, tick: tick)
                    )
                )
            }
        }

        private func streamLine(forJobAt index: Int, tick: Int) -> String {
            let fragment = fragments[(tick + index) % fragments.count]
            return String(format: "stream.tick %03d %@", tick, fragment)
        }
    }

    @_spi(PreviewSupport)
    public static func makeStore(
        streamInterval: Duration = .seconds(1)
    ) -> CodexReviewStore {
        let store = CodexReviewStore.makePreviewStore(
            seed: .init(initialSettingsSnapshot: makePreviewSettingsSnapshot())
        )
        let accounts = makePreviewAccounts()
        let previewContent = makeSidebarContent()
        store.loadForTesting(
            serverState: .running,
            account: accounts.first,
            persistedAccounts: accounts,
            serverURL: URL(string: "http://localhost:9417/mcp"),
            workspaces: previewContent.workspaces,
            jobs: previewContent.jobs
        )
        store.previewSupportRetainer = PreviewLogStreamer(
            store: store,
            interval: streamInterval
        )
        return store
    }

    @_spi(PreviewSupport)
    public static func makePreviewAccounts() -> [CodexAccount] {
        [
            makePreviewAccount(
                email: "workspace@example.com",
                usedPercents: (short: 34, long: 61)
            ),
            makePreviewAccount(
                email: "personal@example.com",
                usedPercents: (short: 12, long: 27)
            ),
            makePreviewAccount(
                email: "team@example.com",
                usedPercents: (short: 72, long: 44)
            ),
        ]
    }

    @_spi(PreviewSupport)
    public static func makePreviewAccount(
        email: String = "review@example.com",
        usedPercents: (short: Int, long: Int) = (short: 34, long: 61)
    ) -> CodexAccount {
        let account = CodexAccount(email: email, planType: "pro")
        account.updateRateLimits(
            [
                (
                    windowDurationMinutes: 300,
                    usedPercent: usedPercents.short,
                    resetsAt: Date.now.addingTimeInterval(60 * 60)
                ),
                (
                    windowDurationMinutes: 10_080,
                    usedPercent: usedPercents.long,
                    resetsAt: Date.now.addingTimeInterval(24 * 60 * 60)
                ),
            ]
        )
        return account
    }

    static func makePreviewSettingsSnapshot() -> CodexReviewSettingsSnapshot {
        .init(
            model: "gpt-5.4",
            reasoningEffort: .medium,
            serviceTier: .fast,
            models: makePreviewModelCatalog()
        )
    }

    static func makePreviewModelCatalog() -> [CodexReviewModelCatalogItem] {
        [
            .init(
                id: "gpt-5.4",
                model: "gpt-5.4",
                displayName: "GPT-5.4",
                hidden: false,
                supportedReasoningEfforts: [
                    .init(reasoningEffort: .low, description: "Lower latency."),
                    .init(reasoningEffort: .medium, description: "Balanced default."),
                    .init(reasoningEffort: .high, description: "More deliberation."),
                ],
                defaultReasoningEffort: .medium,
                supportedServiceTiers: [.fast]
            ),
            .init(
                id: "gpt-5.4-mini",
                model: "gpt-5.4-mini",
                displayName: "GPT-5.4 Mini",
                hidden: false,
                supportedReasoningEfforts: [
                    .init(reasoningEffort: .low, description: "Quick pass."),
                    .init(reasoningEffort: .medium, description: "Balanced default."),
                ],
                defaultReasoningEffort: .medium,
                supportedServiceTiers: []
            ),
            .init(
                id: "gpt-5.3-codex",
                model: "gpt-5.3-codex",
                displayName: "GPT-5.3 Codex",
                hidden: false,
                supportedReasoningEfforts: [
                    .init(reasoningEffort: .minimal, description: "Lowest overhead."),
                    .init(reasoningEffort: .low, description: "Faster iteration."),
                    .init(reasoningEffort: .medium, description: "Balanced default."),
                ],
                defaultReasoningEffort: .medium,
                supportedServiceTiers: [.fast, .flex]
            ),
        ]
    }

    private static func makeSidebarContent() -> (workspaces: [CodexReviewWorkspace], jobs: [CodexReviewJob]) {
        let now = Date()
        let workspacePaths = [
            "/path/to/workspace-alpha",
            "/path/to/workspace-beta",
            "/path/to/workspace-gamma",
        ]

        var workspaces: [CodexReviewWorkspace] = []
        var jobs: [CodexReviewJob] = []
        for (workspaceIndex, cwd) in workspacePaths.enumerated() {
            let workspaceName = URL(fileURLWithPath: cwd).lastPathComponent
            workspaces.append(CodexReviewWorkspace(cwd: cwd))
            jobs += makeJobDefinitions(for: workspaceName).enumerated().map { jobIndex, definition in
                makeJob(
                    id: "preview-\(workspaceIndex)-\(jobIndex)",
                    cwd: cwd,
                    model: definition.model,
                    status: definition.status,
                    targetSummary: definition.targetSummary,
                    startedAt: definition.startedOffset.map { now.addingTimeInterval($0) },
                    endedAt: definition.endedOffset.map { now.addingTimeInterval($0) },
                    summary: definition.summary,
                    hasFinalReview: definition.hasFinalReview,
                    lastAgentMessage: definition.lastAgentMessage,
                    logText: makePreviewLogText(for: definition)
                )
            }
        }
        return (workspaces, jobs)
    }

    private static func makeJob(
        id: String,
        cwd: String,
        model: String,
        status: ReviewJobState,
        targetSummary: String,
        startedAt: Date?,
        endedAt: Date?,
        summary: String,
        hasFinalReview: Bool,
        lastAgentMessage: String,
        logText: String
    ) -> CodexReviewJob {
        CodexReviewJob.makeForTesting(
            id: id,
            cwd: cwd,
            targetSummary: targetSummary,
            model: model,
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: status,
            startedAt: startedAt,
            endedAt: endedAt,
            summary: summary,
            hasFinalReview: hasFinalReview,
            lastAgentMessage: lastAgentMessage,
            logEntries: [
                ReviewLogEntry(
                    kind: .agentMessage,
                    text: logText
                )
            ]
        )
    }

    private static func makePreviewLogText(for definition: PreviewJobDefinition) -> String {
        if definition.status == .running {
            return """
            $ review.start
            queue.pop -> session/open
            turn.create -> 01HZX9M4K2
            plan.delta + sidebar.scan
            plan.delta + row.identity
            plan.delta + log.scroll
            item.start -> diff/sidebar
            diff/sidebar +18 -6
            item.start -> render/layout
            render/layout frame=900x600
            """
        }

        return """
        \(definition.summary)

        \(definition.lastAgentMessage)
        """
    }

    private static func makeJobDefinitions(for workspaceName: String) -> [PreviewJobDefinition] {
        [
            PreviewJobDefinition(
                status: .running,
                targetSummary: "Branch: feature/\(workspaceName.lowercased())-sidebar",
                summary: "Review is streaming updates from the embedded server.",
                lastAgentMessage: "Inspecting recent sidebar changes and collecting render timings.",
                model: "gpt-5.4",
                startedOffset: -420,
                endedOffset: nil,
                hasFinalReview: false
            ),
            PreviewJobDefinition(
                status: .running,
                targetSummary: "Uncommitted changes",
                summary: "The working tree review is still in progress.",
                lastAgentMessage: "Comparing row reuse behavior across the latest local edits.",
                model: "gpt-5.4-mini",
                startedOffset: -135,
                endedOffset: nil,
                hasFinalReview: false
            ),
            PreviewJobDefinition(
                status: .queued,
                targetSummary: "Base branch: main",
                summary: "Queued behind another active review in this workspace.",
                lastAgentMessage: "Waiting for an available backend slot.",
                model: "gpt-5.3-codex",
                startedOffset: nil,
                endedOffset: nil,
                hasFinalReview: false
            ),
            PreviewJobDefinition(
                status: .succeeded,
                targetSummary: "Commit: abc1234",
                summary: "Review completed without correctness findings.",
                lastAgentMessage: "No correctness issues found in the touched files.",
                model: "gpt-5.4",
                startedOffset: -1_500,
                endedOffset: -1_260,
                hasFinalReview: true
            ),
            PreviewJobDefinition(
                status: .failed,
                targetSummary: "Custom: investigate CI flake",
                summary: "The review stopped after the test command failed.",
                lastAgentMessage: "Build failed before the model could finish evaluating the patch.",
                model: "gpt-5.3-codex",
                startedOffset: -2_400,
                endedOffset: -2_190,
                hasFinalReview: false
            ),
            PreviewJobDefinition(
                status: .cancelled,
                targetSummary: "Branch: feature/\(workspaceName.lowercased())-transport",
                summary: "Cancellation was requested after initial diagnostics completed.",
                lastAgentMessage: "Stopped after the first pass to free the session for a retry.",
                model: "gpt-5.4-mini",
                startedOffset: -960,
                endedOffset: -840,
                hasFinalReview: false
            ),
            PreviewJobDefinition(
                status: .succeeded,
                targetSummary: "Commit: def5678",
                summary: "Review suggested a small cleanup in the sidebar row renderer.",
                lastAgentMessage: "Suggested simplifying duplicated state handling in the row view.",
                model: "gpt-5.4",
                startedOffset: -5_400,
                endedOffset: -5_040,
                hasFinalReview: true
            ),
        ]
    }
}
