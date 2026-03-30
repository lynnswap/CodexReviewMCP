import Foundation

package func resolveCodexCommand(
    requestedCommand: String,
    environment: [String: String]
) -> String {
    if requestedCommand.contains("/") {
        return requestedCommand
    }

    let searchPaths = searchPathsForExecutableLookup(environment: environment)
    for directory in searchPaths {
        let candidate = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(requestedCommand)
            .path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }

    return requestedCommand
}

private func searchPathsForExecutableLookup(environment: [String: String]) -> [String] {
    let envPaths = environment["PATH"]?
        .split(separator: ":")
        .map(String.init) ?? []

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
