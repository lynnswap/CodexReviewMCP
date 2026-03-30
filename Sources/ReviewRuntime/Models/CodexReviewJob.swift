import Foundation
import Observation
import ReviewJobs

@MainActor
@Observable
public final class CodexReviewJob: Identifiable, Hashable {
    public nonisolated let id: String
    public let sessionID: String
    public var cwd: String
    public var targetSummary: String
    public var model: String?
    public var threadID: String?
    public var turnID: String?
    public var status: CodexReviewJobStatus
    public var startedAt: Date?
    public var endedAt: Date?
    public var summary: String
    public var lastAgentMessage: String?
    public var reviewEntries: [ReviewLogEntry]
    public var reasoningEntries: [ReviewLogEntry]
    public var rawEventLines: [String]
    public var errorMessage: String?
    public var exitCode: Int?
    package var artifacts: ReviewArtifacts

    public var isTerminal: Bool {
        status.isTerminal
    }

    public var displayTitle: String {
        targetSummary
    }

    public var activityLogText: String {
        Self.concatenatedText(from: reviewEntries)
    }

    public var reviewLogText: String {
        activityLogText
    }

    public var reasoningSummaryText: String {
        Self.concatenatedText(from: reasoningEntries)
    }

    public var reasoningLogText: String {
        reasoningSummaryText
    }

    public var rawLogText: String {
        rawEventLines.joined(separator: "\n")
    }

    public var reviewText: String {
        if let lastAgentMessage, lastAgentMessage.isEmpty == false {
            return lastAgentMessage
        }
        if let errorMessage, errorMessage.isEmpty == false {
            return errorMessage
        }
        return summary
    }

    public var reviewThreadID: String {
        id
    }

    public var parentThreadID: String? {
        threadID
    }

    package init(
        id: String,
        sessionID: String,
        cwd: String,
        targetSummary: String,
        model: String?,
        threadID: String?,
        turnID: String?,
        status: CodexReviewJobStatus,
        startedAt: Date?,
        endedAt: Date?,
        summary: String,
        lastAgentMessage: String?,
        reviewEntries: [ReviewLogEntry],
        reasoningEntries: [ReviewLogEntry],
        rawEventLines: [String],
        errorMessage: String?,
        exitCode: Int?,
        artifacts: ReviewArtifacts
    ) {
        self.id = id
        self.sessionID = sessionID
        self.cwd = cwd
        self.targetSummary = targetSummary
        self.model = model
        self.threadID = threadID
        self.turnID = turnID
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.summary = summary
        self.lastAgentMessage = lastAgentMessage
        self.reviewEntries = reviewEntries
        self.reasoningEntries = reasoningEntries
        self.rawEventLines = rawEventLines
        self.errorMessage = errorMessage
        self.exitCode = exitCode
        self.artifacts = artifacts
    }

    public nonisolated static func == (lhs: CodexReviewJob, rhs: CodexReviewJob) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    private static func concatenatedText(from entries: [ReviewLogEntry]) -> String {
        entries.map(\.text).joined(separator: "\n\n")
    }
}
