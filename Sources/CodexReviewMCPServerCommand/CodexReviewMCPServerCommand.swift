import Foundation
import ReviewCLI

@main
struct CodexReviewMCPServerCommand {
    static func main() async {
        let exitCode = await ReviewCLI.runServer(
            args: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment
        )
        guard exitCode == 0 else {
            exit(exitCode)
        }
    }
}
