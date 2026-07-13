import Foundation
import Testing
@testable import ClipVaultCore

@Suite("Clip move payload")
struct ClipMovePayloadTests {
    @Test("payload round-trips only the trimmed clip identifier")
    func payloadRoundTrips() throws {
        let payload = try #require(ClipMovePayload(clipID: "  clip-123  \n"))
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ClipMovePayload.self, from: data)

        #expect(payload.clipID == "clip-123")
        #expect(decoded == payload)
        #expect(String(decoding: data, as: UTF8.self) == #"{"clipID":"clip-123"}"#)
        #expect(ClipMovePayload.contentType.identifier == "com.andrzej.ClipVault.clip-move")

        let paddedData = Data(#"{"clipID":"  clip-123  "}"#.utf8)
        #expect(try JSONDecoder().decode(ClipMovePayload.self, from: paddedData) == payload)
    }

    @Test("payload accepts identifiers at the byte limits")
    func acceptsBoundaryIdentifiers() {
        #expect(ClipMovePayload(clipID: "a")?.clipID == "a")
        #expect(ClipMovePayload(clipID: String(repeating: "a", count: 128)) != nil)
        #expect(ClipMovePayload(clipID: "AZaz09-_.") != nil)
    }

    @Test("payload rejects empty, oversized, and non-ASCII identifiers")
    func rejectsMalformedIdentifiers() {
        #expect(ClipMovePayload(clipID: "") == nil)
        #expect(ClipMovePayload(clipID: " \t\n ") == nil)
        #expect(ClipMovePayload(clipID: String(repeating: "a", count: 129)) == nil)
        #expect(ClipMovePayload(clipID: "clip/../../secret") == nil)
        #expect(ClipMovePayload(clipID: "clip-ą") == nil)
    }

    @Test(
        "decoding rejects malformed clip identifiers",
        arguments: [
            #"{"clipID":"   "}"#,
            #"{"clipID":"clip/../../secret"}"#,
            #"{"clipID":"clip-ą"}"#,
            #"{"clipID":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#,
        ]
    )
    func decodingRejectsMalformedIdentifier(json: String) {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ClipMovePayload.self, from: Data(json.utf8))
        }
    }
}
