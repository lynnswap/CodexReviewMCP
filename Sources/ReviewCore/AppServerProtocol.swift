import Foundation
import ReviewJobs

package enum AppServerJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: AppServerJSONValue])
    case array([AppServerJSONValue])
    case null

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: AppServerJSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([AppServerJSONValue].self))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    package var debugText: String {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        case .object(let value):
            guard let data = try? JSONSerialization.data(
                withJSONObject: value.mapValues(\.foundationObject),
                options: [.sortedKeys]
            ),
                  let text = String(data: data, encoding: .utf8)
            else {
                return "{}"
            }
            return text
        case .array(let value):
            guard let data = try? JSONSerialization.data(
                withJSONObject: value.map(\.foundationObject),
                options: [.sortedKeys]
            ),
                  let text = String(data: data, encoding: .utf8)
            else {
                return "[]"
            }
            return text
        case .null:
            return "null"
        }
    }

    private var foundationObject: Any {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues(\.foundationObject)
        case .array(let value):
            return value.map(\.foundationObject)
        case .null:
            return NSNull()
        }
    }
}

package enum AppServerRequestID: Hashable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)

    package init?(jsonObject: Any) {
        if let string = jsonObject as? String {
            self = .string(string)
            return
        }
        if let integer = jsonObject as? Int {
            self = .integer(integer)
            return
        }
        if let double = jsonObject as? Double {
            if double.rounded(.towardZero) == double, let exact = Int(exactly: double) {
                self = .integer(exact)
            } else {
                self = .double(double)
            }
            return
        }
        if let number = jsonObject as? NSNumber {
            let doubleValue = number.doubleValue
            if doubleValue.rounded(.towardZero) == doubleValue, let exact = Int(exactly: doubleValue) {
                self = .integer(exact)
            } else {
                self = .double(doubleValue)
            }
            return
        }
        return nil
    }

    package var foundationObject: Any {
        switch self {
        case .string(let value):
            value
        case .integer(let value):
            value
        case .double(let value):
            value
        }
    }
}

package struct AppServerInitializeParams: Encodable, Sendable {
    package struct ClientInfo: Encodable, Sendable {
        package var name: String
        package var title: String
        package var version: String
    }

    package var clientInfo: ClientInfo
}

package struct AppServerInitializeResponse: Decodable, Sendable {
    package var userAgent: String?
    package var codexHome: String?
    package var platformFamily: String?
    package var platformOs: String?
}

package struct AppServerInitializedParams: Codable, Sendable {}

package struct AppServerConfigReadParams: Encodable, Sendable {
    package var cwd: String
    package var includeLayers: Bool
}

package struct AppServerConfigReadResponse: Decodable, Sendable {
    package struct Config: Decodable, Sendable {
        package var model: String?
        package var reviewModel: String?
        package var modelContextWindow: Int?
        package var modelAutoCompactTokenLimit: Int?

        package enum CodingKeys: String, CodingKey {
            case model
            case reviewModel = "review_model"
            case modelContextWindow = "model_context_window"
            case modelAutoCompactTokenLimit = "model_auto_compact_token_limit"
        }

        package init(
            model: String? = nil,
            reviewModel: String? = nil,
            modelContextWindow: Int? = nil,
            modelAutoCompactTokenLimit: Int? = nil
        ) {
            self.model = model
            self.reviewModel = reviewModel
            self.modelContextWindow = modelContextWindow
            self.modelAutoCompactTokenLimit = modelAutoCompactTokenLimit
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            reviewModel = try container.decodeIfPresent(String.self, forKey: .reviewModel)
            modelContextWindow = try Self.decodeFlexibleIntIfPresent(from: container, forKey: .modelContextWindow)
            modelAutoCompactTokenLimit = try Self.decodeFlexibleIntIfPresent(from: container, forKey: .modelAutoCompactTokenLimit)
        }

        private static func decodeFlexibleIntIfPresent(
            from container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) throws -> Int? {
            guard container.contains(key) else {
                return nil
            }
            if let value = try? container.decode(Int.self, forKey: key) {
                return value
            }
            if let rawValue = try? container.decode(String.self, forKey: key) {
                let normalized = rawValue
                    .replacingOccurrences(of: "_", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return Int(normalized)
            }
            return nil
        }
    }

    package var config: Config
}

package struct AppServerThreadStartParams: Encodable, Sendable {
    package var model: String?
    package var cwd: String?
    package var approvalPolicy: String?
    package var sandbox: String?
    package var config: [String: AppServerJSONValue]?
    package var personality: String?
    package var ephemeral: Bool?
}

package struct AppServerThreadStartResponse: Decodable, Sendable {
    package struct Thread: Decodable, Sendable {
        package var id: String
    }

    package var thread: Thread
    package var model: String?
}

package struct AppServerReviewStartParams: Encodable, Sendable {
    package var threadID: String
    package var target: ReviewTarget
    package var delivery: String?

    package enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case target
        case delivery
    }
}

