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
            "run": core.run.structuredContent(),
            "lifecycle": core.lifecycle.structuredContent(
                elapsedSeconds: elapsedSeconds,
                cancellable: cancellable
            ),
            "output": core.output.structuredContent(review: core.reviewText),
        ]
        if includeDetails {
            object["logs"] = .array(logs.map { $0.structuredContent() })
            object["rawLogText"] = .string(rawLogText)
        }
        return .object(object)
    }
}

extension ReviewJobListItem {
    package func structuredContent() -> Value {
        let object: [String: Value] = [
            "jobId": .string(jobID),
            "cwd": .string(cwd),
            "targetSummary": .string(targetSummary),
            "run": core.run.structuredContent(),
            "lifecycle": core.lifecycle.structuredContent(
                elapsedSeconds: elapsedSeconds,
                cancellable: cancellable
            ),
            "output": core.output.structuredContent(review: core.reviewText),
        ]
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
        .object([
            "jobId": .string(jobID),
            "cancelled": .bool(cancelled),
            "run": core.run.structuredContent(),
            "lifecycle": core.lifecycle.structuredContent(
                elapsedSeconds: nil,
                cancellable: false
            ),
            "output": core.output.structuredContent(review: core.reviewText),
        ])
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

extension ReviewRunMetadata {
    package func structuredContent() -> Value {
        .object([
            "reviewThreadId": reviewThreadID.map(Value.string) ?? .null,
            "threadId": threadID.map(Value.string) ?? .null,
            "turnId": turnID.map(Value.string) ?? .null,
            "model": model.map(Value.string) ?? .null,
        ])
    }
}

extension ReviewLifecycleState {
    package func structuredContent(
        elapsedSeconds: Int?,
        cancellable: Bool
    ) -> Value {
        .object([
            "status": .string(status.rawValue),
            "exitCode": exitCode.map(Value.int) ?? .null,
            "startedAt": startedAt.map { .string($0.ISO8601Format()) } ?? .null,
            "endedAt": endedAt.map { .string($0.ISO8601Format()) } ?? .null,
            "elapsedSeconds": elapsedSeconds.map(Value.int) ?? .null,
            "cancellable": .bool(cancellable),
            "cancellation": cancellation.map { $0.structuredContent() } ?? .null,
            "errorMessage": errorMessage.map(Value.string) ?? .null,
        ])
    }
}

extension ReviewOutputState {
    package func structuredContent(review: String) -> Value {
        .object([
            "summary": .string(summary),
            "review": .string(review),
            "hasFinalReview": .bool(hasFinalReview),
            "lastAgentMessage": lastAgentMessage.map(Value.string) ?? .null,
            "reviewResult": reviewResult.map { $0.structuredContent() } ?? .null,
        ])
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

extension ParsedReviewResult {
    package func structuredContent() -> Value {
        .object([
            "state": .string(state.rawValue),
            "findingCount": findingCount.map(Value.int) ?? .null,
            "findings": .array(findings.map { $0.structuredContent() }),
            "source": .string(source.rawValue),
            "parserVersion": .int(parserVersion),
        ])
    }
}

extension ParsedReviewFinding {
    package func structuredContent() -> Value {
        .object([
            "title": .string(title),
            "body": .string(body),
            "priority": priority.map(Value.int) ?? .null,
            "location": location.map { $0.structuredContent() } ?? .null,
            "rawText": .string(rawText),
        ])
    }
}

extension ParsedReviewFindingLocation {
    package func structuredContent() -> Value {
        .object([
            "path": .string(path),
            "startLine": .int(startLine),
            "endLine": .int(endLine),
        ])
    }
}
