import Foundation
import Testing
@testable import ReviewStdioAdapter

@Suite(.serialized) struct ReviewStdioAdapterTests {
    @Test func stdioFramerSplitsNewlineDelimitedJSON() {
        var framer = SimpleStdioFramer()
        let firstChunk = Data("{\"jsonrpc\":\"2.0\"}\n{\"json".utf8)
        let secondChunk = Data("rpc\":\"2.0\",\"id\":1}\n".utf8)

        let firstMessages = framer.append(firstChunk)
        let secondMessages = framer.append(secondChunk)

        #expect(firstMessages.count == 1)
        #expect(String(decoding: firstMessages[0], as: UTF8.self) == "{\"jsonrpc\":\"2.0\"}")
        #expect(secondMessages.count == 1)
        #expect(String(decoding: secondMessages[0], as: UTF8.self) == "{\"jsonrpc\":\"2.0\",\"id\":1}")
    }

    @Test func sseDecoderCombinesMultilineDataFields() {
        var decoder = SSEDecoder()
        let lines = [
            "id: 1",
            "event: message",
            "data: {\"a\":1,",
            "data: \"b\":2}",
            "",
        ]

        var payload: ReviewStdioSSEEvent?
        for line in lines {
            if let decoded = decoder.feed(line: line) {
                payload = decoded
            }
        }

        #expect(String(decoding: payload?.payload ?? Data(), as: UTF8.self) == "{\"a\":1,\n\"b\":2}")
    }

    @Test func jsonRPCRequestIDPreservesNumericIDs() {
        let numeric = JSONRPCRequestID(jsonObject: 1)
        let string = JSONRPCRequestID(jsonObject: "1")

        #expect(numeric == .integer(1))
        #expect(string == .string("1"))
        #expect((numeric?.foundationObject as? Int) == 1)
        #expect((string?.foundationObject as? String) == "1")
    }

    @Test func burstInitializeAndToolCallStayOrderedAcrossHandshake() async throws {
        let transport = TestTransport(
            postHandler: { call in
                switch await call.index() {
                case 1:
                    #expect(call.method == "initialize")
                    #expect(call.sessionID == nil)
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-1", body: successResponse(id: 1))
                case 2:
                    #expect(call.method == "notifications/initialized")
                    #expect(call.sessionID == "session-1")
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                case 3:
                    #expect(call.method == "tools/call")
                    #expect(call.sessionID == "session-1")
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: nil, body: successResponse(id: 2))
                default:
                    throw TestFailure("unexpected POST call")
                }
            }
        )
        let harness = try await AdapterHarness.make(transport: transport)

        try await harness.send(initializeRequest(id: 1))
        try await harness.send(initializedNotification())
        try await harness.send(toolCallRequest(id: 2))

