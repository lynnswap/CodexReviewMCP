import Foundation
import MCP
import ReviewDomain

extension ReviewReadResult {
    package func structuredContentForStart() -> Value {
        structuredContent(includeDetails: false)
    }

    package func structuredContentForRead() -> Value {
        structuredContent(includeDetails: true)
    }

    private func structuredContent(includeDetails: Bool) -> Value {
        var object: [String: Value] = [
            "jobId": .string(jobID),
            "status": .string(status.rawValue),
            "review": .string(review),
        ]
        if let threadID {
            object["threadId"] = .string(threadID)
        }
        object["turnId"] = turnID.map(Value.string) ?? .null
        object["model"] = model.map(Value.string) ?? .null
        if let cancellation {
            object["cancellation"] = cancellation.structuredContent()
        }
        if includeDetails {
            object["logs"] = .array(logs.map { $0.structuredContent() })
            object["rawLogText"] = .string(rawLogText)
            if lastAgentMessage.isEmpty == false {
                object["lastAgentMessage"] = .string(lastAgentMessage)
            }
        }
        if let error {
            object["error"] = .string(error)
        }
        return .object(object)
    }
}

extension ReviewJobListItem {
    package func structuredContent() -> Value {
        var object: [String: Value] = [
            "jobId": .string(jobID),
            "cwd": .string(cwd),
            "targetSummary": .string(targetSummary),
            "status": .string(status.rawValue),
            "summary": .string(summary),
            "cancellable": .bool(cancellable),
        ]
        object["model"] = model.map(Value.string) ?? .null
        if let cancellation {
            object["cancellation"] = cancellation.structuredContent()
        }
        if let startedAt {
            object["startedAt"] = .string(startedAt.ISO8601Format())
        }
        if let endedAt {
            object["endedAt"] = .string(endedAt.ISO8601Format())
        }
        if let elapsedSeconds {
            object["elapsedSeconds"] = .int(elapsedSeconds)
        }
        if let threadID {
            object["threadId"] = .string(threadID)
        }
        if lastAgentMessage.isEmpty == false {
            object["lastAgentMessage"] = .string(lastAgentMessage)
        }
        return .object(object)
    }
}

extension ReviewListResult {
    package func structuredContent() -> Value {
        .object([
            "items": .array(items.map { $0.structuredContent() })
        ])
    }
}

extension ReviewCancelOutcome {
    package func structuredContent() -> Value {
        var object: [String: Value] = [
            "jobId": .string(jobID),
            "cancelled": .bool(cancelled),
            "status": .string(status.rawValue),
            "turnId": .null,
        ]
        if let threadID {
            object["threadId"] = .string(threadID)
        }
        if let cancellation {
            object["cancellation"] = cancellation.structuredContent()
        }
        return .object(object)
    }
}

extension ReviewCancelResult {
    package func structuredContent() -> Value {
        .object([
            "jobId": .string(jobID),
            "status": .string(state.rawValue),
            "signalled": .bool(signalled),
        ])
    }
}

extension ReviewLogEntry {
    package func structuredContent() -> Value {
        var object: [String: Value] = [
            "id": .string(id.uuidString),
            "kind": .string(kind.rawValue),
            "replacesGroup": .bool(replacesGroup),
            "text": .string(text),
            "timestamp": .string(timestamp.ISO8601Format()),
        ]
        object["groupId"] = groupID.map(Value.string) ?? .null
        return .object(object)
    }
}

extension ReviewCancellation {
    package func structuredContent() -> Value {
        .object([
            "source": .string(source.rawValue),
            "message": .string(message),
        ])
    }
}
