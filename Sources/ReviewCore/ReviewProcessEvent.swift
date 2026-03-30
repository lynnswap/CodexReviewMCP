import ReviewJobs

package enum ReviewProcessEvent: Sendable {
    case progress(ReviewProgressStage, String?)
    case threadStarted(String)
    case logEntry(ReviewLogEntry)
    case rawLine(String)
    case agentMessage(String)
    case failed(String)
}
