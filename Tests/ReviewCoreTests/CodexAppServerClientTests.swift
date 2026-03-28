import Foundation
import MCP
import Testing
@testable import ReviewCore

@Suite(.serialized) struct CodexAppServerClientTests {
    @Test func appServerInvocationResetsSignalHandlersBeforeExec() {
        let invocation = appServerProcessInvocation(codexCommand: "/usr/local/bin/codex")

        #expect(invocation.executable == "/bin/sh")
        #expect(invocation.arguments.count == 2)
        #expect(invocation.arguments[0] == "-lc")
        #expect(invocation.arguments[1].contains("trap - TERM INT"))
        #expect(invocation.arguments[1].contains("app-server --listen stdio://"))
        #expect(invocation.arguments[1].contains("'/usr/local/bin/codex'"))
    }

    @Test func clientInitializesAndRoutesResponses() async throws {
        let transport = ScriptedAppServerTransport { message, transport in
            let method = try #require(message.objectValue?["method"]?.stringValue)
            let requestID = message.objectValue?["id"]?.intValue
            switch method {
            case "initialize":
                await transport.respond(id: try #require(requestID), result: ["serverInfo": ["name": "codex"]])
            case "initialized":
                break
            case "thread/start":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "thread": [
                            "id": "parent-1",
                            "turns": [],
                        ],
                    ]
                )
            default:
                throw TestFailure("unexpected method \(method)")
            }
        }
        let client = CodexAppServerClient(
            configuration: .init(),
            transportFactory: { transport }
        )

        let response: TestThreadResponse = try await client.call(
            method: "thread/start",
            params: ["cwd": "/repo"],
            as: TestThreadResponse.self
        )

