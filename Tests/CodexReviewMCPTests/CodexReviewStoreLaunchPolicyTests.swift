import Foundation
import Testing
@testable import CodexReviewMCP

@Suite(.serialized)
struct CodexReviewStoreLaunchPolicyTests {
    @Test func plainXCTestLaunchDisablesEmbeddedServerAutoStart() {
        let environment = [
            CodexReviewStoreLaunchPolicy.xctestConfigurationKey: "/tmp/test.xctestconfiguration",
        ]

        #expect(
            CodexReviewStoreLaunchPolicy.shouldAutoStartEmbeddedServer(
                environment: environment,
                arguments: []
            ) == false
        )
    }

    @Test func explicitTestOverrideKeepsEmbeddedServerAutoStartEnabled() {
        let environment = [
            CodexReviewStoreLaunchPolicy.xctestConfigurationKey: "/tmp/test.xctestconfiguration",
            CodexReviewStoreTestEnvironment.portKey: "9417",
        ]

        #expect(
            CodexReviewStoreLaunchPolicy.shouldAutoStartEmbeddedServer(
                environment: environment,
                arguments: []
            )
        )
    }

    @Test func previewLaunchDisablesEmbeddedServerAutoStart() {
        let environment = [
            CodexReviewStoreLaunchPolicy.xcodeRunningForPreviewsKey: "YES",
        ]

        #expect(
            CodexReviewStoreLaunchPolicy.shouldAutoStartEmbeddedServer(
                environment: environment,
                arguments: []
            ) == false
        )
    }

    @Test func uiTestLaunchDisablesEmbeddedServerAutoStart() {
        let environment = [
            CodexReviewStoreTestEnvironment.uiTestModeKey: "1",
        ]

        #expect(
            CodexReviewStoreLaunchPolicy.shouldAutoStartEmbeddedServer(
                environment: environment,
                arguments: []
            ) == false
        )
    }

    @Test func hostedUnitTestLaunchDisablesEmbeddedServerAutoStart() {
        let environment = [
            CodexReviewStoreLaunchPolicy.xcInjectBundleIntoKey: "/tmp/CodexReviewMonitor",
            CodexReviewStoreLaunchPolicy.xctestBundlePathKey: "/tmp/CodexReviewMonitorTests.xctest",
            CodexReviewStoreLaunchPolicy.xctestSessionIdentifierKey: "session-123",
        ]

        #expect(
            CodexReviewStoreLaunchPolicy.shouldAutoStartEmbeddedServer(
                environment: environment,
                arguments: []
            ) == false
        )
    }
}
