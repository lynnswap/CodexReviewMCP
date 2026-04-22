import Foundation
import Logging
import CodexReviewMCP
import CodexReviewModel
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

}
