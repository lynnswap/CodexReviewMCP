import Foundation
import ReviewCLI

@main
struct CodexReviewMCPLoginExecutable {
    static func main() async {
        let exitCode = await ReviewCLI.runLogin(
            args: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment
        )
        guard exitCode == 0 else {
            exit(exitCode)
        }
    }
}
