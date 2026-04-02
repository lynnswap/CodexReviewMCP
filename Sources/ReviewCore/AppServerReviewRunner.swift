import Darwin
import Foundation
import ReviewJobs

package struct ReviewBootstrapFailure: Error, LocalizedError, Sendable {
    package var message: String
    package var model: String?

    package var errorDescription: String? {
        message
    }
}

package struct ReviewProcessOutcome: Sendable {
    package var state: ReviewJobState
    package var exitCode: Int
    package var reviewThreadID: String?
    package var threadID: String?
    package var turnID: String?
    package var model: String?
    package var lastAgentMessage: String
    package var errorMessage: String?
    package var summary: String
    package var startedAt: Date
    package var endedAt: Date
    package var content: String
}

package struct AppServerReviewRunner: Sendable {
    package var settingsBuilder: ReviewExecutionSettingsBuilder
    package var gracefulTerminationWait: Duration = .seconds(2)
    package var pollInterval: Duration = .milliseconds(100)

    package init(settingsBuilder: ReviewExecutionSettingsBuilder = .init()) {
        self.settingsBuilder = settingsBuilder
    }

    package func run(
        request: ReviewRequestOptions,
        defaultTimeoutSeconds: Int?,
        onStart: @escaping @Sendable (AppServerProcessController, Date) async -> Void,
        onEvent: @escaping @Sendable (ReviewProcessEvent) async -> Void,
        requestedTerminationReason: @escaping @Sendable () async -> ReviewTerminationReason?
    ) async throws -> ReviewProcessOutcome {
        let settings = try settingsBuilder.build(request: request)
        let request = settings.request
        var effectiveModel: String?
        if let cancelled = await cancelledOutcomeBeforeStart(
            requestedModel: effectiveModel,
            requestedTerminationReason: requestedTerminationReason,
            onEvent: onEvent
        ) {
            return cancelled
        }

        let startedProcess = try AppServerProcessController.start(command: settings.command)
        let controller = startedProcess.controller
        let startedAt = Date()
        await onStart(controller, startedAt)
        await onEvent(.progress(.started, "Review started."))

        let state = AppServerReviewState()
        let connection = AppServerConnection(
            controller: controller,
            stdoutHandle: startedProcess.stdoutHandle,
            stderrHandle: startedProcess.stderrHandle,
            onNotification: { notification in
                await handle(notification: notification, state: state, onEvent: onEvent)
            },
            onStderrLine: { line in
                await state.appendStandardError(line)
                await onEvent(.rawLine(line))
            }
        )
        await connection.start()

        func cleanupForThrow() async {
            await connection.stop()
            _ = await controller.terminateGracefully(grace: gracefulTerminationWait)
        }

        func cleanupForReturn() async {
            await connection.stop()
        }

        func cancelledOutcomeDuringBootstrap() async -> ReviewProcessOutcome? {
            let cancellationReason: String?
            if Task.isCancelled {
                cancellationReason = "Review cancelled."
            } else if case .cancelled(let reason)? = await requestedTerminationReason() {
                cancellationReason = reason
            } else {
                cancellationReason = nil
            }

            guard let cancellationReason else {
                return nil
            }

            await cleanupForThrow()
            let endedAt = Date()
            await onEvent(.progress(.completed, "Review cancelled."))
            return ReviewProcessOutcome(
                state: .cancelled,
                exitCode: (await controller.pollExitStatus()) ?? 130,
                reviewThreadID: nil,
                threadID: nil,
                turnID: nil,
                model: effectiveModel,
                lastAgentMessage: "",
                errorMessage: cancellationReason,
                summary: "Review cancelled.",
                startedAt: startedAt,
                endedAt: endedAt,
                content: cancellationReason
            )
        }

        if let cancelled = await cancelledOutcomeDuringBootstrap() {
            return cancelled
        }

        let initializeResponse: AppServerInitializeResponse
        do {
            initializeResponse = try await connection.initialize()
        } catch {
            await cleanupForThrow()
            throw ReviewError.bootstrapFailed("Failed to initialize app-server: \(error.localizedDescription)")
        }

        if let cancelled = await cancelledOutcomeDuringBootstrap() {
            return cancelled
        }

        let resolvedCodexHome = ReviewHomePaths.resolvedCodexHomeURL(
            appServerCodexHome: initializeResponse.codexHome,
            environment: settings.command.environment
        )

        let localConfig: ReviewLocalConfig
        do {
            localConfig = try loadReviewLocalConfig(environment: settings.command.environment)
        } catch {
            await cleanupForThrow()
            throw ReviewError.bootstrapFailed("Failed to read ReviewMCP config: \(error.localizedDescription)")
        }

        let fallbackAppServerConfig = loadFallbackAppServerConfig(
            environment: settings.command.environment,
            codexHome: resolvedCodexHome
        )
        effectiveModel = resolveReviewModelSelection(
            localConfig: localConfig,
            resolvedConfig: fallbackAppServerConfig
        ).reportedModelBeforeThreadStart

        if let cancelled = await cancelledOutcomeDuringBootstrap() {
            return cancelled
        }

        let resolvedConfig: AppServerConfigReadResponse.Config
        do {
            let configResponse: AppServerConfigReadResponse = try await connection.request(
                method: "config/read",
                params: AppServerConfigReadParams(
                    cwd: request.cwd,
                    includeLayers: false
                ),
                responseType: AppServerConfigReadResponse.self
            )
            resolvedConfig = mergeAppServerConfig(
                primary: configResponse.config,
                fallback: fallbackAppServerConfig
            )
        } catch {
            guard shouldFallbackFromConfigReadError(error) else {
                await cleanupForThrow()
                throw ReviewBootstrapFailure(
                    message: "Failed to read app-server config: \(error.localizedDescription)",
                    model: effectiveModel
                )
            }
            resolvedConfig = fallbackAppServerConfig
            await onEvent(.logEntry(.init(
                kind: .progress,
                text: "Falling back to local config parsing because `config/read` is unavailable."
            )))
        }

        let reviewSpecificModel = localConfig.reviewModel?.nilIfEmpty
            ?? resolvedConfig.reviewModel?.nilIfEmpty
        let resolvedModels = resolveReviewModelSelection(
            localConfig: localConfig,
            resolvedConfig: resolvedConfig
        )
        effectiveModel = resolvedModels.reportedModelBeforeThreadStart

        if let cancelled = await cancelledOutcomeDuringBootstrap() {
            return cancelled
        }

        let threadStart = AppServerThreadStartParams(
            model: resolvedModels.threadStartModelHint,
            cwd: request.cwd,
            approvalPolicy: settings.overrides.approvalPolicy,
            sandbox: settings.overrides.sandbox,
            config: makeReviewThreadStartConfig(
                reviewSpecificModel: reviewSpecificModel,
                localConfig: localConfig,
                resolvedConfig: resolvedConfig,
                clampModel: resolvedModels.clampModel,
                environment: settings.command.environment,
                codexHome: resolvedCodexHome
            ),
            personality: settings.overrides.personality,
            ephemeral: settings.overrides.ephemeral
        )

        let threadResponse: AppServerThreadStartResponse
        do {
            threadResponse = try await connection.request(
                method: "thread/start",
                params: threadStart,
                responseType: AppServerThreadStartResponse.self
            )
        } catch {
            await cleanupForThrow()
            throw ReviewBootstrapFailure(
                message: "Failed to start review thread: \(error.localizedDescription)",
                model: effectiveModel
            )
        }

        effectiveModel = if reviewSpecificModel != nil {
            resolvedModels.reportedModelBeforeThreadStart
                ?? threadResponse.model?.nilIfEmpty
                ?? effectiveModel
        } else {
            threadResponse.model?.nilIfEmpty
                ?? resolvedModels.reportedModelBeforeThreadStart
                ?? effectiveModel
        }

        if let cancelled = await cancelledOutcomeDuringBootstrap() {
            return cancelled
        }

        var reviewStart = AppServerReviewStartParams(
            threadID: "",
            target: request.target,
            delivery: "inline"
        )
        reviewStart.threadID = threadResponse.thread.id

        let reviewResponse: AppServerReviewStartResponse
        do {
            reviewResponse = try await connection.request(
                method: "review/start",
                params: reviewStart,
                responseType: AppServerReviewStartResponse.self
            )
        } catch {
            await cleanupForThrow()
            throw ReviewBootstrapFailure(
                message: "Failed to start review: \(error.localizedDescription)",
                model: effectiveModel
            )
        }

        let reviewThreadID = reviewResponse.reviewThreadID
        let turnID = reviewResponse.turn.id
        await state.markReviewStarted(
            reviewThreadID: reviewThreadID,
            threadID: threadResponse.thread.id,
            turnID: turnID
        )
        await onEvent(.reviewStarted(
            reviewThreadID: reviewThreadID,
            threadID: threadResponse.thread.id,
            turnID: turnID,
            model: effectiveModel
        ))
        await onEvent(.progress(.threadStarted, "Review started: \(reviewThreadID)"))

        var cancellationReason: String?
        var interruptSent = false
        var processExitObservedAt: Date?
        var completedWithoutReviewObservedAt: Date?
        let timeoutSeconds = request.timeoutSeconds ?? defaultTimeoutSeconds

        while true {
            if cancellationReason == nil,
               case .cancelled(let reason)? = await requestedTerminationReason()
            {
                cancellationReason = reason
            }

            if let cancellationReason,
               interruptSent == false
            {
                interruptSent = true
                do {
                    let snapshot = await state.snapshot()
                    let _: AppServerEmptyResponse = try await connection.request(
                        method: "turn/interrupt",
                        params: AppServerTurnInterruptParams(
                            threadID: snapshot.reviewThreadID ?? reviewThreadID,
                            turnID: snapshot.turnID ?? turnID
                        ),
                        responseType: AppServerEmptyResponse.self
                    )
                    await onEvent(.logEntry(.init(kind: .progress, text: "Cancellation requested.")))
                } catch {
                    await onEvent(.failed(cancellationReason))
                    _ = await controller.terminateGracefully(grace: gracefulTerminationWait)
                }
            }

            let snapshot = await state.snapshot()
            if let turnStatus = snapshot.turnStatus {
                await connection.synchronize()
                let synchronizedSnapshot = await state.snapshot()
                if turnStatus == .completed,
                   synchronizedSnapshot.finalReview?.nilIfEmpty == nil
                {
                    let observedAt = completedWithoutReviewObservedAt ?? Date()
                    completedWithoutReviewObservedAt = observedAt
                    if Date().timeIntervalSince(observedAt) < 0.25 {
                        try? await Task.sleep(for: .milliseconds(20))
                        continue
                    }
                } else {
                    completedWithoutReviewObservedAt = nil
                }
                let endedAt = Date()
                let exitCode = await stopAppServer(controller: controller)
                await connection.synchronize()
                let snapshot = await state.snapshot()
                switch turnStatus {
                case .completed:
                    guard let review = snapshot.finalReview?.nilIfEmpty else {
                        await cleanupForReturn()
                        return ReviewProcessOutcome(
                            state: .failed,
                            exitCode: exitCode,
                            reviewThreadID: snapshot.reviewThreadID ?? reviewThreadID,
                            threadID: snapshot.threadID ?? threadResponse.thread.id,
                            turnID: snapshot.turnID ?? turnID,
                            model: effectiveModel,
                            lastAgentMessage: snapshot.lastAgentMessage ?? "",
                            errorMessage: "Review completed without an `exitedReviewMode` item.",
                            summary: "Review failed.",
                            startedAt: startedAt,
                            endedAt: endedAt,
                            content: snapshot.lastAgentMessage ?? "Review failed."
                        )
                    }
                    let stateValue: ReviewJobState = cancellationReason == nil ? .succeeded : .cancelled
                    let summary = cancellationReason == nil ? "Review completed successfully." : "Review cancelled."
                    await onEvent(.progress(.completed, summary))
                    await cleanupForReturn()
                    return ReviewProcessOutcome(
                        state: stateValue,
                        exitCode: exitCode,
                        reviewThreadID: snapshot.reviewThreadID ?? reviewThreadID,
                        threadID: snapshot.threadID ?? threadResponse.thread.id,
                        turnID: snapshot.turnID ?? turnID,
                        model: effectiveModel,
                        lastAgentMessage: review,
                        errorMessage: cancellationReason,
                        summary: summary,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        content: review
                    )
                case .interrupted:
                    let reason = cancellationReason ?? snapshot.errorMessage ?? "Review cancelled."
                    await onEvent(.progress(.completed, "Review cancelled."))
                    await cleanupForReturn()
                    return ReviewProcessOutcome(
                        state: .cancelled,
                        exitCode: exitCode,
                        reviewThreadID: snapshot.reviewThreadID ?? reviewThreadID,
                        threadID: snapshot.threadID ?? threadResponse.thread.id,
                        turnID: snapshot.turnID ?? turnID,
                        model: effectiveModel,
                        lastAgentMessage: snapshot.lastAgentMessage ?? "",
                        errorMessage: reason,
                        summary: "Review cancelled.",
                        startedAt: startedAt,
                        endedAt: endedAt,
                        content: snapshot.finalReview ?? snapshot.lastAgentMessage ?? reason
                    )
                case .failed, .inProgress:
                    let errorMessage = snapshot.errorMessage ?? "Review failed."
                    await onEvent(.progress(.completed, "Review failed."))
                    await cleanupForReturn()
                    return ReviewProcessOutcome(
                        state: .failed,
                        exitCode: exitCode,
                        reviewThreadID: snapshot.reviewThreadID ?? reviewThreadID,
                        threadID: snapshot.threadID ?? threadResponse.thread.id,
                        turnID: snapshot.turnID ?? turnID,
                        model: effectiveModel,
                        lastAgentMessage: snapshot.lastAgentMessage ?? "",
                        errorMessage: errorMessage,
                        summary: "Review failed.",
                        startedAt: startedAt,
                        endedAt: endedAt,
                        content: snapshot.finalReview ?? snapshot.lastAgentMessage ?? errorMessage
                    )
                }
            }

            if let exitCode = await controller.pollExitStatus() {
                let snapshot = await state.snapshot()
                if snapshot.reviewThreadID == nil {
                    await cleanupForThrow()
                    throw ReviewBootstrapFailure(
                        message: bootstrapFailureMessage(exitCode: exitCode, stderr: snapshot.stderrText),
                        model: effectiveModel
                    )
                }
                if snapshot.turnStatus == nil {
                    let observedAt = processExitObservedAt ?? Date()
                    processExitObservedAt = observedAt
                    if Date().timeIntervalSince(observedAt) < 0.25 {
                        try? await Task.sleep(for: .milliseconds(20))
                        continue
                    }
                }
                let endedAt = Date()
                let reason = cancellationReason ?? snapshot.errorMessage ?? "app-server exited unexpectedly (exit=\(exitCode))."
                await onEvent(.progress(.completed, cancellationReason == nil ? "Review failed." : "Review cancelled."))
                await cleanupForReturn()
                return ReviewProcessOutcome(
                    state: cancellationReason == nil ? .failed : .cancelled,
                    exitCode: exitCode,
                    reviewThreadID: snapshot.reviewThreadID,
                    threadID: snapshot.threadID,
                    turnID: snapshot.turnID,
                    model: effectiveModel,
                    lastAgentMessage: snapshot.lastAgentMessage ?? "",
                    errorMessage: reason,
                    summary: cancellationReason == nil ? "Review failed." : "Review cancelled.",
                    startedAt: startedAt,
                    endedAt: endedAt,
                    content: snapshot.finalReview ?? snapshot.lastAgentMessage ?? reason
                )
            }

            if let timeoutSeconds,
               Date().timeIntervalSince(startedAt) >= Double(timeoutSeconds)
            {
                _ = await controller.terminateGracefully(grace: gracefulTerminationWait)
                let snapshot = await state.snapshot()
                let endedAt = Date()
                await onEvent(.progress(.completed, "Review timed out."))
                await cleanupForReturn()
                return ReviewProcessOutcome(
                    state: .failed,
                    exitCode: (await controller.pollExitStatus()) ?? 124,
                    reviewThreadID: snapshot.reviewThreadID,
                    threadID: snapshot.threadID,
                    turnID: snapshot.turnID,
                    model: effectiveModel,
                    lastAgentMessage: snapshot.lastAgentMessage ?? "",
                    errorMessage: "Review timed out after \(timeoutSeconds) seconds.",
                    summary: "Review timed out after \(timeoutSeconds) seconds.",
                    startedAt: startedAt,
                    endedAt: endedAt,
                    content: snapshot.finalReview ?? snapshot.lastAgentMessage ?? "Review timed out."
                )
            }

            if Task.isCancelled {
                let reason = cancellationReason ?? "Review cancelled."
                _ = await controller.terminateGracefully(grace: gracefulTerminationWait)
                let snapshot = await state.snapshot()
                let endedAt = Date()
                await onEvent(.progress(.completed, "Review cancelled."))
                await cleanupForReturn()
                return ReviewProcessOutcome(
                    state: .cancelled,
                    exitCode: (await controller.pollExitStatus()) ?? 130,
                    reviewThreadID: snapshot.reviewThreadID,
                    threadID: snapshot.threadID,
                    turnID: snapshot.turnID,
                    model: effectiveModel,
                    lastAgentMessage: snapshot.lastAgentMessage ?? "",
                    errorMessage: reason,
                    summary: "Review cancelled.",
                    startedAt: startedAt,
                    endedAt: endedAt,
                    content: snapshot.finalReview ?? snapshot.lastAgentMessage ?? reason
                )
            }

            try? await Task.sleep(for: pollInterval)
        }
    }

    private func shouldFallbackFromConfigReadError(_ error: Error) -> Bool {
        guard let responseError = error as? AppServerResponseError else {
            return false
        }
        return responseError.isUnsupportedMethod
    }

    private func cancelledOutcomeBeforeStart(
        requestedModel: String?,
        requestedTerminationReason: @escaping @Sendable () async -> ReviewTerminationReason?,
        onEvent: @escaping @Sendable (ReviewProcessEvent) async -> Void
    ) async -> ReviewProcessOutcome? {
        let cancellationReason: String?
        if Task.isCancelled {
            cancellationReason = "Review cancelled."
        } else if case .cancelled(let reason)? = await requestedTerminationReason() {
            cancellationReason = reason
        } else {
            cancellationReason = nil
        }
        guard let cancellationReason else {
            return nil
        }

        let startedAt = Date()
        await onEvent(.progress(.completed, "Review cancelled."))
        return ReviewProcessOutcome(
            state: .cancelled,
            exitCode: 130,
            reviewThreadID: nil,
            threadID: nil,
            turnID: nil,
            model: requestedModel,
            lastAgentMessage: "",
            errorMessage: cancellationReason,
            summary: "Review cancelled.",
            startedAt: startedAt,
            endedAt: startedAt,
            content: cancellationReason
        )
    }
}

