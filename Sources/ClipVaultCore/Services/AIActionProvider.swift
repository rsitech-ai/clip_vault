import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

public enum AIActionKind: String, CaseIterable, Codable, Hashable, Sendable {
    case summarize
    case explain
    case email
    case todos
    case ask

    public var title: String {
        switch self {
        case .summarize: "Summarize"
        case .explain: "Explain"
        case .email: "Email"
        case .todos: "Todos"
        case .ask: "Ask"
        }
    }
}

public struct AIAvailability: Hashable, Sendable {
    public var isAvailable: Bool
    public var reason: String?

    public init(isAvailable: Bool, reason: String? = nil) {
        self.isAvailable = isAvailable
        self.reason = reason
    }
}

public struct AIActionRequest: Hashable, Sendable {
    public var kind: AIActionKind
    public var clips: [Clip]
    public var question: String?

    public init(kind: AIActionKind, clips: [Clip], question: String? = nil) {
        self.kind = kind
        self.clips = clips
        self.question = question
    }
}

public struct AIActionResult: Hashable, Sendable {
    public var title: String
    public var content: String
    public var citedClipIDs: [String]
    public var isFallback: Bool

    public init(title: String, content: String, citedClipIDs: [String], isFallback: Bool = false) {
        self.title = title
        self.content = content
        self.citedClipIDs = citedClipIDs
        self.isFallback = isFallback
    }
}

public protocol AIActionProviding: Sendable {
    func availability() -> AIAvailability
    func perform(_ request: AIActionRequest) async throws -> AIActionResult
}

public enum AIActionError: Error, LocalizedError {
    case emptySelection
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            "Select one or more clips first."
        case .unavailable(let reason):
            reason
        }
    }
}

public struct FoundationModelsAIActionProvider: AIActionProviding {
    public init() {}

    public func availability() -> AIAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return AIAvailability(isAvailable: true)
            case .unavailable(let reason):
                return AIAvailability(isAvailable: false, reason: String(describing: reason))
            @unknown default:
                return AIAvailability(isAvailable: false, reason: "Foundation Models are unavailable.")
            }
        }
        #endif

        return AIAvailability(isAvailable: false, reason: "Foundation Models require an Apple Intelligence-capable macOS.")
    }

    public func perform(_ request: AIActionRequest) async throws -> AIActionResult {
        guard !request.clips.isEmpty else {
            throw AIActionError.emptySelection
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), availability().isAvailable {
            let session = LanguageModelSession(
                instructions: Instructions("""
                You help a Mac user reason over selected clipboard items.
                Use only the supplied clips.
                Keep answers concise and cite clip numbers when useful.
                """)
            )
            let response = try await session.respond(to: Prompt(prompt(for: request)))
            return AIActionResult(
                title: request.kind.title,
                content: response.content,
                citedClipIDs: request.clips.map(\.id)
            )
        }
        #endif

        return fallbackResult(for: request)
    }

    private func prompt(for request: AIActionRequest) -> String {
        let clips = request.clips.enumerated().map { index, clip in
            """
            Clip \(index + 1) [\(clip.kind.title)]:
            \(clip.extractedText)
            """
        }.joined(separator: "\n\n")

        switch request.kind {
        case .summarize:
            return "Summarize these clips in clear bullets.\n\n\(clips)"
        case .explain:
            return "Explain what these clips are about and why they may matter.\n\n\(clips)"
        case .email:
            return "Turn these clips into a concise professional email draft.\n\n\(clips)"
        case .todos:
            return "Extract concrete todos from these clips.\n\n\(clips)"
        case .ask:
            return "Question: \(request.question ?? "What matters here?")\n\nAnswer using only these clips.\n\n\(clips)"
        }
    }

    private func fallbackResult(for request: AIActionRequest) -> AIActionResult {
        let preview = request.clips
            .prefix(5)
            .map { "• \($0.title)" }
            .joined(separator: "\n")
        let reason = availability().reason ?? "AI is unavailable."

        return AIActionResult(
            title: "\(request.kind.title) unavailable",
            content: "\(reason)\n\nSelected clips:\n\(preview)",
            citedClipIDs: request.clips.map(\.id),
            isFallback: true
        )
    }
}

public struct CloudAIProviderPlaceholder: AIActionProviding {
    public init() {}

    public func availability() -> AIAvailability {
        AIAvailability(
            isAvailable: false,
            reason: "Cloud AI providers are intentionally disabled until explicit opt-in settings exist."
        )
    }

    public func perform(_ request: AIActionRequest) async throws -> AIActionResult {
        throw AIActionError.unavailable(availability().reason ?? "Cloud AI is disabled.")
    }
}