package struct AppServerReviewStartResponse: Decodable, Sendable {
    package var turn: AppServerTurn
    package var reviewThreadID: String

    package enum CodingKeys: String, CodingKey {
        case turn
        case reviewThreadID = "reviewThreadId"
    }
}

package struct AppServerTurnInterruptParams: Encodable, Sendable {
    package var threadID: String
    package var turnID: String

    package enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
    }
}

package struct AppServerEmptyResponse: Decodable, Sendable {}

package enum AppServerTurnStatus: String, Decodable, Sendable {
    case completed
    case interrupted
    case failed
    case inProgress
}

package struct AppServerTurnError: Decodable, Sendable {
    package var message: String?
}

package struct AppServerTurn: Decodable, Sendable {
    package var id: String
    package var status: AppServerTurnStatus
    package var error: AppServerTurnError?
}

package struct AppServerTurnStartedNotification: Decodable, Sendable {
    package var threadID: String
    package var turn: AppServerTurn

    package enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }
}

package struct AppServerTurnCompletedNotification: Decodable, Sendable {
    package var threadID: String
    package var turn: AppServerTurn

    package enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }
}

package enum AppServerThreadItem: Decodable, Sendable, Equatable {
    case enteredReviewMode(id: String, review: String)
    case exitedReviewMode(id: String, review: String)
    case commandExecution(id: String, command: String, aggregatedOutput: String?, exitCode: Int?, status: String)
    case agentMessage(id: String, text: String)
    case plan(id: String, text: String)
    case reasoning(id: String, summary: [String], content: [String])
    case mcpToolCall(id: String, server: String, tool: String, status: String, error: String?, result: String?)
    case contextCompaction(id: String)
    case unsupported(type: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case review
        case command
        case aggregatedOutput
        case exitCode
        case status
        case text
        case summary
        case content
        case server
        case tool
        case error
        case result
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "enteredReviewMode":
            self = .enteredReviewMode(
                id: try container.decode(String.self, forKey: .id),
                review: try container.decode(String.self, forKey: .review)
            )
        case "exitedReviewMode":
            self = .exitedReviewMode(
                id: try container.decode(String.self, forKey: .id),
                review: try container.decode(String.self, forKey: .review)
            )
        case "commandExecution":
            self = .commandExecution(
                id: try container.decode(String.self, forKey: .id),
                command: try container.decode(String.self, forKey: .command),
                aggregatedOutput: try container.decodeIfPresent(String.self, forKey: .aggregatedOutput),
                exitCode: try container.decodeIfPresent(Int.self, forKey: .exitCode),
                status: try container.decode(String.self, forKey: .status)
            )
        case "agentMessage":
            self = .agentMessage(
                id: try container.decode(String.self, forKey: .id),
                text: try container.decode(String.self, forKey: .text)
            )
        case "plan":
            self = .plan(
                id: try container.decode(String.self, forKey: .id),
                text: try container.decode(String.self, forKey: .text)
            )
        case "reasoning":
            self = .reasoning(
                id: try container.decode(String.self, forKey: .id),
                summary: try container.decodeIfPresent([String].self, forKey: .summary) ?? [],
                content: try container.decodeIfPresent([String].self, forKey: .content) ?? []
            )
        case "mcpToolCall":
            let rawError = try container.decodeIfPresent(AppServerJSONValue.self, forKey: .error)
            let rawResult = try container.decodeIfPresent(AppServerJSONValue.self, forKey: .result)
            self = .mcpToolCall(
                id: try container.decode(String.self, forKey: .id),
                server: try container.decode(String.self, forKey: .server),
                tool: try container.decode(String.self, forKey: .tool),
                status: try container.decode(String.self, forKey: .status),
                error: rawError?.nonNullDebugText,
                result: rawResult?.nonNullDebugText
            )
        case "contextCompaction":
            self = .contextCompaction(
                id: try container.decode(String.self, forKey: .id)
            )
        default:
            self = .unsupported(type: type)
        }
    }
}

