import Foundation

public struct ClipResultSection: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var results: [SearchResult]

    public static func group(
        _ results: [SearchResult],
        relativeTo referenceDate: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> [ClipResultSection] {
        var sections: [ClipResultSection] = []
        let weekdayFormatter = formatter(
            format: "EEEE",
            calendar: calendar,
            locale: locale
        )
        let datedFormatter = formatter(
            format: "MMM d, yyyy",
            calendar: calendar,
            locale: locale
        )

        for result in results {
            let label = sectionLabel(
                for: result.clip.createdAt,
                relativeTo: referenceDate,
                calendar: calendar,
                weekdayFormatter: weekdayFormatter,
                datedFormatter: datedFormatter
            )

            if sections.last?.title == label {
                sections[sections.count - 1].results.append(result)
            } else {
                sections.append(ClipResultSection(
                    id: "\(label)-\(result.id)",
                    title: label,
                    results: [result]
                ))
            }
        }

        return sections
    }

    private static func sectionLabel(
        for date: Date,
        relativeTo referenceDate: Date,
        calendar: Calendar,
        weekdayFormatter: DateFormatter,
        datedFormatter: DateFormatter
    ) -> String {
        let dateStart = calendar.startOfDay(for: date)
        let referenceStart = calendar.startOfDay(for: referenceDate)

        if dateStart == referenceStart {
            return "Today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: referenceStart),
           dateStart == yesterday {
            return "Yesterday"
        }
        if let week = calendar.dateInterval(of: .weekOfYear, for: referenceDate),
           week.contains(date) {
            return weekdayFormatter.string(from: date)
        }
        return datedFormatter.string(from: date)
    }

    private static func formatter(
        format: String,
        calendar: Calendar,
        locale: Locale
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }
}
