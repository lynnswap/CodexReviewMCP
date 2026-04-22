import Foundation
import MCP
import ReviewDomain

package struct ReviewStdioHTTPResponse: Sendable {
    package var statusCode: Int
    package var sessionID: String?
    package var body: Data?
}

package struct ReviewStdioSSEEvent: Sendable {
    package var id: String?
    package var payload: Data
}

package enum ReviewStdioUpstreamTransportError: Error, Sendable {
    case invalidResponse(String)
    case httpStatus(Int)
}

package protocol ReviewStdioUpstreamTransport: Sendable {
    func sendPOST(
        url: URL,
        data: Data,
        sessionID: String?,
        timeout: TimeInterval
    ) async throws -> ReviewStdioHTTPResponse

    func openSSE(
        url: URL,
        sessionID: String,
        lastEventID: String?
    ) async throws -> AsyncThrowingStream<ReviewStdioSSEEvent, Error>

    func deleteSession(
        url: URL,
        sessionID: String
    ) async

    func invalidate() async
}

package actor URLSessionReviewStdioTransport: ReviewStdioUpstreamTransport {
    private let session: URLSession

    package init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            self.session = URLSession(configuration: configuration)
        }
    }

    package func sendPOST(
        url: URL,
        data: Data,
        sessionID: String?,
        timeout: TimeInterval
    ) async throws -> ReviewStdioHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        request.setValue(Version.latest, forHTTPHeaderField: HTTPHeaderName.protocolVersion)
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: HTTPHeaderName.sessionID)
        }
        request.timeoutInterval = timeout > 0 ? timeout : .infinity
        request.httpBody = data

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReviewStdioUpstreamTransportError.invalidResponse("Invalid upstream HTTP response.")
        }

        let contentType = http.value(forHTTPHeaderField: HTTPHeaderName.contentType) ?? ""
        if contentType.localizedCaseInsensitiveContains("text/event-stream") {
            var decoder = SSEDecoder()
            for try await line in bytes.lines {
                if let event = decoder.feed(line: line), event.payload.isEmpty == false {
                    return ReviewStdioHTTPResponse(
                        statusCode: http.statusCode,
                        sessionID: http.value(forHTTPHeaderField: HTTPHeaderName.sessionID)?.nilIfEmpty,
                        body: event.payload
                    )
                }
            }
            let tail = decoder.flushIfNeeded()
            return ReviewStdioHTTPResponse(
                statusCode: http.statusCode,
                sessionID: http.value(forHTTPHeaderField: HTTPHeaderName.sessionID)?.nilIfEmpty,
                body: tail?.payload.isEmpty == false ? tail?.payload : nil
            )
        }

        var collected = Data()
        for try await byte in bytes {
            collected.append(byte)
        }
        return ReviewStdioHTTPResponse(
            statusCode: http.statusCode,
            sessionID: http.value(forHTTPHeaderField: HTTPHeaderName.sessionID)?.nilIfEmpty,
            body: collected.isEmpty ? nil : collected
        )
    }

    package func openSSE(
        url: URL,
        sessionID: String,
        lastEventID: String?
    ) async throws -> AsyncThrowingStream<ReviewStdioSSEEvent, Error> {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Version.latest, forHTTPHeaderField: HTTPHeaderName.protocolVersion)
        request.setValue(sessionID, forHTTPHeaderField: HTTPHeaderName.sessionID)
        if let lastEventID {
            request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
        }
        request.timeoutInterval = .infinity

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReviewStdioUpstreamTransportError.invalidResponse("Invalid SSE response.")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw ReviewStdioUpstreamTransportError.httpStatus(http.statusCode)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var decoder = SSEDecoder()
                do {
                    for try await line in bytes.lines {
                        if let event = decoder.feed(line: line), event.payload.isEmpty == false {
                            continuation.yield(event)
                        }
                    }
                    if let event = decoder.flushIfNeeded(), event.payload.isEmpty == false {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    package func deleteSession(
        url: URL,
        sessionID: String
    ) async {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(Version.latest, forHTTPHeaderField: HTTPHeaderName.protocolVersion)
        request.setValue(sessionID, forHTTPHeaderField: HTTPHeaderName.sessionID)
        request.timeoutInterval = 2
        _ = try? await session.data(for: request)
    }

    package func invalidate() async {
        session.invalidateAndCancel()
    }
}
