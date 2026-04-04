package enum ReviewProgressStage: String, Sendable {
    case queued
    case started
    case threadStarted = "thread_started"
    case completed
}
