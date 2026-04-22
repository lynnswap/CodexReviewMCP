import Foundation
import Testing
@testable import ReviewCore
@testable import ReviewJobs

@Suite
struct AppServerV2ContractFenceTests {
    @Test func appServerThreadStartParamsEncodeCurrentWireKeys() throws {
        let payload = AppServerThreadStartParams(
            model: "gpt-5.4",
            cwd: "/tmp/repo",
            approvalPolicy: "never",
            sandbox: "workspaceWrite",
            config: [
                "model_reasoning_effort": .string("high"),
            ],
            personality: "pragmatic",
            ephemeral: false
        )

        let object = try encodedObject(payload)
        let config = try #require(object["config"] as? [String: Any])

        #expect(object["model"] as? String == "gpt-5.4")
        #expect(object["cwd"] as? String == "/tmp/repo")
        #expect(object["approvalPolicy"] as? String == "never")
        #expect(object["sandbox"] as? String == "workspaceWrite")
        #expect(config["model_reasoning_effort"] as? String == "high")
        #expect(object["personality"] as? String == "pragmatic")
        #expect(object["ephemeral"] as? Bool == false)
    }

    @Test func appServerReviewStartParamsEncodeCurrentWireKeys() throws {
        let payload = AppServerReviewStartParams(
            threadID: "thr_123",
            target: .commit(sha: "abc1234", title: "Polish tui colors"),
            delivery: "inline"
        )

        let object = try encodedObject(payload)
        let target = try #require(object["target"] as? [String: Any])

        #expect(object["threadId"] as? String == "thr_123")
        #expect(object["delivery"] as? String == "inline")
        #expect(target["type"] as? String == "commit")
        #expect(target["sha"] as? String == "abc1234")
        #expect(target["title"] as? String == "Polish tui colors")
    }

    @Test func appServerReviewStartResponseDecodesReviewThreadID() throws {
        let data = Data(
            """
            {
              "turn": {
                "id": "turn_900",
                "status": "inProgress",
                "error": null
              },
              "reviewThreadId": "thr_review"
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(AppServerReviewStartResponse.self, from: data)

        #expect(response.turn.id == "turn_900")
        #expect(response.turn.status == .inProgress)
        #expect(response.reviewThreadID == "thr_review")
    }

    @Test func appServerAccountNotificationsDecodeCurrentWireKeys() throws {
        let loginCompleted = try JSONDecoder().decode(
            AppServerAccountLoginCompletedNotification.self,
            from: Data(
                """
                {
                  "error": null,
                  "loginId": "login_123",
                  "success": true
                }
                """.utf8
            )
        )
        let accountUpdated = try JSONDecoder().decode(
            AppServerAccountUpdatedNotification.self,
            from: Data(
                """
                {
                  "authMode": "chatgpt",
                  "planType": "pro"
                }
                """.utf8
            )
        )

        #expect(loginCompleted.loginID == "login_123")
        #expect(loginCompleted.success == true)
        #expect(accountUpdated.authMode == .chatGPT)
        #expect(accountUpdated.planType == "pro")
    }
}

private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw EncodingError.invalidValue(
            value,
            .init(codingPath: [], debugDescription: "Encoded payload was not a JSON object.")
        )
    }
    return object
}
