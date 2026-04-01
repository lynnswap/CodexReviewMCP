import Foundation
import Testing
@testable import ReviewCore
@testable import ReviewJobs

@Suite
struct ReviewTargetTests {
    @Test func reviewTargetDecodesCurrentContractValues() throws {
        let uncommitted = try JSONDecoder().decode(ReviewTarget.self, from: Data(#"{"type":"uncommittedChanges"}"#.utf8))
        let branch = try JSONDecoder().decode(ReviewTarget.self, from: Data(#"{"type":"baseBranch","branch":"main"}"#.utf8))
        let commit = try JSONDecoder().decode(ReviewTarget.self, from: Data(#"{"type":"commit","sha":"abc123","title":"Title"}"#.utf8))
        let custom = try JSONDecoder().decode(ReviewTarget.self, from: Data(#"{"type":"custom","instructions":"Review this."}"#.utf8))

        #expect(uncommitted == .uncommittedChanges)
        #expect(branch == .baseBranch("main"))
        #expect(commit == .commit(sha: "abc123", title: "Title"))
        #expect(custom == .custom(instructions: "Review this."))
    }

    @Test func reviewTargetRejectsLegacyContractValues() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ReviewTarget.self, from: Data(#"{"type":"uncommitted"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ReviewTarget.self, from: Data(#"{"type":"branch","branch":"main"}"#.utf8))
        }
    }
}
