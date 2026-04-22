import Foundation
import ReviewDomain
import ReviewInfra

package enum CodexReviewStoreLaunchPolicy {
    package static let xctestConfigurationKey = "XCTestConfigurationFilePath"
    package static let xctestBundlePathKey = "XCTestBundlePath"
    package static let xcInjectBundleIntoKey = "XCInjectBundleInto"
    package static let xctestSessionIdentifierKey = "XCTestSessionIdentifier"
    package static let xcodeRunningForPlaygroundsKey = "XCODE_RUNNING_FOR_PLAYGROUNDS"
    package static let xcodeRunningForPreviewsKey = "XCODE_RUNNING_FOR_PREVIEWS"

    package static func shouldAutoStartEmbeddedServer(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        if isEnabledFlag(environment[CodexReviewStoreTestEnvironment.uiTestModeKey]) {
            return false
        }
        if isRunningInPreviews(environment: environment) {
            return false
        }
        if hasExplicitTestOverride(environment: environment, arguments: arguments) {
            return true
        }
        if isRunningUnderXCTest(environment: environment) {
            return false
        }
        return true
    }

    private static func isRunningInPreviews(environment: [String: String]) -> Bool {
        isEnabledFlag(environment[xcodeRunningForPreviewsKey])
            || isEnabledFlag(environment[xcodeRunningForPlaygroundsKey])
    }

    private static func hasExplicitTestOverride(
        environment: [String: String],
        arguments: [String]
    ) -> Bool {
        environment[CodexReviewStoreTestEnvironment.portKey] != nil
            || environment[CodexReviewStoreTestEnvironment.codexCommandKey] != nil
            || environment[CodexReviewStoreTestEnvironment.diagnosticsPathKey] != nil
            || arguments.contains(CodexReviewStoreTestEnvironment.portArgument)
            || arguments.contains(CodexReviewStoreTestEnvironment.codexCommandArgument)
            || arguments.contains(CodexReviewStoreTestEnvironment.diagnosticsPathArgument)
    }

    package static func isRunningUnderXCTest(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        isNonEmpty(environment[xctestConfigurationKey])
            || isNonEmpty(environment[xctestBundlePathKey])
            || isNonEmpty(environment[xcInjectBundleIntoKey])
            || isNonEmpty(environment[xctestSessionIdentifierKey])
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
