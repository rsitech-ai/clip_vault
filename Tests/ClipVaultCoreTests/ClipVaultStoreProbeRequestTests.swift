#if CLIPVAULT_E2E_PROBE
import Testing
@testable import ClipVaultCore

@Suite("Store probe launch request")
struct ClipVaultStoreProbeRequestTests {
    @Test("parses one explicit nonempty stored-clip token")
    func parsesValidStoredClipRequest() {
        let request = ClipVaultStoreProbeRequest.parse(
            arguments: ["ClipVault", "--verify-stored-clip", "probe token"]
        )

        #expect(request == ClipVaultStoreProbeRequest(token: "probe token"))
    }

    @Test("parses an explicit multi-source generated-prompt batch")
    func parsesGeneratedPromptBatchRequest() {
        let request = ClipVaultStoreProbeRequest.parse(
            arguments: [
                "ClipVault",
                "--verify-generated-prompt-batch",
                "source one",
                "source two",
            ]
        )

        #expect(request == ClipVaultStoreProbeRequest(
            mode: .generatedPromptBatch,
            tokens: ["source one", "source two"]
        ))
    }

    @Test("accepts only an exact multi-source generated-prompt batch")
    func reportsExactGeneratedPromptBatch() {
        let sourceOne = source(id: "source-1", token: "source one")
        let sourceTwo = source(id: "source-2", token: "source two")
        let result = ClipVaultGeneratedPromptBatchProbeResult.inspect(
            sourceTokens: ["source one", "source two"],
            clips: [
                sourceOne,
                sourceTwo,
                generated(id: "prompt-2", association: sourceTwo.id),
                generated(id: "prompt-1", association: sourceOne.id),
            ]
        )

        #expect(result.expectedTokenCount == 2)
        #expect(result.resolvedSourceCount == 2)
        #expect(result.generatedRowCount == 2)
        #expect(result.associatedRowCount == 2)
        #expect(result.missingAssociationCount == 0)
        #expect(result.unexpectedAssociationCount == 0)
        #expect(result.duplicateAssociationCount == 0)
        #expect(result.missingExpectedOutputCount == 0)
        #expect(result.expectedSourceIDs == ["source-1", "source-2"])
        #expect(result.promptSourceClipIDs == ["source-1", "source-2"])
        #expect(result.isExactBatch)
        #expect(result.outputLine == "CLIPVAULT_GENERATED_PROMPT_BATCH_PROBE expected_token_count=2 resolved_source_count=2 generated_row_count=2 associated_row_count=2 missing_association_count=0 unexpected_association_count=0 duplicate_association_count=0 missing_expected_output_count=0 expected_source_ids=source-1,source-2 prompt_source_clip_ids=source-1,source-2")
    }

    @Test("rejects a batch containing one good row and one missing association")
    func rejectsMissingAssociationInCombinedBatch() {
        let clips = twoSources + [
            generated(id: "prompt-1", association: "source-1"),
            generated(id: "prompt-2", association: nil),
        ]
        let result = inspectTwoSourceBatch(clips)

        #expect(result.missingAssociationCount == 1)
        #expect(result.missingExpectedOutputCount == 1)
        #expect(!result.isExactBatch)
    }

    @Test("rejects a batch containing one good row and one mismatched association")
    func rejectsMismatchInCombinedBatch() {
        let clips = twoSources + [
            generated(id: "prompt-1", association: "source-1"),
            generated(id: "prompt-2", association: "source-3"),
        ]
        let result = inspectTwoSourceBatch(clips)

        #expect(result.unexpectedAssociationCount == 1)
        #expect(result.missingExpectedOutputCount == 1)
        #expect(!result.isExactBatch)
    }

    @Test("rejects an orphan generated association")
    func rejectsOrphanAssociation() {
        let result = ClipVaultGeneratedPromptBatchProbeResult.inspect(
            sourceTokens: ["source one"],
            clips: [
                source(id: "source-1", token: "source one"),
                generated(id: "prompt-1", association: "orphan-source"),
            ]
        )

        #expect(result.unexpectedAssociationCount == 1)
        #expect(!result.isExactBatch)
    }

    @Test("rejects duplicate outputs for one expected source")
    func rejectsDuplicateOutput() {
        let result = ClipVaultGeneratedPromptBatchProbeResult.inspect(
            sourceTokens: ["source one"],
            clips: [
                source(id: "source-1", token: "source one"),
                generated(id: "prompt-1", association: "source-1"),
                generated(id: "prompt-2", association: "source-1"),
            ]
        )

        #expect(result.duplicateAssociationCount == 1)
        #expect(!result.isExactBatch)
    }

    @Test("rejects an expected source token that is absent")
    func rejectsMissingSource() {
        let result = ClipVaultGeneratedPromptBatchProbeResult.inspect(
            sourceTokens: ["source one", "missing source"],
            clips: [
                source(id: "source-1", token: "source one"),
                generated(id: "prompt-1", association: "source-1"),
            ]
        )

        #expect(result.resolvedSourceCount == 1)
        #expect(!result.isExactBatch)
    }

    @Test("rejects ordinary, malformed, and ambiguous launches")
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
        #expect(ClipVaultStoreProbeRequest.parse(
            arguments: ["ClipVault", "--verify-generated-prompt-batch"]
        ) == nil)
        #expect(ClipVaultStoreProbeRequest.parse(
            arguments: ["ClipVault", "--verify-generated-prompt-batch", "token", " "]
        ) == nil)
        #expect(ClipVaultStoreProbeRequest.parse(
            arguments: ["ClipVault", "--verify-generated-prompt-batch", "token", "token"]
        ) == nil)
    }

    private var twoSources: [Clip] {
        [
            source(id: "source-1", token: "source one"),
            source(id: "source-2", token: "source two"),
        ]
    }

    private func inspectTwoSourceBatch(_ clips: [Clip]) -> ClipVaultGeneratedPromptBatchProbeResult {
        ClipVaultGeneratedPromptBatchProbeResult.inspect(
            sourceTokens: ["source one", "source two"],
            clips: clips
        )
    }

    private func source(id: String, token: String) -> Clip {
        Clip(
            id: id,
            kind: .text,
            title: "Source",
            preview: token,
            extractedText: token
        )
    }

    private func generated(id: String, association: String?) -> Clip {
        var metadata: [String: String] = [:]
        if let association {
            metadata["promptSourceClipID"] = association
        }
        return Clip(
            id: id,
            kind: .text,
            title: "Enhanced Source",
            preview: "synthetic generated prompt",
            extractedText: "synthetic generated prompt",
            collectionIDs: [ClipCollection.prompts.id],
            sourceApp: "ClipVault AI",
            metadata: metadata
        )
    }
}
#endif
