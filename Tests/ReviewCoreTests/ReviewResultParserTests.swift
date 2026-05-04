import Testing
import ReviewDomain

struct ReviewResultParserTests {
    @Test func parsesSingleReviewCommentIntoTitleBodyPriorityAndLocation() throws {
        let dash = "\u{2014}"
        let result = ParsedReviewResult.parse(finalReviewText: """
        The changes introduce one issue.

        Review comment:

        - [P2] Keep review state structured \(dash) /tmp/project/Sources/App.swift:10-12
          This loses finding metadata, so later UI code has to parse the display text again.
        """)

        #expect(result.state == .hasFindings)
        #expect(result.findingCount == 1)
        #expect(result.source == .parsedFinalReviewText)
        let finding = try #require(result.findings.first)
        #expect(finding.title == "[P2] Keep review state structured")
        #expect(finding.body == "This loses finding metadata, so later UI code has to parse the display text again.")
        #expect(finding.priority == 2)
        #expect(finding.location?.path == "/tmp/project/Sources/App.swift")
        #expect(finding.location?.startLine == 10)
        #expect(finding.location?.endLine == 12)
    }

    @Test func parsesMultipleReviewCommentsInOrder() throws {
        let dash = "\u{2014}"
        let result = ParsedReviewResult.parse(finalReviewText: """
        The patch has two issues.

        Full review comments:

        - [P1] Preserve cancellation metadata \(dash) /tmp/project/Sources/Store.swift:20-20
          Cancelling after a partial final result currently drops the cancellation source.

        - [P3] Keep row subtitle stable \(dash) /tmp/project/Sources/Row.swift:42-44
          The subtitle shifts between equivalent terminal states.
        """)

        #expect(result.state == .hasFindings)
        #expect(result.findingCount == 2)
        #expect(result.findings.map(\.title) == [
            "[P1] Preserve cancellation metadata",
            "[P3] Keep row subtitle stable",
        ])
        #expect(result.findings.map(\.priority) == [1, 3])
        #expect(result.findings.map { $0.location?.path } == [
            "/tmp/project/Sources/Store.swift",
            "/tmp/project/Sources/Row.swift",
        ])
    }

    @Test func successfulTextWithoutFindingBlockIsNoFindings() {
        let result = ParsedReviewResult.parse(finalReviewText: """
        No discrete, introduced correctness issues were identified in the reviewed diff.
        """)

        #expect(result.state == .noFindings)
        #expect(result.findingCount == 0)
        #expect(result.findings.isEmpty)
        #expect(result.source == .parsedFinalReviewText)
    }

    @Test func malformedFindingBlockIsUnknown() {
        let result = ParsedReviewResult.parse(finalReviewText: """
        The review output included a malformed finding block.

        Review comment:

        - [P2] Missing location delimiter
          This cannot be mapped to a file and line range.
        """)

        #expect(result.state == .unknown)
        #expect(result.findingCount == nil)
        #expect(result.findings.isEmpty)
        #expect(result.source == .unrecognizedFindingBlock)
    }
}
