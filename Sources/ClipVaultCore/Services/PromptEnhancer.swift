import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

public protocol PromptEnhancing: Sendable {
    func availability() -> AIAvailability
    func enhance(_ source: Clip) async throws -> String
}

public struct PromptEnhancementProgress: Equatable, Sendable {
    public var current: Int
    public var total: Int
    public var sourceTitle: String

    public init(current: Int, total: Int, sourceTitle: String) {
        self.current = current
        self.total = total
        self.sourceTitle = sourceTitle
    }
}

public enum PromptEnhancementError: Error, LocalizedError, Equatable {
    case emptySelection
    case unavailable(String)
    case emptySource(String)
    case emptyOutput(String)
    case unchangedOutput(String)
    case commentaryWrapper(String)
    case sensitiveOutput(String)
    case droppedValue(String)

    public var errorDescription: String? {
        switch self {
        case .emptySelection: "Select one or more prompt clips first."
        case .unavailable(let reason): reason
        case .emptySource(let title): "\(title) has no text to enhance."
        case .emptyOutput(let title): "\(title) produced an empty result."
        case .unchangedOutput(let title): "\(title) is already well structured."
        case .commentaryWrapper(let title): "\(title) produced commentary instead of a prompt."
        case .sensitiveOutput(let title): "\(title) produced content ClipVault cannot save safely."
        case .droppedValue(let title): "\(title) did not preserve required source values."
        }
    }
}

public struct FoundationModelsPromptEnhancer: PromptEnhancing {
    public init() {}

    public func availability() -> AIAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return AIAvailability(isAvailable: true)
            case .unavailable(let reason):
                return AIAvailability(isAvailable: false, reason: availabilityReason(reason))
            @unknown default:
                return AIAvailability(
                    isAvailable: false,
                    reason: "Apple Intelligence is unavailable."
                )
            }
        }
        #endif

        return AIAvailability(
            isAvailable: false,
            reason: "Prompt enhancement requires Apple Intelligence on macOS 26 or later."
        )
    }

    public func enhance(_ source: Clip) async throws -> String {
        let sourceText = promptSourceText(for: source)
        guard !sourceText.isEmpty else {
            throw PromptEnhancementError.emptySource(source.title)
        }

        let currentAvailability = availability()
        guard currentAvailability.isAvailable else {
            throw PromptEnhancementError.unavailable(
                currentAvailability.reason ?? "Apple Intelligence is unavailable."
            )
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                try Task.checkCancellation()
                let session = LanguageModelSession(
                    instructions: Instructions(Self.instructions)
                )
                let response = try await session.respond(to: Prompt(sourceText))
                try Task.checkCancellation()
                return response.content
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LanguageModelSession.GenerationError {
                throw PromptEnhancementError.unavailable(generationFailureReason(error))
            } catch {
                throw PromptEnhancementError.unavailable(
                    "Apple Intelligence could not enhance this prompt."
                )
            }
        }
        #endif

        throw PromptEnhancementError.unavailable(
            "Prompt enhancement requires Apple Intelligence on macOS 26 or later."
        )
    }

    private static let instructions = """
    Rewrite one source prompt for execution. Preserve all explicit facts, numbers, URLs, emails, quoted literals, identifiers, formats, and constraints. Put the requested outcome first. Add only sections that improve execution. Return only the enhanced prompt. Do not add commentary or invent requirements.
    """

    private func promptSourceText(for source: Clip) -> String {
        let extractedText = source.extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extractedText.isEmpty {
            return extractedText
        }
        return source.preview.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func availabilityReason(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            "Apple Intelligence is not supported on this Mac."
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence to enhance prompts."
        case .modelNotReady:
            "Apple Intelligence is not ready yet."
        @unknown default:
            "Apple Intelligence is unavailable."
        }
    }

    @available(macOS 26.0, *)
    private func generationFailureReason(
        _ error: LanguageModelSession.GenerationError
    ) -> String {
        switch error {
        case .exceededContextWindowSize:
            "This prompt is too long for Apple Intelligence."
        case .assetsUnavailable:
            "Apple Intelligence is not ready yet."
        case .guardrailViolation, .refusal:
            "Apple Intelligence could not safely enhance this prompt."
        case .unsupportedLanguageOrLocale:
            "Apple Intelligence does not support this prompt's language."
        case .rateLimited, .concurrentRequests:
            "Apple Intelligence is busy. Try again in a moment."
        case .unsupportedGuide, .decodingFailure:
            "Apple Intelligence could not enhance this prompt."
        @unknown default:
            "Apple Intelligence could not enhance this prompt."
        }
    }
    #endif
}

