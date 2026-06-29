import Foundation
import Testing
@testable import ClipVaultCore

@Suite("Retention policy")
struct RetentionPolicyTests {
    @Test("ordinary clips expire after the configured window")
    func ordinaryClipsExpire() {
        let policy = RetentionPolicy.default
        let now = Date(timeIntervalSince1970: 1_800_000)
        let oldClip = Clip.makeForTests(createdAt: now.addingTimeInterval(-31 * 24 * 60 * 60))
        let recentClip = Clip.makeForTests(createdAt: now.addingTimeInterval(-2 * 24 * 60 * 60))

        #expect(policy.shouldExpire(oldClip, now: now))
        #expect(!policy.shouldExpire(recentClip, now: now))
    }

    @Test("pinned and board clips do not expire automatically")
    func retainedClipsStay() {
        let policy = RetentionPolicy.default
        let now = Date(timeIntervalSince1970: 1_800_000)
        let pinned = Clip.makeForTests(createdAt: now.addingTimeInterval(-120 * 24 * 60 * 60), isPinned: true)
        let board = Clip.makeForTests(createdAt: now.addingTimeInterval(-120 * 24 * 60 * 60), pinboardIDs: ["research"])

        #expect(!policy.shouldExpire(pinned, now: now))
        #expect(!policy.shouldExpire(board, now: now))
    }
}
