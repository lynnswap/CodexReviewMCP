//
//  CodexReviewMonitorApp.swift
//  CodexReviewMonitor
//
//  Created by Kazuki Nakashima on 2026/03/28.
//

import AppKit
import SwiftUI
import CodexReviewMCP

private enum CodexReviewMonitorLaunchEnvironment {
    static let xctestConfigurationKey = "XCTestConfigurationFilePath"
    static let testPortKey = "CODEX_REVIEW_MONITOR_TEST_PORT"
    static let testCodexCommandKey = "CODEX_REVIEW_MONITOR_TEST_CODEX_COMMAND"
    static let testDiagnosticsPathKey = "CODEX_REVIEW_MONITOR_TEST_DIAGNOSTICS_PATH"
    static let testPortArgument = "--codex-review-monitor-test-port"
    static let testCodexCommandArgument = "--codex-review-monitor-test-codex-command"
    static let testDiagnosticsPathArgument = "--codex-review-monitor-test-diagnostics-path"
}

final class CodexReviewMonitorAppDelegate: NSObject, NSApplicationDelegate {
    private var shouldManageEmbeddedServer = true

    lazy var store = CodexReviewStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        shouldManageEmbeddedServer = shouldStartEmbeddedServer()
        guard shouldManageEmbeddedServer else {
            return
        }
        Task {
            await store.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        guard shouldManageEmbeddedServer else {
            return
        }
        Task {
            await store.stop()
        }
    }

    private func shouldStartEmbeddedServer() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let arguments = CommandLine.arguments
        let hasExplicitTestOverride = environment[CodexReviewMonitorLaunchEnvironment.testPortKey] != nil
            || environment[CodexReviewMonitorLaunchEnvironment.testCodexCommandKey] != nil
            || environment[CodexReviewMonitorLaunchEnvironment.testDiagnosticsPathKey] != nil
            || arguments.contains(CodexReviewMonitorLaunchEnvironment.testPortArgument)
            || arguments.contains(CodexReviewMonitorLaunchEnvironment.testCodexCommandArgument)
            || arguments.contains(CodexReviewMonitorLaunchEnvironment.testDiagnosticsPathArgument)
        if hasExplicitTestOverride {
            return true
        }
        return environment[CodexReviewMonitorLaunchEnvironment.xctestConfigurationKey] == nil
    }
}

@main
struct CodexReviewMonitorApp: App {
    @NSApplicationDelegateAdaptor(CodexReviewMonitorAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(store: appDelegate.store)
        }
    }
}
