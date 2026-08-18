import Foundation
import Testing
@testable import ClipVaultCore

@Suite("Clip time formatter")
struct ClipTimeFormatterTests {
    @Test("relative labels never show seconds")
    func relativeLabelsDoNotShowSeconds() {
        let referenceDate = Date(timeIntervalSinceReferenceDate: 10_000)
        let labels = [
            ClipTimeFormatter.relativeLabel(for: referenceDate.addingTimeInterval(-5), relativeTo: referenceDate),
            ClipTimeFormatter.relativeLabel(for: referenceDate.addingTimeInterval(-65), relativeTo: referenceDate),
            ClipTimeFormatter.relativeLabel(for: referenceDate.addingTimeInterval(-3_900), relativeTo: referenceDate)
        ]

        #expect(labels == ["Just now", "1 min ago", "1 hr ago"])
        #expect(labels.allSatisfy { !$0.localizedCaseInsensitiveContains("sec") })
    }

    @Test("older relative labels stay compact")
    func olderRelativeLabelsStayCompact() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ClipTimeFormatter.relativeLabel(
            for: referenceDate.addingTimeInterval(-2 * 86_400),
            relativeTo: referenceDate,
            calendar: calendar
        ) == "2 days ago")
    }

    @Test("list row labels stay time-only under dated section headers")
    func listRowLabelsStayTimeOnly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_GB")
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 18,
            hour: 11,
            minute: 54
        ))!

        #expect(ClipTimeFormatter.listRowLabel(
            for: now.addingTimeInterval(-5),
            relativeTo: now,
            calendar: calendar,
            locale: locale
        ) == "Just now")

        let today = ClipTimeFormatter.listRowLabel(
            for: now.addingTimeInterval(-3_600),
            relativeTo: now,
            calendar: calendar,
            locale: locale
        )
        #expect(today == "10:54")

        let older = ClipTimeFormatter.listRowLabel(
            for: now.addingTimeInterval(-28 * 86_400),
            relativeTo: now,
            calendar: calendar,
            locale: locale
        )
        #expect(older == "11:54")
        #expect(!older.contains("2026"))
        #expect(!older.localizedCaseInsensitiveContains("jul"))
        #expect(!older.localizedCaseInsensitiveContains(" at "))
    }
}
