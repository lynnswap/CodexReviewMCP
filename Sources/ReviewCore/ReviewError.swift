import Foundation

package enum ReviewError: LocalizedError, Sendable {
    case invalidArguments(String)
    case jobNotFound(String)
    case accessDenied(String)
    case spawnFailed(String)
    case io(String)

    package var errorDescription: String? {
        switch self {
        case .invalidArguments(let message),
             .jobNotFound(let message),
             .accessDenied(let message),
             .spawnFailed(let message),
             .io(let message):
            message
        }
    }
}
