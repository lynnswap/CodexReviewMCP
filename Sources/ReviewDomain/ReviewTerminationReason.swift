package enum ReviewTerminationReason: Sendable, Equatable {
    case cancelled(ReviewCancellation)

    package var cancellation: ReviewCancellation {
        switch self {
        case .cancelled(let cancellation):
            cancellation
        }
    }

    package var message: String {
        cancellation.message
    }
}