private func handle(
    notification: AppServerServerNotification,
    state: AppServerReviewState,
    onEvent: @escaping @Sendable (ReviewProcessEvent) async -> Void
) async {
    switch notification {
    case .turnStarted(let payload):
        await state.noteTurnStarted(turnID: payload.turn.id)
        await onEvent(.logEntry(.init(kind: .event, text: "Turn started: \(payload.turn.id)")))
    case .turnCompleted(let payload):
        await state.noteTurnCompleted(turn: payload.turn)
    case .itemStarted(let payload):
        switch payload.item {
        case .enteredReviewMode(_, let review):
            await onEvent(.logEntry(.init(kind: .progress, text: "Reviewing \(review)")))
        case .commandExecution(_, let command, _, _, _):
            await onEvent(.logEntry(.init(kind: .command, text: "$ \(command)")))
        case .mcpToolCall(let itemID, let server, let tool, _, _, _):
            await state.noteToolCall(itemID: itemID, server: server, tool: tool)
            await onEvent(.logEntry(.init(
                kind: .toolCall,
                groupID: itemID,
                text: "MCP \(server).\(tool) started."
            )))
        case .contextCompaction:
            await onEvent(.logEntry(.init(kind: .event, text: "Context compaction started.")))
        case .exitedReviewMode, .agentMessage, .plan, .reasoning, .unsupported:
            break
        }
    case .itemCompleted(let payload):
        switch payload.item {
        case .exitedReviewMode(_, let review):
            await state.noteFinalReview(review)
            await onEvent(.agentMessage(review))
            await onEvent(.logEntry(.init(kind: .agentMessage, groupID: payload.turnID, text: review)))
        case .agentMessage(let itemID, let text):
            let completed = await state.noteCompletedAgentMessage(itemID: itemID, text: text)
            await onEvent(.agentMessage(completed.latestText))
            if let logUpdate = completed.logUpdate {
                await onEvent(.logEntry(.init(
                    kind: .agentMessage,
                    groupID: itemID,
                    replacesGroup: logUpdate.replacesGroup,
                    text: logUpdate.text
                )))
            }
        case .commandExecution(let itemID, _, let output, _, _):
            if let output = await state.noteCommandCompleted(itemID: itemID, aggregatedOutput: output),
               output.isEmpty == false
            {
                await onEvent(.logEntry(.init(kind: .commandOutput, groupID: itemID, text: output)))
            }
        case .plan(let itemID, let text):
            if let finalUpdate = await state.notePlanCompleted(itemID: itemID, text: text) {
                await onEvent(.logEntry(.init(
                    kind: .plan,
                    groupID: itemID,
                    replacesGroup: finalUpdate.replacesGroup,
                    text: finalUpdate.text
                )))
            }
        case .reasoning(let itemID, let summary, let content):
            let completed = await state.noteReasoningCompleted(
                itemID: itemID,
                summary: summary,
                content: content
            )
            for summaryEntry in completed.summaryEntries where summaryEntry.update.text.isEmpty == false {
                await onEvent(.logEntry(.init(
                    kind: .reasoningSummary,
                    groupID: summaryEntry.groupID,
                    replacesGroup: summaryEntry.update.replacesGroup,
                    text: summaryEntry.update.text
                )))
            }
            for rawEntry in completed.rawEntries where rawEntry.update.text.isEmpty == false {
                await onEvent(.logEntry(.init(
                    kind: .rawReasoning,
                    groupID: rawEntry.groupID,
                    replacesGroup: rawEntry.update.replacesGroup,
                    text: rawEntry.update.text
                )))
            }
        case .mcpToolCall(let itemID, let server, let tool, let status, let error, let result):
            await state.noteToolCall(itemID: itemID, server: server, tool: tool)
            var text = "MCP \(server).\(tool) \(status)."
            if let error = error?.nilIfEmpty {
                text += " Error: \(error)"
            } else if let result = result?.nilIfEmpty {
                text += " Result: \(result)"
            }
            await onEvent(.logEntry(.init(kind: .toolCall, groupID: itemID, text: text)))
        case .contextCompaction:
            await onEvent(.logEntry(.init(kind: .event, text: "Context compacted.")))
        case .enteredReviewMode, .unsupported:
            break
        }
    case .agentMessageDelta(let payload):
        if let latest = await state.appendAgentMessageDelta(itemID: payload.itemID, delta: payload.delta) {
            await onEvent(.agentMessage(latest))
            await onEvent(.logEntry(.init(kind: .agentMessage, groupID: payload.itemID, text: payload.delta)))
        }
    case .planDelta(let payload):
        if await state.notePlanDelta(itemID: payload.itemID, delta: payload.delta) {
            await onEvent(.logEntry(.init(kind: .plan, groupID: payload.itemID, text: payload.delta)))
        }
    case .commandExecutionOutputDelta(let payload):
        await state.noteCommandOutput(itemID: payload.itemID, delta: payload.delta)
        if payload.delta.isEmpty == false {
            await onEvent(.logEntry(.init(kind: .commandOutput, groupID: payload.itemID, text: payload.delta)))
        }
    case .reasoningSummaryTextDelta(let payload):
        if await state.noteReasoningSummaryDelta(
            itemID: payload.itemID,
            summaryIndex: payload.summaryIndex,
            delta: payload.delta
        ) {
            await onEvent(.logEntry(.init(
                kind: .reasoningSummary,
                groupID: reasoningSummaryGroupID(itemID: payload.itemID, summaryIndex: payload.summaryIndex),
                text: payload.delta
            )))
        }
    case .reasoningSummaryPartAdded(let payload):
        _ = await state.noteReasoningSummaryPartAdded(
            itemID: payload.itemID,
            summaryIndex: payload.summaryIndex
        )
    case .reasoningTextDelta(let payload):
        if await state.noteRawReasoningDelta(
            itemID: payload.itemID,
            contentIndex: payload.contentIndex,
            delta: payload.delta
        ),
           payload.delta.isEmpty == false
        {
            await onEvent(.logEntry(.init(
                kind: .rawReasoning,
                groupID: rawReasoningGroupID(itemID: payload.itemID, contentIndex: payload.contentIndex),
                text: payload.delta
            )))
        }
    case .mcpToolCallProgress(let payload):
        let label = await state.toolCallLabel(itemID: payload.itemID)
        let prefix = label.map { "MCP \($0): " } ?? "MCP: "
        await onEvent(.logEntry(.init(
            kind: .toolCall,
            groupID: payload.itemID,
            text: prefix + payload.message
        )))
    case .ignored:
        break
    }
}

