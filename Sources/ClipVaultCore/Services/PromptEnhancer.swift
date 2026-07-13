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

public enum PromptEnhancementState: Equatable, Sendable {
    case idle
    case enhancing(current: Int, total: Int, sourceTitle: String)
    case saving(total: Int)
    case success(count: Int)
    case failed(sourceTitle: String?, message: String)
    case cancelled

    public var allowsCancellation: Bool {
        if case .enhancing = self {
            return true
        }
        return false
    }

    public var showsCancelControl: Bool {
        allowsCancellation
    }

    public var savedCount: Int? {
        if case .success(let count) = self {
            return count
        }
        return nil
    }

    public var canOpenPrompts: Bool {
        if case .success = self {
            return true
        }
        return false
    }

    public var blocksAIOperations: Bool {
        switch self {
        case .enhancing, .saving:
            true
        case .idle, .success, .failed, .cancelled:
            false
        }
    }
}

public struct PromptEnhancementSelection: Equatable, Sendable {
    public var currentClipID: String?
    public var selectedClipIDs: Set<String>

    public init(currentClipID: String?, selectedClipIDs: Set<String>) {
        self.currentClipID = currentClipID
        self.selectedClipIDs = selectedClipIDs
    }
}

public struct PromptEnhancementSelectionSnapshot: Equatable, Sendable {
    public var currentClipID: String?
    public var selectedClipIDs: Set<String>
    public var sourceIDs: [String]

    public init(
        currentClipID: String?,
        selectedClipIDs: Set<String>,
        sourceIDs: [String]
    ) {
        self.currentClipID = currentClipID
        self.selectedClipIDs = selectedClipIDs
        self.sourceIDs = sourceIDs
    }

