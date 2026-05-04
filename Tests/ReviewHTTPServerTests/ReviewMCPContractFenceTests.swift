import Foundation
import MCP
@testable import ReviewMCPAdapter

import ReviewDomain
import ReviewPorts
import Testing

@Suite
struct ReviewMCPContractFenceTests {
    @Test func reviewToolCatalogExposesStableToolNamesAndAnnotations() {
        let tools = ReviewToolCatalog.tools

        #expect(tools.map(\.name) == [
            "review_start",
            "review_list",
            "review_read",
            "review_cancel",
        ])
        #expect(tools[0].annotations.readOnlyHint == false)
        #expect(tools[1].annotations.readOnlyHint == true)
        #expect(tools[2].annotations.readOnlyHint == true)
        #expect(tools[3].annotations.readOnlyHint == false)
        #expect(tools[3].annotations.idempotentHint == true)
        #expect(tools[3].annotations.openWorldHint == false)
        #expect(tools[0].description?.contains(ReviewHelpCatalog.toolURI("review_start")) == true)
        #expect(tools[2].description?.contains(ReviewHelpCatalog.toolURI("review_read")) == true)
    }

    @Test func reviewStartAdvertisesTargetAsCanonicalObject() throws {
        let tool = try #require(ReviewToolCatalog.tools.first { $0.name == "review_start" })
        let inputSchema = try #require(tool.inputSchema.objectValue)
        let properties = try #require(inputSchema["properties"]?.objectValue)
        let targetSchema = try #require(properties["target"]?.objectValue)
        let targetProperties = try #require(targetSchema["properties"]?.objectValue)
        let targetTypeSchema = try #require(targetProperties["type"]?.objectValue)
        let targetConstraints = try #require(targetSchema["allOf"]?.arrayValue)
        let baseBranchConstraint = try targetConstraint(targetConstraints, for: "baseBranch")
        let commitConstraint = try targetConstraint(targetConstraints, for: "commit")
        let customConstraint = try targetConstraint(targetConstraints, for: "custom")
        let uncommittedChangesConstraint = try targetConstraint(targetConstraints, for: "uncommittedChanges")

        #expect(targetSchema["type"] == .string("object"))
        #expect(targetSchema["oneOf"] == nil)
        #expect(targetSchema["required"]?.arrayValue == [.string("type")])
        #expect(targetTypeSchema["enum"]?.arrayValue == ReviewHelpCatalog.targetTypes.map(Value.string))
        #expect(targetConstraints.count == 4)
        #expect(try requiredProperties(in: baseBranchConstraint) == ["branch"])
        #expect(try requiredProperties(in: commitConstraint) == ["sha"])
        #expect(try requiredProperties(in: customConstraint) == ["instructions"])
        #expect(try forbiddenProperties(in: uncommittedChangesConstraint) == [
            "branch",
            "sha",
            "title",
            "instructions",
        ])
        #expect(try forbiddenProperties(in: commitConstraint) == ["branch", "instructions"])
        #expect(tool.description?.contains("Compatibility shorthand") == false)
    }

    @Test func reviewHelpCatalogExposesStableResourcesAndTemplates() throws {
        #expect(ReviewHelpCatalog.staticResources.map(\.uri) == [
            ReviewHelpCatalog.overviewURI,
            ReviewHelpCatalog.troubleshootingURI,
        ])
        #expect(ReviewHelpCatalog.resourceTemplates.map(\.uriTemplate) == [
            ReviewHelpCatalog.toolTemplateURI,
            ReviewHelpCatalog.targetTemplateURI,
        ])

        let overview = try ReviewHelpCatalog.readResource(uri: ReviewHelpCatalog.overviewURI)
        let toolHelp = try ReviewHelpCatalog.readResource(
            uri: ReviewHelpCatalog.toolURI("review_start")
        )
        let targetHelp = try ReviewHelpCatalog.readResource(
            uri: ReviewHelpCatalog.targetURI("commit")
        )

        #expect(overview.contents.first?.uri == ReviewHelpCatalog.overviewURI)
        #expect(overview.contents.first?.text?.contains("# Review MCP Overview") == true)
        #expect(toolHelp.contents.first?.text?.contains("# `review_start`") == true)
        #expect(targetHelp.contents.first?.text?.contains(#"# `target.type = "commit"`"#) == true)
    }

    @Test func reviewJobToolsDocumentProcessWideScope() throws {
        let overview = try ReviewHelpCatalog.readResource(uri: ReviewHelpCatalog.overviewURI)
        let readHelp = try ReviewHelpCatalog.readResource(
            uri: ReviewHelpCatalog.toolURI("review_read")
        )
        let listHelp = try ReviewHelpCatalog.readResource(
            uri: ReviewHelpCatalog.toolURI("review_list")
        )
        let cancelHelp = try ReviewHelpCatalog.readResource(
            uri: ReviewHelpCatalog.toolURI("review_cancel")
        )
        let helpText = [
            try #require(overview.contents.first?.text),
            try #require(readHelp.contents.first?.text),
            try #require(listHelp.contents.first?.text),
            try #require(cancelHelp.contents.first?.text),
            ReviewHelpCatalog.reviewReadDescription,
            ReviewHelpCatalog.reviewListDescription,
            ReviewHelpCatalog.reviewCancelDescription,
        ].joined(separator: "\n")

        #expect(helpText.contains("current MCP session") == false)
        #expect(helpText.contains("known to this Review Monitor process"))
    }

    @Test func reviewStartHelpUsesCanonicalTargetObjectOnly() throws {
        let toolHelp = try ReviewHelpCatalog.readResource(
            uri: ReviewHelpCatalog.toolURI("review_start")
        )
        let troubleshooting = try ReviewHelpCatalog.readResource(
            uri: ReviewHelpCatalog.troubleshootingURI
        )
        let toolHelpText = try #require(toolHelp.contents.first?.text)
        let troubleshootingText = try #require(troubleshooting.contents.first?.text)

        #expect(toolHelpText.contains(#""target": {"#))
        #expect(toolHelpText.contains(#"target: "uncommitted""#) == false)
        #expect(toolHelpText.contains(#"target: "uncommittedChanges""#) == false)
        #expect(troubleshootingText.contains(#"target: "uncommitted""#) == false)
    }

    @Test func reviewStartValidationErrorsReturnStableGuidanceEnvelope() async throws {
        let handler = makeHandler()
        let result = await handler.handle(
            params: CallTool.Parameters(
                name: "review_start",
                arguments: [
                    "cwd": "/tmp/repo",
                    "target": [
                        "type": "baseBranch",
                    ],
                ]
            )
        )

        #expect(result.isError == true)
        let object = try #require(result.structuredContent?.objectValue)
        let helpResources = try #require(object["helpResources"]?.arrayValue)
        let helpTemplates = try #require(object["helpTemplates"]?.arrayValue)
        #expect(Set(object.keys) == [
            "acceptedTargetTypes",
            "detail",
            "example",
            "helpResources",
            "helpTemplates",
        ])
        #expect(object["acceptedTargetTypes"]?.arrayValue?.count == 4)
        #expect(helpResources == [
            .string(ReviewHelpCatalog.overviewURI),
            .string(ReviewHelpCatalog.troubleshootingURI),
        ])
        #expect(helpTemplates == [
            .string(ReviewHelpCatalog.toolTemplateURI),
            .string(ReviewHelpCatalog.targetTemplateURI),
        ])
    }

    @Test func reviewStartStructuredContentKeysRemainStable() async throws {
        let handler = makeHandler(
            startReview: { _ in
                ReviewReadResult(
                    jobID: "job_1",
                    core: makeCore(
                        status: .succeeded,
                        threadID: "thr_1",
                        turnID: "turn_1",
                        model: "gpt-5.4",
                        summary: "Review completed successfully.",
                        hasFinalReview: true,
                        lastAgentMessage: "Looks good"
                    ),
                    cancellable: false,
                    logs: [],
                    rawLogText: ""
                )
            }
        )

        let result = await handler.handle(
            params: CallTool.Parameters(
                name: "review_start",
                arguments: [
                    "cwd": "/tmp/repo",
                    "target": [
                        "type": "uncommittedChanges",
                    ],
                ]
            )
        )

        #expect(result.isError == false)
        let object = try #require(result.structuredContent?.objectValue)
        #expect(Set(object.keys) == [
            "jobId",
            "lifecycle",
            "output",
            "run",
        ])
    }

    @Test func reviewStartStructuredContentIncludesParsedReviewResult() async throws {
        let dash = "\u{2014}"
        let reviewResult = ParsedReviewResult.parse(finalReviewText: """
        The changes introduce one issue.

        Review comment:

        - [P2] Keep result data structured \(dash) /tmp/repo/Sources/App.swift:11-13
          UI clients should not have to parse rendered review text.
        """)
        let handler = makeHandler(
            startReview: { _ in
                ReviewReadResult(
                    jobID: "job_structured",
                    core: makeCore(
                        status: .succeeded,
                        threadID: "thr_structured",
                        turnID: "turn_structured",
                        model: "gpt-5.4",
                        summary: "Review completed successfully.",
                        hasFinalReview: true,
                        lastAgentMessage: "review text",
                        reviewResult: reviewResult
                    ),
                    cancellable: false,
                    logs: [],
                    rawLogText: ""
                )
            }
        )

        let result = await handler.handle(
            params: CallTool.Parameters(
                name: "review_start",
                arguments: [
                    "cwd": "/tmp/repo",
                    "target": [
                        "type": "uncommittedChanges",
                    ],
                ]
            )
        )

        let object = try #require(result.structuredContent?.objectValue)
        let outputObject = try #require(object["output"]?.objectValue)
        let resultObject = try #require(outputObject["reviewResult"]?.objectValue)
        #expect(resultObject["state"] == Value.string("hasFindings"))
        #expect(resultObject["findingCount"] == Value.int(1))
        let findingObject = try #require(resultObject["findings"]?.arrayValue?.first?.objectValue)
        #expect(findingObject["title"] == Value.string("[P2] Keep result data structured"))
        #expect(findingObject["body"] == Value.string("UI clients should not have to parse rendered review text."))
        #expect(findingObject["priority"] == Value.int(2))
        let locationObject = try #require(findingObject["location"]?.objectValue)
        #expect(locationObject["path"] == Value.string("/tmp/repo/Sources/App.swift"))
        #expect(locationObject["startLine"] == Value.int(11))
        #expect(locationObject["endLine"] == Value.int(13))
    }

    @Test func reviewStartStillAcceptsLegacyStringTargets() async throws {
        let recorder = ReviewStartRequestRecorder()
        let handler = makeHandler(
            startReview: { request in
                await recorder.record(request)
                return ReviewReadResult(
                    jobID: "job_legacy",
                    core: makeCore(
                        status: .succeeded,
                        threadID: "thr_legacy",
                        turnID: "turn_legacy",
                        model: "gpt-5.4",
                        summary: "Review completed successfully.",
                        hasFinalReview: true,
                        lastAgentMessage: "Looks good"
                    ),
                    cancellable: false,
                    logs: [],
                    rawLogText: ""
                )
            }
        )

        for target in ["uncommitted", "uncommittedChanges"] {
            let result = await handler.handle(
                params: CallTool.Parameters(
                    name: "review_start",
                    arguments: [
                        "cwd": "/tmp/repo",
                        "target": .string(target),
                    ]
                )
            )
            #expect(result.isError == false)
        }

        let requests = await recorder.snapshot()
        #expect(requests.map(\.cwd) == ["/tmp/repo", "/tmp/repo"])
        #expect(requests.map(\.target) == [.uncommittedChanges, .uncommittedChanges])
    }

    @Test func reviewReadStructuredContentKeysRemainStable() async throws {
        let handler = makeHandler(
            readReview: { _ in
                ReviewReadResult(
                    jobID: "job_2",
                    core: makeCore(
                        status: .failed,
                        threadID: "thr_2",
                        turnID: "turn_2",
                        model: "gpt-5.4-mini",
                        exitCode: 1,
                        summary: "Review failed.",
                        lastAgentMessage: "last agent message",
                        errorMessage: "boom"
                    ),
                    cancellable: false,
                    logs: [
                        ReviewLogEntry(
                            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                            kind: ReviewLogEntry.Kind.progress,
                            text: "Running"
                        ),
                    ],
                    rawLogText: "raw logs"
                )
            }
        )

        let result = await handler.handle(
            params: CallTool.Parameters(
                name: "review_read",
                arguments: [
                    "jobId": "job_2",
                ]
            )
        )

        #expect(result.isError == true)
        let object = try #require(result.structuredContent?.objectValue)
        #expect(Set(object.keys) == [
            "jobId",
            "lifecycle",
            "logs",
            "output",
            "rawLogText",
            "run",
        ])
    }

    @Test func reviewListStructuredContentKeysRemainStable() async throws {
        let handler = makeHandler(
            listReviews: { _, _, _ in
                ReviewListResult(
                    items: [
                        ReviewJobListItem(
                            jobID: "job_3",
                            cwd: "/tmp/repo",
                            targetSummary: "current changes",
                            core: makeCore(
                                status: .running,
                                threadID: "thr_3",
                                model: "gpt-5.4",
                                startedAt: Date(timeIntervalSince1970: 1),
                                summary: "Running.",
                                lastAgentMessage: "working"
                            ),
                            elapsedSeconds: 12,
                            cancellable: true
                        ),
                    ]
                )
            }
        )

        let result = await handler.handle(
            params: CallTool.Parameters(
                name: "review_list",
                arguments: [
                    "cwd": "/tmp/repo",
                ]
            )
        )

        #expect(result.isError == false)
        let object = try #require(result.structuredContent?.objectValue)
        let firstItem = try #require(object["items"]?.arrayValue?.first?.objectValue)
        #expect(Set(object.keys) == ["items"])
        #expect(Set(firstItem.keys) == [
            "cwd",
            "jobId",
            "lifecycle",
            "output",
            "run",
            "targetSummary",
        ])
        let runObject = try #require(firstItem["run"]?.objectValue)
        #expect(runObject["threadId"] == Value.string("thr_3"))
        #expect(runObject["model"] == Value.string("gpt-5.4"))
        let lifecycleObject = try #require(firstItem["lifecycle"]?.objectValue)
        #expect(lifecycleObject["status"] == Value.string("running"))
        #expect(lifecycleObject["elapsedSeconds"] == Value.int(12))
        #expect(lifecycleObject["cancellable"] == Value.bool(true))
        let outputObject = try #require(firstItem["output"]?.objectValue)
        #expect(outputObject["summary"] == Value.string("Running."))
        #expect(outputObject["lastAgentMessage"] == Value.string("working"))
    }

    @Test func reviewCancelStructuredContentKeysRemainStable() async throws {
        let handler = makeHandler(
            cancelReviewByID: { _, cancellation in
                ReviewCancelOutcome(
                    jobID: "job_4",
                    cancelled: true,
                    core: makeCore(
                        status: .cancelled,
                        threadID: "thr_4",
                        summary: cancellation.message,
                        cancellation: cancellation,
                        errorMessage: cancellation.message
                    )
                )
            }
        )

        let result = await handler.handle(
            params: CallTool.Parameters(
                name: "review_cancel",
                arguments: [
                    "jobId": "job_4",
                ]
            )
        )

        #expect(result.isError == false)
        let object = try #require(result.structuredContent?.objectValue)
        #expect(Set(object.keys) == [
            "cancelled",
            "jobId",
            "lifecycle",
            "output",
            "run",
        ])
        let lifecycleObject = try #require(object["lifecycle"]?.objectValue)
        #expect(lifecycleObject["status"] == Value.string("cancelled"))
        let runObject = try #require(object["run"]?.objectValue)
        #expect(runObject["threadId"] == Value.string("thr_4"))
        try expectCancellation(
            lifecycleObject["cancellation"],
            source: "mcpClient",
            message: "Cancellation requested by MCP client."
        )
    }

    @Test func reviewCancelWithoutCancellationMetadataUsesNeutralText() async throws {
        let handler = makeHandler(
            cancelReviewByID: { _, _ in
                ReviewCancelOutcome(
                    jobID: "job_legacy_cancelled",
                    cancelled: true,
                    core: makeCore(
                        status: .cancelled,
                        threadID: "thr_legacy_cancelled",
                        summary: "Review cancelled."
                    )
                )
            }
        )

        let result = await handler.handle(
            params: CallTool.Parameters(
                name: "review_cancel",
                arguments: [
                    "jobId": "job_legacy_cancelled",
                ]
            )
        )

        #expect(result.isError == false)
        let content = try #require(result.content.first)
        guard case .text(let text, _, _) = content else {
            Issue.record("Expected text content")
            return
        }
        #expect(text == "Review cancelled.")
        let object = try #require(result.structuredContent?.objectValue)
        #expect(Set(object.keys) == [
            "cancelled",
            "jobId",
            "lifecycle",
            "output",
            "run",
        ])
    }

    @Test func cancelledReviewStructuredContentIncludesCancellationMetadata() async throws {
        let cancellation = ReviewCancellation.userInterface()
        let startResult = ReviewReadResult(
            jobID: "job_start_cancelled",
            core: makeCore(
                status: .cancelled,
                summary: cancellation.message,
                cancellation: cancellation,
                errorMessage: cancellation.message
            ),
            cancellable: false,
            logs: [],
            rawLogText: ""
        ).structuredContentForStart()
        let readResult = ReviewReadResult(
            jobID: "job_read_cancelled",
            core: makeCore(
                status: .cancelled,
                summary: cancellation.message,
                cancellation: cancellation,
                errorMessage: cancellation.message
            ),
            cancellable: false,
            logs: [],
            rawLogText: ""
        ).structuredContentForRead()
        let listResult = ReviewJobListItem(
            jobID: "job_list_cancelled",
            cwd: "/tmp/repo",
            targetSummary: "current changes",
            core: makeCore(
                status: .cancelled,
                summary: cancellation.message,
                cancellation: cancellation,
                errorMessage: cancellation.message
            ),
            elapsedSeconds: nil,
            cancellable: false
        ).structuredContent()

        try expectCancellation(
            startResult.objectValue?["lifecycle"]?.objectValue?["cancellation"],
            source: "userInterface",
            message: cancellation.message
        )
        try expectCancellation(
            readResult.objectValue?["lifecycle"]?.objectValue?["cancellation"],
            source: "userInterface",
            message: cancellation.message
        )
        try expectCancellation(
            listResult.objectValue?["lifecycle"]?.objectValue?["cancellation"],
            source: "userInterface",
            message: cancellation.message
        )
    }
}

