import Foundation
import Observation
import ReviewJobs

@MainActor
@Observable
public final class CodexReviewJob: Identifiable, Hashable {
    private struct GroupKey: Hashable {
        var kind: ReviewLogEntry.Kind
        var groupID: String
    }

    private struct RenderedBlock {
        var kind: ReviewLogEntry.Kind
        var text: String
    }

    public nonisolated let id: String
    public var sortOrder: Int
    public let sessionID: String
    public let cwd: String
    public var reviewThreadID: String?
    public var targetSummary: String
    public var model: String?
    public var threadID: String?
    public var turnID: String?
    public var status: CodexReviewJobStatus
    public var cancellationRequested: Bool
    public var startedAt: Date?
    public var endedAt: Date?
    public var summary: String
    public var hasFinalReview: Bool
    public var lastAgentMessage: String?
    public var logEntries: [ReviewLogEntry]
    public var errorMessage: String?
    public var exitCode: Int?

    public var isTerminal: Bool {
        status.isTerminal
    }

    public var displayTitle: String {
        targetSummary
    }

    public var logText: String {
        Self.renderedText(
            from: logEntries,
            kinds: Self.displayedLogKinds
        )
    }

    public var rawLogText: String {
        Self.rawText(
            from: logEntries,
            kinds: [.diagnostic]
        )
    }

    public var reviewOutputText: String {
        Self.renderedText(
            from: logEntries,
            kinds: [.agentMessage, .plan, .reasoningSummary, .reasoning, .rawReasoning]
        )
    }

    public var activityLogText: String {
        Self.renderedText(
            from: logEntries,
            kinds: [.command, .commandOutput, .toolCall, .progress, .event]
        )
    }

    public var diagnosticText: String {
        Self.combinedText(
            sections: [
                Self.renderedText(
                    from: logEntries,
                    kinds: [.error]
                ),
                rawLogText,
            ]
        )
    }

    public var reviewText: String {
        if status == .cancelled {
            if hasFinalReview,
               let lastAgentMessage,
               lastAgentMessage.isEmpty == false
            {
                return lastAgentMessage
            }
            if let errorMessage, errorMessage.isEmpty == false {
                return errorMessage
            }
            return summary
        }
        if let lastAgentMessage, lastAgentMessage.isEmpty == false {
            return lastAgentMessage
        }
        if let errorMessage, errorMessage.isEmpty == false {
            return errorMessage
        }
        return summary
    }

    package init(
        id: String,
        sortOrder: Int,
        sessionID: String,
        cwd: String,
        reviewThreadID: String?,
        targetSummary: String,
        model: String?,
        threadID: String?,
        turnID: String?,
        status: CodexReviewJobStatus,
        cancellationRequested: Bool = false,
        startedAt: Date?,
        endedAt: Date?,
        summary: String,
        hasFinalReview: Bool,
        lastAgentMessage: String?,
        logEntries: [ReviewLogEntry],
        errorMessage: String?,
        exitCode: Int?
    ) {
        self.id = id
        self.sortOrder = sortOrder
        self.sessionID = sessionID
        self.cwd = cwd
        self.reviewThreadID = reviewThreadID
        self.targetSummary = targetSummary
        self.model = model
        self.threadID = threadID
        self.turnID = turnID
        self.status = status
        self.cancellationRequested = cancellationRequested
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.summary = summary
        self.hasFinalReview = hasFinalReview
        self.lastAgentMessage = lastAgentMessage
        self.logEntries = logEntries
        self.errorMessage = errorMessage
        self.exitCode = exitCode
    }

    public nonisolated static func == (lhs: CodexReviewJob, rhs: CodexReviewJob) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    private static func combinedText(sections: [String]) -> String {
        joinSectionsPreservingWhitespace(
            sections.filter { $0.isEmpty == false }
        )
    }

    private static func rawText(
        from entries: [ReviewLogEntry],
        kinds: Set<ReviewLogEntry.Kind>
    ) -> String {
        entries
            .filter { kinds.contains($0.kind) }
            .map(\.text)
            .joined(separator: "\n")
    }

    private static func renderedText(
        from entries: [ReviewLogEntry],
        kinds: Set<ReviewLogEntry.Kind>
    ) -> String {
        let filtered = entries.filter { kinds.contains($0.kind) }
        guard filtered.isEmpty == false else {
            return ""
        }

        var blocks: [RenderedBlock] = []
        var indexByGroup: [GroupKey: Int] = [:]

        for entry in filtered {
            if let key = mergeKey(for: entry) {
                if let index = indexByGroup[key] {
                    if entry.replacesGroup {
                        blocks[index].text = entry.text
                    } else {
                        blocks[index].text.append(entry.text)
                    }
                    continue
                }
                indexByGroup[key] = blocks.count
            }

            blocks.append(.init(kind: entry.kind, text: entry.text))
        }

        let rendered = blocks.compactMap { block in
            if block.kind == .diagnostic || block.text.isEmpty == false {
                return block.text
            }
            return nil
        }
        return joinSectionsPreservingWhitespace(rendered)
    }

    private static func mergeKey(for entry: ReviewLogEntry) -> GroupKey? {
        guard let groupID = entry.groupID,
              groupID.isEmpty == false
        else {
            return nil
        }

        switch entry.kind {
        case .agentMessage, .commandOutput, .plan, .reasoning, .reasoningSummary, .rawReasoning:
            return GroupKey(kind: entry.kind, groupID: groupID)
        case .command, .todoList, .toolCall, .diagnostic, .error, .progress, .event:
            return nil
        }
    }

    private static func joinSectionsPreservingWhitespace(_ sections: [String]) -> String {
        var iterator = sections.makeIterator()
        guard var result = iterator.next() else {
            return ""
        }

        while let next = iterator.next() {
            if next.isEmpty {
                result += "\n\n"
                continue
            }
            if result.hasSuffix("\n\n") {
                result += next
                continue
            }
            if result.hasSuffix("\n") || next.hasPrefix("\n") {
                result += "\n"
            } else {
                result += "\n\n"
            }
            result += next
        }

        return result
    }

    private static let displayedLogKinds: Set<ReviewLogEntry.Kind> = [
        .agentMessage,
        .command,
        .commandOutput,
        .plan,
        .todoList,
        .reasoning,
        .reasoningSummary,
        .rawReasoning,
        .toolCall,
        .diagnostic,
        .error,
        .progress,
        .event,
    ]
}
