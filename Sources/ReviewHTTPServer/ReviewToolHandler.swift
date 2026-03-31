import Foundation
import MCP
import ReviewCore
import ReviewJobs

struct ReviewToolHandler {
    let sessionID: String
    let startReview: @MainActor @Sendable (ReviewStartRequest) async throws -> ReviewReadResult
    let readReview: @MainActor @Sendable (String) async throws -> ReviewReadResult
    let listReviews: @MainActor @Sendable (String?, [ReviewJobState]?, Int?) async -> ReviewListResult
    let cancelReviewByID: @MainActor @Sendable (String) async throws -> ReviewCancelOutcome
    let cancelReviewBySelector: @MainActor @Sendable (String?, [ReviewJobState]?, Bool) async throws -> ReviewCancelOutcome

    func handle(params: CallTool.Parameters) async -> CallTool.Result {
        switch params.name {
        case "review_start":
            return await handleReviewStart(params: params)
        case "review_list":
            return await handleReviewList(params: params)
        case "review_read":
            return await handleReviewRead(params: params)
        case "review_cancel":
            return await handleCancel(params: params)
        default:
            return toolError("Unknown tool: \(params.name)")
        }
    }

    private func handleReviewStart(params: CallTool.Parameters) async -> CallTool.Result {
        do {
            let arguments = try decodeArguments(params.arguments, as: ReviewStartArguments.self)
            let result = try await startReview(arguments.makeRequest())
            return try CallTool.Result(
                content: [.text(text: result.review.isEmpty ? result.status.rawValue : result.review, annotations: nil, _meta: nil)],
                structuredContent: result.structuredContentForStart(),
                isError: result.status == .failed
            )
        } catch let error as DecodingError {
            let detail = reviewStartErrorDetail(from: error)
            return toolError(
                ReviewHelpCatalog.reviewStartGuidanceMessage(detail: detail),
                structuredContent: ReviewHelpCatalog.reviewStartGuidanceStructuredContent(detail: detail)
            )
        } catch let error as ReviewError {
            if case .invalidArguments(let detail) = error {
                return toolError(
                    ReviewHelpCatalog.reviewStartGuidanceMessage(detail: detail),
                    structuredContent: ReviewHelpCatalog.reviewStartGuidanceStructuredContent(detail: detail)
                )
            }
            return toolError(error.localizedDescription)
        } catch {
            return toolError(error.localizedDescription)
        }
    }

    private func handleReviewRead(params: CallTool.Parameters) async -> CallTool.Result {
        do {
            let arguments = try decodeArguments(params.arguments, as: ReviewReadArguments.self)
            let result = try await readReview(arguments.reviewThreadID)
            return try CallTool.Result(
                content: [.text(text: result.review.isEmpty ? result.status.rawValue : result.review, annotations: nil, _meta: nil)],
                structuredContent: result.structuredContentForRead(),
                isError: result.status == .failed
            )
        } catch {
            return toolError(error.localizedDescription)
        }
    }

    private func handleReviewList(params: CallTool.Parameters) async -> CallTool.Result {
        do {
            let arguments = try decodeArguments(params.arguments, as: ReviewListArguments.self)
            let result = await listReviews(arguments.cwd, arguments.statuses, arguments.limit)
            return try CallTool.Result(
                content: [.text(text: "Listed \(result.items.count) review job(s).", annotations: nil, _meta: nil)],
                structuredContent: result.structuredContent(),
                isError: false
            )
        } catch {
            return toolError(error.localizedDescription)
        }
    }

    private func handleCancel(params: CallTool.Parameters) async -> CallTool.Result {
        do {
            let arguments = try decodeArguments(params.arguments, as: ReviewCancelArguments.self)
            let result: ReviewCancelOutcome
            if let rawReviewThreadID = arguments.reviewThreadID {
                guard let reviewThreadID = rawReviewThreadID.nilIfEmpty else {
                    return toolError("`reviewThreadId` cannot be empty.")
                }
                result = try await cancelReviewByID(reviewThreadID)
            } else {
                result = try await cancelReviewBySelector(
                    arguments.cwd,
                    arguments.statuses,
                    arguments.latest ?? false
                )
            }
            return try CallTool.Result(
                content: [.text(text: result.cancelled ? "Cancellation requested." : "Review was already finished.", annotations: nil, _meta: nil)],
                structuredContent: result.structuredContent(),
                isError: false
            )
        } catch let error as ReviewJobSelectionError {
            switch error {
            case .notFound(let message):
                return toolError(message)
            case .ambiguous(let candidates):
                return toolError(
                    "Multiple matching review jobs were found. Narrow the selector or set latest=true.",
                    structuredContent: .object([
                        "candidates": .array(candidates.map { $0.structuredContent() })
                    ])
                )
            }
        } catch {
            return toolError(error.localizedDescription)
        }
    }

    private func toolError(_ message: String, structuredContent: Value? = nil) -> CallTool.Result {
        if let structuredContent {
            if let result = try? CallTool.Result(
                content: [.text(text: message, annotations: nil, _meta: nil)],
                structuredContent: structuredContent,
                isError: true
            ) {
                return result
            }
        }
        return CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }
}

private struct ReviewStartArguments: Codable {
    var cwd: String
    var target: ReviewTarget
    var model: String?

    func makeRequest() -> ReviewStartRequest {
        ReviewStartRequest(
            cwd: cwd,
            target: target,
            model: model
        )
    }
}

private struct ReviewReadArguments: Codable {
    var reviewThreadID: String

    private enum CodingKeys: String, CodingKey {
        case reviewThreadID = "reviewThreadId"
    }
}

private struct ReviewCancelArguments: Codable {
    var reviewThreadID: String?
    var cwd: String?
    var statuses: [ReviewJobState]?
    var latest: Bool?

    private enum CodingKeys: String, CodingKey {
        case reviewThreadID = "reviewThreadId"
        case cwd
        case statuses
        case latest
    }
}

private struct ReviewListArguments: Codable {
    var cwd: String?
    var statuses: [ReviewJobState]?
    var limit: Int?
}

private func decodeArguments<T: Decodable>(_ arguments: [String: Value]?, as type: T.Type) throws -> T {
    let data = try JSONEncoder().encode(arguments ?? [:])
    return try JSONDecoder().decode(type, from: data)
}

private func reviewStartErrorDetail(from error: DecodingError) -> String {
    switch error {
    case .dataCorrupted(let context):
        return context.debugDescription
    case .keyNotFound(let key, let context):
        let path = reviewStartCodingPathString(from: context.codingPath + [key])
        return path.isEmpty ? "`\(key.stringValue)` is required." : "`\(path)` is required."
    case .typeMismatch(_, let context), .valueNotFound(_, let context):
        return context.debugDescription
    @unknown default:
        return error.localizedDescription
    }
}

private func reviewStartCodingPathString(from codingPath: [CodingKey]) -> String {
    codingPath
        .map(\.stringValue)
        .filter { $0.isEmpty == false }
        .joined(separator: ".")
}
