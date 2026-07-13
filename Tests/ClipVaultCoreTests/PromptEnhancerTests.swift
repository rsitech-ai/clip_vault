import Foundation
import Testing
@testable import ClipVaultCore

@Suite("Prompt enhancer")
struct PromptEnhancerTests {
    @Test("workflow state exposes cancellation and saved-count semantics")
    func workflowStateSemantics() {
        #expect(PromptEnhancementState.enhancing(
            current: 1,
            total: 2,
            sourceTitle: "One"
        ).allowsCancellation)
        #expect(!PromptEnhancementState.saving(total: 2).allowsCancellation)
        #expect(PromptEnhancementState.success(count: 2).savedCount == 2)
        #expect(PromptEnhancementState.cancelled.savedCount == nil)
    }

    @Test("validator rejects an empty source")
    func validatorRejectsEmptySource() {
        let source = makeClip(
            title: "Empty",
            preview: "  \n",
            extractedText: "\n\t"
        )

        #expect(throws: PromptEnhancementError.emptySource("Empty")) {
            try PromptEnhancementValidator().validate(
                output: "Goal: Improve the prompt.",
                source: source
            )
        }
    }

    @Test("validator rejects an empty output")
    func validatorRejectsEmptyOutput() {
        let source = makeClip(preview: "Write a release note.", extractedText: "Write a release note.")

        #expect(throws: PromptEnhancementError.emptyOutput("Source")) {
            try PromptEnhancementValidator().validate(output: " \n\t ", source: source)
        }
    }

    @Test("validator rejects normalized source equality")
    func validatorRejectsNormalizedSourceEquality() {
        let source = makeClip(
            preview: "Fallback is ignored.",
            extractedText: "  Goal: Ship.\t\n\n\nSteps:\t \n- Test.   \n"
        )

        #expect(throws: PromptEnhancementError.unchangedOutput("Source")) {
            try PromptEnhancementValidator().validate(
                output: "Goal: Ship.\n\nSteps:\n- Test.",
                source: source
            )
        }
    }

    @Test("validator rejects known model commentary wrapper")
    func validatorRejectsKnownCommentaryWrapper() {
        let source = makeClip(preview: "Draft a launch plan.", extractedText: "Draft a launch plan.")

        #expect(throws: PromptEnhancementError.commentaryWrapper("Source")) {
            try PromptEnhancementValidator().validate(
                output: "Here is the enhanced prompt:\n\nGoal: Draft a launch plan.",
                source: source
            )
        }
    }

    @Test("validator rejects explicit first-line wrappers with Markdown decoration")
    func validatorRejectsDecoratedFirstLineWrappers() {
        let source = makeClip(preview: "Draft a launch plan.", extractedText: "Draft a launch plan.")
        let wrappers = [
            "**Enhanced prompt:**",
            "### Enhanced prompt",
            "Below is the enhanced prompt:",
            "Here's the enhanced prompt:",
            "Here’s the enhanced prompt:"
        ]

        for wrapper in wrappers {
            #expect(throws: PromptEnhancementError.commentaryWrapper("Source")) {
                try PromptEnhancementValidator().validate(
                    output: "\(wrapper)\n\nGoal: Draft a launch plan.",
                    source: source
                )
            }
        }
    }

    @Test("validator allows legitimate first lines containing prompt")
    func validatorAllowsLegitimatePromptFirstLine() throws {
        let source = makeClip(
            preview: "Draft onboarding instructions.",
            extractedText: "Draft onboarding instructions."
        )
        let output = "### Prompt goal: Improve onboarding\n\nWrite concise instructions for new users."

        let validated = try PromptEnhancementValidator().validate(output: output, source: source)

        #expect(validated == output)
    }

    @Test("validator rejects sensitive generated output")
    func validatorRejectsSensitiveOutput() {
        let source = makeClip(preview: "Write setup instructions.", extractedText: "Write setup instructions.")

        #expect(throws: PromptEnhancementError.sensitiveOutput("Source")) {
            try PromptEnhancementValidator().validate(
                output: "Goal: Configure the service.\nOPENAI_API_KEY=sk-proj-1234567890abcdef1234567890abcdef",
                source: source
            )
        }
    }

    @Test("validator rejects every dropped observable value category")
    func validatorRejectsDroppedObservableValues() {
        let cases: [(source: String, output: String)] = [
            ("Retry exactly 42 times.", "Goal: Retry the operation."),
            ("Read https://example.com/docs.", "Goal: Read the documentation."),
            ("Email ada@example.com.", "Goal: Email the owner."),
            (#"Keep the literal "release candidate"."#, "Goal: Keep the named build."),
            ("Set request_id before launch.", "Goal: Set the request field before launch.")
        ]

        for item in cases {
            let source = makeClip(preview: item.source, extractedText: item.source)
            #expect(throws: PromptEnhancementError.droppedValue("Source")) {
                try PromptEnhancementValidator().validate(output: item.output, source: source)
            }
        }
    }

    @Test("validator rejects dropped percentage currency and numeric units")
    func validatorRejectsDroppedNumericUnits() {
        let cases: [(source: String, output: String)] = [
            ("Use a 42% threshold.", "Goal: Use a threshold of 42."),
            ("Keep the price at $19.99.", "Goal: Keep the price at 19.99."),
            ("Set the timeout to 250 ms.", "Goal: Set the timeout to 250."),
            ("Limit the archive to 5GB.", "Goal: Limit the archive to 5.")
        ]

        for item in cases {
            let source = makeClip(preview: item.source, extractedText: item.source)
            #expect(throws: PromptEnhancementError.droppedValue("Source")) {
                try PromptEnhancementValidator().validate(output: item.output, source: source)
            }
        }
    }

    @Test("validator allows rewrites preserving percentage currency and numeric units")
    func validatorAllowsPreservedNumericUnits() throws {
        let sourceText = "Use 42%, charge $19.99, wait 250 ms, and cap storage at 5GB."
        let source = makeClip(preview: sourceText, extractedText: sourceText)
        let output = "Goal: Cap storage at 5GB after waiting 250 ms. Use 42% and charge $19.99."

        let validated = try PromptEnhancementValidator().validate(output: output, source: source)

        #expect(validated == output)
    }

    @Test("validator rejects dropped command-line flags")
    func validatorRejectsDroppedCommandLineFlags() {
        let cases: [(source: String, output: String)] = [
            ("Run the command with --dry-run.", "Goal: Run the command as a dry run."),
            ("Enable verbose output with -v.", "Goal: Enable verbose output.")
        ]

        for item in cases {
            let source = makeClip(preview: item.source, extractedText: item.source)
            #expect(throws: PromptEnhancementError.droppedValue("Source")) {
                try PromptEnhancementValidator().validate(output: item.output, source: source)
            }
        }
    }

    @Test("validator rejects dropped grouped and value-bearing short options")
    func validatorRejectsDroppedGroupedShortOptions() {
        let cases: [(source: String, output: String)] = [
            ("Delete with -rf.", "Goal: Delete recursively and forcefully."),
            ("Enable modes with -abc.", "Goal: Enable all requested modes."),
            ("Compile with -O2.", "Goal: Compile with O2."),
            ("Define the symbol with -DDEBUG.", "Goal: Define the debug symbol.")
        ]

        for item in cases {
            let source = makeClip(preview: item.source, extractedText: item.source)
            #expect(throws: PromptEnhancementError.droppedValue("Source")) {
                try PromptEnhancementValidator().validate(output: item.output, source: source)
            }
        }
    }

    @Test("validator preserves grouped short options without freezing compounds or negative numbers")
    func validatorAllowsPreservedGroupedShortOptions() throws {
        let sourceText = "Run -rf -abc -O2 -DDEBUG, keep outcome-first copy, and compare -42 with -7."
        let source = makeClip(preview: sourceText, extractedText: sourceText)
        let output = "Goal: Compare -42 with -7. Run -DDEBUG, -O2, -abc, and -rf with concise copy."

        let validated = try PromptEnhancementValidator().validate(output: output, source: source)

        #expect(validated == output)
    }

    @Test("validator preserves flags without freezing ordinary hyphenated prose")
    func validatorAllowsPreservedFlagsAndRewrittenHyphenatedProse() throws {
        let sourceText = "Create an outcome-first command guide using --dry-run and -v."
        let source = makeClip(preview: sourceText, extractedText: sourceText)
        let output = "Goal: Write a concise command guide. Include -v and --dry-run."

        let validated = try PromptEnhancementValidator().validate(output: output, source: source)

        #expect(validated == output)
    }

    @Test("validator rejects dropped paths and dot-qualified names")
    func validatorRejectsDroppedPathsAndDotQualifiedNames() {
        let cases: [(source: String, output: String)] = [
            ("Load ./config/app.json.", "Goal: Load the app configuration."),
            ("Write output to /tmp/output.", "Goal: Write to the temporary output directory."),
            ("Update config.json.", "Goal: Update the configuration file."),
            ("Open example.com.", "Goal: Open the website."),
            ("Use com.example.ClipVault.", "Goal: Use the application bundle identifier.")
        ]

        for item in cases {
            let source = makeClip(preview: item.source, extractedText: item.source)
            #expect(throws: PromptEnhancementError.droppedValue("Source")) {
                try PromptEnhancementValidator().validate(output: item.output, source: source)
            }
        }
    }

    @Test("validator allows rewrites preserving paths and dot-qualified names")
    func validatorAllowsPreservedPathsAndDotQualifiedNames() throws {
        let sourceText = "Read ./config/app.json, update config.json, open example.com, write /tmp/output, and use com.example.ClipVault."
        let source = makeClip(preview: sourceText, extractedText: sourceText)
        let output = "Goal: Use com.example.ClipVault. Open example.com, read ./config/app.json, update config.json, then write /tmp/output."

        let validated = try PromptEnhancementValidator().validate(output: output, source: source)

        #expect(validated == output)
    }

    @Test("validator rejects a dropped home-relative path even when the file name remains")
    func validatorRejectsDroppedHomeRelativePath() {
        let sourceText = "Read ~/Library/archive/config.json."
        let source = makeClip(preview: sourceText, extractedText: sourceText)

        #expect(throws: PromptEnhancementError.droppedValue("Source")) {
            try PromptEnhancementValidator().validate(
                output: "Goal: Read config.json.",
                source: source
            )
        }
    }

    @Test("validator allows rewrites preserving every supported path root")
    func validatorAllowsPreservedPathRoots() throws {
        let sourceText = "Read ~/Library/archive/config.json, ./config/app.json, ../shared/defaults.json, and /tmp/output."
        let source = makeClip(preview: sourceText, extractedText: sourceText)
        let output = "Goal: Write /tmp/output after reading ../shared/defaults.json, ./config/app.json, and ~/Library/archive/config.json."

        let validated = try PromptEnhancementValidator().validate(output: output, source: source)

        #expect(validated == output)
    }

    @Test("validator allows slash-separated prose and common abbreviations to be rewritten")
    func validatorAllowsRewrittenSlashProseAndAbbreviations() throws {
        let sourceText = "Compare input/output and scheme://input/output formats, e.g. JSON, i.e. structured text, for U.S. users."
        let source = makeClip(preview: sourceText, extractedText: sourceText)
        let output = "Goal: Compare source and result formats using JSON examples for users in the United States."

        let validated = try PromptEnhancementValidator().validate(output: output, source: source)

        #expect(validated == output)
    }

    @Test("validator rejects URLs missing a balanced closing delimiter")
    func validatorRejectsDroppedBalancedURLClosers() {
        let cases: [(source: String, output: String)] = [
            ("Read https://example.com/docs_(v2).", "Goal: Read https://example.com/docs_(v2."),
            ("Read https://example.com/docs_[v2].", "Goal: Read https://example.com/docs_[v2."),
            ("Read https://example.com/docs_{v2}.", "Goal: Read https://example.com/docs_{v2.")
        ]

        for item in cases {
            let source = makeClip(preview: item.source, extractedText: item.source)
            #expect(throws: PromptEnhancementError.droppedValue("Source")) {
                try PromptEnhancementValidator().validate(output: item.output, source: source)
            }
        }
    }

    @Test("validator preserves balanced URL closers and ignores unmatched punctuation")
    func validatorHandlesURLTrailingPunctuation() throws {
        let sourceText = "Use https://example.com/a_(b), https://example.com/a_[b], https://example.com/a_{b}, and https://example.com/docs)."
        let source = makeClip(preview: sourceText, extractedText: sourceText)
        let output = "Goal: Use https://example.com/docs plus https://example.com/a_{b}, https://example.com/a_[b], and https://example.com/a_(b)."

        let validated = try PromptEnhancementValidator().validate(output: output, source: source)

        #expect(validated == output)
    }

    @Test("validator allows prose rewrites that preserve observable values")
    func validatorAllowsSafeProseRewrite() throws {
        let sourceText = #"Email ada@example.com about "release candidate" at https://example.com/docs after 42 retries using request_id."#
        let source = makeClip(preview: sourceText, extractedText: sourceText)
        let output = #"Goal: Contact ada@example.com after 42 retries. Preserve request_id and "release candidate". Reference https://example.com/docs."#

        let validated = try PromptEnhancementValidator().validate(output: "\n\(output)  \n", source: source)

        #expect(validated == output)
    }

    @Test("batch runner produces one draft per source in source order")
    func batchRunnerProducesSeparateDrafts() async throws {
        let enhancer = ScriptedPromptEnhancer(outputs: [
            "one": "Goal: Produce one result.",
            "two": "Goal: Produce two results."
        ])
        let runner = PromptEnhancementBatchRunner(enhancer: enhancer)
        let sources = [
            makeClip(id: "one", title: "One", preview: "one", extractedText: "one"),
            makeClip(id: "two", title: "Two", preview: "two", extractedText: "two")
        ]
        let recorder = PromptProgressRecorder()

        let drafts = try await runner.run(sources: sources) { update in
            await recorder.append(update)
        }
        let progress = await recorder.values()
        let calls = await enhancer.calls()

        #expect(drafts.map(\.sourceClipID) == ["one", "two"])
        #expect(drafts.map(\.enhancedText) == [
            "Goal: Produce one result.",
            "Goal: Produce two results."
        ])
        #expect(calls == ["one", "two"])
        #expect(progress == [
            PromptEnhancementProgress(current: 1, total: 2, sourceTitle: "One"),
            PromptEnhancementProgress(current: 2, total: 2, sourceTitle: "Two")
        ])
    }

    @Test("batch runner preserves the first source-scoped validation failure")
    func batchRunnerPreservesFirstValidationFailure() async {
        let enhancer = ScriptedPromptEnhancer(outputs: [
            "one": "Goal: Produce one result.",
            "two": "Here is the enhanced prompt:\n\nGoal: Produce two results.",
            "three": "Goal: Produce three results."
        ])
        let runner = PromptEnhancementBatchRunner(enhancer: enhancer)
        let sources = [
            makeClip(id: "one", title: "One", preview: "one", extractedText: "one"),
            makeClip(id: "two", title: "Two", preview: "two", extractedText: "two"),
            makeClip(id: "three", title: "Three", preview: "three", extractedText: "three")
        ]
        let recorder = PromptProgressRecorder()

        await #expect(throws: PromptEnhancementError.commentaryWrapper("Two")) {
            try await runner.run(sources: sources) { update in
                await recorder.append(update)
            }
        }

        #expect(await enhancer.calls() == ["one", "two"])
        #expect(await recorder.values().map(\.current) == [1, 2])
    }

    @Test("batch runner source-scopes unexpected enhancer failures")
    func batchRunnerSourceScopesUnexpectedEnhancerFailure() async {
        let rawDetail = "RAW_SCRIPTED_PROVIDER_DETAIL"
        let enhancer = ScriptedPromptEnhancer(
            outputs: [
                "one": "Goal: Produce one result.",
                "three": "Goal: Produce three results."
            ],
            failures: ["two": .rawFailure(rawDetail)]
        )
        let runner = PromptEnhancementBatchRunner(enhancer: enhancer)
        let sources = [
            makeClip(id: "one", title: "One", preview: "one", extractedText: "one"),
            makeClip(id: "two", title: "Two", preview: "two", extractedText: "two"),
            makeClip(id: "three", title: "Three", preview: "three", extractedText: "three")
        ]
        let recorder = PromptProgressRecorder()

        do {
            _ = try await runner.run(sources: sources) { update in
                await recorder.append(update)
            }
            Issue.record("Expected source-scoped generation failure")
        } catch let error as PromptEnhancementError {
            #expect(error == .generationFailed(
                sourceTitle: "Two",
                reason: "The prompt enhancer could not complete this source."
            ))
            #expect(!error.localizedDescription.contains(rawDetail))
        } catch {
            Issue.record("Expected PromptEnhancementError, got \(type(of: error))")
        }

        #expect(await enhancer.calls() == ["one", "two"])
        #expect(await recorder.values().map(\.current) == [1, 2])
    }

    @Test("batch runner preserves source-scoped generation failures")
    func batchRunnerPreservesSourceScopedGenerationFailure() async {
        let expected = PromptEnhancementError.generationFailed(
            sourceTitle: "Two",
            reason: "Apple Intelligence is busy. Try again in a moment."
        )
        let enhancer = ScriptedPromptEnhancer(
            outputs: [
                "one": "Goal: Produce one result.",
                "three": "Goal: Produce three results."
            ],
            sourceScopedFailures: ["two": expected]
        )
        let runner = PromptEnhancementBatchRunner(enhancer: enhancer)
        let sources = [
            makeClip(id: "one", title: "One", preview: "one", extractedText: "one"),
            makeClip(id: "two", title: "Two", preview: "two", extractedText: "two"),
            makeClip(id: "three", title: "Three", preview: "three", extractedText: "three")
        ]
        let recorder = PromptProgressRecorder()

        await #expect(throws: expected) {
            try await runner.run(sources: sources) { update in
                await recorder.append(update)
            }
        }

        #expect(await enhancer.calls() == ["one", "two"])
        #expect(await recorder.values().map(\.current) == [1, 2])
    }

    @Test("batch runner reports unavailability before generation")
    func batchRunnerReportsUnavailabilityBeforeGeneration() async {
        let availability = AIAvailability(
            isAvailable: false,
            reason: "Apple Intelligence is downloading."
        )
        let enhancer = ScriptedPromptEnhancer(
            outputs: ["one": "Goal: Produce one result."],
            availability: availability
        )
        let runner = PromptEnhancementBatchRunner(enhancer: enhancer)
        let source = makeClip(id: "one", title: "One", preview: "one", extractedText: "one")
        let recorder = PromptProgressRecorder()

        #expect(runner.availability() == availability)
        await #expect(
            throws: PromptEnhancementError.unavailable("Apple Intelligence is downloading.")
        ) {
            try await runner.run(sources: [source]) { update in
                await recorder.append(update)
            }
        }

        #expect(await enhancer.calls().isEmpty)
        #expect(await recorder.values().isEmpty)
    }

    @Test("batch runner rejects an empty selection")
    func batchRunnerRejectsEmptySelection() async {
        let enhancer = ScriptedPromptEnhancer(outputs: [:])
        let runner = PromptEnhancementBatchRunner(enhancer: enhancer)

        await #expect(throws: PromptEnhancementError.emptySelection) {
            try await runner.run(sources: []) { _ in }
        }

        #expect(await enhancer.calls().isEmpty)
    }

    @Test("batch runner preserves cancellation between sources")
    func batchRunnerPreservesCancellationBetweenSources() async {
        let enhancer = ScriptedPromptEnhancer(outputs: [
            "one": "Goal: Produce one result.",
            "two": "Goal: Produce two results."
        ])
        let runner = PromptEnhancementBatchRunner(enhancer: enhancer)
        let sources = [
            makeClip(id: "one", title: "One", preview: "one", extractedText: "one"),
            makeClip(id: "two", title: "Two", preview: "two", extractedText: "two")
        ]
        let recorder = PromptProgressRecorder()

        let task = Task {
            try await runner.run(sources: sources) { update in
                await recorder.append(update)
                if update.current == 1 {
                    withUnsafeCurrentTask { task in
                        task?.cancel()
                    }
                }
            }
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await enhancer.calls() == ["one"])
        #expect(await recorder.values().map(\.current) == [1])
    }

    @Test("batch runner preserves cancellation thrown by the enhancer")
    func batchRunnerPreservesEnhancerCancellation() async {
        let enhancer = ScriptedPromptEnhancer(
            outputs: [:],
            cancelledSourceIDs: ["one"]
        )
        let runner = PromptEnhancementBatchRunner(enhancer: enhancer)
        let source = makeClip(id: "one", title: "One", preview: "one", extractedText: "one")
        let recorder = PromptProgressRecorder()

        await #expect(throws: CancellationError.self) {
            try await runner.run(sources: [source]) { update in
                await recorder.append(update)
            }
        }

        #expect(await enhancer.calls() == ["one"])
        #expect(await recorder.values().map(\.current) == [1])
    }

    @Test("Foundation Models enhancer rejects empty source before model access")
    func foundationModelsEnhancerRejectsEmptySourceBeforeModelAccess() async {
        let source = makeClip(
            title: "Blank prompt",
            preview: " \n ",
            extractedText: "\t"
        )

        await #expect(throws: PromptEnhancementError.emptySource("Blank prompt")) {
            try await FoundationModelsPromptEnhancer().enhance(source)
        }
    }

    private func makeClip(
        id: String = "source",
        title: String = "Source",
        preview: String,
        extractedText: String
    ) -> Clip {
        Clip(
            id: id,
            kind: .text,
            title: title,
            preview: preview,
            extractedText: extractedText
        )
    }
}