private func bootstrapFailureMessage(exitCode: Int, stderr: String) -> String {
    if stderr.isEmpty == false {
        return "app-server exited before the review started (exit=\(exitCode)): \(stderr)"
    }
    return "app-server exited before the review started (exit=\(exitCode))."
}

private func rawReasoningGroupID(itemID: String, contentIndex: Int) -> String {
    "\(itemID):\(contentIndex)"
}

private func reasoningSummaryGroupID(itemID: String, summaryIndex: Int) -> String {
    "\(itemID):summary:\(summaryIndex)"
}

private func stopAppServer(controller: AppServerProcessController) async -> Int {
    await controller.closeStandardInput()
    if let exitCode = await controller.waitForExit(timeout: .milliseconds(500)) {
        return exitCode
    }
    _ = await controller.terminateGracefully(grace: .seconds(2))
    return (await controller.pollExitStatus()) ?? 0
}

private actor AppServerReviewState {
    enum GroupTextUpdate: Sendable {
        case append(String)
        case replace(String)

        var text: String {
            switch self {
            case .append(let text), .replace(let text):
                return text
            }
        }

        var replacesGroup: Bool {
            if case .replace = self {
                return true
            }
            return false
        }
    }

    struct ReasoningCompletion: Sendable {
        struct SummaryEntry: Sendable {
            var groupID: String
            var update: GroupTextUpdate
        }

        struct RawEntry: Sendable {
            var groupID: String
            var update: GroupTextUpdate
        }

        var summaryEntries: [SummaryEntry]
        var rawEntries: [RawEntry]
    }

    struct Snapshot: Sendable {
        var reviewThreadID: String?
        var threadID: String?
        var turnID: String?
        var turnStatus: AppServerTurnStatus?
        var lastAgentMessage: String?
        var finalReview: String?
        var errorMessage: String?
        var stderrText: String
    }

    private var reviewThreadID: String?
    private var threadID: String?
    private var turnID: String?
    private var turnStatus: AppServerTurnStatus?
    private var lastAgentMessage: String?
    private var finalReview: String?
    private var errorMessage: String?
    private var stderrLines: [String] = []
    private var agentMessagesByItemID: [String: String] = [:]
    private var completedAgentMessageItemIDs = Set<String>()
    private var commandOutputSeen = Set<String>()
    private var streamedPlanByItemID: [String: String] = [:]
    private var completedPlanItemIDs = Set<String>()
    private var streamedReasoningSummaryByItemID: [String: [Int: String]] = [:]
    private var streamedRawReasoningByItemID: [String: [Int: String]] = [:]
    private var completedReasoningItemIDs = Set<String>()
    private var toolCallLabelsByItemID: [String: String] = [:]

    func markReviewStarted(reviewThreadID: String, threadID: String, turnID: String) {
        self.reviewThreadID = reviewThreadID
        self.threadID = threadID
        self.turnID = turnID
    }

    func noteTurnStarted(turnID: String) {
        if self.turnID == nil {
            self.turnID = turnID
        }
    }

    struct CompletedAgentMessage: Sendable {
        var latestText: String
        var logUpdate: GroupTextUpdate?
    }

    func appendAgentMessageDelta(itemID: String, delta: String) -> String? {
        guard completedAgentMessageItemIDs.contains(itemID) == false else {
            return nil
        }
        let current = agentMessagesByItemID[itemID, default: ""]
        let updated = current + delta
        agentMessagesByItemID[itemID] = updated
        lastAgentMessage = updated
        return updated
    }

    func noteCompletedAgentMessage(itemID: String, text: String) -> CompletedAgentMessage {
        completedAgentMessageItemIDs.insert(itemID)
        let streamedText = agentMessagesByItemID[itemID]
        agentMessagesByItemID[itemID] = text
        lastAgentMessage = text
        return CompletedAgentMessage(
            latestText: text,
            logUpdate: completionGroupUpdate(streamedText: streamedText, finalText: text)
        )
    }

    func noteFinalReview(_ review: String) {
        finalReview = review
        lastAgentMessage = review
    }

    func noteTurnCompleted(turn: AppServerTurn) {
        turnID = turn.id
        turnStatus = turn.status
        errorMessage = turn.error?.message?.nilIfEmpty ?? errorMessage
    }

    func noteCommandOutput(itemID: String, delta: String) {
        if delta.isEmpty == false {
            commandOutputSeen.insert(itemID)
        }
    }

    func noteCommandCompleted(itemID: String, aggregatedOutput: String?) -> String? {
        if commandOutputSeen.contains(itemID) {
            return nil
        }
        return aggregatedOutput?.nilIfEmpty
    }

    func noteToolCall(itemID: String, server: String, tool: String) {
        toolCallLabelsByItemID[itemID] = "\(server).\(tool)"
    }

    func toolCallLabel(itemID: String) -> String? {
        toolCallLabelsByItemID[itemID]
    }

    func notePlanDelta(itemID: String, delta: String) -> Bool {
        guard completedPlanItemIDs.contains(itemID) == false else {
            return false
        }
        streamedPlanByItemID[itemID, default: ""] += delta
        return true
    }

    func notePlanCompleted(itemID: String, text: String) -> GroupTextUpdate? {
        completedPlanItemIDs.insert(itemID)
        return completionGroupUpdate(streamedText: streamedPlanByItemID[itemID], finalText: text)
    }

    func noteReasoningSummaryDelta(itemID: String, summaryIndex: Int, delta: String) -> Bool {
        guard completedReasoningItemIDs.contains(itemID) == false else {
            return false
        }
        streamedReasoningSummaryByItemID[itemID, default: [:]][summaryIndex, default: ""] += delta
        return true
    }

    func noteReasoningSummaryPartAdded(itemID: String, summaryIndex: Int) -> Bool {
        guard completedReasoningItemIDs.contains(itemID) == false else {
            return false
        }
        return true
    }

    func noteRawReasoningDelta(itemID: String, contentIndex: Int, delta: String) -> Bool {
        guard completedReasoningItemIDs.contains(itemID) == false else {
            return false
        }
        streamedRawReasoningByItemID[itemID, default: [:]][contentIndex, default: ""] += delta
        return true
    }

    func noteReasoningCompleted(
        itemID: String,
        summary: [String],
        content: [String]
    ) -> ReasoningCompletion {
        completedReasoningItemIDs.insert(itemID)
        let streamedSummary = streamedReasoningSummaryByItemID[itemID] ?? [:]
        var summaryEntries: [ReasoningCompletion.SummaryEntry] = []

        for (index, finalText) in summary.enumerated() {
            guard let remainder = completionGroupUpdate(
                streamedText: streamedSummary[index],
                finalText: finalText
            ) else {
                continue
            }
            summaryEntries.append(.init(
                groupID: reasoningSummaryGroupID(itemID: itemID, summaryIndex: index),
                update: remainder
            ))
        }

        var rawEntries: [ReasoningCompletion.RawEntry] = []
        let streamedRaw = streamedRawReasoningByItemID[itemID] ?? [:]
        for (index, finalText) in content.enumerated() {
            guard let remainder = completionGroupUpdate(
                streamedText: streamedRaw[index],
                finalText: finalText
            ) else {
                continue
            }
            rawEntries.append(.init(
                groupID: rawReasoningGroupID(itemID: itemID, contentIndex: index),
                update: remainder
            ))
        }

        return ReasoningCompletion(
            summaryEntries: summaryEntries,
            rawEntries: rawEntries
        )
    }

    func appendStandardError(_ line: String) {
        stderrLines.append(line)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            reviewThreadID: reviewThreadID,
            threadID: threadID,
            turnID: turnID,
            turnStatus: turnStatus,
            lastAgentMessage: lastAgentMessage,
            finalReview: finalReview,
            errorMessage: errorMessage,
            stderrText: stderrLines.joined(separator: "\n")
        )
    }

    private func completionGroupUpdate(streamedText: String?, finalText: String) -> GroupTextUpdate? {
        guard finalText.isEmpty == false else {
            return nil
        }
        guard let streamedText else {
            return .append(finalText)
        }
        if streamedText.isEmpty {
            return .append(finalText)
        }
        if finalText.hasPrefix(streamedText) {
            guard let suffix = String(finalText.dropFirst(streamedText.count)).nilIfEmpty else {
                return nil
            }
            return .append(suffix)
        }
        return .replace(finalText)
    }
}

