#if CLIPVAULT_E2E_PROBE
import Testing
@testable import ClipVaultCore

@Suite("Store probe launch request")
struct ClipVaultStoreProbeRequestTests {
    @Test("parses one explicit nonempty probe token")
    func parsesValidRequest() {
        let request = ClipVaultStoreProbeRequest.parse(
            arguments: ["ClipVault", "--verify-stored-clip", "probe token"]
        )

        #expect(request == ClipVaultStoreProbeRequest(token: "probe token"))
    }

    @Test("rejects ordinary and malformed launches")
    func rejectsInvalidRequests() {
        #expect(ClipVaultStoreProbeRequest.parse(arguments: ["ClipVault"]) == nil)
        #expect(ClipVaultStoreProbeRequest.parse(
            arguments: ["ClipVault", "--verify-stored-clip"]
        ) == nil)
        #expect(ClipVaultStoreProbeRequest.parse(
            arguments: ["ClipVault", "--verify-stored-clip", "   "]
        ) == nil)
        #expect(ClipVaultStoreProbeRequest.parse(
            arguments: ["ClipVault", "--verify-stored-clip", "token", "extra"]
        ) == nil)
    }
}
#endif
