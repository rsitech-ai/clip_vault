import Foundation

public struct ClipWorkspaceProjection: Sendable {
    public private(set) var sections: [ClipResultSection] = []
    public private(set) var generation = 0

    private var clipsByID: [String: Clip] = [:]
    private var sourceResults: [SearchResult] = []
    private var sourceClips: [Clip] = []
    private var referenceDay = Date.distantPast

    public init() {}

    public func clip(id: String?) -> Clip? {
        guard let id else {
            return nil
        }
        return clipsByID[id]
    }

    @discardableResult
    public mutating func refresh(
        results: [SearchResult],
        clips: [Clip],
        relativeTo referenceDate: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> Bool {
        let day = calendar.startOfDay(for: referenceDate)
        guard results != sourceResults || clips != sourceClips || day != referenceDay else {
            return false
        }

        sourceResults = results
        sourceClips = clips
        referenceDay = day
        clipsByID = Dictionary(clips.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        sections = ClipResultSection.group(
            results,
            relativeTo: referenceDate,
            calendar: calendar,
            locale: locale
        )
        generation += 1
        return true
    }
}
