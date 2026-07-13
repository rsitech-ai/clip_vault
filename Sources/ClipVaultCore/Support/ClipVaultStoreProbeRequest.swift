#if CLIPVAULT_E2E_PROBE
import Foundation

public struct ClipVaultStoreProbeRequest: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case storedClip
        case generatedPromptSource
    }

    public let mode: Mode
    public let token: String

    public init(token: String) {
        self.init(mode: .storedClip, token: token)
    }

    public init(mode: Mode, token: String) {
        self.mode = mode
        self.token = token
    }

    public static func parse(arguments: [String]) -> Self? {
        guard arguments.count == 3 else {
            return nil
        }

        let mode: Mode
        switch arguments[1] {
        case "--verify-stored-clip":
            mode = .storedClip
        case "--verify-generated-prompt-source":
            mode = .generatedPromptSource
        default:
            return nil
        }

        let token = arguments[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return nil
        }
        return Self(mode: mode, token: token)
    }
}

public struct ClipVaultGeneratedPromptProbeResult: Equatable, Sendable {
    public let sourceRowCount: Int
    public let generatedRowCount: Int
    public let sourceID: String?
    public let promptSourceClipIDs: [String]

    public var isExactSingleAssociation: Bool {
        guard sourceRowCount == 1,
              generatedRowCount == 1,
              let sourceID else {
            return false
        }
        return promptSourceClipIDs == [sourceID]
    }

    public var outputLine: String {
        let renderedSourceID = sourceID ?? "none"
        let renderedAssociations = promptSourceClipIDs.isEmpty
            ? "none"
            : promptSourceClipIDs.joined(separator: ",")
        return "CLIPVAULT_GENERATED_PROMPT_PROBE source_row_count=\(sourceRowCount) generated_row_count=\(generatedRowCount) source_id=\(renderedSourceID) prompt_source_clip_ids=\(renderedAssociations)"
    }

    public static func inspect(sourceToken: String, clips: [Clip]) -> Self {
        let sources = clips.filter { $0.preview == sourceToken }
        guard sources.count == 1, let source = sources.first else {
            return Self(
                sourceRowCount: sources.count,
                generatedRowCount: 0,
                sourceID: nil,
                promptSourceClipIDs: []
            )
        }

        let generated = clips.filter { clip in
            clip.sourceApp == "ClipVault AI"
                && clip.collectionIDs.contains(ClipCollection.prompts.id)
                && clip.metadata["promptSourceClipID"] == source.id
        }
        return Self(
            sourceRowCount: 1,
            generatedRowCount: generated.count,
            sourceID: source.id,
            promptSourceClipIDs: generated.compactMap { $0.metadata["promptSourceClipID"] }.sorted()
        )
    }
}
#endif
