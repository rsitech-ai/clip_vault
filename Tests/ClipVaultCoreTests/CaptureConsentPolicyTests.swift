import ClipVaultCore
import Testing

@Suite("Clipboard capture consent policy")
struct CaptureConsentPolicyTests {
    @Test("First launch pauses capture and presents disclosure")
    func firstLaunchRequiresConsent() {
        let policy = CaptureConsentPolicy(hasPersistedConsent: false)

        #expect(policy.hasConsent == false)
        #expect(policy.isCapturing == false)
        #expect(policy.isDisclosurePresented == true)
    }

    @Test("Accepting disclosure grants consent and starts capture")
    func acceptingStartsCapture() {
        var policy = CaptureConsentPolicy(hasPersistedConsent: false)

        policy.accept()

        #expect(policy.hasConsent == true)
        #expect(policy.isCapturing == true)
        #expect(policy.isDisclosurePresented == false)
    }

    @Test("Declining stays paused and a later resume request presents disclosure again")
    func declineDoesNotAuthorizeResume() {
        var policy = CaptureConsentPolicy(hasPersistedConsent: false)

        policy.decline()
        #expect(policy.isCapturing == false)
        #expect(policy.isDisclosurePresented == false)

        policy.requestResume()

        #expect(policy.hasConsent == false)
        #expect(policy.isCapturing == false)
        #expect(policy.isDisclosurePresented == true)
    }

    @Test("Persisted consent resumes capture on relaunch")
    func persistedConsentStartsCapture() {
        let policy = CaptureConsentPolicy(hasPersistedConsent: true)

        #expect(policy.hasConsent == true)
        #expect(policy.isCapturing == true)
        #expect(policy.isDisclosurePresented == false)
    }

    @Test("Revoking consent stops capture and future resume requires disclosure")
    func revokeStopsAndRegatesCapture() {
        var policy = CaptureConsentPolicy(hasPersistedConsent: true)

        policy.revoke()
        policy.requestResume()

        #expect(policy.hasConsent == false)
        #expect(policy.isCapturing == false)
        #expect(policy.isDisclosurePresented == true)
    }
}
