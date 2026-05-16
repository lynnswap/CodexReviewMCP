import AppKit
import Foundation
import Testing
import ReviewTestSupport
@testable import CodexReviewMonitor

@Suite(.serialized)
@MainActor
struct CodexReviewMonitorTests {
    @Test func launchModeTreatsPreviewEnvironmentAsPreview() {
        let environment = [
            CodexReviewMonitorLaunchEnvironment.xcodeRunningForPlaygroundsKey: "1",
        ]

        #expect(
            CodexReviewMonitorLaunchEnvironment.launchMode(
                environment: environment,
                arguments: []
            ) == .preview
        )
        #expect(
            CodexReviewMonitorLaunchEnvironment.shouldStartEmbeddedServer(
                environment: environment,
                arguments: []
            ) == false
        )
    }

    @Test func launchModeTreatsXcodePreviewFlagAsPreview() {
        let environment = [
            CodexReviewMonitorLaunchEnvironment.xcodeRunningForPreviewsKey: "YES",
        ]

        #expect(
            CodexReviewMonitorLaunchEnvironment.launchMode(
                environment: environment,
                arguments: []
            ) == .preview
        )
    }

    @Test func mockJobsStoreTreatsEnvironmentFlagAsEnabled() {
        let environment = [
            CodexReviewMonitorLaunchEnvironment.mockJobsKey: "1",
        ]

        #expect(
            CodexReviewMonitorLaunchEnvironment.shouldUseMockJobsStore(
                environment: environment,
                arguments: []
            )
        )
        #expect(
            CodexReviewMonitorLaunchEnvironment.storeMode(
                environment: environment,
                arguments: []
            ) == .mockJobs
        )
        #expect(
            CodexReviewMonitorLaunchEnvironment.shouldStartEmbeddedServer(
                environment: environment,
                arguments: []
            ) == false
        )
    }

    @Test func mockJobsStoreTreatsArgumentFlagAsEnabled() {
        #expect(
            CodexReviewMonitorLaunchEnvironment.shouldUseMockJobsStore(
                environment: [:],
                arguments: [CodexReviewMonitorLaunchEnvironment.mockJobsArgument]
            )
        )
        #expect(
            CodexReviewMonitorLaunchEnvironment.storeMode(
                environment: [:],
                arguments: [CodexReviewMonitorLaunchEnvironment.mockJobsArgument]
            ) == .mockJobs
        )
    }

    @Test func launchModeTreatsPlainXCTestLaunchAsTest() {
        let environment = [
            CodexReviewMonitorLaunchEnvironment.xctestConfigurationKey: "/tmp/test.xctestconfiguration",
        ]

        #expect(
            CodexReviewMonitorLaunchEnvironment.launchMode(
                environment: environment,
                arguments: []
            ) == .xctest
        )
        #expect(
            CodexReviewMonitorLaunchEnvironment.shouldStartEmbeddedServer(
                environment: environment,
                arguments: []
            ) == false
        )
    }

    @Test func launchModeTreatsHostedUnitTestEnvironmentAsTest() {
        let environment = [
            CodexReviewMonitorLaunchEnvironment.xcInjectBundleIntoKey: "/tmp/CodexReviewMonitor",
            CodexReviewMonitorLaunchEnvironment.xctestBundlePathKey: "/tmp/CodexReviewMonitorTests.xctest",
            CodexReviewMonitorLaunchEnvironment.xctestSessionIdentifierKey: "session-123",
        ]

        #expect(
            CodexReviewMonitorLaunchEnvironment.launchMode(
                environment: environment,
                arguments: []
            ) == .xctest
        )
        #expect(
            CodexReviewMonitorLaunchEnvironment.shouldStartEmbeddedServer(
                environment: environment,
                arguments: []
            ) == false
        )
    }

    @Test func hostedUnitTestRuntimeDisablesEmbeddedServer() {
        #expect(CodexReviewMonitorLaunchEnvironment.isRunningUnderXCTest())
        #expect(CodexReviewMonitorLaunchEnvironment.launchMode() == .xctest)
        #expect(CodexReviewMonitorLaunchEnvironment.shouldStartEmbeddedServer() == false)
    }

    @Test func launchModeTreatsUITestOverrideAsTestAndDisablesEmbeddedServer() {
        let environment = [
            CodexReviewMonitorLaunchEnvironment.uiTestModeKey: "1",
        ]

        #expect(
            CodexReviewMonitorLaunchEnvironment.launchMode(
                environment: environment,
                arguments: []
            ) == .xctest
        )
        #expect(
            CodexReviewMonitorLaunchEnvironment.shouldStartEmbeddedServer(
                environment: environment,
                arguments: []
            ) == false
        )
        #expect(
            CodexReviewMonitorLaunchEnvironment.shouldUseUITestStore(
                environment: environment
            )
        )
    }

    @Test func storeModePrefersUITestOverMockJobs() {
        let environment = [
            CodexReviewMonitorLaunchEnvironment.uiTestModeKey: "1",
            CodexReviewMonitorLaunchEnvironment.mockJobsKey: "1",
        ]

        #expect(
            CodexReviewMonitorLaunchEnvironment.shouldUseMockJobsStore(
                environment: environment,
                arguments: [CodexReviewMonitorLaunchEnvironment.mockJobsArgument]
            ) == false
        )
        #expect(
            CodexReviewMonitorLaunchEnvironment.storeMode(
                environment: environment,
                arguments: [CodexReviewMonitorLaunchEnvironment.mockJobsArgument]
            ) == .uiTest
        )
    }

    @Test func launchModeKeepsExplicitTestOverrideLaunchable() {
        let environment = [
            CodexReviewMonitorLaunchEnvironment.xctestConfigurationKey: "/tmp/test.xctestconfiguration",
            CodexReviewMonitorLaunchEnvironment.testPortKey: "9417",
        ]

        #expect(
            CodexReviewMonitorLaunchEnvironment.launchMode(
                environment: environment,
                arguments: []
            ) == .application
        )
        #expect(
            CodexReviewMonitorLaunchEnvironment.shouldStartEmbeddedServer(
                environment: environment,
                arguments: []
            )
        )
    }

    @Test func launchModeTreatsNormalLaunchAsApplication() {
        #expect(
            CodexReviewMonitorLaunchEnvironment.launchMode(
                environment: [:],
                arguments: []
            ) == .application
        )
        #expect(
            CodexReviewMonitorLaunchEnvironment.shouldStartEmbeddedServer(
                environment: [:],
                arguments: []
            )
        )
    }

    @Test func lifecycleStartsStoreOnApplicationLaunch() async {
        let store = FakeLifecycleStore()
        let lifecycle = CodexReviewMonitorLifecycleController(store: store)

        lifecycle.applicationDidFinishLaunching(launchMode: .application)

        await store.startSignal.wait()
        #expect(store.startArguments == [true])
        #expect(store.stopCallCount == 0)
    }

    @Test func lifecycleSkipsStoreStartWhenEmbeddedServerManagementIsDisabled() {
        let store = FakeLifecycleStore()
        let lifecycle = CodexReviewMonitorLifecycleController(
            store: store,
            shouldManageEmbeddedServer: false
        )

        lifecycle.applicationDidFinishLaunching(launchMode: .application)

        #expect(store.startArguments.isEmpty)
        #expect(store.stopCallCount == 0)
    }

    @Test func lifecycleSkipsStoreStartForNonApplicationLaunchModes() {
        for launchMode in [CodexReviewMonitorLaunchMode.xctest, .preview] {
            let store = FakeLifecycleStore()
            let lifecycle = CodexReviewMonitorLifecycleController(store: store)

            lifecycle.applicationDidFinishLaunching(launchMode: launchMode)

            #expect(store.startArguments.isEmpty)
            #expect(store.stopCallCount == 0)
        }
    }

    @Test func lifecycleTerminatesImmediatelyWhenEmbeddedServerIsNotManaged() {
        let store = FakeLifecycleStore()
        let lifecycle = CodexReviewMonitorLifecycleController(store: store)
        let responder = TerminationReplyRecorder()

        lifecycle.applicationDidFinishLaunching(launchMode: .xctest)
        let reply = lifecycle.applicationShouldTerminate(replyingTo: responder)

        #expect(reply == .terminateNow)
        #expect(store.stopCallCount == 0)
        #expect(responder.replies.isEmpty)
    }

    @Test func lifecycleWaitsForStopBeforeReplyingAndDoesNotStartSecondStop() async {
        let store = FakeLifecycleStore()
        let lifecycle = CodexReviewMonitorLifecycleController(store: store)
        let responder = TerminationReplyRecorder()

        lifecycle.applicationDidFinishLaunching(launchMode: .application)
        await store.startSignal.wait()

        let firstReply = lifecycle.applicationShouldTerminate(replyingTo: responder)
        #expect(firstReply == .terminateLater)

        await store.stopStartedSignal.wait()
        #expect(store.stopCallCount == 1)
        #expect(responder.replies.isEmpty)

        let secondReply = lifecycle.applicationShouldTerminate(replyingTo: responder)
        #expect(secondReply == .terminateLater)
        #expect(store.stopCallCount == 1)

        await store.stopGate.open()
        let shouldTerminate = await responder.waitForReply()

        #expect(shouldTerminate == true)
        #expect(responder.replies == [true])
    }

    @Test func appDelegateCreatesSingleWindowControllerOnApplicationLaunch() {
        let previousMainMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMainMenu }
        let recorder = WindowControllerFactoryRecorder()
        let delegate = CodexReviewMonitorAppDelegate(
            launchModeProvider: { .application },
            windowControllerFactory: { _, _ in
                recorder.makeWindowController()
            }
        )

        delegate.applicationDidFinishLaunching(Notification(name: .init("test-launch")))

        let windowController = recorder.lastWindowController
        #expect(recorder.makeCallCount == 1)
        #expect(delegate.windowController === windowController)
        #expect(windowController?.showWindowCallCount == 1)
        #expect(windowController?.windowForTesting.makeKeyAndOrderFrontCallCount == 1)
    }

    @Test func appDelegateInstallsTextFinderMenuItems() {
        let previousMainMenu = NSApp.mainMenu
        let previousServicesMenu = NSApp.servicesMenu
        let previousWindowsMenu = NSApp.windowsMenu
        defer {
            NSApp.mainMenu = previousMainMenu
            NSApp.servicesMenu = previousServicesMenu
            NSApp.windowsMenu = previousWindowsMenu
        }
        let recorder = WindowControllerFactoryRecorder()
        let delegate = CodexReviewMonitorAppDelegate(
            launchModeProvider: { .xctest },
            windowControllerFactory: { _, _ in
                recorder.makeWindowController()
            }
        )

        delegate.applicationDidFinishLaunching(Notification(name: .init("test-launch")))

        guard let editMenu = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { $0.title == "Edit" }),
              let findMenu = editMenu.item(withTitle: "Find")?.submenu
        else {
            Issue.record("Expected the app delegate to install Edit > Find.")
            return
        }
        expectTextFinderMenuItem(
            findMenu.item(withTitle: "Find..."),
            action: .showFindInterface,
            keyEquivalent: "f",
            modifierMask: [.command]
        )
        expectTextFinderMenuItem(
            findMenu.item(withTitle: "Find Next"),
            action: .nextMatch,
            keyEquivalent: "g",
            modifierMask: [.command]
        )
        expectTextFinderMenuItem(
            findMenu.item(withTitle: "Find Previous"),
            action: .previousMatch,
            keyEquivalent: "g",
            modifierMask: [.command, .shift]
        )
    }

    @Test func appDelegateCreatesWindowControllerOnXCTestLaunch() {
        let recorder = WindowControllerFactoryRecorder()
        let delegate = CodexReviewMonitorAppDelegate(
            launchModeProvider: { .xctest },
            windowControllerFactory: { _, _ in
                recorder.makeWindowController()
            }
        )

        delegate.applicationDidFinishLaunching(Notification(name: .init("test-launch")))

        let windowController = recorder.lastWindowController
        #expect(recorder.makeCallCount == 1)
        #expect(delegate.windowController === windowController)
        #expect(windowController?.showWindowCallCount == 1)
        #expect(windowController?.windowForTesting.makeKeyAndOrderFrontCallCount == 1)
    }

    @Test func appDelegateSkipsReopenWhenWindowIsAlreadyVisible() {
        let recorder = WindowControllerFactoryRecorder()
        let delegate = CodexReviewMonitorAppDelegate(
            launchModeProvider: { .application },
            windowControllerFactory: { _, _ in
                recorder.makeWindowController()
            }
        )

        delegate.applicationDidFinishLaunching(Notification(name: .init("test-launch")))

        let handled = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)

        #expect(handled == false)
    }

}

