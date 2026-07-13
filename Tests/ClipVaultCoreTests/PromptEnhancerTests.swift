import Testing
@testable import ClipVaultCore

@Suite("Prompt enhancer")
struct PromptEnhancerTests {
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

    @Test("batch runner stops at the first source failure")
    func batchRunnerStopsAtFirstFailure() async {
        let enhancer = ScriptedPromptEnhancer(outputs: [
            "one": "Goal: Produce one result.",
            "three": "Goal: Produce three results."
        ])
        let runner = PromptEnhancementBatchRunner(enhancer: enhancer)
        let sources = [
            makeClip(id: "one", title: "One", preview: "one", extractedText: "one"),
            makeClip(id: "two", title: "Two", preview: "two", extractedText: "two"),
            makeClip(id: "three", title: "Three", preview: "three", extractedText: "three")
        ]
        let recorder = PromptProgressRecorder()

        await #expect(throws: ScriptedPromptEnhancerError.missingOutput("two")) {
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
    let availabilityValue: AIAvailability
    let callRecorder: PromptCallRecorder

    init(
        outputs: [String: String],
        availability: AIAvailability = AIAvailability(isAvailable: true),
        callRecorder: PromptCallRecorder = PromptCallRecorder()
    ) {
        self.outputs = outputs
        self.availabilityValue = availability
        self.callRecorder = callRecorder
    }

    func availability() -> AIAvailability {
        availabilityValue
    }

    func enhance(_ source: Clip) async throws -> String {
        await callRecorder.append(source.id)
        guard let output = outputs[source.id] else {
            throw ScriptedPromptEnhancerError.missingOutput(source.id)
        }
        return output
    }

    func calls() async -> [String] {
        await callRecorder.values()
    }
}

private enum ScriptedPromptEnhancerError: Error, Equatable {
    case missingOutput(String)
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
