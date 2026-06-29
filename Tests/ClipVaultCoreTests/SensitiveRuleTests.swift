import Testing
@testable import ClipVaultCore

@Suite("Sensitive item exclusion")
struct SensitiveRuleTests {
    @Test("rejects private keys and common API tokens before storage")
    func rejectsSecrets() {
        let classifier = SensitiveRuleEngine.default

        #expect(classifier.classify("-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----").isExcluded)
        #expect(classifier.classify("OPENAI_API_KEY=sk-proj-1234567890abcdef1234567890abcdef").isExcluded)
        #expect(classifier.classify("github_pat_11ABCDEFG0123456789012345678901234567890").isExcluded)
    }

    @Test("keeps useful developer snippets that only look technical")
    func keepsHarmlessSnippets() {
        let classifier = SensitiveRuleEngine.default

        #expect(!classifier.classify("SELECT id, email FROM users WHERE created_at > now() - interval '7 days';").isExcluded)
        #expect(!classifier.classify("Error: connection refused on localhost:5432 while running tests").isExcluded)
        #expect(!classifier.classify("https://developer.apple.com/documentation/swiftdata").isExcluded)
    }
}