package actor AppServerProcessController {
    package struct StartedProcess: Sendable {
        package var controller: AppServerProcessController
        package var stdoutHandle: FileHandle
        package var stderrHandle: FileHandle
    }

    private let pid: pid_t
    private let stdinHandle: FileHandle
    private var cachedExitCode: Int?

    private init(pid: pid_t, stdinHandle: FileHandle) {
        self.pid = pid
        self.stdinHandle = stdinHandle
    }

    package static func start(command: AppServerCommand) throws -> StartedProcess {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: command.currentDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ReviewError.spawnFailed("Working directory does not exist or is not a directory: \(command.currentDirectory)")
        }

        let executable = try resolveExecutable(for: command)
        let stdinPipe = try makePipe()
        let stdoutPipe = try makePipe()
        let stderrPipe = try makePipe()
        var stdinReadFD = stdinPipe.read
        var stdinWriteFD = stdinPipe.write
        var stdoutReadFD = stdoutPipe.read
        var stdoutWriteFD = stdoutPipe.write
        var stderrReadFD = stderrPipe.read
        var stderrWriteFD = stderrPipe.write
        defer {
            for fd in [stdinReadFD, stdinWriteFD, stdoutReadFD, stdoutWriteFD, stderrReadFD, stderrWriteFD] where fd >= 0 {
                close(fd)
            }
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        try throwOnPOSIX(posix_spawn_file_actions_init(&fileActions), context: "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        try throwOnPOSIX(posix_spawn_file_actions_adddup2(&fileActions, stdinPipe.read, STDIN_FILENO), context: "stdin dup2")
        try throwOnPOSIX(posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe.write, STDOUT_FILENO), context: "stdout dup2")
        try throwOnPOSIX(posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.write, STDERR_FILENO), context: "stderr dup2")
        try throwOnPOSIX(posix_spawn_file_actions_addclose(&fileActions, stdinPipe.write), context: "close stdin write")
        try throwOnPOSIX(posix_spawn_file_actions_addclose(&fileActions, stdoutPipe.read), context: "close stdout read")
        try throwOnPOSIX(posix_spawn_file_actions_addclose(&fileActions, stderrPipe.read), context: "close stderr read")
        try command.currentDirectory.withCString { path in
            if #available(macOS 26.0, *) {
                try throwOnPOSIX(posix_spawn_file_actions_addchdir(&fileActions, path), context: "chdir")
            } else {
                try throwOnPOSIX(posix_spawn_file_actions_addchdir_np(&fileActions, path), context: "chdir")
            }
        }

        var attributes: posix_spawnattr_t? = nil
        try throwOnPOSIX(posix_spawnattr_init(&attributes), context: "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }

        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        sigaddset(&defaultSignals, SIGINT)

        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF)
        try throwOnPOSIX(posix_spawnattr_setflags(&attributes, flags), context: "posix_spawnattr_setflags")
        try throwOnPOSIX(posix_spawnattr_setpgroup(&attributes, 0), context: "posix_spawnattr_setpgroup")
        try throwOnPOSIX(posix_spawnattr_setsigdefault(&attributes, &defaultSignals), context: "posix_spawnattr_setsigdefault")

        let argv = [executable] + command.arguments
        let envp = command.environment.map { "\($0.key)=\($0.value)" }

        let pid = try withCStringArray(argv) { argvPointers in
            try withCStringArray(envp) { envPointers in
                var pid: pid_t = 0
                let status = executable.withCString { executablePointer in
                    posix_spawn(&pid, executablePointer, &fileActions, &attributes, argvPointers, envPointers)
                }
                try throwOnPOSIX(status, context: "posix_spawn")
                return pid
            }
        }

        let stdinHandle = FileHandle(fileDescriptor: stdinWriteFD, closeOnDealloc: true)
        let stdoutHandle = FileHandle(fileDescriptor: stdoutReadFD, closeOnDealloc: true)
        let stderrHandle = FileHandle(fileDescriptor: stderrReadFD, closeOnDealloc: true)
        stdinWriteFD = -1
        stdoutReadFD = -1
        stderrReadFD = -1
        stdinReadFD = -1
        stdoutWriteFD = -1
        stderrWriteFD = -1

        return StartedProcess(
            controller: AppServerProcessController(pid: pid, stdinHandle: stdinHandle),
            stdoutHandle: stdoutHandle,
            stderrHandle: stderrHandle
        )
    }

    package func writeLine(_ data: Data) throws {
        try stdinHandle.write(contentsOf: data + Data([0x0A]))
    }

    package func closeStandardInput() {
        try? stdinHandle.close()
    }

    package func pollExitStatus() -> Int? {
        if let cachedExitCode {
            return cachedExitCode
        }
        var status: Int32 = 0
        let waitResult = waitpid(pid, &status, WNOHANG)
        if waitResult == 0 {
            return nil
        }
        if waitResult == pid {
            let exitCode = normalizeWaitStatus(status)
            cachedExitCode = exitCode
            return exitCode
        }
        if waitResult == -1, errno == ECHILD {
            return cachedExitCode
        }
        return nil
    }

    package func waitForExit(timeout: Duration) async -> Int? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let exitCode = pollExitStatus() {
                return exitCode
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return pollExitStatus()
    }

    package func terminateGracefully(grace: Duration) async -> Bool {
        guard pollExitStatus() == nil else {
            return false
        }
        killpg(pid, SIGTERM)
        let deadline = ContinuousClock.now.advanced(by: grace)
        while ContinuousClock.now < deadline {
            if pollExitStatus() != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        killpg(pid, SIGKILL)
        _ = await waitForExit(timeout: .seconds(2))
        return true
    }
}

