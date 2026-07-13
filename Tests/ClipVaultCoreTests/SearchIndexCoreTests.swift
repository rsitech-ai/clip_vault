import Testing
@testable import ClipVaultCore

@Suite("Rust search index core")
struct SearchIndexCoreTests {
    @Test("normalizes whitespace and case for deduplication")
    func normalizesText() {
        let index = RustSearchIndexCore()

        #expect(index.normalizedText("  SELECT  *\nFROM Users  ") == "select * from users")
        #expect(index.fingerprint("Hello   World") == index.fingerprint(" hello world "))
    }

    @Test("scores lexical matches above unrelated text")
    func scoresLexicalMatches() {
        let index = RustSearchIndexCore()

        let sqlScore = index.lexicalScore(query: "copied sql last week", text: "SELECT id FROM users WHERE active = true")
        let unrelatedScore = index.lexicalScore(query: "copied sql last week", text: "Meeting notes about launch copy")

        #expect(sqlScore > unrelatedScore)
        #expect(sqlScore > 0)
    }

    @Test("nonmatching queries exclude recent and pinned clips")
    func nonmatchingQueriesExcludeBoostedClips() {
        let recent = Clip(
            kind: .text,
            title: "Recent meeting notes",
            preview: "Launch discussion",
            extractedText: "Launch discussion"
        )
        let pinned = Clip(
            kind: .text,
            title: "Pinned roadmap",
            preview: "Quarterly roadmap",
            extractedText: "Quarterly roadmap",
            isPinned: true
        )

        let results = ClipSearcher().search(
            [recent, pinned],
            query: SearchQuery(text: "zzqxywplmnoabc")
        )

        #expect(results.isEmpty)
    }

    @Test("multi-term search keeps strong matches and excludes incidental overlap")
    func multiTermSearchUsesAUsefulRelevanceFloor() throws {
        let exact = Clip(
            kind: .text,
            title: "Resizable and responsive workspace",
            preview: "A resizable responsive layout",
            extractedText: "The workspace is resizable and responsive at every window size."
        )
        let partial = Clip(
            kind: .text,
            title: "Resizable inspector",
            preview: "Resize the inspector",
            extractedText: "The inspector is resizable."
        )
        let unrelated = Clip(
            kind: .text,
            title: "Remaining gaps and risks",
            preview: "This is a follow-up review",
            extractedText: "This is a review of release risks and remaining work."
        )

        let results = ClipSearcher().search(
            [unrelated, partial, exact],
            query: SearchQuery(text: "Resizable + responsive")
        )

        #expect(try #require(results.first).clip.id == exact.id)
        #expect(results.contains { $0.clip.id == partial.id })
        #expect(!results.contains { $0.clip.id == unrelated.id })
    }
}
