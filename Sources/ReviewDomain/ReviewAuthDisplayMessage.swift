package func reviewRequiresAuthentication(from message: String?) -> Bool {
    guard let normalized = message?.lowercased(), normalized.isEmpty == false else {
        return false
    }

    let patterns = [
        "401 unauthorized",
        "missing bearer",
        "missing token data",
        "no local auth available",
        "auth_manager_missing",
        "failed to load chatgpt credentials",
        "access token could not be refreshed",
        "token data is not available",
        "local auth is not a chatgpt login",
    ]

    return patterns.contains { normalized.contains($0) }
}

package func reviewAuthDisplayMessage(
    from message: String?
) -> String? {
    guard reviewRequiresAuthentication(from: message) else {
        return message
    }
    return "Authentication required. Sign in to ReviewMCP and retry."
}