    public func restoring(existingClipIDs: Set<String>) -> PromptEnhancementSelection {
        let sourceIDSet = Set(sourceIDs)
        let survivingSourceIDs = sourceIDSet.intersection(existingClipIDs)
        let restoredCurrentClipID: String?
        if let currentClipID, existingClipIDs.contains(currentClipID) {
            restoredCurrentClipID = currentClipID
        } else {
            restoredCurrentClipID = sourceIDs.first(where: survivingSourceIDs.contains)
        }

        return PromptEnhancementSelection(
            currentClipID: restoredCurrentClipID,
            selectedClipIDs: selectedClipIDs.intersection(survivingSourceIDs)
        )
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
    case generationFailed(sourceTitle: String, reason: String)

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
        case .generationFailed(let sourceTitle, let reason):
            "\(sourceTitle) could not be enhanced. \(reason)"
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
                throw PromptEnhancementError.generationFailed(
                    sourceTitle: source.title,
                    reason: generationFailureReason(error)
                )
            } catch {
                throw PromptEnhancementError.generationFailed(
                    sourceTitle: source.title,
                    reason: "Apple Intelligence could not enhance this prompt."
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
        guard !isCommentaryWrapper(normalizedOutput) else {
            throw PromptEnhancementError.commentaryWrapper(source.title)
        }
        guard !sensitiveRules.classify(normalizedOutput).isExcluded else {
            throw PromptEnhancementError.sensitiveOutput(source.title)
        }
        let sourceValues = observableValues(
            in: sourceText(for: source),
            extractingRequirements: true
        )
        let outputValues = observableValues(
            in: normalizedOutput,
            extractingRequirements: false
        )
        guard sourceValues.isSubset(of: outputValues) else {
            throw PromptEnhancementError.droppedValue(source.title)
        }
        return normalizedOutput
    }

    private let commentaryWrapperLines: Set<String> = [
        "enhanced prompt",
        "here is the enhanced prompt:",
        "here's the enhanced prompt:",
        "here’s the enhanced prompt:",
        "enhanced prompt:",
        "below is the enhanced prompt:",
        "sure, here is the enhanced prompt:",
        "sure, here's the enhanced prompt:",
        "sure, here’s the enhanced prompt:"
    ]

    private func isCommentaryWrapper(_ output: String) -> Bool {
        guard let firstLine = output.components(separatedBy: "\n").first else {
            return false
        }

        var line = firstLine.trimmingCharacters(in: .whitespaces)
        line = line.replacingOccurrences(
            of: #"^(?:#{1,6}|>|[-+*])\s+"#,
            with: "",
            options: .regularExpression
        )

        for marker in ["**", "__", "*", "_"] where line.hasPrefix(marker) {
            line.removeFirst(marker.count)
            if line.hasSuffix(marker) {
                line.removeLast(marker.count)
            }
            break
        }

        return commentaryWrapperLines.contains(
            line.trimmingCharacters(in: .whitespaces).lowercased()
        )
    }

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

    private func observableValues(
        in value: String,
        extractingRequirements: Bool
    ) -> Set<String> {
        let patterns: [(String, NSRegularExpression.Options)] = [
            (#"https?://[^\s<>\"']+"#, [.caseInsensitive]),
            (#"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, [.caseInsensitive]),
            (#"(?<![\p{L}\p{N}_./:~-])(?:\./|\.\./|~/|/)(?:[A-Za-z0-9._~-]+/)*[A-Za-z0-9._~-]+"#, []),
            (#"(?<![\p{L}\p{N}_-])--[A-Za-z][A-Za-z0-9]*(?:-[A-Za-z0-9]+)*(?:=[^\s,;]+)?"#, []),
            (#"(?<![\p{L}\p{N}_-])-[A-Za-z][A-Za-z0-9]*(?![\p{L}\p{N}_-])"#, []),
            (#"(?<![\p{L}\p{N}_])(?:[$€£¥]\s*[-+]?\d+(?:[.,]\d+)*|[-+]?\d+(?:[.,]\d+)*\s*(?:%|ms|s|secs?|seconds?|mins?|minutes?|h|hrs?|hours?|[kmgt]i?b|bytes?|px|pt|em|rem|hz|khz|mhz|ghz|ml|mg|kg|mm|cm|km|m|g|l|°c|°f))(?![\p{L}\p{N}_])"#, [.caseInsensitive]),
            (#"(?<![\p{L}\p{N}_])[-+]?\d+(?:[.,]\d+)*(?![\p{L}\p{N}_])"#, []),
            (#"\b(?:[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+|[a-z]+[A-Z][A-Za-z0-9]*|[A-Z][a-z0-9]+(?:[A-Z][A-Za-z0-9]*)+|[A-Za-z]+\d+[A-Za-z0-9]*|[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}|[A-Z]{2,}-\d+)\b"#, [])
        ]

        var values = patterns.reduce(into: Set<String>()) { values, item in
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
                let token = normalizedObservableToken(String(value[tokenRange]))
                if !token.isEmpty {
                    values.insert(token)
                }
            }
        }

        let dotQualifiedPattern = #"\b[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+\b"#
        if let expression = try? NSRegularExpression(pattern: dotQualifiedPattern) {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            for match in expression.matches(in: value, range: range) {
                guard let tokenRange = Range(match.range, in: value) else {
                    continue
                }
                let token = normalizedObservableToken(String(value[tokenRange]))
                let segments = token.split(separator: ".")
                let hasSubstantiveSegment = segments.contains { $0.count >= 2 }
                let hasLetter = token.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
                if hasSubstantiveSegment, hasLetter {
                    values.insert(token)
                }
            }
        }
        values.formUnion(quotedLiterals(in: value))
        values.formUnion(requiredOutputFormats(
            in: value,
            requiresContext: extractingRequirements
        ))
        values.formUnion(kebabCaseIdentifiers(
            in: value,
            requiresContext: extractingRequirements
        ))
        return values
    }

    private func requiredOutputFormats(
        in value: String,
        requiresContext: Bool
    ) -> Set<String> {
        let knownFormats = ["json", "yaml", "csv", "markdown"]
        let contextWords = [
            "as", "deliver", "emit", "export", "format", "formats", "output",
            "produce", "provide", "render", "required", "respond", "response", "return", "write"
        ]
        let clauses = value
            .lowercased()
            .components(separatedBy: CharacterSet(charactersIn: ".!?;\n\r"))

        return clauses.reduce(into: Set<String>()) { formats, clause in
            let words = Set(clause.split(whereSeparator: { !$0.isLetter }).map(String.init))
            guard !requiresContext || !words.isDisjoint(with: contextWords) else {
                return
            }
            for format in knownFormats where words.contains(format) {
                formats.insert("required-format:\(format)")
            }
        }
    }

    private func kebabCaseIdentifiers(
        in value: String,
        requiresContext: Bool
    ) -> Set<String> {
        let contextWords = Set([
            "attribute", "config", "configuration", "field", "header", "id",
            "identifier", "key", "metadata", "option", "parameter", "property",
            "setting", "variable"
        ])
        let identifierSuffixes = Set([
            "count", "format", "id", "key", "limit", "mode", "name", "path",
            "policy", "retries", "schema", "timeout", "token", "type", "uri",
            "url", "version"
        ])
        let clauses = value.components(separatedBy: CharacterSet(charactersIn: ".!?;\n\r"))
        guard let expression = try? NSRegularExpression(
            pattern: #"\b[A-Za-z0-9]+(?:-[A-Za-z0-9]+)+\b"#
        ) else {
            return []
        }

        return clauses.reduce(into: Set<String>()) { identifiers, clause in
            let clauseWords = Set(
                clause.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            )
            let hasIdentifierContext = !clauseWords.isDisjoint(with: contextWords)
            let range = NSRange(clause.startIndex..<clause.endIndex, in: clause)
            for match in expression.matches(in: clause, range: range) {
                guard let tokenRange = Range(match.range, in: clause) else {
                    continue
                }
                let token = String(clause[tokenRange])
                let components = token.lowercased().split(separator: "-").map(String.init)
                let hasCommonIdentifierShape = token.lowercased().hasPrefix("x-")
                    || components.last.map(identifierSuffixes.contains) == true
                guard !requiresContext || hasIdentifierContext || hasCommonIdentifierShape else {
                    continue
                }
                identifiers.insert("identifier:\(token)")
            }
        }
    }

    private func quotedLiterals(in value: String) -> Set<String> {
        let characters = Array(value)
        let closingDelimiter: [Character: Character] = [
            "\"": "\"",
            "'": "'",
            "“": "”",
            "‘": "’",
            "`": "`"
        ]
        var literals: Set<String> = []
        var index = 0

        while index < characters.count {
            let opening = characters[index]
            guard let closing = closingDelimiter[opening],
                  opening != "'" || !isWordCharacter(characters[safe: index - 1]) else {
                index += 1
                continue
            }

            var closingIndex = index + 1
            while closingIndex < characters.count {
                let candidate = characters[closingIndex]
                if candidate == "\n" || candidate == "\r" {
                    break
                }
                if candidate == closing,
                   opening != "'" || !isWordCharacter(characters[safe: closingIndex + 1]) {
                    guard closingIndex > index + 1 else {
                        break
                    }
                    literals.insert(String(characters[index...closingIndex]))
                    index = closingIndex
                    break
                }
                closingIndex += 1
            }
            index += 1
        }

        return literals
    }

    private func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else {
            return false
        }
        return character.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
    }

    private func normalizedObservableToken(_ value: String) -> String {
        var token = value
        let sentencePunctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]

        while let last = token.last {
            if sentencePunctuation.contains(last) {
                token.removeLast()
                continue
            }
            if isUnmatchedTrailingCloser(last, in: token) {
                token.removeLast()
                continue
            }
            break
        }
        return token
    }

    private func isUnmatchedTrailingCloser(_ closer: Character, in value: String) -> Bool {
        let opener: Character
        switch closer {
        case ")": opener = "("
        case "]": opener = "["
        case "}": opener = "{"
        default: return false
        }

        return value.filter { $0 == closer }.count > value.filter { $0 == opener }.count
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
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
            let output: String
            do {
                output = try await enhancer.enhance(source)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as PromptEnhancementError {
                switch error {
                case .emptySource,
                     .emptyOutput,
                     .unchangedOutput,
                     .commentaryWrapper,
                     .sensitiveOutput,
                     .droppedValue,
                     .generationFailed,
                     .unavailable:
                    throw error
                case .emptySelection:
                    throw PromptEnhancementError.generationFailed(
                        sourceTitle: source.title,
                        reason: "The prompt enhancer could not complete this source."
                    )
                }
            } catch {
                throw PromptEnhancementError.generationFailed(
                    sourceTitle: source.title,
                    reason: "The prompt enhancer could not complete this source."
                )
            }
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

public enum PromptEnhancementWorkflowOutcome: Equatable, Sendable {
    case cancelled
    case failedBeforeSave(sourceTitle: String?, message: String)
    case atomicSaveFailed(sourceTitle: String?, message: String)
    case saved(count: Int)
    case savedButReloadFailed(count: Int, message: String)

    public var state: PromptEnhancementState {
        switch self {
        case .cancelled:
            .cancelled
        case .failedBeforeSave(let sourceTitle, let message),
             .atomicSaveFailed(let sourceTitle, let message):
            .failed(sourceTitle: sourceTitle, message: message)
        case .saved(let count):
            .success(count: count)
        case .savedButReloadFailed(_, let message):
            .failed(sourceTitle: nil, message: message)
        }
    }
}

public struct PromptEnhancementCommitBoundary: Sendable {
    private let suspendOperation: @MainActor @Sendable () async -> Void

    public init(
        _ suspendOperation: @escaping @MainActor @Sendable () async -> Void = {
            await Task.yield()
        }
    ) {
        self.suspendOperation = suspendOperation
    }

    @MainActor
    func suspend() async {
        await suspendOperation()
    }
}

@MainActor
public struct PromptEnhancementWorkflow {
    private let runner: PromptEnhancementBatchRunner
    private let commitBoundary: PromptEnhancementCommitBoundary

    public init(
        runner: PromptEnhancementBatchRunner,
        commitBoundary: PromptEnhancementCommitBoundary = PromptEnhancementCommitBoundary()
    ) {
        self.runner = runner
        self.commitBoundary = commitBoundary
    }

    public func run(
        sources: [Clip],
        save: ([GeneratedPromptDraft]) throws -> Int,
        reload: () -> Bool,
        isActive: @escaping () -> Bool,
        publish: @escaping (PromptEnhancementState) -> Void,
        logError: (any Error) -> Void
    ) async -> PromptEnhancementWorkflowOutcome {
        let publisher = PromptEnhancementWorkflowPublisher(
            isActive: isActive,
            publish: publish
        )

        let drafts: [GeneratedPromptDraft]
        do {
            drafts = try await runner.run(sources: sources) { progress in
                await publisher.receive(progress)
            }
        } catch is CancellationError {
            let outcome = PromptEnhancementWorkflowOutcome.cancelled
            publisher.publishIfActive(outcome.state)
            return outcome
        } catch {
            logError(error)
            let failure = Self.failure(
                error: error,
                currentSourceTitle: publisher.currentSourceTitle,
                safeSourceTitles: Set(sources.map(\.title))
            )
            let outcome = PromptEnhancementWorkflowOutcome.failedBeforeSave(
                sourceTitle: failure.sourceTitle,
                message: Self.failureMessage(
                    sourceTitle: failure.sourceTitle,
                    reason: failure.reason
                )
            )
            publisher.publishIfActive(outcome.state)
            return outcome
        }

        do {
            try Task.checkCancellation()
        } catch {
            let outcome = PromptEnhancementWorkflowOutcome.cancelled
            publisher.publishIfActive(outcome.state)
            return outcome
        }
        guard publisher.isActive else {
            return .cancelled
        }

        publisher.publishIfActive(.saving(total: drafts.count))
        await commitBoundary.suspend()
        let savedCount: Int
        do {
            savedCount = try save(drafts)
        } catch {
            logError(error)
            let failure = Self.storeFailure(
                error: error,
                sourceTitlesByID: sources.reduce(into: [:]) { titles, source in
                    titles[source.id] = source.title
                }
            )
            let message = Self.failureMessage(
                sourceTitle: failure.sourceTitle,
                reason: failure.reason
            )
            let outcome = PromptEnhancementWorkflowOutcome.atomicSaveFailed(
                sourceTitle: failure.sourceTitle,
                message: message
            )
            publisher.publishIfActive(outcome.state)
            return outcome
        }

        guard reload() else {
            let message = Self.reloadFailureMessage(savedCount: savedCount)
            let outcome = PromptEnhancementWorkflowOutcome.savedButReloadFailed(
                count: savedCount,
                message: message
            )
            publisher.publishIfActive(outcome.state)
            return outcome
        }

        let outcome = PromptEnhancementWorkflowOutcome.saved(count: savedCount)
        publisher.publishIfActive(outcome.state)
        return outcome
    }

    private static func failure(
        error: any Error,
        currentSourceTitle: String?,
        safeSourceTitles: Set<String>
    ) -> (sourceTitle: String?, reason: String) {
        guard let enhancementError = error as? PromptEnhancementError else {
            return (
                safeSourceTitle(
                    candidate: nil,
                    currentSourceTitle: currentSourceTitle,
                    safeSourceTitles: safeSourceTitles
                ),
                "Prompt enhancement could not be completed."
            )
        }

        switch enhancementError {
        case .emptySelection:
            return (nil, enhancementError.localizedDescription)
        case .unavailable(let reason):
            return (
                safeSourceTitle(
                    candidate: nil,
                    currentSourceTitle: currentSourceTitle,
                    safeSourceTitles: safeSourceTitles
                ),
                reason
            )
        case .emptySource(let sourceTitle):
            return sourceFailure(
                candidateTitle: sourceTitle,
                currentSourceTitle: currentSourceTitle,
                safeSourceTitles: safeSourceTitles,
                reason: "This source has no text to enhance."
            )
        case .emptyOutput(let sourceTitle):
            return sourceFailure(
                candidateTitle: sourceTitle,
                currentSourceTitle: currentSourceTitle,
                safeSourceTitles: safeSourceTitles,
                reason: "Apple Intelligence produced an empty result."
            )
        case .unchangedOutput(let sourceTitle):
            return sourceFailure(
                candidateTitle: sourceTitle,
                currentSourceTitle: currentSourceTitle,
                safeSourceTitles: safeSourceTitles,
                reason: "This prompt is already well structured."
            )
        case .commentaryWrapper(let sourceTitle):
            return sourceFailure(
                candidateTitle: sourceTitle,
                currentSourceTitle: currentSourceTitle,
                safeSourceTitles: safeSourceTitles,
                reason: "Apple Intelligence produced commentary instead of a prompt."
            )
        case .sensitiveOutput(let sourceTitle):
            return sourceFailure(
                candidateTitle: sourceTitle,
                currentSourceTitle: currentSourceTitle,
                safeSourceTitles: safeSourceTitles,
                reason: "Apple Intelligence produced content ClipVault cannot save safely."
            )
        case .droppedValue(let sourceTitle):
            return sourceFailure(
                candidateTitle: sourceTitle,
                currentSourceTitle: currentSourceTitle,
                safeSourceTitles: safeSourceTitles,
                reason: "Apple Intelligence did not preserve all required source values."
            )
        case .generationFailed(let sourceTitle, let reason):
            return sourceFailure(
                candidateTitle: sourceTitle,
                currentSourceTitle: currentSourceTitle,
                safeSourceTitles: safeSourceTitles,
                reason: reason
            )
        }
    }

    private static func sourceFailure(
        candidateTitle: String,
        currentSourceTitle: String?,
        safeSourceTitles: Set<String>,
        reason: String
    ) -> (sourceTitle: String?, reason: String) {
        (
            safeSourceTitle(
                candidate: candidateTitle,
                currentSourceTitle: currentSourceTitle,
                safeSourceTitles: safeSourceTitles
            ),
            reason
        )
    }

    private static func safeSourceTitle(
        candidate: String?,
        currentSourceTitle: String?,
        safeSourceTitles: Set<String>
    ) -> String? {
        if let currentSourceTitle, safeSourceTitles.contains(currentSourceTitle) {
            return currentSourceTitle
        }
        if let candidate, safeSourceTitles.contains(candidate) {
            return candidate
        }
        return nil
    }

    private static func failureMessage(sourceTitle: String?, reason: String) -> String {
        if let sourceTitle {
            return "Couldn’t enhance “\(sourceTitle).” \(reason) Nothing was saved."
        }
        return "\(reason) Nothing was saved."
    }

    private static func storeFailure(
        error: any Error,
        sourceTitlesByID: [String: String]
    ) -> (sourceTitle: String?, reason: String) {
        guard let storeError = error as? GeneratedPromptStoreError else {
            return (nil, "The enhanced prompts could not be saved.")
        }

        let sourceTitle: String?
        switch storeError {
        case .sourceMissing(let sourceID),
             .duplicateSource(let sourceID),
             .rejectedOutput(let sourceID),
             .duplicateOutput(let sourceID),
             .encryptionFailed(let sourceID):
            sourceTitle = sourceTitlesByID[sourceID]
        case .emptyBatch, .promptsUnavailable, .batchSaveFailed:
            sourceTitle = nil
        }
        return (sourceTitle, storeError.localizedDescription)
    }

    private static func reloadFailureMessage(savedCount: Int) -> String {
        let noun = savedCount == 1 ? "prompt was" : "prompts were"
        return "\(savedCount) enhanced \(noun) saved, but ClipVault couldn’t refresh the workspace."
    }
}

@MainActor
private final class PromptEnhancementWorkflowPublisher {
    private let isActiveCheck: () -> Bool
    private let publish: (PromptEnhancementState) -> Void
    private(set) var currentSourceTitle: String?

    var isActive: Bool {
        isActiveCheck()
    }

    init(
        isActive: @escaping () -> Bool,
        publish: @escaping (PromptEnhancementState) -> Void
    ) {
        self.isActiveCheck = isActive
        self.publish = publish
    }

    func receive(_ progress: PromptEnhancementProgress) {
        guard isActive else {
            return
        }
        currentSourceTitle = progress.sourceTitle
        publish(.enhancing(
            current: progress.current,
            total: progress.total,
            sourceTitle: progress.sourceTitle
        ))
    }

    func publishIfActive(_ state: PromptEnhancementState) {
        guard isActive else {
            return
        }
        publish(state)
    }
}