public struct PromptEnhancementValidator: Sendable {
    private let sensitiveRules: SensitiveRuleEngine

    public init(sensitiveRules: SensitiveRuleEngine = .default) {
        self.sensitiveRules = sensitiveRules
    }

    public func validate(output: String, source: Clip) throws -> String {
        guard !sourceText(for: source).isEmpty else {
            throw PromptEnhancementError.emptySource(source.title)
        }
        let normalizedOutput = normalize(output)
        guard !normalizedOutput.isEmpty else {
            throw PromptEnhancementError.emptyOutput(source.title)
        }
        guard normalizedOutput != normalize(sourceText(for: source)) else {
            throw PromptEnhancementError.unchangedOutput(source.title)
        }
        let lowercaseOutput = normalizedOutput.lowercased()
        guard !commentaryPrefixes.contains(where: lowercaseOutput.hasPrefix) else {
            throw PromptEnhancementError.commentaryWrapper(source.title)
        }
        guard !sensitiveRules.classify(normalizedOutput).isExcluded else {
            throw PromptEnhancementError.sensitiveOutput(source.title)
        }
        let sourceValues = observableValues(in: sourceText(for: source))
        let outputValues = observableValues(in: normalizedOutput)
        guard sourceValues.isSubset(of: outputValues) else {
            throw PromptEnhancementError.droppedValue(source.title)
        }
        return normalizedOutput
    }

    private let commentaryPrefixes = [
        "here is the enhanced prompt:",
        "here's the enhanced prompt:",
        "enhanced prompt:",
        "sure, here is the enhanced prompt:",
        "sure, here's the enhanced prompt:"
    ]

    private func sourceText(for source: Clip) -> String {
        let extractedText = source.extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extractedText.isEmpty {
            return extractedText
        }
        return source.preview.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalize(_ value: String) -> String {
        let lines = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression) }

        var normalizedLines: [String] = []
        for line in lines {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank, normalizedLines.last?.isEmpty == true {
                continue
            }
            normalizedLines.append(isBlank ? "" : line)
        }

        return normalizedLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func observableValues(in value: String) -> Set<String> {
        let patterns: [(String, NSRegularExpression.Options)] = [
            (#"https?://[^\s<>\"']+"#, [.caseInsensitive]),
            (#"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, [.caseInsensitive]),
            (#"(?<![\p{L}\p{N}_])[-+]?\d+(?:[.,]\d+)*(?![\p{L}\p{N}_])"#, []),
            (#"\"[^\"\r\n]+\"|'[^'\r\n]+'"#, []),
            (#"\b(?:[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+|[a-z]+[A-Z][A-Za-z0-9]*|[A-Z][a-z0-9]+(?:[A-Z][A-Za-z0-9]*)+|[A-Za-z]+\d+[A-Za-z0-9]*|[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}|[A-Z]{2,}-\d+)\b"#, [])
        ]

        return patterns.reduce(into: Set<String>()) { values, item in
            guard let expression = try? NSRegularExpression(
                pattern: item.0,
                options: item.1
            ) else {
                return
            }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            for match in expression.matches(in: value, range: range) {
                guard let tokenRange = Range(match.range, in: value) else {
                    continue
                }
                let token = String(value[tokenRange])
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}"))
                if !token.isEmpty {
                    values.insert(token)
                }
            }
        }
    }
}

public struct PromptEnhancementBatchRunner: Sendable {
    private let enhancer: any PromptEnhancing
    private let validator: PromptEnhancementValidator

    public init(
        enhancer: any PromptEnhancing,
        validator: PromptEnhancementValidator = PromptEnhancementValidator()
    ) {
        self.enhancer = enhancer
        self.validator = validator
    }

    public func availability() -> AIAvailability {
        enhancer.availability()
    }

    public func run(
        sources: [Clip],
        progress: @Sendable (PromptEnhancementProgress) async -> Void
    ) async throws -> [GeneratedPromptDraft] {
        guard !sources.isEmpty else {
            throw PromptEnhancementError.emptySelection
        }
        let availability = enhancer.availability()
        guard availability.isAvailable else {
            throw PromptEnhancementError.unavailable(
                availability.reason ?? "Apple Intelligence is unavailable."
            )
        }

        var drafts: [GeneratedPromptDraft] = []
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            await progress(PromptEnhancementProgress(
                current: index + 1,
                total: sources.count,
                sourceTitle: source.title
            ))
            let output = try await enhancer.enhance(source)
            let validated = try validator.validate(output: output, source: source)
            drafts.append(GeneratedPromptDraft(
                sourceClipID: source.id,
                sourceTitle: source.title,
                enhancedText: validated
            ))
        }
        try Task.checkCancellation()
        return drafts
    }
}
