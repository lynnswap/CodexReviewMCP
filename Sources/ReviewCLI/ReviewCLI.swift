import Darwin
import Dispatch
import Foundation
import Logging
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
            let server = ReviewMCPHTTPServer(configuration: configuration)
            let signalHandler = ServerSignalHandler {
                Task {
                    await server.stop()
                }
            }
            signalHandler.start()
            defer { signalHandler.cancel() }
            do {
                _ = try await server.start()
            } catch {
                guard options.forceRestart, isAddressInUse(error), let discovery = ReviewDiscovery.read() else {
                    throw error
                }
                guard discoveryMatchesListenAddress(discovery, host: options.host, port: options.port) else {
                    throw error
                }
                try await forceRestart(discovery)
                _ = try await server.start()
            }
            try await server.waitUntilShutdown()
            await server.stop()
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

private struct ServerOptions {
    var host = "localhost"
    var port = codexReviewDefaultPort
    var sessionTimeoutSeconds: TimeInterval = ReviewDefaults.shared.server.sessionTimeoutSeconds
    var codexCommand = "codex"
    var forceRestart = false
}

package struct AdapterOptions {
    var url: URL
    var requestTimeoutSeconds: TimeInterval
}

private struct CLIError: Error {
    var message: String
    var exitCode: Int32
}

private final class LoggingBootstrapState: @unchecked Sendable {
    let lock = NSLock()
    var didBootstrap = false
}

private let loggingBootstrapState = LoggingBootstrapState()

private func bootstrapLogging() {
    loggingBootstrapState.lock.lock()
    defer { loggingBootstrapState.lock.unlock() }
    guard loggingBootstrapState.didBootstrap == false else {
        return
    }
    LoggingSystem.bootstrap(StreamLogHandler.standardError)
    loggingBootstrapState.didBootstrap = true
}

private func parseServerOptions(args: [String]) throws -> ServerOptions {
    var options = ServerOptions()
    var cursor = Array(args.dropFirst()).makeIterator()

    while let arg = cursor.next() {
        switch arg {
        case "--listen":
            guard let value = cursor.next() else {
                throw CLIError(message: "missing value for --listen", exitCode: 2)
            }
            (options.host, options.port) = try parseListenAddress(value)
        case "--session-timeout":
            guard let value = cursor.next(), let seconds = TimeInterval(value), seconds > 0 else {
                throw CLIError(message: "invalid value for --session-timeout", exitCode: 2)
            }
            options.sessionTimeoutSeconds = seconds
        case "--codex-command":
            guard let value = cursor.next(), value.isEmpty == false else {
                throw CLIError(message: "invalid value for --codex-command", exitCode: 2)
            }
            options.codexCommand = value
        case "--force-restart":
            options.forceRestart = true
        case "-h", "--help":
            throw CLIError(message: serverUsage, exitCode: 0)
        default:
            throw CLIError(message: "unknown option: \(arg)\n\n\(serverUsage)", exitCode: 2)
        }
    }
    return options
}

package func parseAdapterOptions(args: [String], environment: [String: String]) throws -> AdapterOptions {
    var explicitURL: URL?
    var requestTimeoutSeconds: TimeInterval = 0

    var cursor = Array(args.dropFirst()).makeIterator()
    while let arg = cursor.next() {
        switch arg {
        case "--url":
            guard let value = cursor.next() else {
                throw CLIError(message: "invalid value for --url", exitCode: 2)
            }
            explicitURL = try validatedAdapterURL(value, source: "--url")
        case "--request-timeout":
            guard let value = cursor.next(), let seconds = TimeInterval(value), seconds >= 0 else {
                throw CLIError(message: "invalid value for --request-timeout", exitCode: 2)
            }
            requestTimeoutSeconds = seconds
        case "-h", "--help":
            throw CLIError(message: adapterUsage, exitCode: 0)
        default:
            throw CLIError(message: "unknown option: \(arg)\n\n\(adapterUsage)", exitCode: 2)
        }
    }

    let url = try explicitURL
        ?? adapterURLFromEnvironment(environment)
        ?? ReviewDiscovery.read().flatMap { URL(string: $0.url) }
        ?? URL(string: "http://localhost:\(codexReviewDefaultPort)/mcp")!
    return AdapterOptions(url: url, requestTimeoutSeconds: requestTimeoutSeconds)
}

package func adapterURLFromEnvironment(_ environment: [String: String]) throws -> URL? {
    guard let rawValue = environment["CODEX_REVIEW_MCP_ENDPOINT"]?.nilIfEmpty else {
        return nil
    }
    return try validatedAdapterURL(rawValue, source: "CODEX_REVIEW_MCP_ENDPOINT")
}

package func parseListenAddress(_ value: String) throws -> (String, Int) {
    guard let separator = value.lastIndex(of: ":") else {
        throw CLIError(message: "listen address must be host:port", exitCode: 2)
    }
    let rawHost = String(value[..<separator])
    let portText = String(value[value.index(after: separator)...])
    guard let port = Int(portText), port >= 0, port <= 65535 else {
        throw CLIError(message: "invalid listen port: \(portText)", exitCode: 2)
    }
    let host: String
    if rawHost.hasPrefix("[") || rawHost.hasSuffix("]") {
        guard rawHost.hasPrefix("["), rawHost.hasSuffix("]"), rawHost.count > 2 else {
            throw CLIError(message: "listen address must be host:port", exitCode: 2)
        }
        host = String(rawHost.dropFirst().dropLast())
    } else {
        host = rawHost
    }
    guard host.isEmpty == false else {
        throw CLIError(message: "listen host cannot be empty", exitCode: 2)
    }
    return (host, port)
}

