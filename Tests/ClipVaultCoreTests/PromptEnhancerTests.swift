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
        #expect(!PromptEnhancementState.saving(total: 2).showsCancelControl)
        #expect(PromptEnhancementState.enhancing(
            current: 1,
            total: 2,
            sourceTitle: "One"
        ).showsCancelControl)
        #expect(PromptEnhancementState.success(count: 2).savedCount == 2)
        #expect(PromptEnhancementState.cancelled.savedCount == nil)
    }

    @MainActor
    @Test("workflow attributes mid-batch unavailability to the active source")
    func workflowAttributesMidBatchUnavailability() async {
        let enhancer = ScriptedPromptEnhancer(
            outputs: ["one": "Goal: Produce one result."],
            sourceScopedFailures: [
                "two": .unavailable("Apple Intelligence became unavailable.")
            ]
        )
        let workflow = PromptEnhancementWorkflow(
            runner: PromptEnhancementBatchRunner(enhancer: enhancer)
        )
        let sources = [
            makeClip(id: "one", title: "One", preview: "one", extractedText: "one"),
            makeClip(id: "two", title: "Two", preview: "two", extractedText: "two")
        ]
        var publishedStates: [PromptEnhancementState] = []

        let outcome = await workflow.run(
            sources: sources,
            save: { _ in
                Issue.record("Save must not run after generation failure")
                return 0
            },
            reload: {
                Issue.record("Reload must not run after generation failure")
                return false
            },
            isActive: { true },
            publish: { publishedStates.append($0) },
            logError: { _ in }
        )

        let expectedMessage = "Couldn’t enhance “Two.” Apple Intelligence became unavailable. Nothing was saved."
        #expect(outcome == .failedBeforeSave(sourceTitle: "Two", message: expectedMessage))
        #expect(publishedStates.last == .failed(sourceTitle: "Two", message: expectedMessage))
    }

    @MainActor
    @Test("workflow keeps preflight unavailability batch-wide")
    func workflowKeepsPreflightUnavailabilityBatchWide() async {
        let reason = "Apple Intelligence is downloading."
        let enhancer = ScriptedPromptEnhancer(
            outputs: [:],
            availability: AIAvailability(isAvailable: false, reason: reason)
        )
        let workflow = PromptEnhancementWorkflow(
            runner: PromptEnhancementBatchRunner(enhancer: enhancer)
        )
        let source = makeClip(
            id: "one",
            title: "One",
            preview: "one",
            extractedText: "one"
        )
        var publishedStates: [PromptEnhancementState] = []

        let outcome = await workflow.run(
            sources: [source],
            save: { _ in 0 },
            reload: { false },
            isActive: { true },
            publish: { publishedStates.append($0) },
            logError: { _ in }
        )

        let expectedMessage = "\(reason) Nothing was saved."
        #expect(outcome == .failedBeforeSave(sourceTitle: nil, message: expectedMessage))
        #expect(publishedStates == [.failed(sourceTitle: nil, message: expectedMessage)])
    }

    @MainActor
    @Test("workflow cancellation before save invokes save zero times")
    func workflowCancellationBeforeSaveSkipsPersistence() async {
        let enhancer = ScriptedPromptEnhancer(
            outputs: [:],
            cancelledSourceIDs: ["one"]
        )
        let workflow = PromptEnhancementWorkflow(
            runner: PromptEnhancementBatchRunner(enhancer: enhancer)
        )
        let source = makeClip(
            id: "one",
            title: "One",
            preview: "one",
            extractedText: "one"
        )
        var saveCalls = 0
        var publishedStates: [PromptEnhancementState] = []

        let outcome = await workflow.run(
            sources: [source],
            save: { _ in
                saveCalls += 1
                return 1
            },
            reload: { true },
            isActive: { true },
            publish: { publishedStates.append($0) },
            logError: { _ in }
        )

        #expect(outcome == .cancelled)
        #expect(saveCalls == 0)
        #expect(publishedStates == [
            .enhancing(current: 1, total: 1, sourceTitle: "One"),
            .cancelled
        ])
    }

    @MainActor
    @Test("workflow success saves and reloads exactly once")
    func workflowSuccessSavesAndReloadsOnce() async {
        let enhancer = ScriptedPromptEnhancer(
            outputs: ["one": "Goal: Produce one result."]
        )
        let workflow = PromptEnhancementWorkflow(
            runner: PromptEnhancementBatchRunner(enhancer: enhancer)
        )
        let source = makeClip(
            id: "one",
            title: "One",
            preview: "one",
            extractedText: "one"
        )
        var saveCalls = 0
        var reloadCalls = 0
        var publishedStates: [PromptEnhancementState] = []

        let outcome = await workflow.run(
            sources: [source],
            save: { drafts in
                saveCalls += 1
                #expect(drafts.map(\.sourceClipID) == ["one"])
                return drafts.count
            },
            reload: {
                reloadCalls += 1
                return true
            },
            isActive: { true },
            publish: { publishedStates.append($0) },
            logError: { _ in }
        )

        #expect(outcome == .saved(count: 1))
        #expect(saveCalls == 1)
        #expect(reloadCalls == 1)
        #expect(publishedStates == [
            .enhancing(current: 1, total: 1, sourceTitle: "One"),
            .saving(total: 1),
            .success(count: 1)
        ])
    }

    @MainActor
    @Test("Saving is observable before a noncancelable atomic commit")
    func workflowSuspendsAfterSavingAndCommitsAfterCancellation() async {
        let gate = PromptCommitBoundaryGate()
        let enhancer = ScriptedPromptEnhancer(
            outputs: ["one": "Goal: Produce one result."]
        )
        let workflow = PromptEnhancementWorkflow(
            runner: PromptEnhancementBatchRunner(enhancer: enhancer),
            commitBoundary: PromptEnhancementCommitBoundary {
                await gate.suspendUntilReleased()
            }
        )
        let source = makeClip(
            id: "one",
            title: "One",
            preview: "one",
            extractedText: "one"
        )
        var saveCalls = 0
        var publishedStates: [PromptEnhancementState] = []

        let task = Task { @MainActor in
            await workflow.run(
                sources: [source],
                save: { drafts in
                    saveCalls += 1
                    return drafts.count
                },
                reload: { true },
                isActive: { true },
                publish: { publishedStates.append($0) },
                logError: { _ in }
            )
        }

        await gate.waitUntilSuspended()
        #expect(publishedStates.last == .saving(total: 1))
        #expect(!PromptEnhancementState.saving(total: 1).allowsCancellation)
        #expect(saveCalls == 0)

        task.cancel()
        await gate.release()
        let outcome = await task.value

        #expect(outcome == .saved(count: 1))
        #expect(saveCalls == 1)
        #expect(publishedStates.last == .success(count: 1))
    }

    @MainActor
    @Test("workflow atomic save failure skips reload and reports zero saved")
    func workflowAtomicSaveFailureSkipsReload() async {
        let enhancer = ScriptedPromptEnhancer(
            outputs: ["one": "Goal: Produce one result."]
        )
        let workflow = PromptEnhancementWorkflow(
            runner: PromptEnhancementBatchRunner(enhancer: enhancer)
        )
        let source = makeClip(
            id: "one",
            title: "One",
            preview: "one",
            extractedText: "one"
        )
        var reloadCalls = 0
        var publishedStates: [PromptEnhancementState] = []

        let outcome = await workflow.run(
            sources: [source],
            save: { _ in
                throw GeneratedPromptStoreError.batchSaveFailed(["one"])
            },
            reload: {
                reloadCalls += 1
                return true
            },
            isActive: { true },
            publish: { publishedStates.append($0) },
            logError: { _ in }
        )

        let expectedMessage = "The enhanced prompts could not be saved. Nothing was saved."
        #expect(outcome == .atomicSaveFailed(sourceTitle: nil, message: expectedMessage))
        #expect(reloadCalls == 0)
        #expect(publishedStates == [
            .enhancing(current: 1, total: 1, sourceTitle: "One"),
            .saving(total: 1),
            .failed(sourceTitle: nil, message: expectedMessage)
        ])
    }

    @MainActor
    @Test("workflow maps source-scoped store IDs to safe source titles")
    func workflowMapsStoreSourceIDToSafeTitle() async {
        let enhancer = ScriptedPromptEnhancer(
            outputs: ["one": "Goal: Produce one result."]
        )
        let workflow = PromptEnhancementWorkflow(
            runner: PromptEnhancementBatchRunner(enhancer: enhancer)
        )
        let source = makeClip(
            id: "one",
            title: "One",
            preview: "one",
            extractedText: "one"
        )

        let outcome = await workflow.run(
            sources: [source],
            save: { _ in
                throw GeneratedPromptStoreError.encryptionFailed("one")
            },
            reload: { true },
            isActive: { true },
            publish: { _ in },
            logError: { _ in }
        )

        let message = "Couldn’t enhance “One.” An enhanced prompt could not be secured for saving. Nothing was saved."
        #expect(outcome == .atomicSaveFailed(sourceTitle: "One", message: message))
    }

    @MainActor
    @Test("workflow reload failure reports persisted count without zero-save copy")
    func workflowReloadFailureReportsPersistedCount() async {
        let enhancer = ScriptedPromptEnhancer(outputs: [
            "one": "Goal: Produce one result.",
            "two": "Goal: Produce two results."
        ])
        let workflow = PromptEnhancementWorkflow(
            runner: PromptEnhancementBatchRunner(enhancer: enhancer)
        )
        let sources = [
            makeClip(id: "one", title: "One", preview: "one", extractedText: "one"),
            makeClip(id: "two", title: "Two", preview: "two", extractedText: "two")
        ]
        var publishedStates: [PromptEnhancementState] = []
        var reloadCalls = 0

        let outcome = await workflow.run(
            sources: sources,
            save: { $0.count },
            reload: {
                reloadCalls += 1
                return false
            },
            isActive: { true },
            publish: { publishedStates.append($0) },
            logError: { _ in }
        )

        let message = "2 enhanced prompts were saved, but ClipVault couldn’t refresh the workspace."
        #expect(outcome == .savedButReloadFailed(count: 2, message: message))
        #expect(reloadCalls == 1)
        #expect(!message.contains("Nothing was saved"))
        #expect(publishedStates == [
            .enhancing(current: 1, total: 2, sourceTitle: "One"),
            .enhancing(current: 2, total: 2, sourceTitle: "Two"),
            .saving(total: 2),
            .failed(sourceTitle: nil, message: message)
        ])
    }

    @MainActor
    @Test("workflow sanitizes unexpected runner errors")
    func workflowSanitizesUnexpectedErrors() async {
        let rawDetail = "RAW_WORKFLOW_PROVIDER_DETAIL"
        let enhancer = ScriptedPromptEnhancer(
            outputs: [:],
            failures: ["one": .rawFailure(rawDetail)]
        )
        let workflow = PromptEnhancementWorkflow(
            runner: PromptEnhancementBatchRunner(enhancer: enhancer)
        )
        let source = makeClip(
            id: "one",
            title: "One",
            preview: "one",
            extractedText: "one"
        )

        let outcome = await workflow.run(
            sources: [source],
            save: { _ in 0 },
            reload: { false },
            isActive: { true },
            publish: { _ in },
            logError: { _ in }
        )

        guard case .failedBeforeSave(let sourceTitle, let message) = outcome else {
            Issue.record("Expected a pre-save workflow failure")
            return
        }
        #expect(sourceTitle == "One")
        #expect(message == "Couldn’t enhance “One.” The prompt enhancer could not complete this source. Nothing was saved.")
        #expect(!message.contains(rawDetail))
    }

    @MainActor
    @Test("workflow gates inactive state publication before persistence")
    func workflowGatesInactivePublication() async {
        let enhancer = ScriptedPromptEnhancer(outputs: [
            "one": "Goal: Produce one result.",
            "two": "Goal: Produce two results."
        ])
        let workflow = PromptEnhancementWorkflow(
            runner: PromptEnhancementBatchRunner(enhancer: enhancer)
        )
        let sources = [
            makeClip(id: "one", title: "One", preview: "one", extractedText: "one"),
            makeClip(id: "two", title: "Two", preview: "two", extractedText: "two")
        ]
        var isActive = true
        var saveCalls = 0
        var publishedStates: [PromptEnhancementState] = []

        let outcome = await workflow.run(
            sources: sources,
            save: { _ in
                saveCalls += 1
                return 2
            },
            reload: { true },
            isActive: { isActive },
            publish: { state in
                publishedStates.append(state)
                if case .enhancing = state {
                    isActive = false
                }
            },
            logError: { _ in }
        )

        #expect(outcome == .cancelled)
        #expect(saveCalls == 0)
        #expect(publishedStates == [
            .enhancing(current: 1, total: 2, sourceTitle: "One")
        ])
    }

    @Test("selection restoration keeps only surviving pre-run sources")
    func selectionRestorationExcludesGeneratedClips() {
        let snapshot = PromptEnhancementSelectionSnapshot(
            currentClipID: "missing-current",
            selectedClipIDs: ["one", "missing-selected"],
            sourceIDs: ["one", "two"]
        )

        let restored = snapshot.restoring(
            existingClipIDs: ["one", "two", "generated"]
        )

        #expect(restored == PromptEnhancementSelection(
            currentClipID: "one",
            selectedClipIDs: ["one"]
        ))
        #expect(restored.currentClipID != "generated")
        #expect(!restored.selectedClipIDs.contains("generated"))
    }

    @Test("selection restoration preserves a surviving current clip outside the sources")
    func selectionRestorationPreservesSurvivingOpenClip() {
        let snapshot = PromptEnhancementSelectionSnapshot(
            currentClipID: "open",
            selectedClipIDs: ["one", "two"],
            sourceIDs: ["one", "two"]
        )

        let restored = snapshot.restoring(
            existingClipIDs: ["open", "one", "two", "generated"]
        )

        #expect(restored == PromptEnhancementSelection(
            currentClipID: "open",
            selectedClipIDs: ["one", "two"]
        ))
        #expect(!restored.selectedClipIDs.contains("generated"))
    }

    @Test("Open Prompts eligibility is success-only")
    func openPromptsEligibilityIsSuccessOnly() {
        #expect(PromptEnhancementState.success(count: 1).canOpenPrompts)
        #expect(!PromptEnhancementState.idle.canOpenPrompts)
        #expect(!PromptEnhancementState.enhancing(
            current: 1,
            total: 1,
            sourceTitle: "One"
        ).canOpenPrompts)
        #expect(!PromptEnhancementState.saving(total: 1).canOpenPrompts)
        #expect(!PromptEnhancementState.failed(sourceTitle: nil, message: "Failure").canOpenPrompts)
        #expect(!PromptEnhancementState.cancelled.canOpenPrompts)
    }

    @Test("active prompt states block ordinary and new prompt operations")
    func activePromptStatesBlockAIOperations() {
        #expect(PromptEnhancementState.enhancing(
            current: 1,
            total: 1,
            sourceTitle: "One"
        ).blocksAIOperations)
        #expect(PromptEnhancementState.saving(total: 1).blocksAIOperations)
        #expect(!PromptEnhancementState.idle.blocksAIOperations)
        #expect(!PromptEnhancementState.success(count: 1).blocksAIOperations)
        #expect(!PromptEnhancementState.failed(
            sourceTitle: nil,
            message: "Failure"
        ).blocksAIOperations)
        #expect(!PromptEnhancementState.cancelled.blocksAIOperations)
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

    @Test("validator does not treat contraction apostrophes as quoted literals")
    func validatorAllowsRewritingContractions() throws {
        let sourceText = "Don't rewrite the user's request when it isn't ambiguous."
        let source = makeClip(preview: sourceText, extractedText: sourceText)
        let output = "Goal: Preserve the request whenever it is clear; do not rewrite what the user asked for."

        let validated = try PromptEnhancementValidator().validate(output: output, source: source)

        #expect(validated == output)
    }

    @Test("validator rejects dropping a required bare output format")
    func validatorRejectsDroppedRequiredOutputFormats() {
        for format in ["JSON", "YAML", "CSV", "Markdown"] {
            let sourceText = "Return the response as \(format)."
            let source = makeClip(preview: sourceText, extractedText: sourceText)

            #expect(throws: PromptEnhancementError.droppedValue("Source")) {
                try PromptEnhancementValidator().validate(
                    output: "Goal: Return the response as structured data.",
                    source: source
                )
            }
        }
    }

    @Test("validator preserves required formats case-insensitively")
    func validatorAllowsRequiredOutputFormatCasingRewrite() throws {
        let sourceText = "Required output formats: JSON, YAML, CSV, and Markdown."
        let source = makeClip(preview: sourceText, extractedText: sourceText)
        let output = "Goal: Return markdown, csv, yaml, and json."

        let validated = try PromptEnhancementValidator().validate(output: output, source: source)

        #expect(validated == output)
    }

    @Test("validator recognizes local required-format obligation forms")
    func validatorRejectsDroppedLocallyObligatedFormats() {
        for format in ["JSON", "YAML", "CSV", "Markdown"] {
            let sources = [
                format + " only.",
                "The output must be " + format + ".",
                "Answer in " + format + ".",
                "Return the result in " + format + "."
            ]

            for sourceText in sources {
                let source = makeClip(preview: sourceText, extractedText: sourceText)
                #expect(throws: PromptEnhancementError.droppedValue("Source")) {
                    try PromptEnhancementValidator().validate(
                        output: "Goal: Return structured data only.",
                        source: source
                    )
                }
            }
        }
    }

    @Test("validator preserves local required-format obligations case-insensitively")
    func validatorAllowsLocallyObligatedFormatCasingRewrite() throws {
        for format in ["JSON", "YAML", "CSV", "Markdown"] {
            let sources = [
                format + " only.",
                "The output must be " + format + ".",
                "Answer in " + format + ".",
                "Return the result in " + format + "."
            ]

            for sourceText in sources {
                let source = makeClip(preview: sourceText, extractedText: sourceText)
                let output = "Goal: Return " + format.lowercased() + " only."

                let validated = try PromptEnhancementValidator().validate(
                    output: output,
                    source: source
                )

                #expect(validated == output)
            }
        }
    }

    @Test("validator allows rewriting nonrequired format references")
    func validatorAllowsRewritingNonrequiredFormatReferences() throws {
        let cases = [
            ("Compare JSON parsers.", "Goal: Compare structured-data parser approaches."),
            ("Compare JSON and YAML parser tradeoffs.", "Goal: Compare two structured-data parser approaches.")
        ]

        for item in cases {
            let source = makeClip(preview: item.0, extractedText: item.0)
            let validated = try PromptEnhancementValidator().validate(output: item.1, source: source)

            #expect(validated == item.1)
        }
    }

    @Test("validator rejects dropping curly-quoted and backtick literals")
    func validatorRejectsDroppedCurlyAndBacktickLiterals() {
        let cases: [(source: String, output: String)] = [
            ("Keep the literal “release candidate” exactly.", "Goal: Keep the named build exactly."),
            ("Keep the literal ‘launch owner’ exactly.", "Goal: Keep the named person exactly."),
            ("Use the literal `strict mode`.", "Goal: Use strict behavior.")
        ]

        for item in cases {
            let source = makeClip(preview: item.source, extractedText: item.source)
            #expect(throws: PromptEnhancementError.droppedValue("Source")) {
                try PromptEnhancementValidator().validate(output: item.output, source: source)
            }
        }
    }

    @Test("validator rejects dropping context-identified kebab-case identifiers")
    func validatorRejectsDroppedKebabCaseIdentifiers() {
        let cases: [(source: String, output: String)] = [
            ("Set the field request-id before launch.", "Goal: Set the request field before launch."),
            ("Preserve the header x-request-id.", "Goal: Preserve the request identifier header."),
            ("Read the configuration key max-retries.", "Goal: Read the retry limit configuration."),
            ("Preserve api-version.", "Goal: Preserve the API version."),
            ("Preserve content-type.", "Goal: Preserve the content type.")
        ]

        for item in cases {
            let source = makeClip(preview: item.source, extractedText: item.source)
            #expect(throws: PromptEnhancementError.droppedValue("Source")) {
                try PromptEnhancementValidator().validate(output: item.output, source: source)
            }
        }
    }

    @Test("validator binds kebab identifier context to the adjacent token")
    func validatorAllowsRewritingDistantHyphenatedProse() throws {
        let sourceText = "Set field request-id in an outcome-first response."
        let source = makeClip(preview: sourceText, extractedText: sourceText)
        let output = "Goal: Set request-id in a response led by the desired outcome."

        let validated = try PromptEnhancementValidator().validate(output: output, source: source)

        #expect(validated == output)
        #expect(throws: PromptEnhancementError.droppedValue("Source")) {
            try PromptEnhancementValidator().validate(
                output: "Goal: Set the request identifier in a response led by the desired outcome.",
                source: source
            )
        }
    }

    @Test("validator locally binds two kebab identifiers without freezing ordinary prose")
    func validatorLocallyBindsTwoKebabIdentifiers() throws {
        let sourceText = "Set field request-id and header cache-control in a user-friendly response."
        let source = makeClip(preview: sourceText, extractedText: sourceText)
        let output = "Goal: Set request-id and cache-control in an approachable response."

        let validated = try PromptEnhancementValidator().validate(output: output, source: source)

        #expect(validated == output)
        #expect(throws: PromptEnhancementError.droppedValue("Source")) {
            try PromptEnhancementValidator().validate(
                output: "Goal: Set request-id in an approachable response.",
                source: source
            )
        }
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

private actor PromptCommitBoundaryGate {
    private var isSuspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendUntilReleased() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else {
            return
        }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
