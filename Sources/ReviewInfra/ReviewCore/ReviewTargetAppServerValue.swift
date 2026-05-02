import MCP
import ReviewDomain

extension ReviewTarget {
    package func appServerValue() -> Value {
        switch self {
        case .uncommittedChanges:
            return [
                "type": .string("uncommittedChanges"),
            ]
        case .baseBranch(let branch):
            return [
                "type": .string("baseBranch"),
                "branch": .string(branch),
            ]
        case .commit(let sha, let title):
            var object: [String: Value] = [
                "type": .string("commit"),
                "sha": .string(sha),
            ]
            if let title {
                object["title"] = .string(title)
            }
            return .object(object)
        case .custom(let instructions):
            return [
                "type": .string("custom"),
                "instructions": .string(instructions),
            ]
        }
    }
}
