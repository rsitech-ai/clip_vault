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
    case emptyQuestion
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            "Select one or more clips first."
        case .emptyQuestion:
            "Ask a question before running Ask."
        case .unavailable(let reason):
            reason
        }
    }
}

public struct LocalClipAIActionProvider: AIActionProviding {
    private let fallbackReason: String?

    public init(fallbackReason: String? = nil) {
        self.fallbackReason = fallbackReason
    }

    public func availability() -> AIAvailability {
        AIAvailability(isAvailable: true, reason: fallbackReason ?? "Local clip fallback ready.")
    }

    public func perform(_ request: AIActionRequest) async throws -> AIActionResult {
        guard !request.clips.isEmpty else {
            throw AIActionError.emptySelection
        }
        if request.kind == .ask, trimmedQuestion(for: request).isEmpty {
            throw AIActionError.emptyQuestion
        }

        return fallbackResult(for: request)
    }

    private func fallbackResult(for request: AIActionRequest) -> AIActionResult {
        let content: String
        switch request.kind {
        case .ask:
            content = answerQuestion(for: request)
        case .summarize:
            content = summarize(request.clips)
        case .explain:
            content = explain(request.clips)
        case .email:
            content = draftEmail(from: request.clips)
        case .todos:
            content = todos(from: request.clips)
        }

        return AIActionResult(
            title: request.kind == .ask ? "Ask" : "\(request.kind.title) local",
            content: prefixed(content),
            citedClipIDs: request.clips.map(\.id),
            isFallback: true
        )
    }

    private func answerQuestion(for request: AIActionRequest) -> String {
        let question = trimmedQuestion(for: request)
        let evidence = rankedEvidence(for: question, clips: request.clips)

        guard !evidence.isEmpty else {
            let closest = request.clips.prefix(3).map { clip in
                "- \(clip.title): \(shorten(clipContext(for: clip), limit: 180))"
            }.joined(separator: "\n")
            return """
            Question: \(question)

            I could not find enough matching context in the selected clip(s).

            Closest selected context:
            \(closest)
            """
        }

        let bullets = evidence.map { item in
            "- Clip \(item.clipIndex + 1) (\(item.title)): \(item.text)"
        }.joined(separator: "\n")

        return """
        Question: \(question)

        Answer from selected clips:
        \(bullets)
        """
    }

    private func summarize(_ clips: [Clip]) -> String {
        let bullets = clips.prefix(5).enumerated().map { index, clip in
            "- Clip \(index + 1): \(clip.title) - \(shorten(clipContext(for: clip), limit: 180))"
        }.joined(separator: "\n")
        return "Selected clip summary:\n\(bullets)"
    }

    private func explain(_ clips: [Clip]) -> String {
        let bullets = clips.prefix(5).enumerated().map { index, clip in
            "- Clip \(index + 1) is \(clip.kind.title.lowercased()): \(shorten(clipContext(for: clip), limit: 220))"
        }.joined(separator: "\n")
        return "What these clips contain:\n\(bullets)"
    }

    private func draftEmail(from clips: [Clip]) -> String {
        let context = clips.prefix(3).enumerated().map { index, clip in
            "Clip \(index + 1): \(shorten(clipContext(for: clip), limit: 220))"
        }.joined(separator: "\n")
        return """
        Subject: Follow-up

        Hi,

        Following up on the selected details:
        \(context)

        Best,
        """
    }

    private func todos(from clips: [Clip]) -> String {
        let evidence = rankedEvidence(for: "todo task action next follow up deadline owner", clips: clips)
        guard !evidence.isEmpty else {
            return "No concrete todos were obvious in the selected clip(s)."
        }
        return evidence.map { "- \(shorten($0.text, limit: 160))" }.joined(separator: "\n")
    }

