//
//  CodexReviewUITests.swift
//  CodexReviewUITests
//
//  Created by Kazuki Nakashima on 2026/03/28.
//

import XCTest
import Foundation

final class CodexReviewUITests: XCTestCase {
    private func skipUnlessUITestsEnabled() throws {
        if ProcessInfo.processInfo.environment["CODEX_REVIEW_MONITOR_RUN_UI_TESTS"] != "1" {
            throw XCTSkip("UI smoke tests are opt-in. Set CODEX_REVIEW_MONITOR_RUN_UI_TESTS=1 to run them.")
        }
    }

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchDisplaysEmptyReviewState() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["review-monitor.sidebar-empty.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["review-monitor.detail-empty.title"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLaunchPerformance() throws {
        try skipUnlessUITestsEnabled()
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launch()
        }
    }

}
