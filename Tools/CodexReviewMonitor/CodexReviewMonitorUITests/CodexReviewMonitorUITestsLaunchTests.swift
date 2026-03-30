//
//  CodexReviewMonitorUITestsLaunchTests.swift
//  CodexReviewMonitorUITests
//
//  Created by Kazuki Nakashima on 2026/03/28.
//

import XCTest

final class CodexReviewMonitorUITestsLaunchTests: XCTestCase {
    private func skipUnlessUITestsEnabled() throws {
        if ProcessInfo.processInfo.environment["CODEX_REVIEW_MONITOR_RUN_UI_TESTS"] != "1" {
            throw XCTSkip("UI launch smoke is opt-in. Set CODEX_REVIEW_MONITOR_RUN_UI_TESTS=1 to run it.")
        }
    }

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        try skipUnlessUITestsEnabled()
        let app = XCUIApplication()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
