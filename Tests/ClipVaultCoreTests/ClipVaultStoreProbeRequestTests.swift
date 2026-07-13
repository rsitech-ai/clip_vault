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

    @Test("parses one explicit generated-prompt source token")
    func parsesGeneratedPromptSourceRequest() {
        let request = ClipVaultStoreProbeRequest.parse(
            arguments: ["ClipVault", "--verify-generated-prompt-source", "source token"]
        )

        #expect(request == ClipVaultStoreProbeRequest(
            mode: .generatedPromptSource,
            token: "source token"
        ))
    }

    @Test("reports exact generated-prompt associations for one stored source")
    func reportsGeneratedPromptSourceAssociations() {
        let source = Clip(
            id: "source-1",
            kind: .text,
            title: "Source",
            preview: "source token",
            extractedText: "source token"
        )
        let associated = Clip(
            id: "prompt-1",
            kind: .text,
            title: "Enhanced Source",
            preview: "enhanced one",
            extractedText: "enhanced one",
            collectionIDs: [ClipCollection.prompts.id],
            sourceApp: "ClipVault AI",
            metadata: ["promptSourceClipID": source.id]
        )
        let unrelated = Clip(
            id: "prompt-2",
            kind: .text,
            title: "Enhanced Other",
            preview: "enhanced two",
            extractedText: "enhanced two",
            collectionIDs: [ClipCollection.prompts.id],
            sourceApp: "ClipVault AI",
            metadata: ["promptSourceClipID": "source-2"]
        )

        let result = ClipVaultGeneratedPromptProbeResult.inspect(
            sourceToken: "source token",
            clips: [source, associated, unrelated]
        )

        #expect(result.sourceRowCount == 1)
        #expect(result.generatedRowCount == 1)
        #expect(result.sourceID == "source-1")
        #expect(result.promptSourceClipIDs == ["source-1"])
        #expect(result.outputLine == "CLIPVAULT_GENERATED_PROMPT_PROBE source_row_count=1 generated_row_count=1 source_id=source-1 prompt_source_clip_ids=source-1")
        #expect(result.isExactSingleAssociation)

        let mismatch = ClipVaultGeneratedPromptProbeResult.inspect(
            sourceToken: "source token",
            clips: [source, unrelated]
        )
        #expect(!mismatch.isExactSingleAssociation)
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