private func makeCore(
    status: ReviewJobState,
    threadID: String? = nil,
    turnID: String? = nil,
    model: String? = nil,
    exitCode: Int? = nil,
    startedAt: Date? = nil,
    endedAt: Date? = nil,
    summary: String,
    hasFinalReview: Bool = false,
    lastAgentMessage: String? = nil,
    reviewResult: ParsedReviewResult? = nil,
    cancellation: ReviewCancellation? = nil,
    errorMessage: String? = nil
) -> ReviewJobCore {
    ReviewJobCore(
        run: .init(
            reviewThreadID: threadID,
            threadID: threadID,
            turnID: turnID,
            model: model
        ),
        lifecycle: .init(
            status: status,
            exitCode: exitCode,
            startedAt: startedAt,
            endedAt: endedAt,
            cancellation: cancellation,
            errorMessage: errorMessage
        ),
        output: .init(
            summary: summary,
            hasFinalReview: hasFinalReview,
            lastAgentMessage: lastAgentMessage,
            reviewResult: reviewResult
        )
    )
}

private func makeHandler(
    startReview: @escaping @MainActor @Sendable (ReviewStartRequest) async throws -> ReviewReadResult = { _ in
        Issue.record("Unexpected startReview call")
        throw ReviewError.invalidArguments("unexpected")
    },
    readReview: @escaping @MainActor @Sendable (String) async throws -> ReviewReadResult = { _ in
        Issue.record("Unexpected readReview call")
        throw ReviewError.invalidArguments("unexpected")
    },
    listReviews: @escaping @MainActor @Sendable (String?, [ReviewJobState]?, Int?) async -> ReviewListResult = { _, _, _ in
        .init(items: [])
    },
    cancelReviewByID: @escaping @MainActor @Sendable (String, ReviewCancellation) async throws -> ReviewCancelOutcome = { _, _ in
        Issue.record("Unexpected cancelReviewByID call")
        throw ReviewError.invalidArguments("unexpected")
    },
    cancelReviewBySelector: @escaping @MainActor @Sendable (String?, [ReviewJobState]?, ReviewCancellation) async throws -> ReviewCancelOutcome = { _, _, _ in
        Issue.record("Unexpected cancelReviewBySelector call")
        throw ReviewError.invalidArguments("unexpected")
    }
) -> ReviewToolHandler {
    ReviewToolHandler(tool: StubReviewTool(
        startReview: startReview,
        readReview: readReview,
        listReviews: listReviews,
        cancelReviewByID: cancelReviewByID,
        cancelReviewBySelector: cancelReviewBySelector
    ))
}

