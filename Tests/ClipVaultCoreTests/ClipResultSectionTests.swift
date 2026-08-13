import Foundation
import Testing
@testable import ClipVaultCore

@Suite("Clip result sections")
struct ClipResultSectionTests {
    @Test("Sections label calendar periods and preserve result order")
    func calendarSectionsPreserveOrder() {
        let calendar = utcCalendar()
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 13,
            hour: 12
        ))!
        let results = [
            result("today-a", now.addingTimeInterval(-60)),
            result("today-b", now.addingTimeInterval(-3_600)),
            result("yesterday", now.addingTimeInterval(-86_400)),
            result("weekday", now.addingTimeInterval(-2 * 86_400)),
            result("older", now.addingTimeInterval(-8 * 86_400))
        ]

        let sections = ClipResultSection.group(
            results,
            relativeTo: now,
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )

        #expect(sections[0].title == "Today")
        #expect(sections[0].results.map(\.id) == ["today-a", "today-b"])
        #expect(sections[1].title == "Yesterday")
        #expect(sections[2].title == "Tuesday")
        #expect(sections[3].title == "Aug 5, 2026")
        #expect(sections.flatMap(\.results).map(\.id) == results.map(\.id))
    }

    @Test("Empty input produces no sections")
    func emptyInput() {
        #expect(ClipResultSection.group([]).isEmpty)
    }

    @Test("Noncontiguous identical labels never reorder results")
    func noncontiguousLabelsRemainSeparate() {
        let calendar = utcCalendar()
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 13,
            hour: 12
        ))!
        let results = [
            result("today-a", now),
            result("yesterday", now.addingTimeInterval(-86_400)),
            result("today-b", now.addingTimeInterval(-60))
        ]

        let sections = ClipResultSection.group(
            results,
            relativeTo: now,
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )

        #expect(sections.map(\.title) == ["Today", "Yesterday", "Today"])
        #expect(sections.flatMap(\.results).map(\.id) == results.map(\.id))
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        return calendar
    }

    private func result(_ id: String, _ date: Date) -> SearchResult {
        SearchResult(
            clip: Clip(
                id: id,
                createdAt: date,
                updatedAt: date,
                kind: .text,
                title: id,
                preview: id,
                extractedText: id
            ),
            score: 0
        )
    }
}
