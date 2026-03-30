import Foundation

public struct ReviewLogEntry: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case agentMessage
        case command
        case commandOutput
        case todoList
        case reasoning
        case error
        case progress
    }

    public let id: UUID
    public let kind: Kind
    public let text: String
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.timestamp = timestamp
    }
}