private actor AppServerConnection {
    private let controller: AppServerProcessController
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let onNotification: @Sendable (AppServerServerNotification) async -> Void
    private let onStderrLine: @Sendable (String) async -> Void
    private var nextRequestID = 1
    private var pendingResponses: [AppServerRequestID: CheckedContinuation<Data, Error>] = [:]
    private var stdoutFramer = AppServerJSONLFramer()
    private var stderrFramer = AppServerJSONLFramer()
    private var stdoutReadTask: Task<Void, Never>?
    private var stderrReadTask: Task<Void, Never>?
    private var exitMonitorTask: Task<Void, Never>?
    private var stopped = false

    init(
        controller: AppServerProcessController,
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle,
        onNotification: @escaping @Sendable (AppServerServerNotification) async -> Void,
        onStderrLine: @escaping @Sendable (String) async -> Void
    ) {
        self.controller = controller
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
        self.onNotification = onNotification
        self.onStderrLine = onStderrLine
    }

    func start() {
        guard stopped == false else {
            return
        }
        stdoutReadTask = Task.detached { [weak self] in
            guard let self else { return }
            while true {
                let data = self.stdoutHandle.availableData
                await self.consumeStdoutData(data)
                if data.isEmpty {
                    return
                }
            }
        }
        stderrReadTask = Task.detached { [weak self] in
            guard let self else { return }
            while true {
                let data = self.stderrHandle.availableData
                await self.consumeStderrData(data)
                if data.isEmpty {
                    return
                }
            }
        }
        exitMonitorTask = Task.detached { [weak self] in
            guard let self else { return }
            _ = await self.controller.waitForExit(timeout: .seconds(600))
            await self.handleProcessExit()
        }
    }

    func initialize() async throws -> AppServerInitializeResponse {
        let response: AppServerInitializeResponse = try await request(
            method: "initialize",
            params: AppServerInitializeParams(
                clientInfo: .init(
                    name: codexReviewMCPName,
                    title: "Codex Review MCP",
                    version: codexReviewMCPVersion
                )
            ),
            responseType: AppServerInitializeResponse.self
        )
        try await notify(method: "initialized", params: AppServerInitializedParams())
        return response
    }

    func request<Params: Encodable, Response: Decodable>(
        method: String,
        params: Params,
        responseType: Response.Type
    ) async throws -> Response {
        let id = AppServerRequestID.integer(nextRequestID)
        nextRequestID += 1
        let payload = try encoder.encode(
            AppServerRequestEnvelope(
                id: id,
                method: method,
                params: params
            )
        )
        let responseData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            pendingResponses[id] = continuation
            Task {
                do {
                    try await self.controller.writeLine(payload)
                } catch {
                    self.failPendingResponse(id: id, error: error)
                }
            }
        }
        return try decoder.decode(AppServerResponseEnvelope<Response>.self, from: responseData).result
    }

    func notify<Params: Encodable>(method: String, params: Params) async throws {
        let payload = try encoder.encode(
            AppServerOutgoingNotificationEnvelope(
                method: method,
                params: params
            )
        )
        try await controller.writeLine(payload)
    }

    func stop() async {
        guard stopped == false else {
            return
        }
        stopped = true
        exitMonitorTask?.cancel()
        exitMonitorTask = nil
        try? stdoutHandle.close()
        try? stderrHandle.close()
        await stdoutReadTask?.value
        await stderrReadTask?.value
        stdoutReadTask = nil
        stderrReadTask = nil
        for (_, continuation) in pendingResponses {
            continuation.resume(throwing: ReviewError.io("app-server connection stopped."))
        }
        pendingResponses.removeAll()
    }

    func synchronize() async {
        // Reader loops run in detached tasks; yield once so any just-read chunk can
        // enter the actor queue before this barrier returns.
        await Task.yield()
    }

    private func consumeStdoutData(_ data: Data) async {
        if data.isEmpty {
            await handleStdoutClosed()
            return
        }
        for message in stdoutFramer.append(data) {
            await processStdoutMessage(message)
        }
    }

    private func handleStdoutClosed() async {
        if stopped == false {
            for message in stdoutFramer.finish() {
                await processStdoutMessage(message)
            }
            failPendingResponses(message: "app-server stdout closed unexpectedly.")
        }
    }

    private func handleProcessExit() {
        guard stopped == false else {
            return
        }
        failPendingResponses(message: "app-server process exited before responding.")
    }

    private func consumeStderrData(_ data: Data) async {
        if data.isEmpty {
            for line in stderrFramer.finish() {
                await emitStderrLine(line)
            }
            return
        }
        for line in stderrFramer.append(data) {
            await emitStderrLine(line)
        }
    }

    private func emitStderrLine(_ line: Data) async {
        guard let text = String(data: line, encoding: .utf8) else {
            return
        }
        await onStderrLine(text)
    }

    private func processStdoutMessage(_ data: Data) async {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let idObject = object["id"], let requestID = AppServerRequestID(jsonObject: idObject) {
            if let method = object["method"] as? String {
                await rejectServerRequest(id: requestID, method: method)
                return
            }
            guard let continuation = pendingResponses.removeValue(forKey: requestID) else {
                return
            }
            if let error = parseResponseError(from: object) {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: data)
            }
            return
        }

        guard let method = object["method"] as? String else {
            return
        }
        await onNotification(decodeNotification(method: method, data: data))
    }

    private func rejectServerRequest(id: AppServerRequestID, method: String) async {
        let payload = [
            "id": id.foundationObject,
            "error": [
                "code": -32601,
                "message": "Unsupported app-server request `\(method)`."
            ]
        ] as [String : Any]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        try? await controller.writeLine(data)
    }

    private func failPendingResponses(message: String) {
        for (_, continuation) in pendingResponses {
            continuation.resume(throwing: ReviewError.io(message))
        }
        pendingResponses.removeAll()
    }

    private func failPendingResponse(id: AppServerRequestID, error: Error) {
        guard let continuation = pendingResponses.removeValue(forKey: id) else {
            return
        }
        continuation.resume(throwing: error)
    }

    private func parseResponseError(from object: [String: Any]) -> AppServerResponseError? {
        guard let error = object["error"] as? [String: Any] else {
            return nil
        }
        let code = (error["code"] as? Int)
            ?? (error["code"] as? NSNumber)?.intValue
        let message = (error["message"] as? String)?.nilIfEmpty ?? "app-server request failed."
        return AppServerResponseError(code: code, message: message)
    }

    private func decodeNotification(method: String, data: Data) -> AppServerServerNotification {
        switch method {
        case "turn/started":
            if let notification = try? decoder.decode(
                AppServerIncomingNotificationEnvelope<AppServerTurnStartedNotification>.self,
                from: data
            ) {
                return .turnStarted(notification.params)
            }
        case "turn/completed":
            if let notification = try? decoder.decode(
                AppServerIncomingNotificationEnvelope<AppServerTurnCompletedNotification>.self,
                from: data
            ) {
                return .turnCompleted(notification.params)
            }
        case "item/started":
            if let notification = try? decoder.decode(
                AppServerIncomingNotificationEnvelope<AppServerItemStartedNotification>.self,
                from: data
            ) {
                return .itemStarted(notification.params)
            }
        case "item/completed":
            if let notification = try? decoder.decode(
                AppServerIncomingNotificationEnvelope<AppServerItemCompletedNotification>.self,
                from: data
            ) {
                return .itemCompleted(notification.params)
            }
        case "item/agentMessage/delta":
            if let notification = try? decoder.decode(
                AppServerIncomingNotificationEnvelope<AppServerAgentMessageDeltaNotification>.self,
                from: data
            ) {
                return .agentMessageDelta(notification.params)
            }
        case "item/plan/delta":
            if let notification = try? decoder.decode(
                AppServerIncomingNotificationEnvelope<AppServerPlanDeltaNotification>.self,
                from: data
            ) {
                return .planDelta(notification.params)
            }
        case "item/commandExecution/outputDelta":
            if let notification = try? decoder.decode(
                AppServerIncomingNotificationEnvelope<AppServerCommandExecutionOutputDeltaNotification>.self,
                from: data
            ) {
                return .commandExecutionOutputDelta(notification.params)
            }
        case "item/reasoning/summaryTextDelta":
            if let notification = try? decoder.decode(
                AppServerIncomingNotificationEnvelope<AppServerReasoningSummaryTextDeltaNotification>.self,
                from: data
            ) {
                return .reasoningSummaryTextDelta(notification.params)
            }
        case "item/reasoning/summaryPartAdded":
            if let notification = try? decoder.decode(
                AppServerIncomingNotificationEnvelope<AppServerReasoningSummaryPartAddedNotification>.self,
                from: data
            ) {
                return .reasoningSummaryPartAdded(notification.params)
            }
        case "item/reasoning/textDelta":
            if let notification = try? decoder.decode(
                AppServerIncomingNotificationEnvelope<AppServerReasoningTextDeltaNotification>.self,
                from: data
            ) {
                return .reasoningTextDelta(notification.params)
            }
        case "item/mcpToolCall/progress":
            if let notification = try? decoder.decode(
                AppServerIncomingNotificationEnvelope<AppServerMcpToolCallProgressNotification>.self,
                from: data
            ) {
                return .mcpToolCallProgress(notification.params)
            }
        default:
            break
        }
        return .ignored
    }
}

