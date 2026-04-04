import Foundation
import MCP

public enum CodexReviewTerminalErrorSource: String, Codable, Sendable, Hashable {
    case turnCompleted
    case errorNotification
    case timeout
    case threadUnavailable
    case bootstrap
    case protocolViolation
    case cancelled
}

public struct CodexReviewTerminalError: Codable, Sendable, Hashable {
    public var source: CodexReviewTerminalErrorSource
    public var message: String
    public var additionalDetails: String?
    public var codexErrorInfo: String?

    public init(
        source: CodexReviewTerminalErrorSource,
        message: String,
        additionalDetails: String? = nil,
        codexErrorInfo: String? = nil
    ) {
        self.source = source
        self.message = message
        self.additionalDetails = additionalDetails
        self.codexErrorInfo = codexErrorInfo
    }

    public var displayText: String {
        var result = message
        if let additionalDetails, additionalDetails.isEmpty == false {
            result += " (\(additionalDetails))"
        }
        if let codexErrorInfo, codexErrorInfo.isEmpty == false {
            result += " [\(codexErrorInfo)]"
        }
        return result
    }

    package func structuredContent() -> Value {
        .object([
            "source": .string(source.rawValue),
            "message": .string(message),
            "additionalDetails": additionalDetails.map(Value.string) ?? .null,
            "codexErrorInfo": codexErrorInfo.map(Value.string) ?? .null,
        ])
    }
}
