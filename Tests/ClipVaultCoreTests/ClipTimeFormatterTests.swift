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

    @Test("sponsor URL is fixed")
    func sponsorURLIsFixed() {
        #expect(ClipVaultSupport.buyMeACoffeeURL.scheme == "https")
        #expect(ClipVaultSupport.buyMeACoffeeURL.host == "www.buymeacoffee.com")
        #expect(ClipVaultSupport.buyMeACoffeeURL.path == "/s1korrrr")
    }
}
