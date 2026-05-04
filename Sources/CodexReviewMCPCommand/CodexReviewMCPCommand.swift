import Foundation
import ReviewCLI

@main
struct CodexReviewMCPCommand {
    static func main() async {
        let exitCode = await ReviewCLI.runAdapter(
            args: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment
        )
        guard exitCode == 0 else {
            exit(exitCode)
        }
    }
}