private func validatedAdapterURL(_ value: String, source: String) throws -> URL {
    guard
        let url = URL(string: value),
        let scheme = url.scheme?.lowercased(),
        let host = url.host?.nilIfEmpty,
        host.isEmpty == false,
        scheme == "http" || scheme == "https"
    else {
        throw CLIError(message: "invalid value for \(source)", exitCode: 2)
    }
    return url
}

package func discoveryMatchesListenAddress(
    _ discovery: ReviewDiscoveryRecord,
    host: String,
    port: Int,
    resolver: (String) -> Set<String> = resolvedHostCandidates
) -> Bool {
    guard discovery.port == port else {
        return false
    }
    return configuredHostCandidates(host, resolver: resolver).contains(normalizeLoopbackHost(discovery.host))
}

private func isAddressInUse(_ error: Error) -> Bool {
    let text = String(describing: error)
    return text.localizedCaseInsensitiveContains("address already in use")
}

private func normalizeLoopbackHost(_ host: String) -> String {
    if host == "localhost" || host == "::1" || host.hasPrefix("127.") {
        return "localhost"
    }
    return host
}

private func configuredHostCandidates(
    _ host: String,
    resolver: (String) -> Set<String>
) -> Set<String> {
    let configuredHost = normalizeLoopbackHost(normalizedDiscoveryHost(configuredHost: host, boundHost: host))
    var candidates: Set<String> = [configuredHost]
    for candidate in resolver(host) {
        candidates.insert(normalizeLoopbackHost(candidate))
    }
    for candidate in resolver(configuredHost) {
        candidates.insert(normalizeLoopbackHost(candidate))
    }
    return candidates
}

private func resolvedHostCandidates(_ host: String) -> Set<String> {
    var hints = addrinfo(
        ai_flags: AI_ADDRCONFIG,
        ai_family: AF_UNSPEC,
        ai_socktype: SOCK_STREAM,
        ai_protocol: IPPROTO_TCP,
        ai_addrlen: 0,
        ai_canonname: nil,
        ai_addr: nil,
        ai_next: nil
    )
    var results: UnsafeMutablePointer<addrinfo>?
    let status = host.withCString { rawHost in
        getaddrinfo(rawHost, nil, &hints, &results)
    }
    guard status == 0, let results else {
        return []
    }
    defer { freeaddrinfo(results) }

    var candidates: Set<String> = []
    var cursor: UnsafeMutablePointer<addrinfo>? = results
    while let entry = cursor {
        if let address = entry.pointee.ai_addr {
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let nameStatus = getnameinfo(
                address,
                entry.pointee.ai_addrlen,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            let length = hostBuffer.firstIndex(of: 0) ?? hostBuffer.count
            let numericHost = String(
                decoding: hostBuffer[..<length].map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            if nameStatus == 0, numericHost.isEmpty == false {
                candidates.insert(numericHost)
            }
        }
        cursor = entry.pointee.ai_next
    }
    return candidates
}

private func forceRestart(_ discovery: ReviewDiscoveryRecord) async throws {
    let pid = pid_t(discovery.pid)
    let signalResult = kill(pid, SIGTERM)
    if signalResult == -1, errno != ESRCH {
        let message = String(cString: strerror(errno))
        throw CLIError(
            message: "failed to stop existing server process \(discovery.pid): \(message)",
            exitCode: 1
        )
    }

    let timeout: Duration = .seconds(10)
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while isProcessAlive(pid), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(100))
    }

    if isProcessAlive(pid) {
        killChildProcessGroups(of: pid, signal: SIGKILL)
        _ = kill(pid, SIGKILL)
        let killDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while isProcessAlive(pid), ContinuousClock.now < killDeadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    guard isProcessAlive(pid) == false else {
        throw CLIError(
            message: "existing server process \(discovery.pid) did not stop within 12 seconds",
            exitCode: 1
        )
    }
}

private func killChildProcessGroups(of pid: pid_t, signal: Int32) {
    for childPID in childProcessIDs(of: pid) {
        _ = killpg(childPID, signal)
        _ = kill(childPID, signal)
    }
}

private final class ServerSignalHandler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "codex-review-mcp.signal")
    private let handler: @Sendable () -> Void
    private var sources: [DispatchSourceSignal] = []

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func start() {
        guard sources.isEmpty else {
            return
        }

        for signal in [SIGTERM, SIGINT] {
            Darwin.signal(signal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signal, queue: queue)
            source.setEventHandler(handler: handler)
            source.resume()
            sources.append(source)
        }
    }

    func cancel() {
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
    }
}

private let serverUsage = """
Usage:
  codex-review-mcp-server [--listen host:port] [--session-timeout sec] [--codex-command path] [--force-restart]
"""

private let adapterUsage = """
Usage:
  codex-review-mcp [--url http://localhost:\(codexReviewDefaultPort)/mcp] [--request-timeout sec]
"""
