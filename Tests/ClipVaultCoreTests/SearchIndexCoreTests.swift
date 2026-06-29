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
}