        try await waitUntil {
            await transport.postCalls().count == 3
        }
        let methods = await transport.postCalls().map(\.method)
        #expect(methods == ["initialize", "notifications/initialized", "tools/call"])
        await harness.stop()
    }

    @Test func cancelNotificationBypassesLongRunningReview() async throws {
        let gate = ReviewGate()
        let transport = TestTransport(
            postHandler: { call in
                switch await call.index() {
                case 1:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-1", body: successResponse(id: 1))
                case 2:
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                case 3:
                    await gate.markReviewStarted()
                    await gate.waitForResume()
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: nil, body: successResponse(id: 2))
                case 4:
                    #expect(call.method == "notifications/cancelled")
                    await gate.markCancelSeen()
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                default:
                    throw TestFailure("unexpected POST call")
                }
            }
        )
        let harness = try await AdapterHarness.make(transport: transport)

        try await harness.send(initializeRequest(id: 1))
        try await harness.send(initializedNotification())
        try await harness.send(toolCallRequest(id: 2))

        try await waitUntil {
            await gate.reviewStarted
        }
        try await harness.send(cancelNotification(requestID: 2))

        try await waitUntil {
            await gate.cancelSeen
        }

        await gate.resume()
        try await waitUntil {
            await transport.postCalls().count == 4
        }
        let methods = await transport.postCalls().map(\.method)
        #expect(Array(methods.suffix(2)) == ["tools/call", "notifications/cancelled"])
        await harness.stop()
    }

    @Test func statusRequestIsNotBlockedByLongRunningReview() async throws {
        let gate = ReviewGate()
        let transport = TestTransport(
            postHandler: { call in
                switch await call.index() {
                case 1:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-1", body: successResponse(id: 1))
                case 2:
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                case 3:
                    await gate.markReviewStarted()
                    await gate.waitForResume()
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: nil, body: successResponse(id: 2))
                case 4:
                    #expect(call.method == "tools/call")
                    await gate.markCancelSeen()
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: nil, body: successResponse(id: 3))
                default:
                    throw TestFailure("unexpected POST call")
                }
            }
        )
        let harness = try await AdapterHarness.make(transport: transport)

        try await harness.send(initializeRequest(id: 1))
        try await harness.send(initializedNotification())
        try await harness.send(toolCallRequest(id: 2))

        try await waitUntil {
            await gate.reviewStarted
        }
        try await harness.send(statusToolCallRequest(id: 3))

        try await waitUntil {
            await gate.cancelSeen
        }

        await gate.resume()
        try await waitUntil {
            await transport.postCalls().count == 4
        }
        await harness.stop()
    }

    @Test func activeSession404ReplaysHandshakeAndRetriesRequestOnce() async throws {
        let transport = TestTransport(
            postHandler: { call in
                switch await call.index() {
                case 1:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-1", body: successResponse(id: 1))
                case 2:
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                case 3:
                    return ReviewStdioHTTPResponse(statusCode: 404, sessionID: nil, body: nil)
                case 4:
                    #expect(call.method == "initialize")
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-2", body: successResponse(id: 1))
                case 5:
                    #expect(call.method == "notifications/initialized")
                    #expect(call.sessionID == "session-2")
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                case 6:
                    #expect(call.method == "tools/call")
                    #expect(call.sessionID == "session-2")
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: nil, body: successResponse(id: 2))
                default:
                    throw TestFailure("unexpected POST call")
                }
            }
        )
        let harness = try await AdapterHarness.make(transport: transport)

        try await harness.send(initializeRequest(id: 1))
        try await harness.send(initializedNotification())
        try await harness.send(toolCallRequest(id: 2))

        try await waitUntil {
            await transport.postCalls().count == 6
        }
        let calls = await transport.postCalls()
        #expect(calls.map(\.sessionID) == [nil, "session-1", "session-1", nil, "session-2", "session-2"])
        await harness.stop()
    }

    @Test func reinitializeCancelsOldGenerationRequestWithoutEmittingReply() async throws {
        let gate = ReviewGate()
        let transport = TestTransport(
            postHandler: { call in
                switch await call.index() {
                case 1:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-1", body: successResponse(id: 1))
                case 2:
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                case 3:
                    await gate.markReviewStarted()
                    try await Task.sleep(for: .seconds(30))
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: nil, body: successResponse(id: 2))
                case 4:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-2", body: successResponse(id: 10))
                case 5:
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                default:
                    throw TestFailure("unexpected POST call")
                }
            }
        )
        let harness = try await AdapterHarness.make(transport: transport)

        try await harness.send(initializeRequest(id: 1))
        try await harness.send(initializedNotification())
        try await harness.send(toolCallRequest(id: 2))

        try await waitUntil {
            await gate.reviewStarted
        }

        try await harness.send(initializeRequest(id: 10))
        try await harness.send(initializedNotification())

        try await waitUntil {
            await transport.postCalls().count == 5
        }

        let outputs = try await harness.waitForOutputs(count: 2, timeout: .seconds(5))
        #expect(outputs.count == 2)
        #expect(outputs.contains(where: { $0.contains("\"id\":1") }))
        #expect(outputs.contains(where: { $0.contains("\"id\":10") }))
        #expect(outputs.contains(where: { $0.contains("\"id\":2") }) == false)
        await harness.stop()
    }

    @Test func recoveryFailureDeletesPartiallyCreatedSession() async throws {
        let transport = TestTransport(
            postHandler: { call in
                switch await call.index() {
                case 1:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-1", body: successResponse(id: 1))
                case 2:
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                case 3:
                    return ReviewStdioHTTPResponse(statusCode: 404, sessionID: nil, body: nil)
                case 4:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-2", body: successResponse(id: 1))
                case 5:
                    return ReviewStdioHTTPResponse(statusCode: 500, sessionID: nil, body: nil)
                default:
                    throw TestFailure("unexpected POST call")
                }
            }
        )
        let harness = try await AdapterHarness.make(transport: transport)

        try await harness.send(initializeRequest(id: 1))
        try await harness.send(initializedNotification())
        try await harness.send(toolCallRequest(id: 2))

        try await waitUntil {
            let postCount = await transport.postCalls().count
            let deletedSessions = await transport.deleteCalls()
            return postCount == 5 && deletedSessions == ["session-2"]
        }

        let outputs = try await harness.waitForOutputs(count: 2, timeout: .seconds(5))
        #expect(outputs.contains(where: { $0.contains("\"id\":2") }))
        await harness.stop()
    }

    @Test func initializeFailureDeletesAllocatedSession() async throws {
        let transport = TestTransport(
            postHandler: { call in
                switch await call.index() {
                case 1:
                    return ReviewStdioHTTPResponse(
                        statusCode: 500,
                        sessionID: "session-1",
                        body: errorResponse(id: 1, message: "initialize failed")
                    )
                default:
                    throw TestFailure("unexpected POST call")
                }
            }
        )
        let harness = try await AdapterHarness.make(transport: transport)

        try await harness.send(initializeRequest(id: 1))

        let outputs = try await harness.waitForOutputs(count: 1, timeout: .seconds(5))
        #expect(outputs[0].contains("\"id\":1"))
        #expect(await transport.deleteCalls() == ["session-1"])
        await harness.stop()
    }

    @Test func initializedFailureDeletesCurrentSession() async throws {
        let transport = TestTransport(
            postHandler: { call in
                switch await call.index() {
                case 1:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-1", body: successResponse(id: 1))
                case 2:
                    return ReviewStdioHTTPResponse(
                        statusCode: 500,
                        sessionID: nil,
                        body: errorResponse(id: 1, message: "initialized failed")
                    )
                default:
                    throw TestFailure("unexpected POST call")
                }
            }
        )
        let harness = try await AdapterHarness.make(transport: transport)

        try await harness.send(initializeRequest(id: 1))
        try await harness.send(initializedNotification())

        let outputs = try await harness.waitForOutputs(count: 1, timeout: .seconds(5))
        #expect(outputs[0].contains("\"id\":1"))
        try await waitUntil {
            await transport.deleteCalls() == ["session-1"]
        }
        #expect(await transport.deleteCalls() == ["session-1"])
        await harness.stop()
    }

    @Test func initializeWithoutBodyDeletesSessionAndClearsHandshakeState() async throws {
        let transport = TestTransport(
            postHandler: { call in
                switch await call.index() {
                case 1:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-1", body: nil)
                default:
                    throw TestFailure("unexpected POST call")
                }
            }
        )
        let harness = try await AdapterHarness.make(transport: transport)

        try await harness.send(initializeRequest(id: 1))

        let firstOutputs = try await harness.waitForOutputs(count: 1, timeout: .seconds(5))
        #expect(firstOutputs.contains(where: { $0.contains("\"id\":1") }))

        try await harness.send(toolCallRequest(id: 2))

        let outputs = try await harness.waitForOutputs(count: 2, timeout: .seconds(5))
        #expect(outputs.contains(where: { $0.contains("\"id\":1") }))
        #expect(outputs.contains(where: { $0.contains("\"id\":2") }))
        #expect(await transport.postCalls().count == 1)
        #expect(await transport.deleteCalls() == ["session-1"])
        await harness.stop()
    }

    @Test func sseEOFReconnectsWithoutDroppingSession() async throws {
        let transport = TestTransport(
            postHandler: { call in
                switch await call.index() {
                case 1:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-1", body: successResponse(id: 1))
                case 2:
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                default:
                    throw TestFailure("unexpected POST call")
                }
            },
            sseHandler: { _, _, count in
                if count == 1 {
                    return finishedStream(eventID: "event-1")
                }
                return neverEndingStream()
            }
        )
        let harness = try await AdapterHarness.make(transport: transport)

        try await harness.send(initializeRequest(id: 1))
        try await harness.send(initializedNotification())

        try await waitUntil(timeout: .seconds(3)) {
            await transport.sseCalls().count >= 2
        }
        let sseCalls = await transport.sseCalls()
        #expect(sseCalls.prefix(2).map(\.sessionID) == ["session-1", "session-1"])
        #expect(sseCalls.dropFirst().first?.lastEventID == "event-1")
        await harness.stop()
    }

    @Test func sse404TriggersHandshakeReplay() async throws {
        let transport = TestTransport(
            postHandler: { call in
                switch await call.index() {
                case 1:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-1", body: successResponse(id: 1))
                case 2:
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                case 3:
                    #expect(call.method == "initialize")
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-2", body: successResponse(id: 1))
                case 4:
                    #expect(call.method == "notifications/initialized")
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                default:
                    throw TestFailure("unexpected POST call")
                }
            },
            sseHandler: { _, _, count in
                if count == 1 {
                    throw ReviewStdioUpstreamTransportError.httpStatus(404)
                }
                return neverEndingStream()
            }
        )
        let harness = try await AdapterHarness.make(transport: transport)

        try await harness.send(initializeRequest(id: 1))
        try await harness.send(initializedNotification())

        try await waitUntil(timeout: .seconds(3)) {
            let postCount = await transport.postCalls().count
            let sseCount = await transport.sseCalls().count
            return postCount == 4 && sseCount == 2
        }
        let postMethods = await transport.postCalls().map(\.method)
        #expect(postMethods == ["initialize", "notifications/initialized", "initialize", "notifications/initialized"])
        let sseCalls = await transport.sseCalls().map(\.sessionID)
        #expect(sseCalls == ["session-1", "session-2"])
        await harness.stop()
    }

    @Test func requestWithoutHandshakeReturnsExplicitError() async throws {
        let transport = TestTransport(
            postHandler: { _ in
                throw TestFailure("unexpected POST call")
            }
        )
        let harness = try await AdapterHarness.make(transport: transport)

        try await harness.send(toolCallRequest(id: 99))

        let outputs = try await harness.waitForOutputs(count: 1, timeout: .seconds(5))
        #expect(outputs[0].contains("\"id\":99"))
        #expect(outputs[0].contains("Cannot recover upstream MCP session"))
        await harness.stop()
    }

    @Test func latestInitializeWinsWhenMultipleInitializesAreQueued() async throws {
        let transport = TestTransport(
            postHandler: { call in
                switch await call.index() {
                case 1:
                    #expect(call.method == "initialize")
                    let object = try #require(JSONSerialization.jsonObject(with: call.data) as? [String: Any])
                    #expect(object["id"] as? Int == 2)
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-2", body: successResponse(id: 2))
                case 2:
                    #expect(call.method == "notifications/initialized")
                    #expect(call.sessionID == "session-2")
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                default:
                    throw TestFailure("unexpected POST call")
                }
            }
        )
        let harness = try await AdapterHarness.make(transport: transport)

        let chunk = try Data([
            JSONSerialization.data(withJSONObject: initializeRequest(id: 1)),
            JSONSerialization.data(withJSONObject: initializeRequest(id: 2)),
            JSONSerialization.data(withJSONObject: initializedNotification()),
        ].joined(separator: Data([0x0A]))) + Data([0x0A])
        await harness.adapter.receiveChunkForTesting(chunk)

        try await waitUntil {
            await transport.postCalls().count == 2
        }
        let outputs = try await harness.waitForOutputs(count: 1, timeout: .seconds(5))
        #expect(outputs[0].contains("\"id\":2"))
        await harness.stop()
    }

    @Test func staleInitializeResponseDoesNotEmitReply() async throws {
        let gate = ReviewGate()
        let transport = TestTransport(
            postHandler: { call in
                switch await call.index() {
                case 1:
                    await gate.markReviewStarted()
                    await gate.waitForResume()
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-1", body: successResponse(id: 1))
                case 2:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-2", body: successResponse(id: 2))
                default:
                    throw TestFailure("unexpected POST call")
                }
            }
        )
        let harness = try await AdapterHarness.make(transport: transport)

        try await harness.send(initializeRequest(id: 1))
        try await waitUntil {
            await gate.reviewStarted
        }
        try await harness.send(initializeRequest(id: 2))
        await gate.resume()

        let outputs = try await harness.waitForOutputs(count: 1, timeout: .seconds(5))
        #expect(outputs.count == 1)
        #expect(outputs[0].contains("\"id\":2"))
        #expect(outputs.contains(where: { $0.contains("\"id\":1") }) == false)
        #expect(await transport.deleteCalls() == ["session-1"])
        await harness.stop()
    }

    @Test func cancelledInFlightRequestDoesNotEmitReply() async throws {
        let gate = ReviewGate()
        let transport = TestTransport(
            postHandler: { call in
                switch await call.index() {
                case 1:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-1", body: successResponse(id: 1))
                case 2:
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                case 3:
                    await gate.markReviewStarted()
                    await gate.waitForResume()
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: nil, body: successResponse(id: 2))
                case 4:
                    await gate.markCancelSeen()
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                default:
                    throw TestFailure("unexpected POST call")
                }
            }
        )
        let harness = try await AdapterHarness.make(transport: transport)

        try await harness.send(initializeRequest(id: 1))
        try await harness.send(initializedNotification())
        try await harness.send(toolCallRequest(id: 2))

        try await waitUntil {
            await gate.reviewStarted
        }
        try await harness.send(cancelNotification(requestID: 2))
        try await waitUntil {
            await gate.cancelSeen
        }
        await gate.resume()
        try await waitUntil {
            await transport.postCalls().count == 4
        }
        try await Task.sleep(for: .milliseconds(100))

        let outputs = harness.outputSink.outputs()
        #expect(outputs.count == 1)
        #expect(outputs[0].contains("\"id\":1"))
        #expect(outputs.contains(where: { $0.contains("\"id\":2") }) == false)
        await harness.stop()
    }

    @Test func requestIDCanBeReusedAfterCancelledRequestCompletes() async throws {
        let gate = ReviewGate()
        let transport = TestTransport(
            postHandler: { call in
                switch await call.index() {
                case 1:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-1", body: successResponse(id: 1))
                case 2:
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                case 3:
                    await gate.markReviewStarted()
                    await gate.waitForResume()
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: nil, body: successResponse(id: 2))
                case 4:
                    await gate.markCancelSeen()
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                case 5:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: nil, body: successResponse(id: 2))
                default:
                    throw TestFailure("unexpected POST call")
                }
            }
        )
        let harness = try await AdapterHarness.make(transport: transport)

        try await harness.send(initializeRequest(id: 1))
        try await harness.send(initializedNotification())
        try await harness.send(toolCallRequest(id: 2))

        try await waitUntil {
            await gate.reviewStarted
        }
        try await harness.send(cancelNotification(requestID: 2))
        try await waitUntil {
            await gate.cancelSeen
        }
        await gate.resume()
        try await waitUntil {
            await transport.postCalls().count == 4
        }

        try await harness.send(toolCallRequest(id: 2))
        let outputs = try await harness.waitForOutputs(count: 2, timeout: .seconds(5))
        #expect(outputs.contains(where: { $0.contains("\"id\":2") }))
        await harness.stop()
    }

    @Test func requestIDCanBeReusedAfterQueuedCancellation() async throws {
        let transport = TestTransport(
            postHandler: { call in
                switch await call.index() {
                case 1:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-1", body: successResponse(id: 1))
                case 2:
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                case 3:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: nil, body: successResponse(id: 2))
                default:
                    throw TestFailure("unexpected POST call")
                }
            }
        )
        let harness = try await AdapterHarness.make(transport: transport)

        try await harness.send(initializeRequest(id: 1))
        try await harness.send(toolCallRequest(id: 2))
        try await harness.send(cancelNotification(requestID: 2))
        let cancelledOutputs = try await harness.waitForOutputs(count: 2, timeout: .seconds(5))
        #expect(cancelledOutputs.contains(where: { $0.contains("\"id\":2") }))

        try await harness.send(initializedNotification())
        try await harness.send(toolCallRequest(id: 2))

        let outputs = try await harness.waitForOutputs(count: 3, timeout: .seconds(5))
        #expect(outputs.filter { $0.contains("\"id\":2") }.count == 2)
        await harness.stop()
    }

    @Test func stopDeletesSessionCreatedDuringRecovery() async throws {
        let gate = ReviewGate()
        let transport = TestTransport(
            postHandler: { call in
                switch await call.index() {
                case 1:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-1", body: successResponse(id: 1))
                case 2:
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                case 3:
                    return ReviewStdioHTTPResponse(statusCode: 404, sessionID: nil, body: nil)
                case 4:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-2", body: successResponse(id: 1))
                case 5:
                    await gate.markReviewStarted()
                    await gate.waitForResume()
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                default:
                    throw TestFailure("unexpected POST call")
                }
            }
        )
        let harness = try await AdapterHarness.make(transport: transport)

        try await harness.send(initializeRequest(id: 1))
        try await harness.send(initializedNotification())
        try await harness.send(toolCallRequest(id: 2))

        try await waitUntil {
            await gate.reviewStarted
        }

        await harness.stop()
        await gate.resume()

        try await waitUntil {
            await transport.deleteCalls().contains("session-2")
        }
    }

    @Test func cancelledRequestIsNotRetriedAfter404Recovery() async throws {
        let gate = ReviewGate()
        let transport = TestTransport(
            postHandler: { call in
                switch await call.index() {
                case 1:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-1", body: successResponse(id: 1))
                case 2:
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                case 3:
                    return ReviewStdioHTTPResponse(statusCode: 404, sessionID: nil, body: nil)
                case 4:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-2", body: successResponse(id: 1))
                case 5:
                    await gate.markReviewStarted()
                    await gate.waitForResume()
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                default:
                    throw TestFailure("unexpected POST call")
                }
            }
        )
        let harness = try await AdapterHarness.make(transport: transport)

        try await harness.send(initializeRequest(id: 1))
        try await harness.send(initializedNotification())
        try await harness.send(toolCallRequest(id: 2))

        try await waitUntil {
            await gate.reviewStarted
        }
        try await harness.send(cancelNotification(requestID: 2))
        await gate.resume()

        try await waitUntil {
            await transport.postCalls().count == 5
        }

        try await Task.sleep(for: .milliseconds(100))

        let outputs = harness.outputSink.outputs()
        #expect(outputs.count == 1)
        #expect(outputs[0].contains("\"id\":1"))
        #expect(outputs.contains(where: { $0.contains("\"id\":2") }) == false)
        await harness.stop()
    }

    @Test func queuedRequestRunsAfterRecoveryBecomesReady() async throws {
        let gate = ReviewGate()
        let transport = TestTransport(
            postHandler: { call in
                switch await call.index() {
                case 1:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-1", body: successResponse(id: 1))
                case 2:
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                case 3:
                    return ReviewStdioHTTPResponse(statusCode: 404, sessionID: nil, body: nil)
                case 4:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: "session-2", body: successResponse(id: 1))
                case 5:
                    await gate.markReviewStarted()
                    await gate.waitForResume()
                    return ReviewStdioHTTPResponse(statusCode: 202, sessionID: nil, body: nil)
                case 6:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: nil, body: successResponse(id: 2))
                case 7:
                    return ReviewStdioHTTPResponse(statusCode: 200, sessionID: nil, body: successResponse(id: 3))
                default:
                    throw TestFailure("unexpected POST call")
                }
            }
        )
        let harness = try await AdapterHarness.make(transport: transport)

        try await harness.send(initializeRequest(id: 1))
        try await harness.send(initializedNotification())
        try await harness.send(toolCallRequest(id: 2))

        try await waitUntil {
            await gate.reviewStarted
        }
        try await harness.send(statusToolCallRequest(id: 3))
        await gate.resume()

        try await waitUntil {
            await transport.postCalls().count == 7
        }

        let outputs = try await harness.waitForOutputs(count: 3, timeout: .seconds(5))
        #expect(outputs.contains(where: { $0.contains("\"id\":2") }))
        #expect(outputs.contains(where: { $0.contains("\"id\":3") }))
        await harness.stop()
    }
}

