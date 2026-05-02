import ReviewDomain

public enum CodexReviewJobStatus: String, Sendable, Hashable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled

    package init(state: ReviewJobState) {
        switch state {
        case .queued:
            self = .queued
        case .running:
            self = .running
        case .succeeded:
            self = .succeeded
        case .failed:
            self = .failed
        case .cancelled:
            self = .cancelled
        }
    }

    package var state: ReviewJobState {
        switch self {
        case .queued:
            .queued
        case .running:
            .running
        case .succeeded:
            .succeeded
        case .failed:
            .failed
        case .cancelled:
            .cancelled
        }
    }

    public var isTerminal: Bool {
        state.isTerminal
    }

    public var displayText: String {
        switch self {
        case .queued:
            "Queued"
        case .running:
            "Running"
        case .succeeded:
            "Succeeded"
        case .failed:
            "Failed"
        case .cancelled:
            "Cancelled"
        }
    }
}