private struct ScriptedPromptEnhancer: PromptEnhancing {
    let outputs: [String: String]
    let failures: [String: ScriptedPromptEnhancerError]
    let sourceScopedFailures: [String: PromptEnhancementError]
    let cancelledSourceIDs: Set<String>
    let availabilityValue: AIAvailability
    let callRecorder: PromptCallRecorder

    init(
        outputs: [String: String],
        failures: [String: ScriptedPromptEnhancerError] = [:],
        sourceScopedFailures: [String: PromptEnhancementError] = [:],
        cancelledSourceIDs: Set<String> = [],
        availability: AIAvailability = AIAvailability(isAvailable: true),
        callRecorder: PromptCallRecorder = PromptCallRecorder()
    ) {
        self.outputs = outputs
        self.failures = failures
        self.sourceScopedFailures = sourceScopedFailures
        self.cancelledSourceIDs = cancelledSourceIDs
        self.availabilityValue = availability
        self.callRecorder = callRecorder
    }

    func availability() -> AIAvailability {
        availabilityValue
    }

    func enhance(_ source: Clip) async throws -> String {
        await callRecorder.append(source.id)
        if cancelledSourceIDs.contains(source.id) {
            throw CancellationError()
        }
        if let sourceScopedFailure = sourceScopedFailures[source.id] {
            throw sourceScopedFailure
        }
        if let failure = failures[source.id] {
            throw failure
        }
        guard let output = outputs[source.id] else {
            throw ScriptedPromptEnhancerError.missingOutput(source.id)
        }
        return output
    }

    func calls() async -> [String] {
        await callRecorder.values()
    }
}

private enum ScriptedPromptEnhancerError: Error, LocalizedError, Equatable {
    case missingOutput(String)
    case rawFailure(String)

    var errorDescription: String? {
        switch self {
        case .missingOutput(let id): "Missing scripted output for \(id)."
        case .rawFailure(let detail): detail
        }
    }
}

private actor PromptCallRecorder {
    private var storage: [String] = []

    func append(_ value: String) {
        storage.append(value)
    }

    func values() -> [String] {
        storage
    }
}

private actor PromptProgressRecorder {
    private var storage: [PromptEnhancementProgress] = []

    func append(_ value: PromptEnhancementProgress) {
        storage.append(value)
    }

    func values() -> [PromptEnhancementProgress] {
        storage
    }
}
