import Foundation

package func resolveCodexCommand(
    requestedCommand: String,
    environment: [String: String],
    currentDirectory: String
) -> String? {
    if requestedCommand.contains("/") {
        return resolveExplicitCommandPath(
            requestedCommand,
            currentDirectory: currentDirectory
        )
    }

    let searchPaths = searchPathsForExecutableLookup(
        environment: environment,
        currentDirectory: currentDirectory
    )
    for directory in searchPaths {
        let candidate = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(requestedCommand)
            .path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }

    return nil
}

private func resolveExplicitCommandPath(
    _ requestedCommand: String,
    currentDirectory: String
) -> String {
    URL(
        fileURLWithPath: requestedCommand,
        relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true)
    )
    .standardizedFileURL
    .path
}

private func searchPathsForExecutableLookup(
    environment: [String: String],
    currentDirectory: String
) -> [String] {
    let envPaths = environment["PATH"]?
        .components(separatedBy: ":")
        .map { path -> String in
            if path.isEmpty {
                return currentDirectory
            }
            if path.hasPrefix("/") {
                return path
            }
            return URL(fileURLWithPath: currentDirectory, isDirectory: true)
                .appendingPathComponent(path, isDirectory: true)
                .path
        } ?? []

    let fallbackPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/Applications/Codex.app/Contents/Resources",
    ]

    var result: [String] = []
    var seen = Set<String>()
    for path in envPaths + fallbackPaths {
        guard seen.insert(path).inserted else {
            continue
        }
        result.append(path)
    }
    return result
}
