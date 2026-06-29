import Foundation

public struct RetentionPolicy: Codable, Hashable, Sendable {
    public var ordinaryClipLifetimeDays: Int

    public init(ordinaryClipLifetimeDays: Int = 30) {
        self.ordinaryClipLifetimeDays = ordinaryClipLifetimeDays
    }

    public static let `default` = RetentionPolicy()

    public func shouldExpire(_ clip: Clip, now: Date = Date()) -> Bool {
        guard !clip.isPinned, clip.pinboardIDs.isEmpty else {
            return false
        }

        let lifetime = TimeInterval(ordinaryClipLifetimeDays * 24 * 60 * 60)
        return now.timeIntervalSince(clip.createdAt) > lifetime
    }
}
