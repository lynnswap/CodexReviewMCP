//
//  CodexReviewMonitorApp.swift
//  CodexReviewMonitor
//
//  Created by Kazuki Nakashima on 2026/03/28.
//

import AppKit
import SwiftUI
import CodexReviewMCP

enum CodexReviewMonitorLaunchMode {
    case application
    case xctest
    case preview
}

enum CodexReviewMonitorLaunchEnvironment {
    static let xctestConfigurationKey = "XCTestConfigurationFilePath"
    static let xcodeRunningForPlaygroundsKey = "XCODE_RUNNING_FOR_PLAYGROUNDS"
    static let xcodeRunningForPreviewsKey = "XCODE_RUNNING_FOR_PREVIEWS"
    static let testPortKey = "CODEX_REVIEW_MONITOR_TEST_PORT"
    static let testCodexCommandKey = "CODEX_REVIEW_MONITOR_TEST_CODEX_COMMAND"
    static let testDiagnosticsPathKey = "CODEX_REVIEW_MONITOR_TEST_DIAGNOSTICS_PATH"
    static let testPortArgument = "--codex-review-monitor-test-port"
    static let testCodexCommandArgument = "--codex-review-monitor-test-codex-command"
    static let testDiagnosticsPathArgument = "--codex-review-monitor-test-diagnostics-path"

    static func launchMode(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> CodexReviewMonitorLaunchMode {
        if isRunningInPreviews(environment: environment) {
            return .preview
        }
        if hasExplicitTestOverride(environment: environment, arguments: arguments) {
            return .application
        }
        if let xctestConfiguration = environment[xctestConfigurationKey],
           xctestConfiguration.isEmpty == false {
            return .xctest
        }
        return .application
    }

    static func shouldStartEmbeddedServer(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        launchMode(environment: environment, arguments: arguments) == .application
    }

    private static func isRunningInPreviews(environment: [String: String]) -> Bool {
        isEnabledFlag(environment[xcodeRunningForPreviewsKey])
            || isEnabledFlag(environment[xcodeRunningForPlaygroundsKey])
    }

    private static func hasExplicitTestOverride(
        environment: [String: String],
        arguments: [String]
    ) -> Bool {
        environment[testPortKey] != nil
            || environment[testCodexCommandKey] != nil
            || environment[testDiagnosticsPathKey] != nil
            || arguments.contains(testPortArgument)
            || arguments.contains(testCodexCommandArgument)
            || arguments.contains(testDiagnosticsPathArgument)
    }

    private static func isEnabledFlag(_ value: String?) -> Bool {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes":
            true
        default:
            false
        }
    }
}

@MainActor
protocol CodexReviewMonitorLifecycleStore: AnyObject {
    func start(forceRestartIfNeeded: Bool) async
    func stop() async
}

extension CodexReviewStore: CodexReviewMonitorLifecycleStore {}

@MainActor
protocol CodexReviewMonitorTerminationReplying: AnyObject {
    func replyToApplicationShouldTerminate(_ shouldTerminate: Bool)
}

extension NSApplication: CodexReviewMonitorTerminationReplying {
    func replyToApplicationShouldTerminate(_ shouldTerminate: Bool) {
        reply(toApplicationShouldTerminate: shouldTerminate)
    }
}

@MainActor
final class CodexReviewMonitorLifecycleController {
    private let store: any CodexReviewMonitorLifecycleStore
    private var shouldManageEmbeddedServer = true
    private var terminationTask: Task<Void, Never>?

    init(store: any CodexReviewMonitorLifecycleStore) {
        self.store = store
    }

    func applicationDidFinishLaunching(launchMode: CodexReviewMonitorLaunchMode) {
        shouldManageEmbeddedServer = launchMode == .application
        guard shouldManageEmbeddedServer else {
            return
        }
        Task { @MainActor in
            await store.start(forceRestartIfNeeded: true)
        }
    }

    func applicationShouldTerminate(
        replyingTo application: any CodexReviewMonitorTerminationReplying
    ) -> NSApplication.TerminateReply {
        guard shouldManageEmbeddedServer else {
            return .terminateNow
        }
        guard terminationTask == nil else {
            return .terminateLater
        }
        terminationTask = Task { @MainActor in
            await store.stop()
            terminationTask = nil
            application.replyToApplicationShouldTerminate(true)
        }
        return .terminateLater
    }
}

@MainActor
final class CodexReviewMonitorAppDelegate: NSObject, NSApplicationDelegate {
    lazy var store = CodexReviewStore()
    lazy var lifecycle = CodexReviewMonitorLifecycleController(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        lifecycle.applicationDidFinishLaunching(
            launchMode: CodexReviewMonitorLaunchEnvironment.launchMode()
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        lifecycle.applicationShouldTerminate(replyingTo: sender)
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
