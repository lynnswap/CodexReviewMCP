//
//  CodexReviewMonitorApp.swift
//  CodexReviewMonitor
//
//  Created by Kazuki Nakashima on 2026/03/28.
//

import AppKit
import ReviewApplication
@_spi(PreviewSupport) import CodexReviewUI

enum CodexReviewMonitorNativeAuthentication {
    static let callbackScheme = "lynnpd.codexreviewmonitor.auth"
}

enum CodexReviewMonitorLaunchMode {
    case application
    case xctest
    case preview
}

enum CodexReviewMonitorStoreMode {
    case uiTest
    case mockJobs
    case live
}

enum CodexReviewMonitorLaunchEnvironment {
    static let uiTestModeKey = CodexReviewStoreTestEnvironment.uiTestModeKey
    static let mockJobsKey = CodexReviewStoreTestEnvironment.mockJobsKey
    static let xctestConfigurationKey = "XCTestConfigurationFilePath"
    static let xctestBundlePathKey = "XCTestBundlePath"
    static let xcInjectBundleIntoKey = "XCInjectBundleInto"
    static let xctestSessionIdentifierKey = "XCTestSessionIdentifier"
    static let xcodeRunningForPlaygroundsKey = "XCODE_RUNNING_FOR_PLAYGROUNDS"
    static let xcodeRunningForPreviewsKey = "XCODE_RUNNING_FOR_PREVIEWS"
    static let testPortKey = CodexReviewStoreTestEnvironment.portKey
    static let testCodexCommandKey = CodexReviewStoreTestEnvironment.codexCommandKey
    static let testDiagnosticsPathKey = CodexReviewStoreTestEnvironment.diagnosticsPathKey
    static let mockJobsArgument = CodexReviewStoreTestEnvironment.mockJobsArgument
    static let testPortArgument = CodexReviewStoreTestEnvironment.portArgument
    static let testCodexCommandArgument = CodexReviewStoreTestEnvironment.codexCommandArgument
    static let testDiagnosticsPathArgument = CodexReviewStoreTestEnvironment.diagnosticsPathArgument

