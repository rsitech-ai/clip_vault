import Foundation

enum ClipVaultSettingsKey {
    static let ordinaryClipRetentionDays = "ordinaryClipRetentionDays"
    static let cloudAIEnabled = "cloudAIEnabled"
    static let dockBadgeEnabled = "dockBadgeEnabled"
    static let dockAnimationEnabled = "dockAnimationEnabled"
    static let dockKindBarsEnabled = "dockKindBarsEnabled"
    static let dockRecentClipLimit = "dockRecentClipLimit"
}

enum ClipVaultSettingsDefault {
    static let ordinaryClipRetentionDays = 30
    static let cloudAIEnabled = false
    static let dockBadgeEnabled = true
    static let dockAnimationEnabled = true
    static let dockKindBarsEnabled = true
    static let dockRecentClipLimit = 6
}

extension UserDefaults {
    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        object(forKey: key) as? Bool ?? defaultValue
    }

    func integer(forKey key: String, default defaultValue: Int) -> Int {
        object(forKey: key) as? Int ?? defaultValue
    }
}