private struct AdapterHarness {
    let adapter: ReviewStdioAdapter
    let outputSink: RecordingOutputSink

    static func make(transport: any ReviewStdioUpstreamTransport) async throws -> AdapterHarness {
        let inputPipe = Pipe()
        let outputSink = RecordingOutputSink()
        let upstreamURL = try #require(URL(string: "http://localhost:9417/mcp"))

        let adapter = ReviewStdioAdapter(
            configuration: .init(upstreamURL: upstreamURL),
            input: inputPipe.fileHandleForReading,
            outputSink: outputSink,
            transport: transport
        )
        return AdapterHarness(adapter: adapter, outputSink: outputSink)
    }

    func send(_ object: Any) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        await adapter.receiveChunkForTesting(data + Data([0x0A]))
    }

    func waitForOutputs(count: Int, timeout: Duration = .seconds(2)) async throws -> [String] {
        try await waitUntil(timeout: timeout) {
            outputSink.outputs().count >= count
        }
        return outputSink.outputs()
    }

    func stop() async {
        await adapter.stop()
    }
}

private final class RecordingOutputSink: ReviewStdioOutputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func send(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(String(decoding: data, as: UTF8.self))
    }

    func outputs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

private actor ReviewGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var reviewStarted = false
    private(set) var cancelSeen = false

    func markReviewStarted() {
        reviewStarted = true
    }

    func markCancelSeen() {
        cancelSeen = true
    }

    func waitForResume() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor TestTransport: ReviewStdioUpstreamTransport {
    struct RecordedPost: Sendable {
        let ordinal: Int
        let method: String?
        let sessionID: String?
        let data: Data

        func index() async -> Int {
            ordinal
        }
    }

    typealias POSTHandler = @Sendable (RecordedPost) async throws -> ReviewStdioHTTPResponse
    typealias SSEHandler = @Sendable (String, String?, Int) async throws -> AsyncThrowingStream<ReviewStdioSSEEvent, Error>
    typealias DeleteHandler = @Sendable (String) async -> Void

    private let postHandler: POSTHandler
    private let sseHandler: SSEHandler
    private let deleteHandler: DeleteHandler
    private var postLog: [RecordedPost] = []
    struct RecordedSSE: Sendable {
        let sessionID: String
        let lastEventID: String?
    }

    private var sseLog: [RecordedSSE] = []
    private var deleteLog: [String] = []

    init(
        postHandler: @escaping POSTHandler,
        sseHandler: @escaping SSEHandler = { _, _, _ in neverEndingStream() },
        deleteHandler: @escaping DeleteHandler = { _ in }
    ) {
        self.postHandler = postHandler
        self.sseHandler = sseHandler
        self.deleteHandler = deleteHandler
    }

    func sendPOST(
        url: URL,
        data: Data,
        sessionID: String?,
        timeout: TimeInterval
    ) async throws -> ReviewStdioHTTPResponse {
        let recorded = RecordedPost(
            ordinal: postLog.count + 1,
            method: parseMethod(from: data),
            sessionID: sessionID,
            data: data
        )
        postLog.append(recorded)
        return try await postHandler(recorded)
    }

    func openSSE(
        url: URL,
        sessionID: String,
        lastEventID: String?
    ) async throws -> AsyncThrowingStream<ReviewStdioSSEEvent, Error> {
        sseLog.append(RecordedSSE(sessionID: sessionID, lastEventID: lastEventID))
        return try await sseHandler(sessionID, lastEventID, sseLog.count)
    }

    func deleteSession(
        url: URL,
        sessionID: String
    ) async {
        deleteLog.append(sessionID)
        await deleteHandler(sessionID)
    }

    func invalidate() async {
    }

    func postCalls() -> [RecordedPost] {
        postLog
    }

    func sseCalls() -> [RecordedSSE] {
        sseLog
    }

    func deleteCalls() -> [String] {
        deleteLog
    }
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    interval: Duration = .milliseconds(20),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: interval)
    }
    throw TestFailure("timed out")
}

