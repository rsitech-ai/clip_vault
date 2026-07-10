public struct CaptureConsentPolicy: Equatable, Sendable {
    public private(set) var hasConsent: Bool
    public private(set) var isCapturing: Bool
    public private(set) var isDisclosurePresented: Bool

    public init(hasPersistedConsent: Bool) {
        hasConsent = hasPersistedConsent
        isCapturing = hasPersistedConsent
        isDisclosurePresented = !hasPersistedConsent
    }

    public mutating func accept() {
        hasConsent = true
        isCapturing = true
        isDisclosurePresented = false
    }

    public mutating func decline() {
        isCapturing = false
        isDisclosurePresented = false
    }

    public mutating func requestResume() {
        guard hasConsent else {
            isCapturing = false
            isDisclosurePresented = true
            return
        }
        isCapturing = true
    }

    public mutating func pause() {
        isCapturing = false
    }

    public mutating func revoke() {
        hasConsent = false
        isCapturing = false
        isDisclosurePresented = false
    }
}
