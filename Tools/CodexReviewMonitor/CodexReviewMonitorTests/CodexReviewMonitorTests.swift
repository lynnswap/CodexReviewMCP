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
        let recorder = WindowControllerFactoryRecorder()
        let delegate = CodexReviewMonitorAppDelegate(
            launchModeProvider: { .application },
            windowControllerFactory: { _ in
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

    @Test func appDelegateCreatesWindowControllerOnXCTestLaunch() {
        let recorder = WindowControllerFactoryRecorder()
        let delegate = CodexReviewMonitorAppDelegate(
            launchModeProvider: { .xctest },
            windowControllerFactory: { _ in
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

    @Test func appDelegateSkipsWindowControllerCreationOnPreviewLaunch() {
        let recorder = WindowControllerFactoryRecorder()
        let delegate = CodexReviewMonitorAppDelegate(
            launchModeProvider: { .preview },
            windowControllerFactory: { _ in
                recorder.makeWindowController()
            }
        )

        delegate.applicationDidFinishLaunching(Notification(name: .init("test-launch")))

        #expect(recorder.makeCallCount == 0)
    }

    @Test func appDelegateReusesSingleWindowControllerWhenReopening() {
        let recorder = WindowControllerFactoryRecorder()
        let delegate = CodexReviewMonitorAppDelegate(
            launchModeProvider: { .application },
            windowControllerFactory: { _ in
                recorder.makeWindowController()
            }
        )

        delegate.applicationDidFinishLaunching(Notification(name: .init("test-launch")))
        let initialWindowController = recorder.lastWindowController

        let handled = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)

        #expect(handled)
        #expect(recorder.makeCallCount == 1)
        #expect(delegate.windowController === initialWindowController)
        #expect(initialWindowController?.showWindowCallCount == 2)
        #expect(initialWindowController?.windowForTesting.makeKeyAndOrderFrontCallCount == 2)
    }

    @Test func appDelegateSkipsReopenWhenWindowIsAlreadyVisible() {
        let recorder = WindowControllerFactoryRecorder()
        let delegate = CodexReviewMonitorAppDelegate(
            launchModeProvider: { .application },
            windowControllerFactory: { _ in
                recorder.makeWindowController()
            }
        )

        delegate.applicationDidFinishLaunching(Notification(name: .init("test-launch")))
        let initialWindowController = recorder.lastWindowController

        let handled = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)

        #expect(handled == false)
        #expect(recorder.makeCallCount == 1)
        #expect(delegate.windowController === initialWindowController)
        #expect(initialWindowController?.showWindowCallCount == 1)
    }

    @Test func appDelegateSkipsReopenOutsideApplicationLaunchMode() {
        let recorder = WindowControllerFactoryRecorder()
        let delegate = CodexReviewMonitorAppDelegate(
            launchModeProvider: { .preview },
            windowControllerFactory: { _ in
                recorder.makeWindowController()
            }
        )

        let handled = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)

        #expect(handled == false)
        #expect(recorder.makeCallCount == 0)
    }
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