private func initializeRequest(id: Int) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-11-25",
            "capabilities": [:],
            "clientInfo": ["name": "test", "version": "0.0.1"],
        ],
    ]
}

private func initializedNotification() -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "method": "notifications/initialized",
        "params": [:],
    ]
}

private func toolCallRequest(id: Int) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": [
            "name": "review",
            "arguments": ["cwd": "/tmp"],
        ],
    ]
}

private func statusToolCallRequest(id: Int) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": [
            "name": "review_status",
            "arguments": ["jobId": "job-1"],
        ],
    ]
}

private func cancelNotification(requestID: Int) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "method": "notifications/cancelled",
        "params": [
            "requestId": requestID,
            "reason": "test cancel",
        ],
    ]
}

private func successResponse(id: Int) -> Data {
    serializeJSONObject([
        "jsonrpc": "2.0",
        "id": id,
        "result": ["ok": true],
    ])
}

private func errorResponse(id: Int, message: String) -> Data {
    serializeJSONObject([
        "jsonrpc": "2.0",
        "id": id,
        "error": [
            "code": -32000,
            "message": message,
        ],
    ])
}

private func parseMethod(from data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object["method"] as? String
}

private func serializeJSONObject(_ object: Any) -> Data {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object)
    else {
        assertionFailure("Expected a valid JSON object.")
        return Data()
    }
    return data
}

private func neverEndingStream() -> AsyncThrowingStream<ReviewStdioSSEEvent, Error> {
    AsyncThrowingStream { _ in
    }
}

private func finishedStream(eventID: String? = nil) -> AsyncThrowingStream<ReviewStdioSSEEvent, Error> {
    AsyncThrowingStream { continuation in
        continuation.yield(ReviewStdioSSEEvent(id: eventID, payload: Data("{}".utf8)))
        continuation.finish()
    }
}

private struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