@MainActor
private struct StubReviewTool: ReviewToolProtocol {
    var startReview: @MainActor @Sendable (ReviewStartRequest) async throws -> ReviewReadResult
    var readReview: @MainActor @Sendable (String) async throws -> ReviewReadResult
    var listReviews: @MainActor @Sendable (String?, [ReviewJobState]?, Int?) async -> ReviewListResult
    var cancelReviewByID: @MainActor @Sendable (String, ReviewCancellation) async throws -> ReviewCancelOutcome
    var cancelReviewBySelector: @MainActor @Sendable (String?, [ReviewJobState]?, ReviewCancellation) async throws -> ReviewCancelOutcome

    func startReview(_ request: ReviewStartRequest) async throws -> ReviewReadResult {
        try await startReview(request)
    }

    func readReview(jobID: String) async throws -> ReviewReadResult {
        try await readReview(jobID)
    }

    func listReviews(
        cwd: String?,
        statuses: [ReviewJobState]?,
        limit: Int?
    ) async -> ReviewListResult {
        await listReviews(cwd, statuses, limit)
    }

    func cancelReview(
        jobID: String,
        cancellation: ReviewCancellation
    ) async throws -> ReviewCancelOutcome {
        try await cancelReviewByID(jobID, cancellation)
    }

    func cancelReview(
        selector: ReviewJobSelector,
        cancellation: ReviewCancellation
    ) async throws -> ReviewCancelOutcome {
        try await cancelReviewBySelector(
            selector.cwd,
            selector.statuses,
            cancellation
        )
    }
}