    private func rankedEvidence(for question: String, clips: [Clip]) -> [EvidenceLine] {
        let terms = queryTerms(from: question)
        let wantsEmail = containsAny(question, ["email", "e-mail", "mail", "contact"])
        let wantsPhone = containsAny(question, ["phone", "mobile", "number", "call"])
        let wantsCustomer = containsAny(question, ["customer", "client", "account", "user"])

        let scored = clips.enumerated().flatMap { clipIndex, clip in
            candidateLines(from: clip).map { line in
                var score = terms.reduce(0) { partial, term in
                    partial + (line.localizedCaseInsensitiveContains(term) ? 1 : 0)
                }
                if wantsEmail, line.range(of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    score += 5
                }
                if wantsPhone, line.range(of: #"\+?[0-9][0-9\s().-]{6,}[0-9]"#, options: .regularExpression) != nil {
                    score += 4
                }
                if wantsCustomer, containsAny(line, ["customer", "client", "account", "user", "name"]) {
                    score += 2
                }
                return EvidenceLine(
                    score: score,
                    clipIndex: clipIndex,
                    title: clip.title,
                    text: shorten(line, limit: 220)
                )
            }
        }

        let useful = scored.filter { $0.score > 0 }
        if useful.isEmpty, terms.isEmpty {
            return clips.prefix(3).enumerated().map { index, clip in
                EvidenceLine(score: 0, clipIndex: index, title: clip.title, text: shorten(clipContext(for: clip), limit: 220))
            }
        }

        return useful
            .sorted {
                if $0.score == $1.score {
                    return $0.clipIndex < $1.clipIndex
                }
                return $0.score > $1.score
            }
            .prefix(6)
            .map { $0 }
    }

    private func candidateLines(from clip: Clip) -> [String] {
        var seen = Set<String>()
        return clipContext(for: clip)
            .components(separatedBy: CharacterSet(charactersIn: "\n\r;|"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private func clipContext(for clip: Clip) -> String {
        [
            clip.title,
            clip.preview,
            clip.extractedText,
            clip.userNote,
            clip.tags.joined(separator: " ")
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func prefixed(_ content: String) -> String {
        guard let fallbackReason, !fallbackReason.isEmpty else {
            return content
        }
        return "\(fallbackReason)\n\n\(content)"
    }

    private func trimmedQuestion(for request: AIActionRequest) -> String {
        (request.question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func queryTerms(from question: String) -> [String] {
        let stopwords: Set<String> = [
            "what", "which", "where", "when", "who", "why", "how", "the", "and", "for", "with",
            "this", "that", "clip", "clips", "selected", "customer", "client", "please", "tell", "show"
        ]
        return question
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
    }

    private func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.localizedCaseInsensitiveContains($0) }
    }

    private func shorten(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else {
            return normalized
        }
        return "\(normalized.prefix(max(0, limit - 1)))..."
    }
}

private struct EvidenceLine: Hashable, Sendable {
    var score: Int
    var clipIndex: Int
    var title: String
    var text: String
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
        if request.kind == .ask,
           (request.question ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AIActionError.emptyQuestion
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), availability().isAvailable {
            do {
                let session = LanguageModelSession(
                    instructions: Instructions("""
                    You help a Mac user reason over selected clipboard items.
                    Use only the supplied clips.
                    Keep answers concise and cite clip numbers when useful.
                    If the clips do not contain enough context, say what is missing.
                    """)
                )
                let response = try await session.respond(to: Prompt(prompt(for: request)))
                return AIActionResult(
                    title: request.kind.title,
                    content: response.content,
                    citedClipIDs: request.clips.map(\.id)
                )
            } catch {
                return try await LocalClipAIActionProvider(
                    fallbackReason: "Local fallback used because Foundation Models could not answer: \(error.localizedDescription)"
                ).perform(request)
            }
        }
        #endif

        return try await LocalClipAIActionProvider(
            fallbackReason: availability().reason ?? "Foundation Models are unavailable."
        ).perform(request)
    }

    private func prompt(for request: AIActionRequest) -> String {
        let clips = request.clips.enumerated().map { index, clip in
            """
            Clip \(index + 1) [\(clip.kind.title)]:
            \(promptContext(for: clip))
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
            let question = (request.question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return "Question: \(question)\n\nAnswer using only these clips.\n\n\(clips)"
        }
    }

    private func promptContext(for clip: Clip) -> String {
        let context = [
            "Title: \(clip.title)",
            "Preview: \(clip.preview)",
            "Text: \(clip.extractedText)",
            clip.userNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "Notes: \(clip.userNote)",
            clip.tags.isEmpty ? "" : "Tags: \(clip.tags.joined(separator: ", "))"
        ]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")

        guard context.count > 3_000 else {
            return context
        }
        return "\(context.prefix(3_000))..."
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