        #expect(response.thread.id == "parent-1")
        #expect(await transport.sentMethods() == ["initialize", "initialized", "thread/start"])
        await client.shutdown()
    }

    @Test func clientReconnectsLazilyAfterDisconnect() async throws {
        let firstTransport = ScriptedAppServerTransport { message, transport in
            let method = try #require(message.objectValue?["method"]?.stringValue)
            let requestID = message.objectValue?["id"]?.intValue
            switch method {
            case "initialize":
                await transport.respond(id: try #require(requestID), result: ["serverInfo": ["name": "codex"]])
            case "initialized":
                break
            case "thread/start":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "thread": [
                            "id": "parent-1",
                            "turns": [],
                        ],
                    ]
                )
                await transport.finish()
            default:
                throw TestFailure("unexpected method \(method)")
            }
        }
        let secondTransport = ScriptedAppServerTransport { message, transport in
            let method = try #require(message.objectValue?["method"]?.stringValue)
            let requestID = message.objectValue?["id"]?.intValue
            switch method {
            case "initialize":
                await transport.respond(id: try #require(requestID), result: ["serverInfo": ["name": "codex"]])
            case "initialized":
                break
            case "thread/read":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "thread": [
                            "id": "parent-1",
                            "turns": [],
                        ],
                    ]
                )
            default:
                throw TestFailure("unexpected method \(method)")
            }
        }
        let factory = SequentialTransportFactory(transports: [firstTransport, secondTransport])
        let client = CodexAppServerClient(
            configuration: .init(),
            transportFactory: {
                factory.nextTransport()
            }
        )

        _ = try await client.call(method: "thread/start", params: ["cwd": "/repo"], as: TestThreadResponse.self)
        try await waitUntil {
            await firstTransport.didFinish
        }
        _ = try await client.call(
            method: "thread/read",
            params: Value.object([
                "threadId": .string("parent-1"),
                "includeTurns": .bool(true),
            ]),
            as: TestThreadResponse.self
        )

        #expect(await secondTransport.sentMethods() == ["initialize", "initialized", "thread/read"])
        await client.shutdown()
    }

    @Test func registryReusesParentThreadForSameSessionAndCWD() async throws {
        let transport = ScriptedAppServerTransport { message, transport in
            let method = try #require(message.objectValue?["method"]?.stringValue)
            let requestID = message.objectValue?["id"]?.intValue
            switch method {
            case "initialize":
                await transport.respond(id: try #require(requestID), result: ["serverInfo": ["name": "codex"]])
            case "initialized":
                break
            case "thread/start":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "thread": [
                            "id": "parent-1",
                            "turns": [],
                        ],
                    ]
                )
            case "thread/resume":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "thread": [
                            "id": "parent-1",
                            "turns": [],
                        ],
                    ]
                )
            case "review/start":
                let reviewThreadID = await transport.sentReviewStartCount() == 1 ? "review-1" : "review-2"
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "turn": [
                            "id": "turn-\(reviewThreadID)",
                            "items": [],
                            "status": "inProgress",
                            "error": nil,
                        ],
                        "reviewThreadId": .string(reviewThreadID),
                    ]
                )
            default:
                throw TestFailure("unexpected method \(method)")
            }
        }
        let registry = ReviewRegistry(
            configuration: .init(),
            transportFactory: { transport }
        )
        await registry.start()

        let first = try await registry.startReview(
            sessionID: "session-1",
            request: ReviewStartRequest(cwd: "/repo", target: ReviewTarget.uncommittedChanges)
        )
        let second = try await registry.startReview(
            sessionID: "session-1",
            request: ReviewStartRequest(cwd: "/repo", target: ReviewTarget.baseBranch(branch: "main"))
        )

        #expect(first.parentThreadID == "parent-1")
        #expect(second.parentThreadID == "parent-1")
        #expect(await transport.sentMethods() == [
            "initialize", "initialized", "thread/start", "review/start", "thread/resume", "review/start",
        ])
        await registry.shutdown()
    }

    @Test func registryDeduplicatesConcurrentParentThreadCreation() async throws {
        let gate = StartGate()
        let transport = ScriptedAppServerTransport { message, transport in
            let method = try #require(message.objectValue?["method"]?.stringValue)
            let requestID = message.objectValue?["id"]?.intValue
            switch method {
            case "initialize":
                await transport.respond(id: try #require(requestID), result: ["serverInfo": ["name": "codex"]])
            case "initialized":
                break
            case "thread/start":
                await gate.markStarted()
                await gate.waitForResume()
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "thread": [
                            "id": "parent-1",
                            "turns": [],
                        ],
                    ]
                )
            case "review/start":
                let reviewThreadID = await transport.sentReviewStartCount() == 1 ? "review-1" : "review-2"
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "turn": [
                            "id": "turn-\(reviewThreadID)",
                            "items": [],
                            "status": "inProgress",
                            "error": nil,
                        ],
                        "reviewThreadId": .string(reviewThreadID),
                    ]
                )
            default:
                throw TestFailure("unexpected method \(method)")
            }
        }
        let registry = ReviewRegistry(
            configuration: .init(),
            transportFactory: { transport }
        )
        await registry.start()

        let firstTask = Task {
            try await registry.startReview(
                sessionID: "session-1",
                request: ReviewStartRequest(cwd: "/repo", target: ReviewTarget.uncommittedChanges)
            )
        }

        try await waitUntil {
            await gate.didStart
        }

        let secondTask = Task {
            try await registry.startReview(
                sessionID: "session-1",
                request: ReviewStartRequest(cwd: "/repo", target: ReviewTarget.baseBranch(branch: "main"))
            )
        }

        await gate.resume()

        let first = try await firstTask.value
        let second = try await secondTask.value

        #expect(first.parentThreadID == "parent-1")
        #expect(second.parentThreadID == "parent-1")
        #expect(await transport.sentMethods() == [
            "initialize", "initialized", "thread/start", "review/start", "review/start",
        ])
        await registry.shutdown()
    }

    @Test func registryStartsFreshParentThreadWhenResumeFails() async throws {
        let transport = ScriptedAppServerTransport { message, transport in
            let method = try #require(message.objectValue?["method"]?.stringValue)
            let requestID = message.objectValue?["id"]?.intValue
            switch method {
            case "initialize":
                await transport.respond(id: try #require(requestID), result: ["serverInfo": ["name": "codex"]])
            case "initialized":
                break
            case "thread/start":
                let parentID = await transport.sentMethods().filter { $0 == "thread/start" }.count == 1 ? "parent-1" : "parent-2"
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "thread": [
                            "id": .string(parentID),
                            "turns": [],
                        ],
                    ]
                )
            case "thread/resume":
                await transport.respondError(
                    id: try #require(requestID),
                    code: -32002,
                    message: "resume failed"
                )
            case "review/start":
                let reviewThreadID = await transport.sentReviewStartCount() == 1 ? "review-1" : "review-2"
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "turn": [
                            "id": "turn-\(reviewThreadID)",
                            "items": [],
                            "status": "inProgress",
                            "error": nil,
                        ],
                        "reviewThreadId": .string(reviewThreadID),
                    ]
                )
            default:
                throw TestFailure("unexpected method \(method)")
            }
        }
        let registry = ReviewRegistry(
            configuration: .init(),
            transportFactory: { transport }
        )
        await registry.start()

        let first = try await registry.startReview(
            sessionID: "session-1",
            request: ReviewStartRequest(cwd: "/repo", target: ReviewTarget.uncommittedChanges)
        )
        let second = try await registry.startReview(
            sessionID: "session-1",
            request: ReviewStartRequest(cwd: "/repo", target: ReviewTarget.baseBranch(branch: "main"))
        )

        #expect(first.parentThreadID == "parent-1")
        #expect(second.parentThreadID == "parent-2")
        #expect(await transport.sentMethods() == [
            "initialize", "initialized", "thread/start", "review/start", "thread/resume", "thread/start", "review/start",
        ])
        await registry.shutdown()
    }

    @Test func registryReadsCompletedReviewFromThreadReadAfterDisconnect() async throws {
        let firstTransport = ScriptedAppServerTransport { message, transport in
            let method = try #require(message.objectValue?["method"]?.stringValue)
            let requestID = message.objectValue?["id"]?.intValue
            switch method {
            case "initialize":
                await transport.respond(id: try #require(requestID), result: ["serverInfo": ["name": "codex"]])
            case "initialized":
                break
            case "thread/start":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "thread": [
                            "id": "parent-1",
                            "turns": [],
                        ],
                    ]
                )
            case "review/start":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "turn": [
                            "id": "turn-1",
                            "items": [],
                            "status": "inProgress",
                            "error": nil,
                        ],
                        "reviewThreadId": .string("review-1"),
                    ]
                )
                await transport.notify(
                    method: "turn/completed",
                    params: [
                        "threadId": "review-1",
                        "turn": [
                            "id": "turn-1",
                            "items": [],
                            "status": "completed",
                            "error": nil,
                        ],
                    ]
                )
                await transport.finish()
            default:
                throw TestFailure("unexpected method \(method)")
            }
        }
        let secondTransport = ScriptedAppServerTransport { message, transport in
            let method = try #require(message.objectValue?["method"]?.stringValue)
            let requestID = message.objectValue?["id"]?.intValue
            switch method {
            case "initialize":
                await transport.respond(id: try #require(requestID), result: ["serverInfo": ["name": "codex"]])
            case "initialized":
                break
            case "thread/read":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "thread": [
                            "id": "review-1",
                            "turns": [[
                                "id": "turn-1",
                                "status": "completed",
                                "error": nil,
                                "items": [[
                                    "type": "exitedReviewMode",
                                    "id": "turn-1",
                                    "review": "Looks good.",
                                ]],
                            ]],
                        ],
                    ]
                )
            default:
                throw TestFailure("unexpected method \(method)")
            }
        }
        let factory = SequentialTransportFactory(transports: [firstTransport, secondTransport])
        let registry = ReviewRegistry(
            configuration: .init(),
            transportFactory: {
                factory.nextTransport()
            }
        )
        await registry.start()

        _ = try await registry.startReview(
            sessionID: "session-1",
            request: ReviewStartRequest(cwd: "/repo", target: ReviewTarget.uncommittedChanges)
        )

        try await waitUntil {
            await firstTransport.didFinish
        }
        try await waitUntil(timeout: .seconds(5)) {
            let result = try? await registry.readReview(
                reviewThreadID: "review-1",
                sessionID: "session-1"
            )
            return result?.review == "Looks good."
        }
        let result = try await registry.readReview(
            reviewThreadID: "review-1",
            sessionID: "session-1"
        )

        #expect(result.status == .succeeded)
        #expect(result.review == "Looks good.")
        await registry.shutdown()
    }

    @Test func registryCancelsActiveReview() async throws {
        let transport = ScriptedAppServerTransport { message, transport in
            let method = try #require(message.objectValue?["method"]?.stringValue)
            let requestID = message.objectValue?["id"]?.intValue
            switch method {
            case "initialize":
                await transport.respond(id: try #require(requestID), result: ["serverInfo": ["name": "codex"]])
            case "initialized":
                break
            case "thread/start":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "thread": [
                            "id": "parent-1",
                            "turns": [],
                        ],
                    ]
                )
            case "review/start":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "turn": [
                            "id": "turn-1",
                            "items": [],
                            "status": "inProgress",
                            "error": nil,
                        ],
                        "reviewThreadId": .string("review-1"),
                    ]
                )
            case "turn/interrupt":
                await transport.respond(id: try #require(requestID), result: [:])
            default:
                throw TestFailure("unexpected method \(method)")
            }
        }
        let registry = ReviewRegistry(
            configuration: .init(),
            transportFactory: { transport }
        )
        await registry.start()

        _ = try await registry.startReview(
            sessionID: "session-1",
            request: ReviewStartRequest(cwd: "/repo", target: ReviewTarget.uncommittedChanges)
        )
        let result = try await registry.cancelReview(
            reviewThreadID: "review-1",
            sessionID: "session-1"
        )

        #expect(result.cancelled)
        #expect(await transport.sentMethods().suffix(1) == ["turn/interrupt"])
        await registry.shutdown()
    }

    @Test func registryCancelReviewThrowsWhenInterruptFails() async throws {
        let transport = ScriptedAppServerTransport { message, transport in
            let method = try #require(message.objectValue?["method"]?.stringValue)
            let requestID = message.objectValue?["id"]?.intValue
            switch method {
            case "initialize":
                await transport.respond(id: try #require(requestID), result: ["serverInfo": ["name": "codex"]])
            case "initialized":
                break
            case "thread/start":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "thread": [
                            "id": "parent-1",
                            "turns": [],
                        ],
                    ]
                )
            case "review/start":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "turn": [
                            "id": "turn-1",
                            "items": [],
                            "status": "inProgress",
                            "error": nil,
                        ],
                        "reviewThreadId": .string("review-1"),
                    ]
                )
            case "turn/interrupt":
                await transport.respondError(
                    id: try #require(requestID),
                    code: -32001,
                    message: "interrupt failed"
                )
            default:
                throw TestFailure("unexpected method \(method)")
            }
        }
        let registry = ReviewRegistry(
            configuration: .init(),
            transportFactory: { transport }
        )
        await registry.start()

        _ = try await registry.startReview(
            sessionID: "session-1",
            request: ReviewStartRequest(cwd: "/repo", target: ReviewTarget.uncommittedChanges)
        )

        do {
            _ = try await registry.cancelReview(
                reviewThreadID: "review-1",
                sessionID: "session-1"
            )
            throw TestFailure("expected cancelReview to surface interrupt failure")
        } catch {
        }

        await registry.shutdown()
    }

    @Test func registryKeepsCancelledStateWhenLateTurnNotificationArrives() async throws {
        let transport = ScriptedAppServerTransport { message, transport in
            let method = try #require(message.objectValue?["method"]?.stringValue)
            let requestID = message.objectValue?["id"]?.intValue
            switch method {
            case "initialize":
                await transport.respond(id: try #require(requestID), result: ["serverInfo": ["name": "codex"]])
            case "initialized":
                break
            case "thread/start":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "thread": [
                            "id": "parent-1",
                            "turns": [],
                        ],
                    ]
                )
            case "review/start":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "turn": [
                            "id": "turn-1",
                            "items": [],
                            "status": "inProgress",
                            "error": nil,
                        ],
                        "reviewThreadId": .string("review-1"),
                    ]
                )
            case "turn/interrupt":
                await transport.respond(id: try #require(requestID), result: [:])
            default:
                throw TestFailure("unexpected method \(method)")
            }
        }
        let registry = ReviewRegistry(
            configuration: .init(),
            transportFactory: { transport }
        )
        await registry.start()

        _ = try await registry.startReview(
            sessionID: "session-1",
            request: ReviewStartRequest(cwd: "/repo", target: ReviewTarget.uncommittedChanges)
        )
        _ = try await registry.cancelReview(
            reviewThreadID: "review-1",
            sessionID: "session-1"
        )
        await transport.notify(
            method: "turn/completed",
            params: [
                "threadId": "review-1",
                "turn": [
                    "id": "turn-1",
                    "items": [],
                    "status": "completed",
                    "error": nil,
                ],
            ]
        )

        let result = try await registry.readReview(
            reviewThreadID: "review-1",
            sessionID: "session-1"
        )

        #expect(result.status == .cancelled)
        await registry.shutdown()
    }

    @Test func registryDoesNotRefreshCancelledReviewState() async throws {
        let transport = ScriptedAppServerTransport { message, transport in
            let method = try #require(message.objectValue?["method"]?.stringValue)
            let requestID = message.objectValue?["id"]?.intValue
            switch method {
            case "initialize":
                await transport.respond(id: try #require(requestID), result: ["serverInfo": ["name": "codex"]])
            case "initialized":
                break
            case "thread/start":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "thread": [
                            "id": "parent-1",
                            "turns": [],
                        ],
                    ]
                )
            case "review/start":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "turn": [
                            "id": "turn-1",
                            "items": [],
                            "status": "inProgress",
                            "error": nil,
                        ],
                        "reviewThreadId": .string("review-1"),
                    ]
                )
            case "turn/interrupt":
                await transport.respond(id: try #require(requestID), result: [:])
            case "thread/read":
                throw TestFailure("cancelled review should not refresh from thread/read")
            default:
                throw TestFailure("unexpected method \(method)")
            }
        }
        let registry = ReviewRegistry(
            configuration: .init(),
            transportFactory: { transport }
        )
        await registry.start()

        _ = try await registry.startReview(
            sessionID: "session-1",
            request: ReviewStartRequest(cwd: "/repo", target: ReviewTarget.uncommittedChanges)
        )
        _ = try await registry.cancelReview(
            reviewThreadID: "review-1",
            sessionID: "session-1"
        )

        let result = try await registry.readReview(
            reviewThreadID: "review-1",
            sessionID: "session-1"
        )

        #expect(result.status == .cancelled)
        await registry.shutdown()
    }

    @Test func registryDoesNotRecreateReviewAfterSessionClose() async throws {
        let gate = StartGate()
        let transport = ScriptedAppServerTransport { message, transport in
            let method = try #require(message.objectValue?["method"]?.stringValue)
            let requestID = message.objectValue?["id"]?.intValue
            switch method {
            case "initialize":
                await transport.respond(id: try #require(requestID), result: ["serverInfo": ["name": "codex"]])
            case "initialized":
                break
            case "thread/start":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "thread": [
                            "id": "parent-1",
                            "turns": [],
                        ],
                    ]
                )
            case "review/start":
                await gate.markStarted()
                await gate.waitForResume()
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "turn": [
                            "id": "turn-1",
                            "items": [],
                            "status": "inProgress",
                            "error": nil,
                        ],
                        "reviewThreadId": .string("review-1"),
                    ]
                )
            case "turn/interrupt":
                await transport.respond(id: try #require(requestID), result: [:])
            default:
                throw TestFailure("unexpected method \(method)")
            }
        }
        let registry = ReviewRegistry(
            configuration: .init(),
            transportFactory: { transport }
        )
        await registry.start()

        let task = Task {
            try await registry.startReview(
                sessionID: "session-1",
                request: ReviewStartRequest(cwd: "/repo", target: ReviewTarget.uncommittedChanges)
            )
        }

        try await waitUntil {
            await gate.didStart
        }
        await registry.closeSession("session-1", reason: "closed")
        await gate.resume()

        do {
            _ = try await task.value
            throw TestFailure("expected startReview to fail after session close")
        } catch {
        }

        try await waitUntil {
            await transport.sentMethods().suffix(1) == ["turn/interrupt"]
        }

        do {
            _ = try await registry.readReview(reviewThreadID: "review-1", sessionID: "session-1")
            throw TestFailure("expected closed session review to be removed")
        } catch {
        }

        await registry.shutdown()
    }

    @Test func registryKeepsActiveReviewCancelableAfterDisconnect() async throws {
        let firstTransport = ScriptedAppServerTransport { message, transport in
            let method = try #require(message.objectValue?["method"]?.stringValue)
            let requestID = message.objectValue?["id"]?.intValue
            switch method {
            case "initialize":
                await transport.respond(id: try #require(requestID), result: ["serverInfo": ["name": "codex"]])
            case "initialized":
                break
            case "thread/start":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "thread": [
                            "id": "parent-1",
                            "turns": [],
                        ],
                    ]
                )
            case "review/start":
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "turn": [
                            "id": "turn-1",
                            "items": [],
                            "status": "inProgress",
                            "error": nil,
                        ],
                        "reviewThreadId": .string("review-1"),
                    ]
                )
                await transport.finish()
            default:
                throw TestFailure("unexpected method \(method)")
            }
        }
        let secondTransport = ScriptedAppServerTransport { message, transport in
            let method = try #require(message.objectValue?["method"]?.stringValue)
            let requestID = message.objectValue?["id"]?.intValue
            switch method {
            case "initialize":
                await transport.respond(id: try #require(requestID), result: ["serverInfo": ["name": "codex"]])
            case "initialized":
                break
            case "turn/interrupt":
                await transport.respond(id: try #require(requestID), result: [:])
            default:
                throw TestFailure("unexpected method \(method)")
            }
        }
        let factory = SequentialTransportFactory(transports: [firstTransport, secondTransport])
        let registry = ReviewRegistry(
            configuration: .init(),
            transportFactory: {
                factory.nextTransport()
            }
        )
        await registry.start()

        _ = try await registry.startReview(
            sessionID: "session-1",
            request: ReviewStartRequest(cwd: "/repo", target: ReviewTarget.uncommittedChanges)
        )
        try await waitUntil {
            await firstTransport.didFinish
        }

        let cancel = try await registry.cancelReview(
            reviewThreadID: "review-1",
            sessionID: "session-1"
        )

        #expect(cancel.cancelled)
        #expect(await secondTransport.sentMethods() == ["initialize", "initialized", "turn/interrupt"])
        await registry.shutdown()
    }

    @Test func registryUnsubscribesParentThreadWhenSessionClosesDuringThreadStart() async throws {
        let gate = StartGate()
        let transport = ScriptedAppServerTransport { message, transport in
            let method = try #require(message.objectValue?["method"]?.stringValue)
            let requestID = message.objectValue?["id"]?.intValue
            switch method {
            case "initialize":
                await transport.respond(id: try #require(requestID), result: ["serverInfo": ["name": "codex"]])
            case "initialized":
                break
            case "thread/start":
                await gate.markStarted()
                await gate.waitForResume()
                await transport.respond(
                    id: try #require(requestID),
                    result: [
                        "thread": [
                            "id": "parent-1",
                            "turns": [],
                        ],
                    ]
                )
            case "thread/unsubscribe":
                await transport.respond(id: try #require(requestID), result: [:])
            default:
                throw TestFailure("unexpected method \(method)")
            }
        }
        let registry = ReviewRegistry(
            configuration: .init(),
            transportFactory: { transport }
        )
        await registry.start()

        let task = Task {
            try await registry.startReview(
                sessionID: "session-1",
                request: ReviewStartRequest(cwd: "/repo", target: ReviewTarget.uncommittedChanges)
            )
        }

        try await waitUntil {
            await gate.didStart
        }
        await registry.closeSession("session-1", reason: "closed")
        await gate.resume()

        do {
            _ = try await task.value
            throw TestFailure("expected startReview to fail after session close")
        } catch {
        }

        #expect(await transport.sentMethods() == ["initialize", "initialized", "thread/start", "thread/unsubscribe"])
        await registry.shutdown()
    }
}

private struct TestThreadResponse: Decodable {
    struct Thread: Decodable {
        var id: String
    }

    var thread: Thread
}

private final class SequentialTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [ScriptedAppServerTransport]
    private var index = 0

    init(transports: [ScriptedAppServerTransport]) {
        self.transports = transports
    }

    func nextTransport() -> any CodexAppServerTransport {
        lock.lock()
        defer { lock.unlock() }
        let transport = transports[index]
        index += 1
        return transport
    }
}

private actor ScriptedAppServerTransport: CodexAppServerTransport {
    typealias Handler = @Sendable (Value, ScriptedAppServerTransport) async throws -> Void

    private let handler: Handler
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var sentMessages: [Value] = []
    private(set) var didFinish = false

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() async throws -> AsyncThrowingStream<String, Error> {
        var continuation: AsyncThrowingStream<String, Error>.Continuation!
        let stream = AsyncThrowingStream<String, Error> { continuation = $0 }
        self.continuation = continuation
        self.didFinish = false
        return stream
    }

    func send(_ line: String) async throws {
        let value = try JSONDecoder().decode(Value.self, from: Data(line.utf8))
        sentMessages.append(value)
        try await handler(value, self)
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
        didFinish = true
    }

    func respond(id: Int, result: Value) {
        continuation?.yield(jsonLine([
            "id": .int(id),
            "result": result,
        ]))
    }

    func respondError(id: Int, code: Int, message: String) {
        continuation?.yield(jsonLine([
            "id": .int(id),
            "error": .object([
                "code": .int(code),
                "message": .string(message),
            ]),
        ]))
    }

    func notify(method: String, params: Value) {
        continuation?.yield(jsonLine([
            "method": .string(method),
            "params": params,
        ]))
    }

    func finish() {
        continuation?.finish()
        continuation = nil
        didFinish = true
    }

    func sentMethods() -> [String] {
        sentMessages.compactMap { $0.objectValue?["method"]?.stringValue }
    }

    func sentReviewStartCount() -> Int {
        sentMethods().filter { $0 == "review/start" }.count
    }
}

private actor StartGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var didStart = false

    func markStarted() {
        didStart = true
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

private func jsonLine(_ value: Value) -> String {
    let data = try! JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
}

private struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
