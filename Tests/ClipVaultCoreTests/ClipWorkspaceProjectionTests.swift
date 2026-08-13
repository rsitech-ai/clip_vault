import Foundation
import Testing
@testable import ClipVaultCore

@Suite("Clip workspace projection")
struct ClipWorkspaceProjectionTests {
    @Test("selection lookup is indexed and unchanged inputs preserve sections")
    func indexedLookupAndStableSections() throws {
        let now = Date(timeIntervalSince1970: 1_786_579_200)
        let clips = (0..<585).map { index in
            makeClip(id: "clip-\(index)", createdAt: now)
        }
        let results = clips.map { SearchResult(clip: $0, score: 1) }
        var projection = ClipWorkspaceProjection()

        let didRefresh = projection.refresh(results: results, clips: clips, relativeTo: now)
        #expect(didRefresh)
        let initialGeneration = projection.generation
        #expect(try #require(projection.clip(id: "clip-584")).id == "clip-584")
        let unchangedRefresh = projection.refresh(results: results, clips: clips, relativeTo: now)
        #expect(!unchangedRefresh)
        #expect(projection.generation == initialGeneration)
        #expect(projection.sections.flatMap(\.results).map(\.id) == results.map(\.id))
    }

    @Test("a calendar day change refreshes relative section labels")
    func dayBoundaryRefreshesSections() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let clipDate = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 13, hour: 12)
        ))
        let nextDay = try #require(calendar.date(byAdding: .day, value: 1, to: clipDate))
        let clip = makeClip(id: "day-boundary", createdAt: clipDate)
        let results = [SearchResult(clip: clip, score: 1)]
        var projection = ClipWorkspaceProjection()

        let initialRefresh = projection.refresh(
            results: results,
            clips: [clip],
            relativeTo: clipDate,
            calendar: calendar
        )
        #expect(initialRefresh)
        #expect(projection.sections.map(\.title) == ["Today"])
        let nextDayRefresh = projection.refresh(
            results: results,
            clips: [clip],
            relativeTo: nextDay,
            calendar: calendar
        )
        #expect(nextDayRefresh)
        #expect(projection.sections.map(\.title) == ["Yesterday"])
    }

    @Test("changed clip content refreshes lookup and sections")
    func changedClipRefreshesProjection() throws {
        let now = Date(timeIntervalSince1970: 1_786_579_200)
        let original = makeClip(id: "clip", createdAt: now)
        var updated = original
        updated.title = "Updated"
        updated.updatedAt = now.addingTimeInterval(1)
        var projection = ClipWorkspaceProjection()

        let initialRefresh = projection.refresh(
            results: [SearchResult(clip: original, score: 1)],
            clips: [original],
            relativeTo: now
        )
        #expect(initialRefresh)
        let updatedRefresh = projection.refresh(
            results: [SearchResult(clip: updated, score: 1)],
            clips: [updated],
            relativeTo: now
        )
        #expect(updatedRefresh)
        #expect(try #require(projection.clip(id: "clip")).title == "Updated")
    }

    private func makeClip(id: String, createdAt: Date) -> Clip {
        Clip(
            id: id,
            createdAt: createdAt,
            updatedAt: createdAt,
            kind: .text,
            title: id,
            preview: id,
            extractedText: id
        )
    }
}
