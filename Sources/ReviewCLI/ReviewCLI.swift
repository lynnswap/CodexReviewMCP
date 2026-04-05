import Foundation
import Logging
import CodexReviewModel
import CodexReviewMCP
import ReviewCore
import ReviewHTTPServer
import ReviewStdioAdapter

public enum ReviewCLI {
    public static func runServer(args: [String], environment: [String: String]) async -> Int32 {
        bootstrapLogging()
        do {
            let options = try parseServerOptions(args: args)
            let configuration = ReviewServerConfiguration(
                host: options.host,
                port: options.port,
                sessionTimeoutSeconds: options.sessionTimeoutSeconds,
                codexCommand: options.codexCommand,
                environment: environment
            )
            let store = await MainActor.run {
                CodexReviewStore(configuration: configuration)
            }
            let signalHandler = ServerSignalHandler {
                Task {
                    await store.stop()
                }
            }
            signalHandler.start()
            defer { signalHandler.cancel() }
            await store.start(forceRestartIfNeeded: options.forceRestart)
            let serverState = await MainActor.run { store.serverState }
            if case .failed(let message) = serverState {
                throw CLIError(message: message, exitCode: 1)
            }
            await store.waitUntilStopped()
            await store.stop()
            return 0
        } catch let error as CLIError {
            FileHandle.standardError.write(Data((error.message + "\n").utf8))
            return error.exitCode
        } catch {
            FileHandle.standardError.write(Data(("server error: \(error)\n").utf8))
            return 1
        }
    }

    public static func runAdapter(args: [String], environment: [String: String]) async -> Int32 {
        bootstrapLogging()
        do {
            let options = try parseAdapterOptions(args: args, environment: environment)
            let adapter = ReviewStdioAdapter(
                configuration: .init(
                    upstreamURL: options.url,
                    requestTimeout: options.requestTimeoutSeconds
                )
            )
            await adapter.start()
            await adapter.wait()
            return 0
        } catch let error as CLIError {
            FileHandle.standardError.write(Data((error.message + "\n").utf8))
            return error.exitCode
        } catch {
            FileHandle.standardError.write(Data(("adapter error: \(error)\n").utf8))
            return 1
        }
    }

    public static func runLogin(args: [String], environment: [String: String]) async -> Int32 {
        bootstrapLogging()
        do {
            let options = try parseLoginOptions(args: args)
            let manager = ReviewAuthManager(
                configuration: .init(
                    codexCommand: options.codexCommand,
                    environment: environment
                )
            )

            switch options.action {
            case .status:
                printLoginStatus(try await manager.loadState())
                return 0
            case .logout:
                _ = try await manager.logout()
                FileHandle.standardOutput.write(Data("Signed out of ReviewMCP.\n".utf8))
                return 0
            case .login:
                let browserOpenState = LoginBrowserOpenState()
                try await manager.beginAuthentication(
                ) { state in
                    await browserOpenState.openIfNeeded(state: state)
                    let rendered = renderLoginUpdate(state)
                    FileHandle.standardOutput.write(Data((rendered + "\n").utf8))
                }
                printLoginStatus(try await manager.loadState())
                return 0
            }
        } catch let error as CLIError {
            FileHandle.standardError.write(Data((error.message + "\n").utf8))
            return error.exitCode
        } catch let error as ReviewAuthError {
            FileHandle.standardError.write(Data(((error.errorDescription ?? "Authentication failed.") + "\n").utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data(("login error: \(error)\n").utf8))
            return 1
        }
    }
}

private func printLoginStatus(_ state: CodexReviewAuthModel.State) {
    let message = loginStatusMessage(state)
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

package func loginStatusMessage(_ state: CodexReviewAuthModel.State) -> String {
    switch state {
    case .signedOut:
        return "Not logged in"
    case .signingIn(let progress):
        return "Authentication in progress: \(progress.detail)"
    case .signedIn:
        return "Logged in using ChatGPT"
    case .failed(let detail):
        return "Authentication failed: \(detail)"
    }
}

package func renderLoginUpdate(_ state: CodexReviewAuthModel.State) -> String {
    switch state {
    case .signedOut:
        return "Not logged in"
    case .signedIn:
        return "Signed in using ChatGPT"
    case .failed(let message):
        return message
    case .signingIn(let progress):
        if let browserURL = progress.browserURL {
            return """
            If your browser did not open, navigate to this URL to authenticate:

            \(browserURL)
            """
        }
        return progress.detail
    }
}

private actor LoginBrowserOpenState {
    private var openedURL: String?

    func openIfNeeded(state: CodexReviewAuthModel.State) async {
        guard case .signingIn(let progress) = state,
              let browserURL = progress.browserURL,
              openedURL != browserURL,
              let url = URL(string: browserURL)
        else {
            return
        }

        openedURL = browserURL
        if openBrowserURL(url) == false {
            openedURL = nil
        }
    }
}

private func openBrowserURL(_ url: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}
