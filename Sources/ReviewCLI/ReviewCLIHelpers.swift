import Darwin
import Dispatch
import Foundation
import Logging
import ReviewCore
import ReviewHTTPServer
import ReviewJobs

struct ServerOptions {
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

struct CLIError: Error {
    var message: String
    var exitCode: Int32
}

private final class LoggingBootstrapState: @unchecked Sendable {
    let lock = NSLock()
    var didBootstrap = false
}

private let loggingBootstrapState = LoggingBootstrapState()

func bootstrapLogging() {
    loggingBootstrapState.lock.lock()
    defer { loggingBootstrapState.lock.unlock() }
    guard loggingBootstrapState.didBootstrap == false else {
        return
    }
    LoggingSystem.bootstrap(StreamLogHandler.standardError)
    loggingBootstrapState.didBootstrap = true
}

func parseServerOptions(args: [String]) throws -> ServerOptions {
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

    guard let defaultURL = URL(string: "http://localhost:\(codexReviewDefaultPort)/mcp") else {
        throw CLIError(message: "failed to construct default MCP endpoint", exitCode: 1)
    }
    let discoveryFileURL = ReviewHomePaths.discoveryFileURL(environment: environment)
    let url = try explicitURL
        ?? adapterURLFromEnvironment(environment)
        ?? ReviewDiscovery.read(from: discoveryFileURL).flatMap { URL(string: $0.url) }
        ?? defaultURL
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
    _ discovery: LiveEndpointRecord,
    host: String,
    port: Int,
    resolver: (String) -> Set<String> = resolvedHostCandidates
) -> Bool {
    guard discovery.port == port else {
        return false
    }
    return configuredHostCandidates(host, resolver: resolver).contains(normalizeLoopbackHost(discovery.host))
}

func isAddressInUse(_ error: Error) -> Bool {
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

private let serverUsage = """
Usage:
  codex-review-mcp-server [--listen host:port] [--session-timeout sec] [--codex-command path] [--force-restart]
"""

private let adapterUsage = """
Usage:
  codex-review-mcp [--url http://localhost:\(codexReviewDefaultPort)/mcp] [--request-timeout sec]
"""