private func expectCancellation(
    _ value: Value?,
    source: String,
    message: String
) throws {
    let object = try #require(value?.objectValue)
    #expect(object["source"] == .string(source))
    #expect(object["message"] == .string(message))
}

private actor ReviewStartRequestRecorder {
    private var requests: [ReviewStartRequest] = []

    func record(_ request: ReviewStartRequest) {
        requests.append(request)
    }

    func snapshot() -> [ReviewStartRequest] {
        requests
    }
}

private func targetConstraint(_ constraints: [Value], for type: String) throws -> [String: Value] {
    try #require(constraints.compactMap(\.objectValue).first { constraint in
        constraintTargetType(constraint) == type
    })
}

private func constraintTargetType(_ constraint: [String: Value]) -> String? {
    guard case .object(let condition)? = constraint["if"],
          case .object(let properties)? = condition["properties"],
          case .object(let typeSchema)? = properties["type"],
          case .string(let type)? = typeSchema["const"]
    else {
        return nil
    }
    return type
}

private func requiredProperties(in constraint: [String: Value]) throws -> [String] {
    guard case .object(let thenSchema)? = constraint["then"] else {
        return []
    }
    return propertyNames(in: thenSchema["required"])
}

private func forbiddenProperties(in constraint: [String: Value]) throws -> [String] {
    guard case .object(let thenSchema)? = constraint["then"],
          case .object(let notSchema)? = thenSchema["not"],
          case .array(let alternatives)? = notSchema["anyOf"]
    else {
        return []
    }
    return alternatives.compactMap { alternative in
        propertyNames(in: alternative.objectValue?["required"]).first
    }
}

private func propertyNames(in value: Value?) -> [String] {
    guard case .array(let values)? = value else {
        return []
    }
    return values.compactMap { value in
        guard case .string(let name) = value else {
            return nil
        }
        return name
    }
}
