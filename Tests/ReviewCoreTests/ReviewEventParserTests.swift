import Foundation
import Testing
@testable import ReviewAppServerAdapter
@testable import ReviewPlatform
@testable import ReviewMCPAdapter


@Suite
struct AppServerProtocolTests {
    @Test func appServerJSONLFramerSplitsCompleteMessages() {
        var framer = AppServerJSONLFramer()

        let firstMessages = framer.append(Data("{\"id\":1}\n{\"id\":".utf8))
        let secondMessages = framer.append(Data("2}\n".utf8))

        #expect(firstMessages.count == 1)
        #expect(String(decoding: firstMessages[0], as: UTF8.self) == "{\"id\":1}")
        #expect(secondMessages.count == 1)
        #expect(String(decoding: secondMessages[0], as: UTF8.self) == "{\"id\":2}")
    }

    @Test func appServerJSONLFramerFlushesRemainingMessageOnFinish() {
        var framer = AppServerJSONLFramer()
        _ = framer.append(Data("{\"method\":\"initialized\"}".utf8))

        let flushed = framer.finish()
        #expect(flushed.count == 1)
        #expect(String(decoding: flushed[0], as: UTF8.self) == "{\"method\":\"initialized\"}")
    }

    @Test func appServerRequestIDParsesSupportedJSONShapes() {
        #expect(AppServerRequestID(jsonObject: "1") == .string("1"))
        #expect(AppServerRequestID(jsonObject: 7) == .integer(7))
        #expect(AppServerRequestID(jsonObject: NSNumber(value: 11)) == .integer(11))
        #expect(AppServerRequestID(jsonObject: NSNumber(value: 3.5)) == .double(3.5))
    }

    @Test func appServerConfigReadResponseIgnoresCodexOwnedContextLimitFields() throws {
        let data = Data("""
        {
          "config": {
            "model": "gpt-5.4",
            "model_context_window": "120_000",
            "model_auto_compact_token_limit": "110_000"
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(AppServerConfigReadResponse.self, from: data)

        #expect(response.config.model == "gpt-5.4")
    }

    @Test func appServerThreadItemDecodesPlanReasoningAndToolItems() throws {
        let plan = try JSONDecoder().decode(
            AppServerThreadItem.self,
            from: Data(#"{"type":"plan","id":"plan_1","text":"- step 1\n- step 2"}"#.utf8)
        )
        let reasoning = try JSONDecoder().decode(
            AppServerThreadItem.self,
            from: Data(#"{"type":"reasoning","id":"rsn_1","summary":["first"],"content":["raw"]}"#.utf8)
        )
        let toolCall = try JSONDecoder().decode(
            AppServerThreadItem.self,
            from: Data(#"{"type":"mcpToolCall","id":"tool_1","server":"github","tool":"search","status":"completed","result":{"ok":true}}"#.utf8)
        )
        let contextCompaction = try JSONDecoder().decode(
            AppServerThreadItem.self,
            from: Data(#"{"type":"contextCompaction","id":"ctx_1"}"#.utf8)
        )
        let nullToolCall = try JSONDecoder().decode(
            AppServerThreadItem.self,
            from: Data(#"{"type":"mcpToolCall","id":"tool_2","server":"github","tool":"search","status":"completed","result":null,"error":null}"#.utf8)
        )
        let floatingPointToolCall = try JSONDecoder().decode(
            AppServerThreadItem.self,
            from: Data(#"{"type":"mcpToolCall","id":"tool_3","server":"github","tool":"search","status":"completed","result":0.5}"#.utf8)
        )

        #expect(plan == .plan(id: "plan_1", text: "- step 1\n- step 2"))
        #expect(reasoning == .reasoning(id: "rsn_1", summary: ["first"], content: ["raw"]))
        #expect(toolCall == .mcpToolCall(id: "tool_1", server: "github", tool: "search", status: "completed", error: nil, result: #"{"ok":true}"#))
        #expect(contextCompaction == .contextCompaction(id: "ctx_1"))
        #expect(nullToolCall == .mcpToolCall(id: "tool_2", server: "github", tool: "search", status: "completed", error: nil, result: nil))
        #expect(floatingPointToolCall == .mcpToolCall(id: "tool_3", server: "github", tool: "search", status: "completed", error: nil, result: "0.5"))
    }

    @Test func appServerDeltaNotificationsDecode() throws {
        let planDelta = try JSONDecoder().decode(
            TestNotificationEnvelope<AppServerPlanDeltaNotification>.self,
            from: Data(#"{"method":"item/plan/delta","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"plan_1","delta":"- first\n"}}"#.utf8)
        )
        let reasoningSummary = try JSONDecoder().decode(
            TestNotificationEnvelope<AppServerReasoningSummaryTextDeltaNotification>.self,
            from: Data(#"{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"rsn_1","delta":"thinking","summaryIndex":0}}"#.utf8)
        )
        let reasoningBreak = try JSONDecoder().decode(
            TestNotificationEnvelope<AppServerReasoningSummaryPartAddedNotification>.self,
            from: Data(#"{"method":"item/reasoning/summaryPartAdded","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"rsn_1","summaryIndex":1}}"#.utf8)
        )
        let rawReasoning = try JSONDecoder().decode(
            TestNotificationEnvelope<AppServerReasoningTextDeltaNotification>.self,
            from: Data(#"{"method":"item/reasoning/textDelta","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"rsn_1","delta":"raw","contentIndex":0}}"#.utf8)
        )
        let toolProgress = try JSONDecoder().decode(
            TestNotificationEnvelope<AppServerMcpToolCallProgressNotification>.self,
            from: Data(#"{"method":"item/mcpToolCall/progress","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"tool_1","message":"Fetching schema"}}"#.utf8)
        )

        #expect(planDelta.params.delta == "- first\n")
        #expect(reasoningSummary.params.delta == "thinking")
        #expect(reasoningBreak.params.summaryIndex == 1)
        #expect(rawReasoning.params.delta == "raw")
        #expect(toolProgress.params.message == "Fetching schema")
    }
}

private struct TestNotificationEnvelope<Params: Decodable>: Decodable {
    var method: String
    var params: Params
}