private extension AppServerJSONValue {
    var nonNullDebugText: String? {
        if case .null = self {
            return nil
        }
        return debugText
    }
}

package struct AppServerItemStartedNotification: Decodable, Sendable {
    package var item: AppServerThreadItem
    package var threadID: String
    package var turnID: String

    package enum CodingKeys: String, CodingKey {
        case item
        case threadID = "threadId"
        case turnID = "turnId"
    }
}

package struct AppServerItemCompletedNotification: Decodable, Sendable {
    package var item: AppServerThreadItem
    package var threadID: String
    package var turnID: String

    package enum CodingKeys: String, CodingKey {
        case item
        case threadID = "threadId"
        case turnID = "turnId"
    }
}

package struct AppServerAgentMessageDeltaNotification: Decodable, Sendable {
    package var threadID: String
    package var turnID: String
    package var itemID: String
    package var delta: String

    package enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
    }
}

package struct AppServerCommandExecutionOutputDeltaNotification: Decodable, Sendable {
    package var threadID: String
    package var turnID: String
    package var itemID: String
    package var delta: String

    package enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
    }
}

package struct AppServerPlanDeltaNotification: Decodable, Sendable {
    package var threadID: String
    package var turnID: String
    package var itemID: String
    package var delta: String

    package enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
    }
}

package struct AppServerReasoningSummaryTextDeltaNotification: Decodable, Sendable {
    package var threadID: String
    package var turnID: String
    package var itemID: String
    package var delta: String
    package var summaryIndex: Int

    package enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
        case summaryIndex
    }
}

package struct AppServerReasoningSummaryPartAddedNotification: Decodable, Sendable {
    package var threadID: String
    package var turnID: String
    package var itemID: String
    package var summaryIndex: Int

    package enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case summaryIndex
    }
}

package struct AppServerReasoningTextDeltaNotification: Decodable, Sendable {
    package var threadID: String
    package var turnID: String
    package var itemID: String
    package var delta: String
    package var contentIndex: Int

    package enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
        case contentIndex
    }
}

package struct AppServerMcpToolCallProgressNotification: Decodable, Sendable {
    package var threadID: String
    package var turnID: String
    package var itemID: String
    package var message: String

    package enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case message
    }
}

package struct AppServerResponseError: Decodable, Error, LocalizedError, Sendable {
    package var code: Int?
    package var message: String

    package var errorDescription: String? {
        message
    }

    package var isUnsupportedMethod: Bool {
        if code == -32601 {
            return true
        }
        return message.range(of: "method not found", options: [.caseInsensitive]) != nil
    }
}

package enum AppServerServerNotification: Sendable {
    case turnStarted(AppServerTurnStartedNotification)
    case turnCompleted(AppServerTurnCompletedNotification)
    case itemStarted(AppServerItemStartedNotification)
    case itemCompleted(AppServerItemCompletedNotification)
    case agentMessageDelta(AppServerAgentMessageDeltaNotification)
    case planDelta(AppServerPlanDeltaNotification)
    case commandExecutionOutputDelta(AppServerCommandExecutionOutputDeltaNotification)
    case reasoningSummaryTextDelta(AppServerReasoningSummaryTextDeltaNotification)
    case reasoningSummaryPartAdded(AppServerReasoningSummaryPartAddedNotification)
    case reasoningTextDelta(AppServerReasoningTextDeltaNotification)
    case mcpToolCallProgress(AppServerMcpToolCallProgressNotification)
    case ignored
}

package struct AppServerJSONLFramer {
    private var buffer = Data()

    package init() {}

    package mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var messages: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let message = Data(buffer[..<newlineIndex]).trimmedWhitespace()
            buffer.removeSubrange(...newlineIndex)
            if message.isEmpty == false {
                messages.append(message)
            }
        }
        return messages
    }

    package mutating func finish() -> [Data] {
        let message = buffer.trimmedWhitespace()
        buffer.removeAll(keepingCapacity: false)
        if message.isEmpty {
            return []
        }
        return [message]
    }
}

private extension Data {
    func trimmedWhitespace() -> Data {
        guard let text = String(data: self, encoding: .utf8) else {
            return self
        }
        return Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }
}