private struct AppServerRequestEnvelope<Params: Encodable>: Encodable {
    var id: AppServerRequestID
    var method: String
    var params: Params

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch id {
        case .string(let value):
            try container.encode(value, forKey: .id)
        case .integer(let value):
            try container.encode(value, forKey: .id)
        case .double(let value):
            try container.encode(value, forKey: .id)
        }
        try container.encode(method, forKey: .method)
        try container.encode(params, forKey: .params)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case method
        case params
    }
}


private struct AppServerOutgoingNotificationEnvelope<Params: Encodable>: Encodable {
    var method: String
    var params: Params
}

private struct AppServerIncomingNotificationEnvelope<Params: Decodable>: Decodable {
    var method: String
    var params: Params
}

private struct AppServerResponseEnvelope<Result: Decodable>: Decodable {
    var result: Result
}

private func resolveExecutable(for command: AppServerCommand) throws -> String {
    if command.executable.contains("/") {
        return command.executable
    }

    guard let resolved = resolveCodexCommand(
        requestedCommand: command.executable,
        environment: command.environment,
        currentDirectory: command.currentDirectory
    ) else {
        throw ReviewError.spawnFailed(
            "Unable to locate \(command.executable) executable. Set --codex-command or ensure PATH contains \(command.executable)."
        )
    }
    return resolved
}

