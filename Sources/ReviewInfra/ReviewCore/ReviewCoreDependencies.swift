import Darwin
import Foundation

package struct ReviewFileSystemClient: Sendable {
    package var homeDirectoryForCurrentUser: @Sendable () -> URL
    package var currentDirectoryPath: @Sendable () -> String
    package var createDirectory: @Sendable (_ url: URL, _ withIntermediateDirectories: Bool) throws -> Void
    package var writeData: @Sendable (_ data: Data, _ url: URL, _ options: Data.WritingOptions) throws -> Void
    package var readData: @Sendable (_ url: URL) throws -> Data
    package var readString: @Sendable (_ url: URL, _ encoding: String.Encoding) throws -> String
    package var copyItem: @Sendable (_ sourceURL: URL, _ destinationURL: URL) throws -> Void
    package var removeItem: @Sendable (_ url: URL) throws -> Void
    package var fileExists: @Sendable (_ path: String) -> Bool
    package var contentsOfDirectory: @Sendable (_ url: URL, _ skipsHiddenFiles: Bool) throws -> [URL]
    package var isExecutableFile: @Sendable (_ path: String) -> Bool
    package var contentModificationDate: @Sendable (_ url: URL) -> Date?

    package init(
        homeDirectoryForCurrentUser: @escaping @Sendable () -> URL,
        currentDirectoryPath: @escaping @Sendable () -> String,
        createDirectory: @escaping @Sendable (_ url: URL, _ withIntermediateDirectories: Bool) throws -> Void,
        writeData: @escaping @Sendable (_ data: Data, _ url: URL, _ options: Data.WritingOptions) throws -> Void,
        readData: @escaping @Sendable (_ url: URL) throws -> Data,
        readString: @escaping @Sendable (_ url: URL, _ encoding: String.Encoding) throws -> String,
        copyItem: @escaping @Sendable (_ sourceURL: URL, _ destinationURL: URL) throws -> Void,
        removeItem: @escaping @Sendable (_ url: URL) throws -> Void,
        fileExists: @escaping @Sendable (_ path: String) -> Bool,
        contentsOfDirectory: @escaping @Sendable (_ url: URL, _ skipsHiddenFiles: Bool) throws -> [URL],
        isExecutableFile: @escaping @Sendable (_ path: String) -> Bool,
        contentModificationDate: @escaping @Sendable (_ url: URL) -> Date?
    ) {
        self.homeDirectoryForCurrentUser = homeDirectoryForCurrentUser
        self.currentDirectoryPath = currentDirectoryPath
        self.createDirectory = createDirectory
        self.writeData = writeData
        self.readData = readData
        self.readString = readString
        self.copyItem = copyItem
        self.removeItem = removeItem
        self.fileExists = fileExists
        self.contentsOfDirectory = contentsOfDirectory
        self.isExecutableFile = isExecutableFile
        self.contentModificationDate = contentModificationDate
    }

    package static var live: Self {
        Self(
            homeDirectoryForCurrentUser: {
                FileManager.default.homeDirectoryForCurrentUser
            },
            currentDirectoryPath: {
                FileManager.default.currentDirectoryPath
            },
            createDirectory: { url, withIntermediateDirectories in
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: withIntermediateDirectories
                )
            },
            writeData: { data, url, options in
                try data.write(to: url, options: options)
            },
            readData: { url in
                try Data(contentsOf: url)
            },
            readString: { url, encoding in
                try String(contentsOf: url, encoding: encoding)
            },
            copyItem: { sourceURL, destinationURL in
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            },
            removeItem: { url in
                try FileManager.default.removeItem(at: url)
            },
            fileExists: { path in
                FileManager.default.fileExists(atPath: path)
            },
            contentsOfDirectory: { url, skipsHiddenFiles in
                try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: skipsHiddenFiles ? [.skipsHiddenFiles] : []
                )
            },
            isExecutableFile: { path in
                FileManager.default.isExecutableFile(atPath: path)
            },
            contentModificationDate: { url in
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
        )
    }
}

package struct ReviewProcessClient: Sendable {
    package var currentProcessIdentifier: @Sendable () -> Int
    package var currentExecutableName: @Sendable () -> String?
    package var isProcessAlive: @Sendable (_ pid: pid_t) -> Bool
    package var processStartTime: @Sendable (_ pid: pid_t) -> ProcessStartTime?
    package var isMatchingExecutable: @Sendable (_ pid: Int, _ expectedName: String?) -> Bool
    package var childProcessIDs: @Sendable (_ pid: pid_t) -> [pid_t]
    package var currentProcessGroupID: @Sendable (_ pid: pid_t) -> pid_t?

    package init(
        currentProcessIdentifier: @escaping @Sendable () -> Int,
        currentExecutableName: @escaping @Sendable () -> String?,
        isProcessAlive: @escaping @Sendable (_ pid: pid_t) -> Bool,
        processStartTime: @escaping @Sendable (_ pid: pid_t) -> ProcessStartTime?,
        isMatchingExecutable: @escaping @Sendable (_ pid: Int, _ expectedName: String?) -> Bool,
        childProcessIDs: @escaping @Sendable (_ pid: pid_t) -> [pid_t],
        currentProcessGroupID: @escaping @Sendable (_ pid: pid_t) -> pid_t?
    ) {
        self.currentProcessIdentifier = currentProcessIdentifier
        self.currentExecutableName = currentExecutableName
        self.isProcessAlive = isProcessAlive
        self.processStartTime = processStartTime
        self.isMatchingExecutable = isMatchingExecutable
        self.childProcessIDs = childProcessIDs
        self.currentProcessGroupID = currentProcessGroupID
    }

    package static var live: Self {
        Self(
            currentProcessIdentifier: {
                Int(ProcessInfo.processInfo.processIdentifier)
            },
            currentExecutableName: {
                ProcessInfo.processInfo.arguments.first.map {
                    URL(fileURLWithPath: $0).lastPathComponent
                }
            },
            isProcessAlive: { pid in
                liveReviewProcessIsProcessAlive(pid)
            },
            processStartTime: { pid in
                liveReviewProcessStartTime(pid)
            },
            isMatchingExecutable: { pid, expectedName in
                ReviewDiscovery.isMatchingExecutable(pid, expectedName: expectedName)
            },
            childProcessIDs: { pid in
                liveReviewChildProcessIDs(pid)
            },
            currentProcessGroupID: { pid in
                liveReviewCurrentProcessGroupID(pid)
            }
        )
    }
}

