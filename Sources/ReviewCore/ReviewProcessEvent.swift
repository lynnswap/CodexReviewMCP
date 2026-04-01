import ReviewJobs

package enum ReviewProcessEvent: Sendable {
    case progress(ReviewProgressStage, String?)
    case reviewStarted(reviewThreadID: String, threadID: String, turnID: String, model: String?)
    case logEntry(ReviewLogEntry)
    case rawLine(String)
    case agentMessage(String)
    case failed(String)
}