    static func launchMode(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> CodexReviewMonitorLaunchMode {
        if isEnabledFlag(environment[uiTestModeKey]) {
            return .xctest
        }
        if isRunningInPreviews(environment: environment) {
            return .preview
        }
        if hasExplicitTestOverride(environment: environment, arguments: arguments) {
            return .application
        }
        if isRunningUnderXCTest(environment: environment) {
            return .xctest
        }
        return .application
    }

    static func shouldStartEmbeddedServer(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        guard storeMode(environment: environment, arguments: arguments) == .live else {
            return false
        }
        return launchMode(environment: environment, arguments: arguments) == .application
    }

    private static func isRunningInPreviews(environment: [String: String]) -> Bool {
        isEnabledFlag(environment[xcodeRunningForPreviewsKey])
            || isEnabledFlag(environment[xcodeRunningForPlaygroundsKey])
    }

    static func shouldUseUITestStore(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        isEnabledFlag(environment[uiTestModeKey])
    }

    static func shouldUseMockJobsStore(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        guard shouldUseUITestStore(environment: environment) == false else {
            return false
        }
        return isEnabledFlag(environment[mockJobsKey]) || arguments.contains(mockJobsArgument)
    }

    static func storeMode(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> CodexReviewMonitorStoreMode {
        if shouldUseUITestStore(environment: environment) {
            return .uiTest
        }
        if shouldUseMockJobsStore(environment: environment, arguments: arguments) {
            return .mockJobs
        }
        return .live
    }

    static func isRunningUnderXCTest(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        isNonEmpty(environment[xctestConfigurationKey])
            || isNonEmpty(environment[xctestBundlePathKey])
            || isNonEmpty(environment[xcInjectBundleIntoKey])
            || isNonEmpty(environment[xctestSessionIdentifierKey])
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

    private static func isNonEmpty(_ value: String?) -> Bool {
        value?.isEmpty == false
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
    private let managesEmbeddedServerOnApplicationLaunch: Bool
    private var shouldManageEmbeddedServer = true
    private var terminationTask: Task<Void, Never>?

    init(
        store: any CodexReviewMonitorLifecycleStore,
        shouldManageEmbeddedServer: Bool = true
    ) {
        self.store = store
        managesEmbeddedServerOnApplicationLaunch = shouldManageEmbeddedServer
    }

    func applicationDidFinishLaunching(launchMode: CodexReviewMonitorLaunchMode) {
        shouldManageEmbeddedServer =
            managesEmbeddedServerOnApplicationLaunch &&
            launchMode == .application
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
private final class ReviewMonitorPresentationAnchorSource {
    weak var window: NSWindow?
}

@main
@MainActor
final class CodexReviewMonitorAppDelegate: NSObject, NSApplicationDelegate {
    private let launchModeProvider: () -> CodexReviewMonitorLaunchMode
    private let customStoreFactory: (() -> CodexReviewStore)?
    private let windowControllerFactory: (CodexReviewStore, Bool) -> NSWindowController
    private let presentationAnchorSource = ReviewMonitorPresentationAnchorSource()

    private lazy var launchEnvironment = ProcessInfo.processInfo.environment
    private lazy var launchArguments = CommandLine.arguments
    private lazy var launchMode = launchModeProvider()
    private lazy var storeMode = CodexReviewMonitorLaunchEnvironment.storeMode(
        environment: launchEnvironment,
        arguments: launchArguments
    )
    lazy var store: CodexReviewStore = {
        if let customStoreFactory {
            return customStoreFactory()
        }
        switch storeMode {
        case .uiTest:
            return CodexReviewStore.makeReviewMonitorUITestStore()
        case .mockJobs:
            return ReviewMonitorPreviewContent.makeStore()
        case .live:
            return CodexReviewStore.makeReviewMonitorStore(
                nativeAuthenticationConfiguration: .init(
                    callbackScheme: CodexReviewMonitorNativeAuthentication.callbackScheme,
                    browserSessionPolicy: .ephemeral,
                    presentationAnchorProvider: { [weak presentationAnchorSource] in
                        presentationAnchorSource?.window
                    }
                )
            )
        }
    }()
    lazy var lifecycle = CodexReviewMonitorLifecycleController(
        store: store,
        shouldManageEmbeddedServer: CodexReviewMonitorLaunchEnvironment.shouldStartEmbeddedServer(
            environment: launchEnvironment,
            arguments: launchArguments
        )
    )
    lazy var windowController: NSWindowController = {
        let windowController = windowControllerFactory(store, storeMode == .mockJobs)
        presentationAnchorSource.window = windowController.window
        return windowController
    }()

    override init() {
        launchModeProvider = {
            CodexReviewMonitorLaunchEnvironment.launchMode()
        }
        customStoreFactory = nil
        windowControllerFactory = { store, _ in
            ReviewMonitorWindowController(store: store)
        }
        super.init()
    }

    init(
        launchModeProvider: @escaping () -> CodexReviewMonitorLaunchMode,
        storeFactory: (() -> CodexReviewStore)? = nil,
        windowControllerFactory: @escaping (CodexReviewStore, Bool) -> NSWindowController
    ) {
        self.launchModeProvider = launchModeProvider
        self.customStoreFactory = storeFactory
        self.windowControllerFactory = windowControllerFactory
        super.init()
    }

    static func main() {
        let application = NSApplication.shared
        let delegate = CodexReviewMonitorAppDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        guard launchMode != .preview else {
            lifecycle.applicationDidFinishLaunching(launchMode: launchMode)
            return
        }
        NSApp.setActivationPolicy(.regular)
        installStandardMainMenuIfNeeded()
        showMainWindow(nil)
        if launchMode == .application {
            NSApp.activate(ignoringOtherApps: true)
        }
        lifecycle.applicationDidFinishLaunching(
            launchMode: launchMode
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        lifecycle.applicationShouldTerminate(replyingTo: sender)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        _ = sender
        guard launchMode == .application else {
            return false
        }
        guard flag == false else {
            return false
        }
        showMainWindow(nil)
        return true
    }

    private func showMainWindow(_ sender: Any?) {
        windowController.showWindow(sender)
        windowController.window?.orderFrontRegardless()
        windowController.window?.makeKeyAndOrderFront(sender)
    }

    private func installStandardMainMenuIfNeeded() {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName

        let mainMenu = NSMenu(title: "Main Menu")

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: appName)
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let deleteItem = NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: String(Character(UnicodeScalar(NSDeleteCharacter)!)))
        editMenu.addItem(deleteItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.servicesMenu = servicesMenu
        NSApp.windowsMenu = windowMenu
    }
}
