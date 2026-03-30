import ReviewJobs

package enum ReviewProcessEvent: Sendable {
    case progress(ReviewProgressStage, String?)
    case threadStarted(String)
    case reviewEntry(ReviewLogEntry)
    case reasoningEntry(ReviewLogEntry)
    case rawLine(String)
    case agentMessage(String)
    case failed(String)
}
