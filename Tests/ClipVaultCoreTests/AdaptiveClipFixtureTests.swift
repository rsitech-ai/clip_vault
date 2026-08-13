import Foundation
import Testing
@testable import ClipVaultCore

@Suite("Adaptive clip fixture")
struct AdaptiveClipFixtureTests {
    @Test("580 visible results preserve identity and derive bounded presentation")
    func largeFixture() {
        let now = Date(timeIntervalSince1970: 1_786_579_200)
        let results = (0..<580).map { index in
            let clip = Clip(
                id: "clip-\(index)",
                createdAt: now.addingTimeInterval(TimeInterval(-index * 90)),
                updatedAt: now,
                kind: index.isMultiple(of: 5) ? .url : .text,
                title: index.isMultiple(of: 5)
                    ? "https://github.com/rsitech-ai/project-\(index)"
                    : "Clip \(index)",
                preview: "Preview content for clip \(index)",
                extractedText: ""
            )
            return SearchResult(clip: clip, score: Double(580 - index))
        }

        let sections = ClipResultSection.group(
            results,
            relativeTo: now
        )
        let presentations = results.map {
            ClipRowPresentation(clip: $0.clip)
        }

        #expect(sections.flatMap(\.results).map(\.id) == results.map(\.id))
        #expect(presentations.count == 580)
        #expect(
            presentations.allSatisfy {
                $0.accessibilitySummary.count < 380
            }
        )
    }
}
