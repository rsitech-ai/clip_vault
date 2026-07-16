import Foundation
import Testing
@testable import ClipVaultCore

@Suite("Rust search index core")
struct SearchIndexCoreTests {
    @Test("search projection recomputes only when its source inputs change")
    func searchProjectionCachesWorkspaceAndMenuResults() {
        let code = Clip(
            id: "code-clip",
            kind: .code,
            title: "Code",
            preview: "let answer = 42",
            extractedText: "let answer = 42",
            collectionIDs: ["code"]
        )
        let image = Clip(
            id: "image-clip",
            kind: .image,
            title: "Image",
            preview: "diagram",
            extractedText: "diagram",
            collectionIDs: ["images"]
        )
        let searcher = CountingClipSearcher()
        var projection = ClipSearchProjection(searcher: searcher)

        projection.refreshAll(
            clips: [code, image],
            searchText: "",
            workspaceCollectionID: "code"
        )

        #expect(searcher.callCount == 2)
        #expect(projection.workspaceResults.map(\.id) == [code.id])
        #expect(projection.menuBarResults.map(\.id) == [code.id, image.id])

        for _ in 0..<50 {
            _ = projection.workspaceResults
            _ = projection.menuBarResults
        }
        #expect(searcher.callCount == 2)

        projection.refreshWorkspace(
            clips: [code, image],
            searchText: "",
            workspaceCollectionID: "images"
        )
        #expect(searcher.callCount == 3)
        #expect(projection.workspaceResults.map(\.id) == [image.id])
        #expect(projection.menuBarResults.map(\.id) == [code.id, image.id])
    }

    @Test("all-clips workspace reuses the menu projection")
    func allClipsWorkspaceReusesMenuProjection() {
        let clip = Clip(
            id: "all-clips-fixture",
            kind: .text,
            title: "Fixture",
            preview: "Fixture",
            extractedText: "Fixture"
        )
        let searcher = CountingClipSearcher()
        var projection = ClipSearchProjection(searcher: searcher)

        projection.refreshAll(
            clips: [clip],
            searchText: "",
            workspaceCollectionID: "all"
        )

        #expect(searcher.callCount == 1)
        #expect(projection.workspaceResults == projection.menuBarResults)
    }

    @Test("search projection refreshes time-dependent ranking on a bounded interval")
    func searchProjectionRefreshesExpiredRanking() {
        let clip = Clip(
            id: "ranking-fixture",
            kind: .text,
            title: "Fixture",
            preview: "Fixture",
            extractedText: "Fixture"
        )
        let searcher = CountingClipSearcher()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var projection = ClipSearchProjection(searcher: searcher)

        projection.refreshAll(
            clips: [clip],
            searchText: "",
            workspaceCollectionID: "all",
            now: startedAt
        )

        #expect(searcher.callCount == 1)
        let refreshedBeforeExpiry = projection.refreshIfExpired(
            clips: [clip],
            searchText: "",
            workspaceCollectionID: "all",
            now: startedAt.addingTimeInterval(299)
        )
        #expect(!refreshedBeforeExpiry)
        #expect(searcher.callCount == 1)
        let refreshedAtExpiry = projection.refreshIfExpired(
            clips: [clip],
            searchText: "",
            workspaceCollectionID: "all",
            now: startedAt.addingTimeInterval(300)
        )
        #expect(refreshedAtExpiry)
        #expect(searcher.callCount == 2)
    }

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

private final class CountingClipSearcher: ClipSearching, @unchecked Sendable {
    private(set) var callCount = 0

    func search(_ clips: [Clip], query: SearchQuery) -> [SearchResult] {
        callCount += 1
        return clips.compactMap { clip in
            guard query.collectionID.map(clip.collectionIDs.contains) ?? true else {
                return nil
            }
            return SearchResult(clip: clip, score: 1)
        }
    }
}
