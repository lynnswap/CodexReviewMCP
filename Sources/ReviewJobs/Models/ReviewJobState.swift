package enum ReviewJobState: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled

    package var isTerminal: Bool {
        switch self {
        case .queued, .running:
            false
        case .succeeded, .failed, .cancelled:
            true
        }
    }
}