private func liveReviewProcessIsProcessAlive(_ pid: pid_t) -> Bool {
    isProcessAlive(pid)
}

private func liveReviewProcessStartTime(_ pid: pid_t) -> ProcessStartTime? {
    processStartTime(of: pid)
}

private func liveReviewChildProcessIDs(_ pid: pid_t) -> [pid_t] {
    childProcessIDs(of: pid)
}

private func liveReviewCurrentProcessGroupID(_ pid: pid_t) -> pid_t? {
    currentProcessGroupID(of: pid)
}

package struct ReviewPathResolver: Sendable {
    package var environment: [String: String]
    package var homeDirectoryForCurrentUser: URL

    package init(
        environment: [String: String],
        homeDirectoryForCurrentUser: URL
    ) {
        self.environment = environment
        self.homeDirectoryForCurrentUser = homeDirectoryForCurrentUser
    }

    package static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileSystem: ReviewFileSystemClient = .live
    ) -> Self {
        Self(
            environment: environment,
            homeDirectoryForCurrentUser: fileSystem.homeDirectoryForCurrentUser()
        )
    }

    package func reviewHomeURL() -> URL {
        if let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           home.isEmpty == false
        {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".codex_review", isDirectory: true)
        }
        return homeDirectoryForCurrentUser
            .appendingPathComponent(".codex_review", isDirectory: true)
    }

    package func reviewConfigURL() -> URL {
        reviewHomeURL().appendingPathComponent("config.toml")
    }

    package func reviewAuthURL() -> URL {
        reviewHomeURL().appendingPathComponent("auth.json")
    }

    package func accountsDirectoryURL() -> URL {
        reviewHomeURL().appendingPathComponent("accounts", isDirectory: true)
    }

    package func accountsRegistryURL() -> URL {
        accountsDirectoryURL().appendingPathComponent("registry.json")
    }

    package func savedAccountDirectoryURL(accountKey: String) -> URL {
        accountsDirectoryURL().appendingPathComponent(
            Self.encodedSavedAccountPathComponent(accountKey: accountKey),
            isDirectory: true
        )
    }

    package func savedAccountAuthURL(accountKey: String) -> URL {
        savedAccountDirectoryURL(accountKey: accountKey).appendingPathComponent("auth.json")
    }

    package func legacySavedAccountDirectoryURL(accountKey: String) -> URL {
        accountsDirectoryURL().appendingPathComponent(accountKey, isDirectory: true)
    }

    package func makeProbeRootURL() -> URL {
        accountsDirectoryURL().appendingPathComponent("probes", isDirectory: true)
    }

    package func reviewAgentsURL() -> URL {
        reviewHomeURL().appendingPathComponent("AGENTS.md")
    }

    package func discoveryFileURL() -> URL {
        reviewHomeURL().appendingPathComponent("review_mcp_endpoint.json")
    }

    package func runtimeStateFileURL() -> URL {
        reviewHomeURL().appendingPathComponent("review_mcp_runtime_state.json")
    }

    package func codexHomeURL() -> URL {
        reviewHomeURL()
    }

    package func resolvedCodexHomeURL(appServerCodexHome: String?) -> URL {
        _ = appServerCodexHome
        return codexHomeURL()
    }

    package func codexConfigURL(codexHome: URL? = nil) -> URL {
        (codexHome ?? codexHomeURL()).appendingPathComponent("config.toml")
    }

    private static let encodedAccountKeyAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private static func encodedSavedAccountPathComponent(accountKey: String) -> String {
        accountKey.addingPercentEncoding(withAllowedCharacters: encodedAccountKeyAllowedCharacters)
            ?? accountKey.replacingOccurrences(of: "/", with: "%2F")
    }
}

package struct ReviewCoreDependencies: Sendable {
    package var environment: [String: String]
    package var arguments: [String]
    package var paths: ReviewPathResolver
    package var fileSystem: ReviewFileSystemClient
    package var process: ReviewProcessClient
    package var dateNow: @Sendable () -> Date
    package var uuid: @Sendable () -> UUID
    package var clock: any ReviewClock

    package init(
        environment: [String: String],
        arguments: [String] = [],
        paths: ReviewPathResolver? = nil,
        fileSystem: ReviewFileSystemClient = .live,
        process: ReviewProcessClient = .live,
        dateNow: @escaping @Sendable () -> Date = { Date() },
        uuid: @escaping @Sendable () -> UUID = { UUID() },
        clock: any ReviewClock = ContinuousClock()
    ) {
        self.environment = environment
        self.arguments = arguments
        self.fileSystem = fileSystem
        self.process = process
        self.dateNow = dateNow
        self.uuid = uuid
        self.clock = clock
        self.paths = paths ?? ReviewPathResolver.live(
            environment: environment,
            fileSystem: fileSystem
        )
    }

    package static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> Self {
        Self(environment: environment, arguments: arguments)
    }
}
