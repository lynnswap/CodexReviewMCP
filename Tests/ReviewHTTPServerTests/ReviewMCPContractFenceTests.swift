import Foundation
import MCP
@testable import ReviewCore
import ReviewDomain
import Testing
@testable import ReviewHTTPServer

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
                    threadID: "thr_1",
                    turnID: "turn_1",
                    model: "gpt-5.4",
                    status: ReviewJobState.succeeded,
                    review: "Looks good",
                    lastAgentMessage: "",
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
            "model",
            "review",
            "status",
            "threadId",
            "turnId",
        ])
    }

    @Test func reviewReadStructuredContentKeysRemainStable() async throws {
        let handler = makeHandler(
            readReview: { _ in
                ReviewReadResult(
                    jobID: "job_2",
                    threadID: "thr_2",
                    turnID: "turn_2",
                    model: "gpt-5.4-mini",
                    status: ReviewJobState.failed,
                    review: "",
                    lastAgentMessage: "last agent message",
                    logs: [
                        ReviewLogEntry(
                            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                            kind: ReviewLogEntry.Kind.progress,
                            text: "Running"
                        ),
                    ],
                    rawLogText: "raw logs",
                    error: "boom"
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
            "error",
            "jobId",
            "lastAgentMessage",
            "logs",
            "model",
            "rawLogText",
            "review",
            "status",
            "threadId",
            "turnId",
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
                            model: "gpt-5.4",
                            status: ReviewJobState.running,
                            summary: "Running.",
                            startedAt: Date(timeIntervalSince1970: 1),
                            endedAt: nil,
                            elapsedSeconds: 12,
                            threadID: "thr_3",
                            lastAgentMessage: "working",
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
            "cancellable",
            "cwd",
            "elapsedSeconds",
            "jobId",
            "lastAgentMessage",
            "model",
            "startedAt",
            "status",
            "summary",
            "targetSummary",
            "threadId",
        ])
    }

    @Test func reviewCancelStructuredContentKeysRemainStable() async throws {
        let handler = makeHandler(
            cancelReviewByID: { _ in
                ReviewCancelOutcome(
                    jobID: "job_4",
                    threadID: "thr_4",
                    cancelled: true,
                    status: ReviewJobState.cancelled
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
            "status",
            "threadId",
            "turnId",
        ])
        #expect(object["turnId"] == Value.null)
    }
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
    cancelReviewByID: @escaping @MainActor @Sendable (String) async throws -> ReviewCancelOutcome = { _ in
        Issue.record("Unexpected cancelReviewByID call")
        throw ReviewError.invalidArguments("unexpected")
    },
    cancelReviewBySelector: @escaping @MainActor @Sendable (String?, [ReviewJobState]?) async throws -> ReviewCancelOutcome = { _, _ in
        Issue.record("Unexpected cancelReviewBySelector call")
        throw ReviewError.invalidArguments("unexpected")
    }
) -> ReviewToolHandler {
    ReviewToolHandler(
        sessionID: "session_1",
        startReview: startReview,
        readReview: readReview,
        listReviews: listReviews,
        cancelReviewByID: cancelReviewByID,
        cancelReviewBySelector: cancelReviewBySelector
    )
}
