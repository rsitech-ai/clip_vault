#if CLIPVAULT_E2E_PROBE
import Foundation

public struct ClipVaultStoreProbeRequest: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case storedClip
        case generatedPromptBatch
        case resetE2EStore
    }

    public let mode: Mode
    public let tokens: [String]

    public init(token: String) {
        self.init(mode: .storedClip, tokens: [token])
    }

    public init(mode: Mode, tokens: [String]) {
        self.mode = mode
        self.tokens = tokens
    }

    public static func parse(arguments: [String]) -> Self? {
        guard arguments.count >= 2 else {
            return nil
        }

        if arguments[1] == "--reset-e2e-store" {
            guard arguments.count == 2 else {
                return nil
            }
            return Self(mode: .resetE2EStore, tokens: [])
        }

        guard arguments.count >= 3 else {
            return nil
        }

        let mode: Mode
        switch arguments[1] {
        case "--verify-stored-clip":
            guard arguments.count == 3 else {
                return nil
            }
            mode = .storedClip
        case "--verify-generated-prompt-batch":
            mode = .generatedPromptBatch
        default:
            return nil
        }

        let tokens = arguments.dropFirst(2).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard tokens.allSatisfy({ !$0.isEmpty }),
              Set(tokens).count == tokens.count else {
            return nil
        }
        return Self(mode: mode, tokens: tokens)
    }

    public static var e2eStoreURL: URL {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "missing-bundle-identifier"
        let runNamespace = bundleIdentifier.replacingOccurrences(
            of: "com.andrzej.ClipVault.e2e.",
            with: ""
        )
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipVault-E2E-\(runNamespace).store")
    }

    public static func resetE2EStoreFiles() throws {
        let fileManager = FileManager.default
        for url in [
            e2eStoreURL,
            URL(fileURLWithPath: e2eStoreURL.path + "-shm"),
            URL(fileURLWithPath: e2eStoreURL.path + "-wal"),
        ] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}

public struct ClipVaultGeneratedPromptBatchProbeResult: Equatable, Sendable {
    public let expectedTokenCount: Int
    public let resolvedSourceCount: Int
    public let generatedRowCount: Int
    public let associatedRowCount: Int
    public let missingAssociationCount: Int
    public let unexpectedAssociationCount: Int
    public let duplicateAssociationCount: Int
    public let missingExpectedOutputCount: Int
    public let expectedSourceIDs: [String]
    public let promptSourceClipIDs: [String]
    private let hasUniqueNonemptyTokens: Bool
    private let hasUniqueResolvedSources: Bool

    public var isExactBatch: Bool {
        hasUniqueNonemptyTokens
            && hasUniqueResolvedSources
            && resolvedSourceCount == expectedTokenCount
            && expectedSourceIDs.count == expectedTokenCount
            && generatedRowCount == expectedTokenCount
            && associatedRowCount == generatedRowCount
            && missingAssociationCount == 0
            && unexpectedAssociationCount == 0
            && duplicateAssociationCount == 0
            && missingExpectedOutputCount == 0
            && promptSourceClipIDs == expectedSourceIDs
    }

    public var outputLine: String {
        let renderedExpectedIDs = expectedSourceIDs.isEmpty
            ? "none"
            : expectedSourceIDs.joined(separator: ",")
        let renderedAssociations = promptSourceClipIDs.isEmpty
            ? "none"
            : promptSourceClipIDs.joined(separator: ",")
        return "CLIPVAULT_GENERATED_PROMPT_BATCH_PROBE expected_token_count=\(expectedTokenCount) resolved_source_count=\(resolvedSourceCount) generated_row_count=\(generatedRowCount) associated_row_count=\(associatedRowCount) missing_association_count=\(missingAssociationCount) unexpected_association_count=\(unexpectedAssociationCount) duplicate_association_count=\(duplicateAssociationCount) missing_expected_output_count=\(missingExpectedOutputCount) expected_source_ids=\(renderedExpectedIDs) prompt_source_clip_ids=\(renderedAssociations)"
    }

    public static func inspect(sourceTokens: [String], clips: [Clip]) -> Self {
        // Inventory the complete canonical generated set before resolving expected sources.
        // Filtering by an expected source ID here would make extra or malformed rows invisible.
        let generated = clips.filter(isCanonicalGeneratedPrompt)
        let normalizedTokens = sourceTokens.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let hasUniqueNonemptyTokens = normalizedTokens.allSatisfy { !$0.isEmpty }
            && Set(normalizedTokens).count == normalizedTokens.count

        let resolvedSources = normalizedTokens.compactMap { token -> Clip? in
            let matches = clips.filter { clip in
                !isCanonicalGeneratedPrompt(clip) && clip.preview == token
            }
            return matches.count == 1 ? matches[0] : nil
        }
        let expectedSourceIDs = resolvedSources.map(\.id).sorted()
        let expectedSourceIDSet = Set(expectedSourceIDs)
        let hasUniqueResolvedSources = expectedSourceIDSet.count == expectedSourceIDs.count

        let associations = generated.compactMap { clip -> String? in
            guard let sourceID = clip.metadata["promptSourceClipID"],
                  !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return sourceID
        }
        let associationCounts = Dictionary(grouping: associations, by: { $0 }).mapValues(\.count)
        let unexpectedAssociationCount = associations.count { !expectedSourceIDSet.contains($0) }
        let duplicateAssociationCount = associationCounts.values.reduce(0) { count, occurrenceCount in
            count + max(0, occurrenceCount - 1)
        }
        let missingExpectedOutputCount = expectedSourceIDs.count { associationCounts[$0] == nil }

        return Self(
            expectedTokenCount: normalizedTokens.count,
            resolvedSourceCount: resolvedSources.count,
            generatedRowCount: generated.count,
            associatedRowCount: associations.count,
            missingAssociationCount: generated.count - associations.count,
            unexpectedAssociationCount: unexpectedAssociationCount,
            duplicateAssociationCount: duplicateAssociationCount,
            missingExpectedOutputCount: missingExpectedOutputCount,
            expectedSourceIDs: expectedSourceIDs,
            promptSourceClipIDs: associations.sorted(),
            hasUniqueNonemptyTokens: hasUniqueNonemptyTokens,
            hasUniqueResolvedSources: hasUniqueResolvedSources
        )
    }

    private static func isCanonicalGeneratedPrompt(_ clip: Clip) -> Bool {
        clip.sourceApp == "ClipVault AI"
            && clip.collectionIDs.contains(ClipCollection.prompts.id)
    }
}
#endif
