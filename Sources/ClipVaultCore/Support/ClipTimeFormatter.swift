import Foundation

public enum ClipTimeFormatter {
    public static func relativeLabel(
        for date: Date,
        relativeTo referenceDate: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let seconds = max(0, Int(referenceDate.timeIntervalSince(date)))

        guard seconds >= 60 else {
            return "Just now"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return minutes == 1 ? "1 min ago" : "\(minutes) min ago"
        }

        let hours = minutes / 60
        if hours < 24 {
            return hours == 1 ? "1 hr ago" : "\(hours) hr ago"
        }

        let dayCount = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: referenceDate)
        ).day ?? (seconds / 86_400)

        if dayCount == 1 {
            return "Yesterday"
        }

        if dayCount < 7 {
            return "\(max(dayCount, 1)) days ago"
        }

        return absoluteLabel(for: date)
    }

    public static func absoluteLabel(for date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