@MainActor
private func expectTextFinderMenuItem(
    _ item: NSMenuItem?,
    action: NSTextFinder.Action,
    keyEquivalent: String,
    modifierMask: NSEvent.ModifierFlags
) {
    guard let item else {
        Issue.record("Expected text finder menu item.")
        return
    }
    #expect(item.action == #selector(NSResponder.performTextFinderAction(_:)))
    #expect(item.tag == action.rawValue)
    #expect(item.keyEquivalent == keyEquivalent)
    #expect(item.keyEquivalentModifierMask == modifierMask)
}

@MainActor
private final class FakeLifecycleStore: CodexReviewMonitorLifecycleStore {
    private(set) var startArguments: [Bool] = []
    private(set) var stopCallCount = 0
    let startSignal = AsyncSignal()
    let stopStartedSignal = AsyncSignal()
    let stopGate = OneShotGate()

    func start(forceRestartIfNeeded: Bool) async {
        startArguments.append(forceRestartIfNeeded)
        await startSignal.signal()
    }

    func stop() async {
        stopCallCount += 1
        await stopStartedSignal.signal()
        await stopGate.wait()
    }
}

@MainActor
private final class TerminationReplyRecorder: CodexReviewMonitorTerminationReplying {
    private let repliesQueue = AsyncValueQueue<Bool>()
    private(set) var replies: [Bool] = []

    func replyToApplicationShouldTerminate(_ shouldTerminate: Bool) {
        replies.append(shouldTerminate)
        Task {
            await repliesQueue.push(shouldTerminate)
        }
    }

    func waitForReply() async -> Bool? {
        await repliesQueue.next()
    }
}

@MainActor
private final class WindowControllerFactoryRecorder {
    private(set) var makeCallCount = 0
    private(set) var lastWindowController: CountingWindowController?

    func makeWindowController() -> CountingWindowController {
        makeCallCount += 1
        let windowController = CountingWindowController()
        lastWindowController = windowController
        return windowController
    }
}

@MainActor
private final class CountingWindowController: NSWindowController {
    private(set) var showWindowCallCount = 0

    var windowForTesting: CountingWindow {
        guard let window = window as? CountingWindow else {
            fatalError("Expected CountingWindow.")
        }
        return window
    }

    init() {
        super.init(
            window: CountingWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        _ = sender
        showWindowCallCount += 1
    }
}

@MainActor
private final class CountingWindow: NSWindow {
    private(set) var makeKeyAndOrderFrontCallCount = 0

    override func makeKeyAndOrderFront(_ sender: Any?) {
        _ = sender
        makeKeyAndOrderFrontCallCount += 1
    }
}