private func makePipe() throws -> (read: Int32, write: Int32) {
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else {
        throw ReviewError.spawnFailed("pipe: \(String(cString: strerror(errno)))")
    }
    return (descriptors[0], descriptors[1])
}

private func normalizeWaitStatus(_ status: Int32) -> Int {
    if wifsignaled(status) {
        return 128 + Int(wtermsig(status))
    }
    if wifexited(status) {
        return Int(wexitstatus(status))
    }
    return Int(status)
}

private func throwOnPOSIX(_ result: Int32, context: String) throws {
    guard result == 0 else {
        let message = String(cString: strerror(result))
        throw ReviewError.spawnFailed("\(context): \(message)")
    }
}

private func withCStringArray<Result>(
    _ values: [String],
    body: ([UnsafeMutablePointer<CChar>?]) throws -> Result
) throws -> Result {
    var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
    pointers.append(nil)
    defer {
        for pointer in pointers where pointer != nil {
            free(pointer)
        }
    }
    return try body(pointers)
}

private func wifexited(_ status: Int32) -> Bool {
    (status & 0x7f) == 0
}

private func wexitstatus(_ status: Int32) -> Int32 {
    (status >> 8) & 0xff
}

private func wifsignaled(_ status: Int32) -> Bool {
    let signal = status & 0x7f
    return signal != 0 && signal != 0x7f
}

private func wtermsig(_ status: Int32) -> Int32 {
    status & 0x7f
}
