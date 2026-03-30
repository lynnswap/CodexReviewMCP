import Foundation
import MCP

@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1

final class ReviewHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }

    private weak var app: ReviewHTTPApplication?
    private let endpoint: String
    private var requestState: RequestState?

    init(app: ReviewHTTPApplication?, endpoint: String) {
        self.app = app
        self.endpoint = endpoint
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestState = RequestState(head: head, bodyBuffer: context.channel.allocator.buffer(capacity: 0))
        case .body(var buffer):
            requestState?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let state = requestState else {
                return
            }
            requestState = nil
            nonisolated(unsafe) let ctx = context
            Task { [weak self] in
                await self?.handleRequest(state: state, context: ctx)
            }
        }
    }

    private func handleRequest(state: RequestState, context: ChannelHandlerContext) async {
        guard let app else {
            await writeResponse(
                .error(statusCode: 500, .internalError("HTTP application deallocated.")),
                version: state.head.version,
                context: context
            )
            return
        }
        let path = state.head.uri.split(separator: "?").first.map(String.init) ?? state.head.uri
        let request = makeHTTPRequest(from: state)
        if path != endpoint {
            await writeResponse(
                .error(statusCode: 404, .invalidRequest("Not Found")),
                version: state.head.version,
                context: context
            )
            return
        }
        let response = await app.handleHTTPRequest(request)
        await writeResponse(response, version: state.head.version, context: context)
    }

    private func makeHTTPRequest(from state: RequestState) -> HTTPRequest {
        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        let body: Data?
        if state.bodyBuffer.readableBytes > 0,
           let bytes = state.bodyBuffer.getBytes(at: 0, length: state.bodyBuffer.readableBytes)
        {
            body = Data(bytes)
        } else {
            body = nil
        }
        let path = String(state.head.uri.split(separator: "?").first ?? Substring(state.head.uri))
        return HTTPRequest(
            method: state.head.method.rawValue,
            headers: headers,
            body: body,
            path: path
        )
    }

    private func writeResponse(
        _ response: HTTPResponse,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let ctx = context
        let eventLoop = ctx.eventLoop
        switch response {
        case .stream(let stream, let headers):
            eventLoop.execute {
                var head = HTTPResponseHead(version: version, status: .init(statusCode: response.statusCode))
                for (name, value) in headers {
                    head.headers.add(name: name, value: value)
                }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                ctx.flush()
            }
            do {
                for try await chunk in stream {
                    eventLoop.execute {
                        var buffer = ctx.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }
                }
            } catch {
                eventLoop.execute {
                    ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                }
                return
            }
            eventLoop.execute {
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }

        default:
            let headers = response.headers
            let bodyData = response.bodyData
            eventLoop.execute {
                var head = HTTPResponseHead(version: version, status: .init(statusCode: response.statusCode))
                for (name, value) in headers {
                    head.headers.add(name: name, value: value)
                }
                if let bodyData {
                    head.headers.replaceOrAdd(name: "Content-Length", value: "\(bodyData.count)")
                } else {
                    head.headers.replaceOrAdd(name: "Content-Length", value: "0")
                }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                if let bodyData {
                    var buffer = ctx.channel.allocator.buffer(capacity: bodyData.count)
                    buffer.writeBytes(bodyData)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}
