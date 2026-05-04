import Foundation
import ReviewDomain

package struct ReviewBootstrapFailure: Error, LocalizedError, Sendable {
    package var message: String
    package var model: String?

    package init(message: String, model: String? = nil) {
        self.message = message
        self.model = model
    }

    package var errorDescription: String? {
        message
    }
}

package struct ReviewProcessOutcome: Sendable {
    package var core: ReviewJobCore
    package var content: String

    package init(
        core: ReviewJobCore,
        content: String
    ) {
        self.core = core
        self.content = content
    }
}
