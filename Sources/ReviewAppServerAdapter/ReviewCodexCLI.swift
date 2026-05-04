import Foundation

package let reviewMCPPersistentAuthCLIOverride = #"cli_auth_credentials_store="file""#

package func reviewMCPCodexCommandArguments(
    _ arguments: [String]
) -> [String] {
    ["-c", reviewMCPPersistentAuthCLIOverride] + arguments
}
